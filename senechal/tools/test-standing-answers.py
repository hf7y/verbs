#!/usr/bin/env python3
"""The point of the audit is that a decision whose mechanism was deleted stops
being enforced silently. That is the case worth testing."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "tools" / "standing-answers.py"


def run(*args, registry=None):
    env = None
    cmd = [sys.executable, str(TOOL), *args]
    if registry is None:
        return subprocess.run(cmd, capture_output=True, text=True)
    # The tool reads a fixed path, so exercise a copy of the tree's registry by
    # pointing a scratch checkout at it.
    with tempfile.TemporaryDirectory() as td:
        scratch = Path(td)
        (scratch / "registry").mkdir()
        (scratch / "tools").mkdir()
        (scratch / "registry" / "standing-answers.json").write_text(registry)
        (scratch / "tools" / "standing-answers.py").write_text(TOOL.read_text())
        return subprocess.run(
            [sys.executable, str(scratch / "tools" / "standing-answers.py"), *args],
            capture_output=True, text=True, env=env)


class StandingAnswersTest(unittest.TestCase):
    def test_live_registry_audits_clean(self):
        r = run("--audit")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_missing_mechanism_fails(self):
        reg = json.dumps({"answers": {"x": {
            "decision": "d", "source": "s",
            "mechanism_paths": ["health/this-was-deleted.sh"]}}})
        r = run("--audit", registry=reg)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("does not exist", r.stdout)

    def test_answer_without_source_fails(self):
        reg = json.dumps({"answers": {"x": {"decision": "d"}}})
        r = run("--audit", registry=reg)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("no source", r.stdout)

    def test_unparseable_registry_is_incomplete_not_pass(self):
        r = run("--audit", registry="{ not json")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)

    def test_empty_registry_is_incomplete_not_pass(self):
        r = run("--audit", registry=json.dumps({"answers": {}}))
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)

    def test_lookup_finds_a_known_answer(self):
        r = run("bashified")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("means, not the decision", r.stdout)

    def test_lookup_miss_is_nonzero(self):
        self.assertEqual(run("nosuchthing").returncode, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
