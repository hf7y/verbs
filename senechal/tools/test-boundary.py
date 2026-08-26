"""Tests for tools/boundary.py.

  python3 tools/test-boundary.py

Merges hf7y/senechal#401's tools/test-boundary.py (classify()/config-key/
disposition assertions against the real, committed registry) and #397's
tools/test-repo-boundary.py (is_mechanism_file()/check() assertions
against throwaway git repos) per hf7y/senechal#408 -- every property
either suite verified still has a test here, none dropped to make the
merge green.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("boundary", HERE / "boundary.py")
boundary = importlib.util.module_from_spec(spec)
sys.modules["boundary"] = boundary
spec.loader.exec_module(boundary)


class ClassifyTest(unittest.TestCase):
    def test_fleet_file_classifies(self):
        cls, _reason = boundary.classify("health/dead-config.sh")
        self.assertEqual(cls, "fleet")

    def test_taste_file_classifies(self):
        cls, _reason = boundary.classify("remedies/colorhash-prompt.sh")
        self.assertEqual(cls, "taste")

    def test_shared_and_meta_are_real_classes(self):
        cls, _reason = boundary.classify("lib/common.sh")
        self.assertEqual(cls, "shared")
        cls, _reason = boundary.classify("registry/boundary.json")
        self.assertEqual(cls, "meta")

    def test_ambiguous_is_gone_as_a_class(self):
        # Zach, 2026-08-24: ambiguous defaults to fleet. The costs are
        # asymmetric -- a taste item wrongly in the fleet is dead weight, a
        # fleet item wrongly in taste is a broken unattended run elsewhere.
        self.assertEqual(boundary.CLASSES, ("fleet", "taste", "shared", "meta"))
        self.assertEqual(
            [p for p, (c, _) in boundary.FILES.items() if c not in boundary.CLASSES], [])

    def test_former_ambiguous_kept_its_reasoning_though_reclassified_shared(self):
        # Was "fleet by default rule" pre-merge; #408's merge moved it to
        # shared (generic systemd hygiene, either half's remedies use it).
        cls, reason = boundary.classify("tools/reap-failed-scopes.sh")
        self.assertEqual(cls, "shared")

    def test_unregistered_path_is_none(self):
        self.assertIsNone(boundary.classify("health/no-such-script.sh"))

    def test_leading_dotslash_is_tolerated(self):
        cls, _reason = boundary.classify("./health/dead-config.sh")
        self.assertEqual(cls, "fleet")

    def test_test_dash_file_inherits_target_class(self):
        cls, reason = boundary.classify("health/test-dead-config.sh")
        self.assertEqual(cls, "fleet")
        self.assertIn("inherits health/dead-config.sh", reason)

    def test_underscore_test_file_inherits_target_class(self):
        cls, reason = boundary.classify("remedies/_test-colorhash-prompt.sh")
        self.assertEqual(cls, "taste")
        self.assertIn("inherits remedies/colorhash-prompt.sh", reason)

    def test_python_test_file_inherits_target_class(self):
        cls, _reason = boundary.classify("tools/test-naming.py")
        self.assertEqual(cls, "shared")

    def test_test_file_with_no_resolvable_target_is_none(self):
        self.assertIsNone(boundary.classify("tools/test-nothing-like-this.py"))

    def test_override_test_file_does_not_use_prefix_stripping(self):
        # health/test-alerting.sh would resolve to "health/alerting.sh" by
        # naive stripping, which does not exist -- the override must win.
        cls, reason = boundary.classify("health/test-alerting.sh")
        self.assertEqual(cls, "fleet")
        self.assertIn("lib/common.sh", reason)


class ConfigKeyTest(unittest.TestCase):
    def test_fleet_key(self):
        cls, _reason = boundary.classify_config_key("estate.devices")
        self.assertEqual(cls, "fleet")

    def test_taste_key(self):
        cls, _reason = boundary.classify_config_key("estate.taste")
        self.assertEqual(cls, "taste")

    def test_former_ambiguous_key_became_fleet(self):
        cls, reason = boundary.classify_config_key("self_dev")
        self.assertEqual(cls, "fleet")
        self.assertIn("was ambiguous", reason)

    def test_unknown_key_is_none(self):
        self.assertIsNone(boundary.classify_config_key("no_such_key"))


class DispositionTest(unittest.TestCase):
    """Zach, 2026-08-24: the taste half is content senechal reads, not a
    second codebase. Every taste file owes an answer to 'and then what'."""

    def test_every_taste_file_has_a_disposition(self):
        missing = [p for p, (c, _) in boundary.FILES.items()
                   if c == "taste" and p not in boundary.DISPOSITION]
        self.assertEqual(missing, [], f"taste files with no disposition: {missing}")

    def test_no_disposition_for_a_non_taste_file(self):
        wrong = [p for p in boundary.DISPOSITION
                 if p in boundary.FILES and boundary.FILES[p][0] != "taste"]
        self.assertEqual(wrong, [])

    def test_dispositions_are_from_the_known_set(self):
        for path, (what, _why) in boundary.DISPOSITION.items():
            self.assertIn(what.split(":")[0], boundary.DISPOSITIONS, path)

    def test_blocked_names_the_issue_it_waits_on(self):
        for path, (what, _why) in boundary.DISPOSITION.items():
            if what.startswith("blocked"):
                self.assertRegex(what, r"^blocked:\d+$", f"{path}: blocked on what?")

    def test_the_evict_list_from_348_landed_as_drop(self):
        # tools/appimage-integrate.sh was the fourth -- actually dropped
        # (hf7y/senechal#410), so it carries no disposition row any more.
        for path in ("tools/browse", "tools/home-declutter.py", "tools/spawn-here"):
            self.assertEqual(boundary.disposition(path)[0], "drop", path)


class MechanismFileTest(unittest.TestCase):
    """hf7y/senechal#397's tracked-file-sweep predicate."""

    def test_health_script_is_a_mechanism_file(self):
        self.assertTrue(boundary.is_mechanism_file("health/curl-bash-installs.sh"))

    def test_health_test_script_is_not(self):
        self.assertFalse(boundary.is_mechanism_file("health/test-curl-bash-installs.sh"))

    def test_remedy_underscore_test_is_not(self):
        self.assertFalse(boundary.is_mechanism_file("remedies/_test-smart-health.sh"))

    def test_remedy_readme_is_a_mechanism_file(self):
        self.assertTrue(boundary.is_mechanism_file("remedies/README.md"))

    def test_ceiling_file_is_never_a_mechanism_file(self):
        self.assertFalse(boundary.is_mechanism_file("health/path-from-checkout.ceiling"))

    def test_baseline_file_is_never_a_mechanism_file(self):
        self.assertFalse(boundary.is_mechanism_file("tools/config-prose-drift.baseline"))

    def test_example_config_is_never_a_mechanism_file(self):
        self.assertFalse(boundary.is_mechanism_file("senechal.json.example"))

    def test_extensionless_tools_executable_is_a_mechanism_file(self):
        self.assertTrue(boundary.is_mechanism_file("tools/browse"))

    def test_tools_man_page_is_a_mechanism_file(self):
        self.assertTrue(boundary.is_mechanism_file("tools/home-declutter.1"))

    def test_man_directory_man_page_is_a_mechanism_file(self):
        self.assertTrue(boundary.is_mechanism_file("man/installe.1"))

    def test_pycache_under_tools_is_not(self):
        self.assertFalse(boundary.is_mechanism_file("tools/__pycache__/naming.cpython-312.pyc"))

    def test_python_test_module_is_not(self):
        self.assertFalse(boundary.is_mechanism_file("tools/test-naming.py"))

    def test_journal_snapshot_is_not(self):
        self.assertFalse(boundary.is_mechanism_file("journal/2026-01-01.json"))

    def test_registry_json_is_a_mechanism_file(self):
        self.assertTrue(boundary.is_mechanism_file("registry/front-doors.json"))

    def test_top_level_doc_is_not(self):
        self.assertFalse(boundary.is_mechanism_file("CLAUDE.md"))

    def test_lib_common_is_a_mechanism_file(self):
        self.assertTrue(boundary.is_mechanism_file("lib/common.sh"))

    def test_bin_verb_is_a_mechanism_file(self):
        self.assertTrue(boundary.is_mechanism_file("bin/installe"))

    def test_provision_script_is_a_mechanism_file(self):
        self.assertTrue(boundary.is_mechanism_file("provision/monkey-vm.sh"))

    def test_quarantine_file_is_never_a_mechanism_file(self):
        self.assertFalse(boundary.is_mechanism_file("tools/run-suites.quarantine"))


