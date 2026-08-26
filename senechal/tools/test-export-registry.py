#!/usr/bin/env python3
"""Witness for tools/export-registry.py.

The assertion that matters is the REFUSAL: this exporter writes a file
that gets committed to git, so a registry carrying a credential-shaped
value must produce no file at all. Everything else here is scaffolding
around that one property.

Runs entirely against tempfile.TemporaryDirectory() trees, never the
real config or the real registry/ directory -- same rule test_senechal.py
holds itself to.

  python3 -m unittest tools.test_export_registry -v
  tools/test-export-registry.py
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
EXPORTER = os.path.join(HERE, "export-registry.py")

RC_PASS, RC_FAIL, RC_INCOMPLETE = 0, 1, 2

CLEAN = {
    "estate": {
        "devices": [{"name": "testbox", "kind": "linux"}],
        "secrets": [{
            "id": "a-token",
            "host": "testbox",
            "path": "~/.config/thing/token",
            "purpose": "what it is for",
            "mint": "how to issue a new one",
            "recovery": "remint",
        }],
    },
    "health": {"stale_days": 3},
    # must NOT be exported: host-local wiring
    "watch": ["~/.gitconfig"],
}


def run(cfg_obj, out_path, *extra):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(cfg_obj, fh)
        cfg_path = fh.name
    try:
        p = subprocess.run(
            [sys.executable, EXPORTER, "--config", cfg_path, "--out", out_path,
             *extra],
            capture_output=True, text=True)
        return p
    finally:
        os.unlink(cfg_path)


class ExportRegistryTest(unittest.TestCase):

    def test_refuses_a_credential_shaped_value_and_writes_nothing(self):
        poisoned = json.loads(json.dumps(CLEAN))
        poisoned["estate"]["secrets"][0]["notes"] = \
            "oops: api_key=AKIAIOSFODNN7EXAMPLE"
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "registry.json")
            p = run(poisoned, out, "--write")
            self.assertEqual(p.returncode, RC_FAIL, p.stderr)
            self.assertIn("REFUSED", p.stderr)
            self.assertFalse(os.path.exists(out),
                             "a refused export must leave no file behind")

    def test_refusal_names_the_path_but_never_prints_the_value(self):
        poisoned = json.loads(json.dumps(CLEAN))
        poisoned["estate"]["secrets"][0]["notes"] = \
            "-----BEGIN OPENSSH PRIVATE KEY-----"
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "registry.json")
            p = run(poisoned, out, "--write")
            self.assertEqual(p.returncode, RC_FAIL)
            self.assertIn("estate.secrets[0].notes", p.stderr)
            # The whole point: the offending material must not be echoed
            # into a terminal, a log, or a CI record.
            self.assertNotIn("BEGIN OPENSSH PRIVATE KEY", p.stderr)

    def test_writes_the_registry_blocks_and_omits_host_local_wiring(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "registry.json")
            p = run(CLEAN, out, "--write")
            self.assertEqual(p.returncode, RC_PASS, p.stderr)
            with open(out) as fh:
                got = json.load(fh)
            self.assertIn("estate", got)
            self.assertIn("health", got)
            self.assertNotIn("watch", got,
                             "watch is one machine's path list, not registry")

    def test_dry_run_is_a_stale_check_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "registry.json")
            p = run(CLEAN, out)                      # no --write
            self.assertEqual(p.returncode, RC_FAIL, "absent export is a finding")
            self.assertFalse(os.path.exists(out))
            self.assertEqual(run(CLEAN, out, "--write").returncode, RC_PASS)
            # now it matches, so the same dry run passes -- idempotent
            self.assertEqual(run(CLEAN, out).returncode, RC_PASS)

    def test_a_changed_registry_makes_the_dry_run_fail_again(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "registry.json")
            run(CLEAN, out, "--write")
            moved = json.loads(json.dumps(CLEAN))
            moved["estate"]["devices"].append({"name": "newbox"})
            p = run(moved, out)
            self.assertEqual(p.returncode, RC_FAIL)
            self.assertIn("stale", p.stdout)

    def test_unreadable_config_is_could_not_look_not_a_pass(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "registry.json")
            bad = os.path.join(d, "bad.json")
            with open(bad, "w") as fh:
                fh.write("{not json")
            p = subprocess.run(
                [sys.executable, EXPORTER, "--config", bad, "--out", out],
                capture_output=True, text=True)
            self.assertEqual(p.returncode, RC_INCOMPLETE)
            self.assertIn("CANNOT LOOK", p.stderr)

    def test_missing_config_is_could_not_look(self):
        with tempfile.TemporaryDirectory() as d:
            p = subprocess.run(
                [sys.executable, EXPORTER,
                 "--config", os.path.join(d, "nope.json"),
                 "--out", os.path.join(d, "registry.json")],
                capture_output=True, text=True)
            self.assertEqual(p.returncode, RC_INCOMPLETE)


if __name__ == "__main__":
    unittest.main(verbosity=2)
