#!/usr/bin/env python3
"""Suite for tools/absorb-notices.py.

Never touches the real config, the real registry, or GitHub: issues (and,
where a test needs a non-fleet door, doors) are injected as objects, and
both stores are TemporaryDirectory files -- same rule test_senechal.py
follows.

The properties that matter: a well-formed filing lands in the RIGHT store
(fleet -> registry, taste -> live config, and only on the taste host), a
malformed one is rejected rather than half-absorbed, an existing entry is
never overwritten, a taste filing that cannot be applied here is deferred
rather than silently dropped or wrongly rejected, and "could not look"
never renders as "nothing pending".
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

# A synthetic door targeting a real TASTE key (estate.taste), so the taste
# routing path -- which no real door exercises today -- has coverage.
TASTE_DOOR = {
    "target": "estate.taste", "key": "id",
    "required": ["id", "file", "status", "hosts"],
    "enums": {"status": ["enabled", "disabled"]},
}
TASTE_FIELDS = {"id": "colorhash-prompt", "file": ".bashrc", "status": "enabled", "hosts": "mandark"}

# A synthetic door targeting a key tools/boundary.py's CONFIG_KEYS says
# nothing about, so the "unclassified defaults to fleet" rule has coverage.
UNCLASSIFIED_DOOR = {
    "target": "nonexistent.wildcard", "key": "id",
    "required": ["id"], "enums": {},
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
