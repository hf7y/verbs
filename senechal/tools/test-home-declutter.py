import importlib.util
import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("home_declutter", HERE / "home-declutter.py")
home_declutter = importlib.util.module_from_spec(spec)
sys.modules["home_declutter"] = home_declutter
spec.loader.exec_module(home_declutter)


class HomeDeclutterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home_patch = mock.patch("home_declutter.Path.home", return_value=Path(self.tmp.name))
        self.home_patch.start()
        self.root = Path(self.tmp.name)
        self.quarantine = self.root / ".senechal-quarantine"

    def tearDown(self):
        self.home_patch.stop()
        self.tmp.cleanup()

    def make_cfg(self, **overrides):
        cfg = {
            "quarantine_root": str(self.quarantine),
            "purge_after_days": 30,
            "exclude": [],
            "regenerable": {"roots": [str(self.root)], "patterns": ["__pycache__", "*.tmp"]},
            "stale_downloads": {"roots": [], "stale_days": 90, "extensions": []},
            "debris": {"roots": [], "patterns": [], "treat_zero_byte_as_debris": True},
        }
        cfg.update(overrides)
        return cfg

    # --- hardlink guard ---------------------------------------------

    def test_hardlinked_file_is_skipped(self):
        d = self.root / "proj" / "__pycache__"
        d.mkdir(parents=True)
        f = d / "a.pyc"
        f.write_text("x")
        (self.root / "sibling.pyc").hardlink_to(f)

        cfg = self.make_cfg()
        candidates = home_declutter.find_candidates(cfg)
        results = [home_declutter.classify(c, cfg, [str(self.root)]) for c in candidates]
        self.assertEqual(results[0]["verdict"], "SKIP_HARDLINK")

    def test_unlinked_regenerable_dir_is_safe(self):
        d = self.root / "proj" / "__pycache__"
        d.mkdir(parents=True)
        (d / "a.pyc").write_text("x")

        cfg = self.make_cfg()
        candidates = home_declutter.find_candidates(cfg)
        results = [home_declutter.classify(c, cfg, [str(self.root)]) for c in candidates]
        self.assertEqual(results[0]["verdict"], "SAFE")

    # --- recoverability gate ------------------------------------------

    def test_stale_download_needs_garde_coverage(self):
        dl = self.root / "Downloads"
        dl.mkdir()
        f = dl / "old.deb"
        f.write_text("x")
        old_time = (datetime.now() - timedelta(days=200)).timestamp()
        import os
        os.utime(f, (old_time, old_time))

        cfg = self.make_cfg(stale_downloads={"roots": [str(dl)], "stale_days": 90, "extensions": [".deb"]})

        with mock.patch("home_declutter.garde_coverage", return_value=("covered", None)):
            candidates = home_declutter.find_candidates(cfg)
            results = [home_declutter.classify(c, cfg, [str(dl)]) for c in candidates]
        self.assertEqual(results[0]["verdict"], "SAFE")

        with mock.patch("home_declutter.garde_coverage", return_value=("uncovered", ["x"])):
            candidates = home_declutter.find_candidates(cfg)
            results = [home_declutter.classify(c, cfg, [str(dl)]) for c in candidates]
        self.assertEqual(results[0]["verdict"], "SKIP_UNCOVERED")

    def test_regenerable_never_calls_garde(self):
        d = self.root / "__pycache__"
        d.mkdir()
        (d / "a.pyc").write_text("x")
        cfg = self.make_cfg()
        with mock.patch("home_declutter.garde_coverage") as g:
            candidates = home_declutter.find_candidates(cfg)
            [home_declutter.classify(c, cfg, [str(self.root)]) for c in candidates]
        g.assert_not_called()

    # --- debris class ---------------------------------------------------

    def _debris_cfg(self, root):
        return self.make_cfg(
            regenerable={"roots": [], "patterns": []},
            debris={
                "roots": [str(root)],
                "patterns": [
                    "*.pre-*-migration.*", "*.pre-*.20*",
                    "*.conflicted-snapshot-*", "*conflicted*snapshot*",
                ],
                "treat_zero_byte_as_debris": True,
            },
        )

    def test_debris_matches_pre_migration_suffix(self):
        sub = self.root / "sub"
        sub.mkdir()
        f = sub / "abcde.conf.pre-mixes-migration.2026-07-26"
        f.write_text("old config")
        cfg = self._debris_cfg(self.root)

        candidates = home_declutter.find_candidates(cfg)
        paths = [c["path"] for c in candidates]
        self.assertIn(f, paths)
        match = next(c for c in candidates if c["path"] == f)
        self.assertEqual(match["class"], "debris")

    def test_debris_matches_conflicted_snapshot_suffix(self):
        sub = self.root / "sub"
        sub.mkdir()
        f = sub / "NOTES.md.conflicted-snapshot-20260730"
        f.write_text("conflict copy")
        cfg = self._debris_cfg(self.root)

        candidates = home_declutter.find_candidates(cfg)
        self.assertIn(f, [c["path"] for c in candidates])

    def test_debris_matches_temp_token_name(self):
        sub = self.root / "sub"
        sub.mkdir()
        f = sub / "tempblockers.md"
        f.write_text("stray")
        cfg = self._debris_cfg(self.root)

        candidates = home_declutter.find_candidates(cfg)
        self.assertIn(f, [c["path"] for c in candidates])

    def test_debris_does_not_match_temp_substring_near_miss(self):
        sub = self.root / "sub"
        sub.mkdir()
        (sub / "attempt.md").write_text("a real file")
        (sub / "contemplate.txt").write_text("also real")
        cfg = self._debris_cfg(self.root)

        candidates = home_declutter.find_candidates(cfg)
        names = [c["path"].name for c in candidates]
        self.assertNotIn("attempt.md", names)
        self.assertNotIn("contemplate.txt", names)

    def test_debris_matches_zero_byte_file(self):
        sub = self.root / "sub"
        sub.mkdir()
        f = sub / "mystery.dat"
        f.write_text("")
        cfg = self._debris_cfg(self.root)

        candidates = home_declutter.find_candidates(cfg)
        self.assertIn(f, [c["path"] for c in candidates])

    def test_debris_zero_byte_ignored_when_disabled(self):
        sub = self.root / "sub"
        sub.mkdir()
        f = sub / "mystery.dat"
        f.write_text("")
        cfg = self._debris_cfg(self.root)
        cfg["debris"]["treat_zero_byte_as_debris"] = False

        candidates = home_declutter.find_candidates(cfg)
        self.assertNotIn(f, [c["path"] for c in candidates])

    def test_debris_needs_garde_coverage_not_regenerable_shortcut(self):
        sub = self.root / "sub"
        sub.mkdir()
        f = sub / "tempblockers.md"
        f.write_text("stray")
        cfg = self._debris_cfg(self.root)

        with mock.patch("home_declutter.garde_coverage", return_value=("uncovered", ["x"])):
            candidates = home_declutter.find_candidates(cfg)
            results = [home_declutter.classify(c, cfg, [str(self.root)]) for c in candidates]
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["class"], "debris")
        self.assertEqual(results[0]["verdict"], "SKIP_UNCOVERED")

    def test_debris_matched_directory_not_quarantined_whole(self):
        # A directory whose own name matches a debris pattern must NOT
        # become a whole-directory candidate -- only files are debris
        # candidates. The walker should still descend into it and find
        # matching files inside.
        d = self.root / "old.conflicted-snapshot-20260101"
        d.mkdir()
        f = d / "tempnote.txt"
        f.write_text("x")
        cfg = self._debris_cfg(self.root)

        candidates = home_declutter.find_candidates(cfg)
        paths = [c["path"] for c in candidates]
        self.assertNotIn(d, paths)
        self.assertIn(f, paths)

    # --- quarantine / verify / purge lifecycle -------------------------

    def test_quarantine_then_verify_then_purge(self):
        d = self.root / "__pycache__"
        d.mkdir()
        (d / "a.pyc").write_text("x")
        cfg = self.make_cfg()

        rc = home_declutter.cmd_quarantine(cfg, argparse_ns())
        self.assertEqual(rc, home_declutter.RC_PASS)
        self.assertFalse(d.exists())
        manifest = home_declutter.load_manifest(cfg["quarantine_root"])
        self.assertEqual(len(manifest), 1)
        self.assertIsNone(manifest[0]["purged_at"])

        rc = home_declutter.cmd_verify(cfg, argparse_ns())
        self.assertEqual(rc, home_declutter.RC_PASS)

        # not old enough yet -- purge should do nothing
        rc = home_declutter.cmd_purge(cfg, argparse_ns(confirm=True))
        self.assertEqual(rc, home_declutter.RC_PASS)
        manifest = home_declutter.load_manifest(cfg["quarantine_root"])
        self.assertIsNone(manifest[0]["purged_at"])

    def test_purge_without_confirm_refuses(self):
        cfg = self.make_cfg()
        rc = home_declutter.cmd_purge(cfg, argparse_ns(confirm=False))
        self.assertEqual(rc, home_declutter.RC_FAIL)

    def test_verify_warns_past_grace_period(self):
        qdir = self.quarantine / "2020-01-01" / "old"
        qdir.mkdir(parents=True)
        f = qdir / "f.txt"
        f.write_text("x")
        home_declutter.save_manifest(str(self.quarantine), [{
            "quarantined_at": "2020-01-01T00:00:00",
            "original_path": str(self.root / "old" / "f.txt"),
            "quarantine_path": str(f.parent),
            "class": "regenerable",
            "reason": "test",
            "evidence": [],
            "file_hashes": home_declutter.hash_tree(f.parent),
            "size_bytes": 1,
            "purged_at": None,
        }])
        cfg = self.make_cfg()
        rc = home_declutter.cmd_verify(cfg, argparse_ns())
        self.assertEqual(rc, home_declutter.RC_WARN)

    def test_verify_fails_on_tampered_content(self):
        qdir = self.quarantine / "2026-01-01" / "item"
        qdir.mkdir(parents=True)
        f = qdir / "f.txt"
        f.write_text("original")
        home_declutter.save_manifest(str(self.quarantine), [{
            "quarantined_at": datetime.now().isoformat(timespec="seconds"),
            "original_path": str(self.root / "item" / "f.txt"),
            "quarantine_path": str(f.parent),
            "class": "regenerable",
            "reason": "test",
            "evidence": [],
            "file_hashes": home_declutter.hash_tree(f.parent),
            "size_bytes": 8,
            "purged_at": None,
        }])
        f.write_text("tampered")  # changed after quarantine
        cfg = self.make_cfg()
        rc = home_declutter.cmd_verify(cfg, argparse_ns())
        self.assertEqual(rc, home_declutter.RC_FAIL)

    def test_purge_deletes_only_past_grace_period(self):
        old_dir = self.quarantine / "2020-01-01" / "old"
        old_dir.mkdir(parents=True)
        (old_dir / "f.txt").write_text("x")
        recent_dir = self.quarantine / "2026-08-01" / "recent"
        recent_dir.mkdir(parents=True)
        (recent_dir / "f.txt").write_text("y")
        home_declutter.save_manifest(str(self.quarantine), [
            {
                "quarantined_at": "2020-01-01T00:00:00",
                "original_path": "old",
                "quarantine_path": str(old_dir),
                "class": "regenerable", "reason": "t", "evidence": [],
                "file_hashes": home_declutter.hash_tree(old_dir),
                "size_bytes": 1, "purged_at": None,
            },
            {
                "quarantined_at": datetime.now().isoformat(timespec="seconds"),
                "original_path": "recent",
                "quarantine_path": str(recent_dir),
                "class": "regenerable", "reason": "t", "evidence": [],
                "file_hashes": home_declutter.hash_tree(recent_dir),
                "size_bytes": 1, "purged_at": None,
            },
        ])
        cfg = self.make_cfg()
        rc = home_declutter.cmd_purge(cfg, argparse_ns(confirm=True))
        self.assertEqual(rc, home_declutter.RC_PASS)
        self.assertFalse(old_dir.exists())
        self.assertTrue(recent_dir.exists())


def argparse_ns(**kwargs):
    class NS:
        pass
    ns = NS()
    ns.confirm = kwargs.get("confirm", False)
    return ns


if __name__ == "__main__":
    unittest.main()
