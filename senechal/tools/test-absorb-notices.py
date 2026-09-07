#!/usr/bin/env python3
"""Suite for tools/absorb-notices.py.

Never touches the real config, the real registry, or GitHub: issues (and,
where a test needs a non-fleet door, doors) are injected as objects, and
both stores are TemporaryDirectory files -- same rule test_senechal.py
follows.

The properties that matter: a well-formed filing lands in the RIGHT store
(fleet -> registry, taste -> live config, only on the taste host), a malformed
one is rejected not half-absorbed, an existing entry is never overwritten, an
undeliverable taste filing is deferred not dropped, "could not look" never
reads as "nothing pending", and an amend door corrects a row only by quoting
the value it replaces (kind/notes are observations, owner/addr/reach/expect
policy).
"""
import importlib.util
import json
import os
import sys
import tempfile
import unittest

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("an", os.path.join(_here, "absorb-notices.py"))
an = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(an)

FOOTPRINT = {
    "id": "spawn-here-symlinks", "kind": "path", "target": "/home/zach/.local/bin/spawn-here",
    "host": "mandark", "owner": "senechal", "status": "live",
    "retire": "remedies/window-spawn-desktop.sh disable", "notes": "installed by the remedy",
}

CRONTAB = {
    "tag": "ecosim:ecosim-sensor:TICK", "host": "monkey", "account": "ecosim",
    "owner": "ecosim", "schedule": "7,37 * * * *",
    "command": "ECOSIM_SENSOR_BIN=/usr/local/bin/sonde /home/ecosim/bin/ecosim-sensor-tick.sh",
    "status": "live", "retire": "crontab -l | grep -v 'ecosim:ecosim-sensor:TICK' | crontab -",
    "notes": "hf7y/ecosim#48",
}

# A synthetic door on a real TASTE key: no real door exercises that path.
TASTE_DOOR = {
    "target": "estate.taste", "key": "id",
    "required": ["id", "file", "status", "hosts"],
    "enums": {"status": ["enabled", "disabled"]},
}
TASTE_FIELDS = {"id": "colorhash-prompt", "file": ".bashrc", "status": "enabled", "hosts": "mandark"}

# A synthetic door on a key CONFIG_KEYS does not classify: defaults to fleet.
UNCLASSIFIED_DOOR = {
    "target": "nonexistent.wildcard", "key": "id",
    "required": ["id"], "enums": {},
}


DEVICE = {
    "name": "dexter", "kind": "windows-mini-pc", "addr": "dexter.local", "reach": "ssh",
    "expect": "always-on", "owner": "crt", "notes": "hosts the monkey VM",
}

CORRECTION = {
    "name": "dexter", "field": "notes", "was": "hosts the monkey VM",
    "now": "a Minisforum Venus mini-PC acting as a SERVER; its Hyper-V holds AMD-V",
    "evidence": "monkey's VBox.log: 'fall back to NEM: AMD-V is not available', 2026-08-29",
}

FOOTPRINT_CORRECTION = {
    "id": "spawn-here-symlinks", "field": "status", "was": "live", "now": "retiring",
    "evidence": "remedies/window-spawn-desktop.sh disable was run, 2026-09-04",
}

CRONTAB_CORRECTION = {
    "host": "monkey", "account": "ecosim", "tag": "ecosim:ecosim-sensor:TICK",
    "field": "status", "was": "live", "now": "retired",
    "evidence": "dose ecosim --park then dose ecosim --apply on monkey, 2026-09-04",
}


def issue(n, payload):
    body = "prose above\n\n```senechal-door\n%s\n```\n" % json.dumps(payload)
    return {"number": n, "title": "t", "body": body}


