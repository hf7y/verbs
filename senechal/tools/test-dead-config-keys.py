#!/usr/bin/env python3
"""Suite for tools/dead-config-keys.py.

Every case builds a throwaway git repo and config in a TemporaryDirectory,
never the real ones -- same rule test_senechal.py follows.

The properties that matter: a key nothing reads is found, a key read by ANY
route is not called dead, and an unreadable config never renders as "clean".
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
_spec = importlib.util.spec_from_file_location(
    "dck", os.path.join(os.path.dirname(os.path.abspath(__file__)), "dead-config-keys.py"))
dck = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dck)


class DeadConfigKeysTest(unittest.TestCase):
    def build(self, cfg, files):
        """-> (root, config_path) for a repo containing `files`."""
        root = self.tmp
        subprocess.run(["git", "init", "-q", root], check=True)
        for name, body in files.items():
            p = os.path.join(root, name)
            os.makedirs(os.path.dirname(p), exist_ok=True) if os.path.dirname(p) else None
            with open(p, "w") as fh:
                fh.write(body)
        subprocess.run(["git", "-C", root, "add", "-A"], check=True)
        cfg_path = os.path.join(root, "cfg.json")
        with open(cfg_path, "w") as fh:
            json.dump(cfg, fh)
        return root, cfg_path

    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.tmp = self._td.name

    def tearDown(self):
        self._td.cleanup()

    def run_main(self, cfg, files):
        root, cfg_path = self.build(cfg, files)
        return dck.main(["--config", cfg_path, "--root", root])

    # --- the rule ------------------------------------------------------
    def test_a_key_no_file_mentions_is_dead(self):
        rc = self.run_main({"self_dev": {"project_registry": "/gone"}},
                           {"a.sh": "echo unrelated\n"})
        self.assertEqual(dck.RC_WARN, rc)

    def test_a_key_read_by_cfg_dotted_path_is_alive(self):
        rc = self.run_main({"health": {"disk_warn_pct": 85}},
                           {"a.sh": 'W="$(cfg health.disk_warn_pct 85)"\n'})
        self.assertEqual(dck.RC_PASS, rc)

    def test_a_key_read_only_by_its_leaf_name_is_alive(self):
        """The loose rule: Python tools navigate parsed JSON, so the dotted
        path never appears. estate.devices is reached by cfg_devices."""
        rc = self.run_main({"estate": {"devices": []}},
                           {"t.py": 'for d in cfg["estate"]["devices"]: pass\n'})
        self.assertEqual(dck.RC_PASS, rc)

    def test_underscore_keys_are_prose_and_never_reported(self):
        rc = self.run_main({"_comment": "explanation nobody reads by name",
                            "health": {"disk_warn_pct": 85}},
                           {"a.sh": "cfg health.disk_warn_pct 85\n"})
        self.assertEqual(dck.RC_PASS, rc)

    def test_the_example_config_cannot_vouch_for_a_key(self):
        """A key documented in senechal.json.example and read nowhere is
        still dead; the example is a copy of the config, not a reader."""
        rc = self.run_main({"self_dev": {"paced_conf": "/x"}},
                           {"senechal.json.example": '{"self_dev": {"paced_conf": "/x"}}',
                            "a.sh": "echo unrelated\n"})
        self.assertEqual(dck.RC_WARN, rc)

    def test_journal_snapshots_cannot_vouch_for_a_key(self):
        rc = self.run_main({"self_dev": {"paced_conf": "/x"}},
                           {"journal/2026-01-01.json": '{"preview": "paced_conf"}',
                            "a.sh": "echo unrelated\n"})
        self.assertEqual(dck.RC_WARN, rc)

    def test_it_names_every_dead_key(self):
        root, cfg_path = self.build(
            {"a": {"one": 1, "two": 2}}, {"x.sh": "echo nothing\n"})
        with open(cfg_path) as fh:
            out = dck.dead_keys(json.load(fh), dck.tracked_source(root))
        self.assertEqual(["a.one", "a.two"], sorted(out))

    # --- could-not-look is never a pass --------------------------------
    def test_a_missing_config_exits_incomplete(self):
        rc = dck.main(["--config", os.path.join(self.tmp, "nope.json"), "--root", self.tmp])
        self.assertEqual(dck.RC_INCOMPLETE, rc)

    def test_an_unparseable_config_exits_incomplete(self):
        p = os.path.join(self.tmp, "bad.json")
        with open(p, "w") as fh:
            fh.write("{not json")
        self.assertEqual(dck.RC_INCOMPLETE, dck.main(["--config", p, "--root", self.tmp]))

    def test_no_tracked_source_exits_incomplete_not_all_dead(self):
        """An empty corpus would make EVERY key look dead. That is
        could-not-look, and reporting it as findings would be a lie."""
        root = self.tmp
        subprocess.run(["git", "init", "-q", root], check=True)
        p = os.path.join(root, "cfg.json")
        with open(p, "w") as fh:
            json.dump({"health": {"disk_warn_pct": 85}}, fh)
        self.assertEqual(dck.RC_INCOMPLETE, dck.main(["--config", p, "--root", root]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
