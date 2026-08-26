"""Tests for tools/naming.py.

  python3 tools/test-naming.py
"""

import importlib.util
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("naming", HERE / "naming.py")
naming = importlib.util.module_from_spec(spec)
sys.modules["naming"] = naming
spec.loader.exec_module(naming)


class CheckTest(unittest.TestCase):
    def test_confirmed_name_passes(self):
        rc, msg = naming.check("senechal", "dev-workflow-project")
        self.assertEqual(rc, 0)
        self.assertIn("steward/majordomo", msg)

    def test_unrelated_name_fails(self):
        rc, _msg = naming.check("totally-made-up-name", "dev-workflow-project")
        self.assertEqual(rc, 1)

    def test_seen_but_unconfirmed_name_is_incomplete_not_fail(self):
        rc, msg = naming.check("chezz", "dev-workflow-project")
        self.assertEqual(rc, 2)
        self.assertIn("#166", msg)

    def test_unknown_kind_is_incomplete(self):
        rc, _msg = naming.check("anything", "no-such-kind")
        self.assertEqual(rc, 2)


class MainTest(unittest.TestCase):
    def test_list_exits_zero(self):
        self.assertEqual(naming.main(["--list"]), 0)

    def test_no_name_is_incomplete(self):
        self.assertEqual(naming.main([]), 2)

    def test_confirmed_name_cli_exits_zero(self):
        self.assertEqual(naming.main(["gardien"]), 0)


if __name__ == "__main__":
    unittest.main()
