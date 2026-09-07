#!/usr/bin/env python3
import importlib.util
import json
import os
import unittest

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "van", os.path.join(_here, "verify-absorbed-notices.py"))
van = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(van)
an = van.an

FOOTPRINT_DOOR = {
    "target": "estate.footprint", "key": "id",
    "required": ["id", "kind", "target", "host", "owner", "status", "retire", "notes"],
    "enums": {"status": ["live", "retiring", "dead"]},
}
FOOTPRINT = {
    "id": "spawn-here-symlinks", "kind": "path", "target": "/home/zach/.local/bin/spawn-here",
    "host": "mandark", "owner": "senechal", "status": "live",
    "retire": "remedies/window-spawn-desktop.sh disable", "notes": "installed by the remedy",
}

TASTE_DOOR = {
    "target": "estate.taste", "key": "id",
    "required": ["id", "file", "status", "hosts"],
    "enums": {"status": ["enabled", "disabled"]},
}
TASTE_FIELDS = {"id": "colorhash-prompt", "file": ".bashrc", "status": "enabled", "hosts": "mandark"}

DOORS = {"footprint": FOOTPRINT_DOOR, "taste": TASTE_DOOR}


def close_comment(door, fields):
    return "Absorbed into `%s` as `%s`. Closing IS the acknowledgement." % (
        door["target"], an.door_key_display(door, fields))


def issue(n, payload, body=None, comments=()):
    if body is None:
        body = "prose above\n\n```senechal-door\n%s\n```\n" % json.dumps(payload)
    return {"number": n, "title": "t", "body": body,
            "comments": [{"body": c} for c in comments]}


class VerifyAbsorbedTest(unittest.TestCase):
    def setUp(self):
        self.fleet = {"estate": {"footprint": []}}

    def run_main(self, issues, doors=None, fleet=None):
        return van.main(issues=issues, doors=doors or DOORS, fleet=fleet or self.fleet)

    def test_closed_filing_that_landed_is_silent(self):
        self.fleet = {"estate": {"footprint": [FOOTPRINT]}}
        rc = self.run_main([issue(1, {"door": "footprint", "fields": FOOTPRINT})])
        self.assertEqual(rc, van.RC_PASS)

    def test_closed_filing_that_never_landed_is_reported(self):
        rc = self.run_main([issue(1, {"door": "footprint", "fields": FOOTPRINT},
                                   comments=[close_comment(FOOTPRINT_DOOR, FOOTPRINT)])])
        self.assertEqual(rc, van.RC_FAIL)

    def test_revisited_filing_is_reported_separately_not_as_missing(self):
        rc = self.run_main([issue(1, {"door": "footprint", "fields": FOOTPRINT},
                                   comments=[close_comment(FOOTPRINT_DOOR, FOOTPRINT), "REJECTED, actually"])])
        self.assertEqual(rc, van.RC_WARN)

    def test_closed_some_other_way_is_not_flagged_at_all(self):
        rc = self.run_main([issue(1, {"door": "footprint", "fields": FOOTPRINT},
                                   comments=["REJECTED -- the fact this recorded turned out false"])])
        self.assertEqual(rc, van.RC_PASS)

    def test_missing_and_revisit_together_missing_wins(self):
        revisited_fields = dict(FOOTPRINT, id="revisited")
        never_landed_fields = dict(FOOTPRINT, id="never-landed")
        rc = self.run_main([
            issue(1, {"door": "footprint", "fields": revisited_fields},
                  comments=[close_comment(FOOTPRINT_DOOR, revisited_fields), "reversed"]),
            issue(2, {"door": "footprint", "fields": never_landed_fields},
                  comments=[close_comment(FOOTPRINT_DOOR, never_landed_fields)]),
        ])
        self.assertEqual(rc, van.RC_FAIL)

    def test_empty_queue_passes(self):
        self.assertEqual(self.run_main([]), van.RC_PASS)

    def test_a_landed_and_a_lost_filing_together_still_fails(self):
        landed = dict(FOOTPRINT, id="landed-one")
        lost = dict(FOOTPRINT, id="lost-one")
        self.fleet = {"estate": {"footprint": [landed]}}
        rc = self.run_main([
            issue(1, {"door": "footprint", "fields": landed}),
            issue(2, {"door": "footprint", "fields": lost},
                  comments=[close_comment(FOOTPRINT_DOOR, lost)]),
        ])
        self.assertEqual(rc, van.RC_FAIL)

    def test_prose_only_closed_issue_is_not_counted_as_lost(self):
        rc = self.run_main([issue(9, None, body="just a paragraph, closed for some other reason")])
        self.assertEqual(rc, van.RC_PASS)

    def test_unknown_door_is_not_counted_as_lost(self):
        rc = self.run_main([issue(1, {"door": "vibes", "fields": FOOTPRINT})])
        self.assertEqual(rc, van.RC_PASS)

    def test_taste_targeted_filing_is_skipped_not_flagged(self):
        rc = self.run_main([issue(1, {"door": "taste", "fields": TASTE_FIELDS})])
        self.assertEqual(rc, van.RC_PASS)

    def test_a_row_that_differs_only_by_non_key_fields_still_registers(self):
        landed = dict(FOOTPRINT, notes="hand-edited after landing")
        self.fleet = {"estate": {"footprint": [landed]}}
        rc = self.run_main([issue(1, {"door": "footprint", "fields": FOOTPRINT})])
        self.assertEqual(rc, van.RC_PASS)

    def test_unreadable_registry_is_could_not_look(self):
        orig = an.registry_path
        an.registry_path = lambda: "/nonexistent/senechal-registry.json"
        try:
            rc = van.main(issues=[], doors=DOORS, fleet=None)
        finally:
            an.registry_path = orig
        self.assertEqual(rc, van.RC_INCOMPLETE)

    def test_unreadable_doors_file_is_could_not_look(self):
        orig = an.doors_path
        an.doors_path = lambda: "/nonexistent/front-doors.json"
        try:
            rc = van.main(issues=[], doors=None, fleet=self.fleet)
        finally:
            an.doors_path = orig
        self.assertEqual(rc, van.RC_INCOMPLETE)


if __name__ == "__main__":
    unittest.main()
