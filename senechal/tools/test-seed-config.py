import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("seed_config", HERE / "seed-config.py")
seed_config = importlib.util.module_from_spec(spec)
sys.modules["seed_config"] = seed_config
spec.loader.exec_module(seed_config)


class SeedConfigTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dest = Path(self.tmp.name) / "senechal.json"
        self.env_patch = mock.patch.dict(
            "os.environ", {"SENECHAL_CONFIG": str(self.dest)}, clear=False)
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)

    def test_preview_does_not_write(self):
        rc = seed_config.main(["--watch", "~/.gitconfig"])
        self.assertEqual(rc, 0)
        self.assertFalse(self.dest.exists())

    def test_write_creates_a_narrow_config(self):
        rc = seed_config.main(["--watch", "~/.gitconfig", "--write"])
        self.assertEqual(rc, 0)
        config = json.loads(self.dest.read_text())
        self.assertEqual(sorted(config), ["_comment", "estate", "self_dev", "watch"])
        self.assertEqual(config["watch"], ["~/.gitconfig"])

    def test_write_matches_the_example_it_must_match(self):
        example = json.loads((seed_config.ROOT / "senechal.json.example").read_text())
        seed_config.main(["--write"])
        config = json.loads(self.dest.read_text())
        self.assertEqual(config["self_dev"], example["self_dev"])
        self.assertEqual(config["estate"]["taste"], example["estate"]["taste"])

    def test_write_carries_no_device_registry(self):
        seed_config.main(["--write"])
        config = json.loads(self.dest.read_text())
        self.assertNotIn("devices", config.get("estate", {}))

    def test_refuses_to_overwrite_a_live_config(self):
        self.dest.write_text("{}")
        rc = seed_config.main(["--write"])
        self.assertEqual(rc, 1)
        self.assertEqual(self.dest.read_text(), "{}")

    def test_default_watch_is_empty(self):
        seed_config.main(["--write"])
        config = json.loads(self.dest.read_text())
        self.assertEqual(config["watch"], [])


if __name__ == "__main__":
    unittest.main()