class AbsorbTest(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.cfg = os.path.join(self._td.name, "senechal.json")
        self.registry = os.path.join(self._td.name, "senechal-registry.json")
        self.write_config({"estate": {"taste": []}})
        self.write_registry({"estate": {"footprint": [], "devices": [], "crontab": []}})
        # Deterministic unless a test overrides it.
        os.environ["SENECHAL_HOSTNAME"] = "mandark"

    def tearDown(self):
        self._td.cleanup()
        os.environ.pop("SENECHAL_HOSTNAME", None)
        os.environ.pop("SENECHAL_TASTE_HOST", None)

    def write_config(self, obj):
        with open(self.cfg, "w") as fh:
            json.dump(obj, fh)

    def write_registry(self, obj):
        with open(self.registry, "w") as fh:
            json.dump(obj, fh)

    def read_config(self):
        with open(self.cfg) as fh:
            return json.load(fh)

    def read_registry(self):
        with open(self.registry) as fh:
            return json.load(fh)

    def run_main(self, issues, *flags, doors=None):
        return an.main(["--config", self.cfg, "--registry", self.registry, *flags],
                        issues=issues, doors=doors)

    # -- fleet doors land in the registry, never the live config ---------

    def test_write_lands_the_footprint_filing_in_the_registry(self):
        rc = self.run_main([issue(1, {"door": "footprint", "fields": FOOTPRINT})], "--write")
        self.assertEqual(rc, an.RC_PASS)
        self.assertEqual(self.read_registry()["estate"]["footprint"], [FOOTPRINT])
        self.assertEqual(self.read_config()["estate"]["taste"], [])

    def test_dry_run_warns_and_writes_nothing(self):
        rc = self.run_main([issue(1, {"door": "footprint", "fields": FOOTPRINT})])
        self.assertEqual(rc, an.RC_WARN)
        self.assertEqual(self.read_registry()["estate"]["footprint"], [])

    def test_empty_queue_passes(self):
        self.assertEqual(self.run_main([]), an.RC_PASS)

    def test_missing_field_is_rejected_not_half_absorbed(self):
        bad = {k: v for k, v in FOOTPRINT.items() if k != "retire"}
        rc = self.run_main([issue(1, {"door": "footprint", "fields": bad})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["footprint"], [])

    def test_value_outside_the_enum_is_rejected(self):
        bad = dict(FOOTPRINT, status="probably-dead")
        self.assertEqual(
            self.run_main([issue(1, {"door": "footprint", "fields": bad})], "--write"),
            an.RC_FAIL)

    def test_unknown_door_is_rejected(self):
        self.assertEqual(
            self.run_main([issue(1, {"door": "vibes", "fields": FOOTPRINT})]), an.RC_FAIL)

    def test_prose_only_issue_is_rejected(self):
        rc = self.run_main([{"number": 9, "title": "t", "body": "just a paragraph"}])
        self.assertEqual(rc, an.RC_FAIL)

    def test_existing_entry_is_never_overwritten(self):
        # The registered row carries a retirement history no filing knows about.
        existing = dict(FOOTPRINT, status="retiring", notes="agreed dead 2026-08-01")
        self.write_registry({"estate": {"footprint": [existing], "devices": []}})
        rc = self.run_main([issue(1, {"door": "footprint", "fields": FOOTPRINT})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["footprint"], [existing])

    def test_a_good_and_a_bad_filing_together_absorb_and_reject(self):
        good = issue(1, {"door": "footprint", "fields": FOOTPRINT})
        bad = issue(2, {"door": "footprint", "fields": dict(FOOTPRINT, id="")})
        rc = self.run_main([good, bad], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["footprint"], [FOOTPRINT])

    def test_device_door_lands_in_registry_estate_devices(self):
        dev = {"name": "monkey", "kind": "vm", "addr": "monkey.local", "reach": "ssh",
               "expect": "always-on", "owner": "realisateur", "notes": "self-dev host"}
        self.assertEqual(
            self.run_main([issue(1, {"door": "device", "fields": dev})], "--write"),
            an.RC_PASS)
        self.assertEqual(self.read_registry()["estate"]["devices"], [dev])

    def test_crontab_door_lands_in_registry_estate_crontab(self):
        self.assertEqual(
            self.run_main([issue(1, {"door": "crontab", "fields": CRONTAB})], "--write"),
            an.RC_PASS)
        self.assertEqual(self.read_registry()["estate"]["crontab"], [CRONTAB])

    def test_crontab_door_rejects_a_target_out_of_the_footprint_shape(self):
        # The whole reason this door exists (hf7y/senechal#362): a crontab
        # entry has no unit name, port, or absolute path -- footprint's own
        # required fields ("kind", "target") don't even appear here.
        rc = self.run_main([issue(1, {"door": "crontab", "fields": FOOTPRINT})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["crontab"], [])

    def test_crontab_door_key_is_composite_not_tag_alone(self):  # #428/#430: one mechanism, two accounts, identical tag -- tag alone is not a safe dedup key
        other_account = dict(CRONTAB, account="apms")
        rc = self.run_main([
            issue(1, {"door": "crontab", "fields": CRONTAB}),
            issue(2, {"door": "crontab", "fields": other_account}),
        ], "--write")
        self.assertEqual(rc, an.RC_PASS)
        self.assertEqual(self.read_registry()["estate"]["crontab"], [CRONTAB, other_account])

    def test_crontab_door_still_rejects_a_true_duplicate(self):
        self.write_registry({"estate": {"footprint": [], "devices": [], "crontab": [CRONTAB]}})
        rc = self.run_main([issue(1, {"door": "crontab", "fields": CRONTAB})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["crontab"], [CRONTAB])

    def test_registry_write_leaves_unrelated_sections_intact(self):
        self.write_registry({"estate": {"footprint": [], "devices": []}, "health": {"kept": 1}})
        self.run_main([issue(1, {"door": "footprint", "fields": FOOTPRINT})], "--write")
        after = self.read_registry()
        self.assertEqual(after["health"], {"kept": 1})
        self.assertEqual(after["estate"]["footprint"], [FOOTPRINT])

    def test_a_commented_issue_is_absorbed_but_never_closed(self):
        # The comment may be Zach's answer, and nothing else reads it.
        closed = []
        an.close_issue = lambda n, m: closed.append(n)
        i = issue(1, {"door": "footprint", "fields": FOOTPRINT})
        i["comments"] = [{"body": "A."}]
        self.assertEqual(self.run_main([i], "--write", "--close"), an.RC_PASS)
        self.assertEqual(self.read_registry()["estate"]["footprint"], [FOOTPRINT])
        self.assertEqual(closed, [])

    def test_an_uncommented_issue_is_still_closed(self):
        closed = []
        an.close_issue = lambda n, m: closed.append(n)
        i = issue(1, {"door": "footprint", "fields": FOOTPRINT})
        self.assertEqual(self.run_main([i], "--write", "--close"), an.RC_PASS)
        self.assertEqual(closed, [1])

    def test_unreadable_registry_is_could_not_look_not_clean(self):
        # The registry is a tracked file; if it can't be read, the checkout
        # itself is broken -- unconditionally fatal, same as the doors file.
        os.remove(self.registry)
        self.assertEqual(self.run_main([]), an.RC_INCOMPLETE)

    def test_unreadable_taste_config_does_not_block_a_fleet_absorb(self):
        # The entire point of #369/#411: a host with no reachable live
        # config can still absorb every fleet filing.
        os.remove(self.cfg)
        rc = self.run_main([issue(1, {"door": "footprint", "fields": FOOTPRINT})], "--write")
        self.assertEqual(rc, an.RC_PASS)
        self.assertEqual(self.read_registry()["estate"]["footprint"], [FOOTPRINT])

    def test_unclassified_target_defaults_to_fleet(self):
        doors = {"wildcard": UNCLASSIFIED_DOOR}
        rc = self.run_main(
            [issue(1, {"door": "wildcard", "fields": {"id": "x"}})], "--write", doors=doors)
        self.assertEqual(rc, an.RC_PASS)
        self.assertEqual(self.read_registry()["nonexistent"]["wildcard"], [{"id": "x"}])

    # -- an amend door corrects a row, and cannot clobber it ------------

    def seed_device(self, **over):
        self.write_registry({"estate": {"devices": [dict(DEVICE, **over)], "footprint": []}})

    def test_correction_amends_the_field_and_keeps_what_it_replaced(self):
        self.seed_device()
        rc = self.run_main(
            [issue(1, {"door": "device-correction", "fields": CORRECTION})], "--write")
        self.assertEqual(rc, an.RC_PASS)
        row = self.read_registry()["estate"]["devices"][0]
        self.assertEqual(row["notes"], CORRECTION["now"])
        self.assertEqual(row["corrections"], [{
            "field": "notes", "was": CORRECTION["was"], "now": CORRECTION["now"],
            "evidence": CORRECTION["evidence"]}])
        self.assertEqual(row["owner"], DEVICE["owner"])
        self.assertEqual(row["addr"], DEVICE["addr"])

    def test_correction_against_a_stale_read_is_rejected_not_applied(self):
        self.seed_device(notes="Zach rewrote this note by hand")
        rc = self.run_main(
            [issue(1, {"door": "device-correction", "fields": CORRECTION})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["devices"][0]["notes"],
                         "Zach rewrote this note by hand")

    def test_correction_to_a_human_only_field_is_rejected_by_the_door(self):
        self.seed_device()
        bad = dict(CORRECTION, field="owner", was="crt", now="senechal")
        rc = self.run_main([issue(1, {"door": "device-correction", "fields": bad})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["devices"][0]["owner"], "crt")

    def test_correction_to_an_unregistered_device_is_rejected(self):
        self.write_registry({"estate": {"devices": [], "footprint": []}})
        rc = self.run_main(
            [issue(1, {"door": "device-correction", "fields": CORRECTION})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["devices"], [])

    def test_correction_that_changes_nothing_is_rejected(self):
        self.seed_device()
        noop = dict(CORRECTION, now=CORRECTION["was"])
        rc = self.run_main([issue(1, {"door": "device-correction", "fields": noop})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertNotIn("corrections", self.read_registry()["estate"]["devices"][0])

    def test_device_door_still_refuses_to_overwrite_a_registered_row(self):
        self.seed_device()
        rc = self.run_main([issue(1, {"door": "device", "fields": dict(DEVICE, notes="x")})],
                           "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["devices"][0]["notes"], DEVICE["notes"])

    def seed_footprint(self, **over):  # footprint-correction: the same shape, one registry over (#633)
        self.write_registry({"estate": {"footprint": [dict(FOOTPRINT, **over)], "devices": []}})

    def test_footprint_correction_amends_the_field_and_keeps_what_it_replaced(self):
        self.seed_footprint()
        rc = self.run_main(
            [issue(1, {"door": "footprint-correction", "fields": FOOTPRINT_CORRECTION})], "--write")
        self.assertEqual(rc, an.RC_PASS)
        row = self.read_registry()["estate"]["footprint"][0]
        self.assertEqual(row["status"], FOOTPRINT_CORRECTION["now"])
        self.assertEqual(row["corrections"], [{
            "field": "status", "was": FOOTPRINT_CORRECTION["was"], "now": FOOTPRINT_CORRECTION["now"],
            "evidence": FOOTPRINT_CORRECTION["evidence"]}])
        self.assertEqual(row["target"], FOOTPRINT["target"])
        self.assertEqual(row["owner"], FOOTPRINT["owner"])

    def test_footprint_correction_against_a_stale_read_is_rejected_not_applied(self):
        self.seed_footprint(status="retired")
        rc = self.run_main(
            [issue(1, {"door": "footprint-correction", "fields": FOOTPRINT_CORRECTION})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["footprint"][0]["status"], "retired")

    def test_footprint_correction_to_a_human_only_field_is_rejected_by_the_door(self):
        self.seed_footprint()
        bad = dict(FOOTPRINT_CORRECTION, field="owner", was="senechal", now="realisateur")
        rc = self.run_main([issue(1, {"door": "footprint-correction", "fields": bad})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["footprint"][0]["owner"], FOOTPRINT["owner"])

    def test_footprint_correction_to_an_unregistered_row_is_rejected(self):
        self.write_registry({"estate": {"footprint": [], "devices": []}})
        rc = self.run_main(
            [issue(1, {"door": "footprint-correction", "fields": FOOTPRINT_CORRECTION})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["footprint"], [])

    def test_footprint_correction_that_changes_nothing_is_rejected(self):
        self.seed_footprint()
        noop = dict(FOOTPRINT_CORRECTION, now=FOOTPRINT_CORRECTION["was"])
        rc = self.run_main([issue(1, {"door": "footprint-correction", "fields": noop})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertNotIn("corrections", self.read_registry()["estate"]["footprint"][0])

    def test_footprint_door_still_refuses_to_overwrite_a_registered_row(self):
        self.seed_footprint()
        rc = self.run_main(
            [issue(1, {"door": "footprint", "fields": dict(FOOTPRINT, notes="x")})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["footprint"][0]["notes"], FOOTPRINT["notes"])

    def seed_crontab(self, **over):  # crontab-correction: the same shape, a composite key (#665's mass-park rejects)
        self.write_registry(
            {"estate": {"crontab": [dict(CRONTAB, **over)], "footprint": [], "devices": []}})

    def test_crontab_correction_amends_the_field_and_keeps_what_it_replaced(self):
        self.seed_crontab()
        rc = self.run_main(
            [issue(1, {"door": "crontab-correction", "fields": CRONTAB_CORRECTION})], "--write")
        self.assertEqual(rc, an.RC_PASS)
        row = self.read_registry()["estate"]["crontab"][0]
        self.assertEqual(row["status"], CRONTAB_CORRECTION["now"])
        self.assertEqual(row["corrections"], [{
            "field": "status", "was": CRONTAB_CORRECTION["was"], "now": CRONTAB_CORRECTION["now"],
            "evidence": CRONTAB_CORRECTION["evidence"]}])
        self.assertEqual(row["command"], CRONTAB["command"])
        self.assertEqual(row["owner"], CRONTAB["owner"])

    def test_crontab_correction_against_a_stale_read_is_rejected_not_applied(self):
        self.seed_crontab(status="retired")
        rc = self.run_main(
            [issue(1, {"door": "crontab-correction", "fields": CRONTAB_CORRECTION})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["crontab"][0]["status"], "retired")

    def test_crontab_correction_to_a_human_only_field_is_rejected_by_the_door(self):
        self.seed_crontab()
        bad = dict(CRONTAB_CORRECTION, field="owner", was="ecosim", now="senechal")
        rc = self.run_main([issue(1, {"door": "crontab-correction", "fields": bad})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["crontab"][0]["owner"], CRONTAB["owner"])

    def test_crontab_correction_to_an_unregistered_row_is_rejected(self):
        self.write_registry({"estate": {"crontab": [], "footprint": [], "devices": []}})
        rc = self.run_main(
            [issue(1, {"door": "crontab-correction", "fields": CRONTAB_CORRECTION})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["crontab"], [])

    def test_crontab_correction_matching_key_fields_but_wrong_account_is_rejected(self):
        self.seed_crontab(account="apms")  # same host+tag, different account -- key must match fully
        rc = self.run_main(
            [issue(1, {"door": "crontab-correction", "fields": CRONTAB_CORRECTION})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["crontab"][0]["status"], "live")

    def test_crontab_correction_that_changes_nothing_is_rejected(self):
        self.seed_crontab()
        noop = dict(CRONTAB_CORRECTION, now=CRONTAB_CORRECTION["was"])
        rc = self.run_main([issue(1, {"door": "crontab-correction", "fields": noop})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertNotIn("corrections", self.read_registry()["estate"]["crontab"][0])

    def test_crontab_door_still_refuses_to_overwrite_a_registered_row(self):
        self.seed_crontab()
        rc = self.run_main(
            [issue(1, {"door": "crontab", "fields": dict(CRONTAB, notes="x")})], "--write")
        self.assertEqual(rc, an.RC_FAIL)
        self.assertEqual(self.read_registry()["estate"]["crontab"][0]["notes"], CRONTAB["notes"])

    # -- taste doors: live config, and only on the taste host ------------

    def test_taste_door_lands_in_the_live_config_on_the_taste_host(self):
        doors = {"taste": TASTE_DOOR}
        rc = self.run_main(
            [issue(1, {"door": "taste", "fields": TASTE_FIELDS})], "--write", doors=doors)
        self.assertEqual(rc, an.RC_PASS)
        self.assertEqual(self.read_config()["estate"]["taste"], [TASTE_FIELDS])
        self.assertNotIn("taste", self.read_registry().get("estate", {}))

    def test_taste_door_is_deferred_not_applied_off_the_taste_host(self):
        os.environ["SENECHAL_HOSTNAME"] = "monkey"
        doors = {"taste": TASTE_DOOR}
        rc = self.run_main(
            [issue(1, {"door": "taste", "fields": TASTE_FIELDS})], "--write", doors=doors)
        self.assertEqual(rc, an.RC_WARN)
        self.assertEqual(self.read_config()["estate"]["taste"], [])

    def test_taste_host_override_is_honoured(self):
        os.environ["SENECHAL_HOSTNAME"] = "dexter"
        os.environ["SENECHAL_TASTE_HOST"] = "dexter"
        doors = {"taste": TASTE_DOOR}
        rc = self.run_main(
            [issue(1, {"door": "taste", "fields": TASTE_FIELDS})], "--write", doors=doors)
        self.assertEqual(rc, an.RC_PASS)
        self.assertEqual(self.read_config()["estate"]["taste"], [TASTE_FIELDS])

    def test_taste_door_is_deferred_when_the_live_config_is_unreadable(self):
        os.remove(self.cfg)
        doors = {"taste": TASTE_DOOR}
        rc = self.run_main(
            [issue(1, {"door": "taste", "fields": TASTE_FIELDS})], "--write", doors=doors)
        self.assertEqual(rc, an.RC_WARN)

    def test_deferred_filing_is_neither_absorbed_nor_rejected(self):
        # A clean filing that just can't land HERE is not the same failure
        # as a malformed one -- RC_FAIL would make it indistinguishable
        # from garbage nobody is coming to fix.
        os.environ["SENECHAL_HOSTNAME"] = "monkey"
        doors = {"taste": TASTE_DOOR}
        rc = self.run_main(
            [issue(1, {"door": "taste", "fields": TASTE_FIELDS})], doors=doors)
        self.assertEqual(rc, an.RC_WARN)

    def test_fleet_and_deferred_taste_together_still_absorb_the_fleet_one(self):
        # Load the real doors file so this exercises a realistic mixed
        # batch (a real fleet door) alongside the synthetic taste door.
        with open(an.doors_path()) as fh:
            real_doors = json.load(fh)["doors"]
        doors = dict(real_doors, taste=TASTE_DOOR)
        os.environ["SENECHAL_HOSTNAME"] = "monkey"
        good = issue(1, {"door": "footprint", "fields": FOOTPRINT})
        deferred = issue(2, {"door": "taste", "fields": TASTE_FIELDS})
        rc = self.run_main([good, deferred], "--write", doors=doors)
        self.assertEqual(rc, an.RC_WARN)
        self.assertEqual(self.read_registry()["estate"]["footprint"], [FOOTPRINT])
        self.assertEqual(self.read_config()["estate"]["taste"], [])


if __name__ == "__main__":
    unittest.main()