class AuditRealTreeTest(unittest.TestCase):
    def test_real_tree_has_no_drift(self):
        # The guard the registry exists for: a new health/remedies/tools/
        # lib/bin/provision/workstation/man/registry file added without an
        # entry here must fail loudly, not silently miss the classification.
        rc, problems = boundary.audit()
        self.assertEqual(problems, [])
        self.assertEqual(rc, boundary.RC_PASS)


class AuditFixtureTest(unittest.TestCase):
    """hf7y/senechal#397's CheckTest, ported onto the merged audit()/check()."""

    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.tmp = self._td.name
        subprocess.run(["git", "init", "-q", self.tmp], check=True)

    def tearDown(self):
        self._td.cleanup()

    def write(self, rel, body=""):
        p = os.path.join(self.tmp, rel)
        if os.path.dirname(p):
            os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as fh:
            fh.write(body)

    def add(self):
        subprocess.run(["git", "-C", self.tmp, "add", "-A"], check=True)

    def registry(self, entries, disposition=None, extra=None):
        p = os.path.join(self.tmp, "boundary.json")
        body = {"entries": entries, "disposition": disposition or {}}
        if extra:
            body.update(extra)
        with open(p, "w") as fh:
            json.dump(body, fh)
        return p

    def test_fully_classified_tree_passes(self):
        self.write("health/foo.sh", "#!/bin/sh\n")
        self.add()
        reg = self.registry({"health/foo.sh": {"class": "fleet", "why": "x"}})
        rc, problems = boundary.audit(self.tmp, reg)
        self.assertEqual(boundary.RC_PASS, rc)
        self.assertEqual([], problems)

    def test_a_new_unclassified_mechanism_file_fails(self):
        self.write("health/foo.sh", "#!/bin/sh\n")
        self.write("health/bar.sh", "#!/bin/sh\n")
        self.add()
        reg = self.registry({"health/foo.sh": {"class": "fleet", "why": "x"}})
        rc, problems = boundary.audit(self.tmp, reg)
        self.assertEqual(boundary.RC_FAIL, rc)
        self.assertTrue(any("unregistered" in p and "health/bar.sh" in p for p in problems))

    def test_a_test_file_is_never_reported_unclassified(self):
        self.write("health/foo.sh", "#!/bin/sh\n")
        self.write("health/test-foo.sh", "#!/bin/sh\n")
        self.add()
        reg = self.registry({"health/foo.sh": {"class": "fleet", "why": "x"}})
        rc, problems = boundary.audit(self.tmp, reg)
        self.assertEqual(boundary.RC_PASS, rc)

    def test_a_removed_files_stale_entry_warns_not_fails(self):
        self.write("health/foo.sh", "#!/bin/sh\n")
        self.add()
        reg = self.registry({
            "health/foo.sh": {"class": "fleet", "why": "x"},
            "health/gone.sh": {"class": "taste", "why": "retired"},
        }, disposition={"health/gone.sh": {"what": "drop", "why": "retired"}})
        rc, problems = boundary.audit(self.tmp, reg)
        self.assertEqual(boundary.RC_WARN, rc)
        self.assertTrue(any("stale" in p and "health/gone.sh" in p for p in problems))

    def test_an_invalid_class_value_fails(self):
        self.write("health/foo.sh", "#!/bin/sh\n")
        self.add()
        reg = self.registry({"health/foo.sh": {"class": "mandark-only", "why": "typo"}})
        rc, problems = boundary.audit(self.tmp, reg)
        self.assertEqual(boundary.RC_FAIL, rc)
        self.assertTrue(any("bad class" in p and "health/foo.sh" in p for p in problems))

    def test_a_missing_class_key_fails(self):
        self.write("health/foo.sh", "#!/bin/sh\n")
        self.add()
        reg = self.registry({"health/foo.sh": {"why": "forgot the class"}})
        rc, problems = boundary.audit(self.tmp, reg)
        self.assertEqual(boundary.RC_FAIL, rc)
        self.assertTrue(any("bad class" in p and "health/foo.sh" in p for p in problems))

    def test_an_undisposed_taste_file_warns(self):
        self.write("health/foo.sh", "#!/bin/sh\n")
        self.add()
        reg = self.registry({"health/foo.sh": {"class": "taste", "why": "x"}})
        rc, problems = boundary.audit(self.tmp, reg)
        self.assertEqual(boundary.RC_WARN, rc)
        self.assertTrue(any("undisposed" in p and "health/foo.sh" in p for p in problems))

    def test_a_disposition_on_a_non_taste_file_is_flagged_stale(self):
        self.write("health/foo.sh", "#!/bin/sh\n")
        self.add()
        reg = self.registry(
            {"health/foo.sh": {"class": "fleet", "why": "x"}},
            disposition={"health/foo.sh": {"what": "content", "why": "wrong, fleet not taste"}})
        rc, problems = boundary.audit(self.tmp, reg)
        self.assertEqual(boundary.RC_WARN, rc)
        self.assertTrue(any("stale disposition" in p and "health/foo.sh" in p for p in problems))

    def test_a_missing_registry_is_incomplete(self):
        self.write("health/foo.sh", "#!/bin/sh\n")
        self.add()
        rc, problems = boundary.audit(self.tmp, os.path.join(self.tmp, "nope.json"))
        self.assertEqual(boundary.RC_INCOMPLETE, rc)

    def test_an_unparseable_registry_is_incomplete(self):
        self.write("health/foo.sh", "#!/bin/sh\n")
        self.add()
        p = os.path.join(self.tmp, "bad.json")
        with open(p, "w") as fh:
            fh.write("{not json")
        rc, problems = boundary.audit(self.tmp, p)
        self.assertEqual(boundary.RC_INCOMPLETE, rc)

    def test_a_registry_whose_entries_is_not_a_dict_is_incomplete(self):
        self.write("health/foo.sh", "#!/bin/sh\n")
        self.add()
        p = os.path.join(self.tmp, "bad.json")
        with open(p, "w") as fh:
            json.dump({"entries": ["not", "a", "dict"]}, fh)
        rc, problems = boundary.audit(self.tmp, p)
        self.assertEqual(boundary.RC_INCOMPLETE, rc)

    def test_not_a_git_repo_is_incomplete(self):
        empty = tempfile.mkdtemp()
        try:
            reg = os.path.join(empty, "boundary.json")
            with open(reg, "w") as fh:
                json.dump({"entries": {}}, fh)
            rc, problems = boundary.audit(empty, reg)
            self.assertEqual(boundary.RC_INCOMPLETE, rc)
        finally:
            os.rmdir(empty) if not os.listdir(empty) else None

    def test_check_matches_audit_shape(self):
        # tools/repo-boundary.py's own compatibility view.
        self.write("health/foo.sh", "#!/bin/sh\n")
        self.write("health/bar.sh", "#!/bin/sh\n")
        self.add()
        reg = self.registry({"health/foo.sh": {"class": "fleet", "why": "x"}})
        rc, unclassified, stale, bad = boundary.check(self.tmp, reg)
        self.assertEqual(boundary.RC_FAIL, rc)
        self.assertEqual(["health/bar.sh"], unclassified)
        self.assertEqual([], stale)
        self.assertEqual([], bad)


class MainTest(unittest.TestCase):
    def test_single_path_fleet_exits_zero(self):
        self.assertEqual(boundary.main(["health/dead-config.sh"]), 0)

    def test_single_path_taste_exits_one(self):
        self.assertEqual(boundary.main(["remedies/colorhash-prompt.sh"]), 1)

    def test_single_path_shared_exits_zero(self):
        self.assertEqual(boundary.main(["lib/common.sh"]), 0)

    def test_single_path_meta_exits_one(self):
        self.assertEqual(boundary.main(["registry/boundary.json"]), 1)

    def test_unregistered_path_exits_two(self):
        self.assertEqual(boundary.main(["no/such/file.sh"]), 2)

    def test_list_exits_zero(self):
        self.assertEqual(boundary.main(["--list"]), 0)

    def test_no_args_is_incomplete(self):
        self.assertEqual(boundary.main([]), 2)

    def test_audit_clean_exits_zero(self):
        self.assertEqual(boundary.main(["--audit"]), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
