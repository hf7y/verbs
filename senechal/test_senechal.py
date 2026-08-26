import base64
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import senechal


class SenechalTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.watched = self.root / "bin"
        self.watched.mkdir()
        (self.watched / "hello.sh").write_text("echo hello")
        self.config_path = self.root / "senechal.json"
        self.config_path.write_text(json.dumps({"watch": [str(self.watched)]}))
        self.journal = self.root / "journal"

    def tearDown(self):
        self.tmp.cleanup()

    def test_scan_finds_file_and_hashes_it(self):
        config = senechal.load_config(self.config_path)
        snapshot = senechal.take_snapshot(config)
        entries = snapshot["paths"][str(self.watched)]
        self.assertEqual(len(entries), 1)
        self.assertTrue(entries[0]["path"].endswith("hello.sh"))
        self.assertEqual(entries[0]["preview"], "echo hello")

    def test_secret_looking_content_is_redacted_not_written(self):
        (self.watched / "creds.sh").write_text("export API_KEY=sk-super-secret-value")
        config = senechal.load_config(self.config_path)
        snapshot = senechal.take_snapshot(config)
        entries = {e["path"]: e for e in snapshot["paths"][str(self.watched)]}
        creds_entry = next(e for p, e in entries.items() if p.endswith("creds.sh"))
        self.assertIsNone(creds_entry["preview"])
        self.assertTrue(creds_entry["redacted"])
        self.assertIn("sha256", creds_entry)

    def test_github_token_is_redacted(self):
        self.assertTrue(senechal.looks_secret("export GH_TOKEN=ghp_" + "a" * 36))

    def test_github_fine_grained_pat_is_redacted(self):
        self.assertTrue(senechal.looks_secret("export GH_TOKEN=github_pat_" + "a" * 30))

    def test_slack_token_is_redacted(self):
        self.assertTrue(senechal.looks_secret("SLACK_TOKEN=xoxb-1234567890-abcdefgh"))

    def test_bearer_token_is_redacted(self):
        self.assertTrue(senechal.looks_secret("Authorization: Bearer " + "a" * 20))

    def test_authorization_header_is_redacted_regardless_of_scheme(self):
        # Basic/Token/custom schemes don't fit the bearer pattern (different
        # keyword) or the api_key=/token= keyword patterns (no "=" or ":"
        # right after the scheme keyword) -- the header line itself is the
        # anchor.
        self.assertTrue(senechal.looks_secret("Authorization: Basic dXNlcjpwYXNzd29yZA=="))
        self.assertTrue(senechal.looks_secret("Authorization: Token abc123def456"))

    def test_jwt_is_redacted(self):
        jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dQw4w9WgXcQ"
        self.assertTrue(senechal.looks_secret(jwt))

    def test_connection_string_with_embedded_password_is_redacted(self):
        self.assertTrue(senechal.looks_secret("postgres://user:hunter2@host:5432/db"))
        self.assertTrue(senechal.looks_secret("redis://:hunter2@host:6379"))

    def test_credential_less_urls_are_not_falsely_redacted(self):
        self.assertFalse(senechal.looks_secret("https://github.com/user/repo.git"))
        self.assertFalse(senechal.looks_secret("ssh://git@github.com/repo.git"))

    def test_stripe_key_is_redacted_without_a_keyword_prefix(self):
        # Stripe keys are commonly hardcoded bare (no "key=" nearby), unlike
        # the api_key=/token= shapes above -- the sk_live_/sk_test_ prefix
        # is itself unambiguous.
        self.assertTrue(senechal.looks_secret("sk_live_" + "a" * 24))
        self.assertTrue(senechal.looks_secret("rk_test_" + "a" * 24))

    def test_google_api_key_is_redacted(self):
        self.assertTrue(senechal.looks_secret("AIza" + "a" * 35))

    def test_npm_token_is_redacted(self):
        self.assertTrue(senechal.looks_secret("npm_" + "a" * 36))

    def test_netrc_entry_is_redacted(self):
        self.assertTrue(senechal.looks_secret("machine example.com login zach password hunter2"))

    def test_ssh_private_key_is_redacted(self):
        self.assertTrue(senechal.looks_secret("-----BEGIN OPENSSH PRIVATE KEY-----"))

    def test_pgp_private_key_block_is_redacted(self):
        # GPG's own export header has a trailing word ("BLOCK") between
        # "PRIVATE KEY" and the closing dashes -- a stricter version of the
        # private-key pattern that required "PRIVATE KEY-----" with nothing
        # in between missed this real shape entirely.
        self.assertTrue(senechal.looks_secret("-----BEGIN PGP PRIVATE KEY BLOCK-----"))

    def test_pgp_public_key_block_is_not_falsely_redacted(self):
        self.assertFalse(senechal.looks_secret("-----BEGIN PGP PUBLIC KEY BLOCK-----"))

    def test_ordinary_text_is_not_redacted(self):
        self.assertFalse(senechal.looks_secret("set nocompatible\nsyntax on\n"))

    def test_snake_case_prefixed_secret_keys_are_redacted(self):
        # \bsecret\b etc. treat "_" as a word char, so a strict word-boundary
        # match misses real-world shapes like AWS credentials files or .env
        # vars that prefix the keyword rather than using it standalone.
        self.assertTrue(senechal.looks_secret("aws_secret_access_key = " + "a" * 40))
        self.assertTrue(senechal.looks_secret("access_token = " + "a" * 20))
        self.assertTrue(senechal.looks_secret("db_api_key: " + "a" * 20))
        self.assertTrue(senechal.looks_secret("my_password=hunter2"))

    def test_json_quoted_secret_keys_are_redacted(self):
        # A closing quote sits between the key and the colon in JSON-style
        # config (e.g. ~/.docker/config.json, gcloud credential files) --
        # confirmed missed entirely before this fix.
        self.assertTrue(senechal.looks_secret('{"password": "hunter2"}'))
        self.assertTrue(senechal.looks_secret('{"api_key": "abc123"}'))
        self.assertTrue(senechal.looks_secret('  "token" : "abc123"'))
        self.assertTrue(senechal.looks_secret('{"secret": "shh"}'))

    def test_secret_lookalike_words_are_not_falsely_redacted(self):
        # The relaxed prefix matching shouldn't start flagging ordinary
        # words that merely start with a secret-ish keyword.
        self.assertFalse(senechal.looks_secret("she kept it secretive"))
        self.assertFalse(senechal.looks_secret("the tokenizer splits words"))
        self.assertFalse(senechal.looks_secret("a secretary sent the memo"))
        self.assertFalse(senechal.looks_secret("passwordless login is enabled"))

    def test_nonexistent_watched_path_returns_no_entries(self):
        missing = str(self.root / "does-not-exist")
        self.assertEqual(senechal.scan_path(missing), [])

    def test_special_file_as_watch_root_is_flagged_not_mislabeled_directory(self):
        fifo_path = self.root / "a_fifo"
        os.mkfifo(fifo_path)
        entries = senechal.scan_path(str(fifo_path))
        self.assertEqual(len(entries), 1)
        self.assertIn("unreadable", entries[0])
        self.assertNotIn("directory", entries[0])

    def test_special_file_nested_in_watched_dir_is_flagged_not_dropped(self):
        # Same shape as the watch-root case above, but found one level down
        # while walking a directory -- confirmed by hand that _walk_files's
        # dir/symlink/regular-file branches previously had no else clause,
        # so a FIFO nested inside a watched directory just vanished from the
        # snapshot with no trace at all, unlike the root-level case which
        # was already flagged.
        os.mkfifo(self.watched / "nested_fifo")
        entries = {e["path"]: e for e in senechal.scan_path(str(self.watched))}
        entry = next(e for p, e in entries.items() if p.endswith("nested_fifo"))
        self.assertIn("unreadable", entry)
        self.assertNotIn("directory", entry)
        self.assertNotIn("sha256", entry)

    def test_binary_file_is_hashed_not_previewed(self):
        (self.watched / "bin.dat").write_bytes(bytes(range(256)))
        entries = {e["path"]: e for e in senechal.scan_path(str(self.watched))}
        bin_entry = next(e for p, e in entries.items() if p.endswith("bin.dat"))
        self.assertIsNone(bin_entry["preview"])
        self.assertTrue(bin_entry["binary"])
        self.assertIn("sha256", bin_entry)

    def test_empty_file_gets_empty_preview_not_redacted(self):
        (self.watched / "empty.txt").write_text("")
        entries = {e["path"]: e for e in senechal.scan_path(str(self.watched))}
        empty_entry = next(e for p, e in entries.items() if p.endswith("empty.txt"))
        self.assertEqual(empty_entry["preview"], "")
        self.assertNotIn("redacted", empty_entry)
        self.assertNotIn("binary", empty_entry)

    def test_symlink_to_watched_file_is_scanned_via_target(self):
        target = self.watched / "target.txt"
        target.write_text("hello target")
        (self.watched / "link.txt").symlink_to(target)
        entries = {e["path"]: e for e in senechal.scan_path(str(self.watched))}
        link_entry = next(e for p, e in entries.items() if p.endswith("link.txt"))
        self.assertEqual(link_entry["preview"], "hello target")

    def test_broken_symlink_is_recorded_not_dropped(self):
        # Was previously skipped outright (the old test asserted that). A
        # dangling symlink in a watched directory is exactly the kind of
        # orphan this journal exists to remember -- e.g. a ~/.local/bin
        # entry whose script was deleted. Absent from the snapshot reads as
        # "never existed", which is the wrong record.
        (self.watched / "broken.txt").symlink_to(self.watched / "does-not-exist.txt")
        entries = {e["path"]: e for e in senechal.scan_path(str(self.watched))}
        entry = next(e for p, e in entries.items() if p.endswith("broken.txt"))
        self.assertEqual(entry["unreadable"], "broken symlink")
        self.assertNotIn("sha256", entry)
        self.assertNotIn("preview", entry)

    def test_symlink_to_special_file_is_flagged_not_dropped(self):
        # The symlink branch checked only p.exists(), so a symlink whose
        # target is a FIFO/socket/device passed the check, was appended to
        # `files`, then hit scan_path's `if not p.is_file(): continue` and
        # vanished with no trace -- same class as the nested-FIFO case
        # above, just reached through a symlink.
        os.mkfifo(self.watched / "realfifo")
        (self.watched / "fifo.link").symlink_to(self.watched / "realfifo")
        entries = {e["path"]: e for e in senechal.scan_path(str(self.watched))}
        entry = next(e for p, e in entries.items() if p.endswith("fifo.link"))
        self.assertEqual(entry["unreadable"], "not a regular file or directory")
        self.assertNotIn("sha256", entry)

    def test_broken_symlink_as_watch_root_is_recorded(self):
        # Distinct from a watch-list path that simply isn't on this machine
        # (which correctly yields no entries): the path is present, it just
        # points at nothing.
        root = Path(self.tmp.name) / "rootlink"
        root.symlink_to(Path(self.tmp.name) / "no-such-target")
        entries = senechal.scan_path(str(root))
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["unreadable"], "broken symlink")

    def test_absent_watch_root_still_yields_no_entries(self):
        # Guards the boundary the test above sits against -- a path that
        # doesn't exist at all must stay silent, not become a finding.
        entries = senechal.scan_path(str(Path(self.tmp.name) / "not-here"))
        self.assertEqual(entries, [])

    def test_all_secret_file_is_fully_redacted(self):
        (self.watched / "allsecret.txt").write_text(
            "password=hunter2\napi_key=abc123\ntoken=xyz789\n"
        )
        entries = {e["path"]: e for e in senechal.scan_path(str(self.watched))}
        secret_entry = next(e for p, e in entries.items() if p.endswith("allsecret.txt"))
        self.assertIsNone(secret_entry["preview"])
        self.assertTrue(secret_entry["redacted"])

    def test_unreadable_file_is_flagged_not_crashed(self):
        unreadable = self.watched / "noperm.txt"
        unreadable.write_text("cant touch this")
        unreadable.chmod(0o000)
        try:
            entries = {e["path"]: e for e in senechal.scan_path(str(self.watched))}
        finally:
            unreadable.chmod(0o644)
        entry = next(e for p, e in entries.items() if p.endswith("noperm.txt"))
        self.assertIn("unreadable", entry)
        self.assertNotIn("sha256", entry)
        self.assertNotIn("preview", entry)

    def test_unreadable_file_does_not_crash_diff(self):
        unreadable = self.watched / "noperm.txt"
        unreadable.write_text("cant touch this")
        unreadable.chmod(0o000)
        try:
            config = senechal.load_config(self.config_path)
            old = senechal.take_snapshot(config)
            new = senechal.take_snapshot(config)
            changes = senechal.diff_snapshots(old, new)
        finally:
            unreadable.chmod(0o644)
        self.assertNotIn(str(unreadable), changes["modified"])

    def test_unreadable_subdirectory_is_flagged_not_silently_dropped(self):
        noperm_dir = self.watched / "noperm_dir"
        noperm_dir.mkdir()
        (noperm_dir / "secret_inside.txt").write_text("would be silently skipped")
        noperm_dir.chmod(0o000)
        try:
            entries = senechal.scan_path(str(self.watched))
        finally:
            noperm_dir.chmod(0o755)
        dir_entry = next(e for e in entries if e["path"].endswith("noperm_dir"))
        self.assertIn("unreadable", dir_entry)
        self.assertTrue(dir_entry.get("directory"))
        self.assertFalse(any(e["path"].endswith("secret_inside.txt") for e in entries))
        # sibling files outside the unreadable directory still get scanned normally
        self.assertTrue(any(e["path"].endswith("hello.sh") for e in entries))

    def test_unreadable_subdirectory_does_not_crash_diff(self):
        noperm_dir = self.watched / "noperm_dir"
        noperm_dir.mkdir()
        noperm_dir.chmod(0o000)
        try:
            config = senechal.load_config(self.config_path)
            old = senechal.take_snapshot(config)
            new = senechal.take_snapshot(config)
            changes = senechal.diff_snapshots(old, new)
        finally:
            noperm_dir.chmod(0o755)
        self.assertNotIn(str(noperm_dir), changes["modified"])

    def test_symlink_directory_cycle_does_not_hang(self):
        looped = self.watched / "looped"
        looped.mkdir()
        (looped / "back_to_watched").symlink_to(self.watched)
        entries = senechal.scan_path(str(self.watched))
        self.assertTrue(any(e["path"].endswith("hello.sh") for e in entries))

    def test_serial_key_content_is_redacted(self):
        (self.watched / "Synergy.conf").write_text("serialKey=7B76313B70726F3B")
        config = senechal.load_config(self.config_path)
        snapshot = senechal.take_snapshot(config)
        entries = {e["path"]: e for e in snapshot["paths"][str(self.watched)]}
        entry = next(e for p, e in entries.items() if p.endswith("Synergy.conf"))
        self.assertIsNone(entry["preview"])
        self.assertTrue(entry["redacted"])

    def test_diff_detects_added_modified_removed(self):
        config = senechal.load_config(self.config_path)
        old = senechal.take_snapshot(config)

        (self.watched / "hello.sh").write_text("echo goodbye")
        (self.watched / "new.sh").write_text("echo new")
        new = senechal.take_snapshot(config)

        changes = senechal.diff_snapshots(old, new)
        self.assertIn(str(self.watched / "new.sh"), changes["added"])
        self.assertIn(str(self.watched / "hello.sh"), changes["modified"])
        self.assertEqual(changes["removed"], [])

    def test_main_writes_dated_snapshot_file(self):
        senechal.main([
            "--config", str(self.config_path),
            "--journal", str(self.journal),
            "--today", "2026-01-01",
        ])
        self.assertTrue((self.journal / "2026-01-01.json").exists())

    def test_main_survives_corrupted_previous_snapshot(self):
        self.journal.mkdir()
        (self.journal / "2026-01-01.json").write_text("not valid json{{{")
        senechal.main([
            "--config", str(self.config_path),
            "--journal", str(self.journal),
            "--today", "2026-01-02",
        ])
        self.assertTrue((self.journal / "2026-01-02.json").exists())

    def test_config_missing_watch_key_raises_clear_error(self):
        with self.assertRaisesRegex(ValueError, "watch"):
            senechal.take_snapshot({})

    def test_config_watch_key_not_a_list_raises_clear_error(self):
        # A string "watch" value would otherwise iterate silently as one
        # bogus single-character path per character instead of failing loud.
        with self.assertRaisesRegex(ValueError, "watch"):
            senechal.take_snapshot({"watch": "~/.bashrc"})

    def test_reconcile_footprint_flags_undeclared_present_path(self):
        result = senechal.reconcile_footprint(["/a", "/b"], ["/a"])
        self.assertEqual(result, {"undeclared": ["/b"], "missing": []})

    def test_reconcile_footprint_flags_declared_but_missing_path(self):
        result = senechal.reconcile_footprint(["/a"], ["/a", "/b"])
        self.assertEqual(result, {"undeclared": [], "missing": ["/b"]})

    def test_reconcile_footprint_empty_when_declared_matches_actual(self):
        result = senechal.reconcile_footprint(["/a", "/b"], ["/b", "/a"])
        self.assertEqual(result, {"undeclared": [], "missing": []})

    def test_reconcile_footprint_directory_declaration_covers_files_under_it(self):
        # A declared entry naming a directory (e.g. "~/.local/bin", the
        # shape real "declare your host footprint" notes actually use)
        # should cover every actual file under it, not just an exact
        # string match -- otherwise every real declaration of this shape
        # would misfire as all-undeclared on day one.
        result = senechal.reconcile_footprint(
            ["/home/zach/.local/bin/foo.sh", "/home/zach/.local/bin/bar.sh"],
            ["/home/zach/.local/bin"],
        )
        self.assertEqual(result, {"undeclared": [], "missing": []})

    def test_reconcile_footprint_directory_declaration_with_trailing_slash(self):
        result = senechal.reconcile_footprint(
            ["/home/zach/.local/bin/foo.sh"], ["/home/zach/.local/bin/"]
        )
        self.assertEqual(result, {"undeclared": [], "missing": []})

    def test_reconcile_footprint_directory_declaration_still_missing_if_empty(self):
        # A declared directory with nothing actually found under it (or
        # matching it exactly) is still a real "missing" case -- the fix
        # only stops false positives, it doesn't stop covering real gaps.
        result = senechal.reconcile_footprint(["/other/file"], ["/home/zach/.local/bin"])
        self.assertEqual(result, {"undeclared": ["/other/file"], "missing": ["/home/zach/.local/bin"]})

    def test_reconcile_footprint_similar_prefix_is_not_falsely_covered(self):
        # "/home/zach/.local/bin2" must not be treated as covered by a
        # declared "/home/zach/.local/bin" -- string startswith without a
        # "/" boundary would wrongly match this.
        result = senechal.reconcile_footprint(
            ["/home/zach/.local/bin2/foo.sh"], ["/home/zach/.local/bin"]
        )
        self.assertEqual(
            result,
            {"undeclared": ["/home/zach/.local/bin2/foo.sh"], "missing": ["/home/zach/.local/bin"]},
        )

    def test_reconcile_footprint_expands_tilde_in_declared_paths(self):
        # A hand-written declared_footprint entry copied from prose (e.g.
        # FOCUS.md's own "installs into ~/.local/bin" examples) must match
        # the already-expanded absolute paths scan_path/scan_remote_path
        # actually produce, not be compared to them literally.
        home = os.path.expanduser("~")
        result = senechal.reconcile_footprint(
            [f"{home}/.local/bin/hello.sh"], ["~/.local/bin"]
        )
        self.assertEqual(result, {"undeclared": [], "missing": []})

    def test_reconcile_footprint_tilde_declaration_still_flags_real_gaps(self):
        # The tilde fix shouldn't swallow genuine mismatches -- an actual
        # file outside the declared (expanded) directory is still undeclared,
        # and the declared directory is still missing if nothing is under it.
        result = senechal.reconcile_footprint(["/other/file"], ["~/.local/bin"])
        home = os.path.expanduser("~")
        self.assertEqual(
            result,
            {"undeclared": ["/other/file"], "missing": [f"{home}/.local/bin"]},
        )

    def test_take_snapshot_flags_footprint_reconciliation_when_configured(self):
        config = senechal.load_config(self.config_path)
        config["declared_footprint"] = [str(self.watched / "hello.sh"), str(self.watched / "gone.sh")]
        snapshot = senechal.take_snapshot(config)
        self.assertEqual(snapshot["footprint_reconciliation"]["undeclared"], [])
        self.assertEqual(
            snapshot["footprint_reconciliation"]["missing"],
            [str(self.watched / "gone.sh")],
        )

    def test_take_snapshot_omits_footprint_reconciliation_when_not_configured(self):
        config = senechal.load_config(self.config_path)
        snapshot = senechal.take_snapshot(config)
        self.assertNotIn("footprint_reconciliation", snapshot)

    def test_take_snapshot_non_list_declared_footprint_raises_clear_error(self):
        config = senechal.load_config(self.config_path)
        config["declared_footprint"] = "not-a-list"
        with self.assertRaisesRegex(ValueError, "declared_footprint"):
            senechal.take_snapshot(config)

    def test_take_snapshot_non_string_declared_footprint_entry_raises_clear_error(self):
        config = senechal.load_config(self.config_path)
        config["declared_footprint"] = [123]
        with self.assertRaisesRegex(ValueError, "123"):
            senechal.take_snapshot(config)


def _fake_ssh_ndjson(lines):
    """Build a fake `run` callable for scan_remote_path returning canned NDJSON."""
    def run(ssh_host, script, timeout=120):
        return 0, "\n".join(json.dumps(line) for line in lines), ""
    return run


class RemoteScanTest(unittest.TestCase):
    def test_scan_remote_path_decodes_and_classifies_files(self):
        content = base64.b64encode(b"echo remote hello").decode()
        run = _fake_ssh_ndjson([{"path": "C:\\Users\\zach\\hello.ps1", "content_b64": content}])
        entries = senechal.scan_remote_path("dexter", "C:\\Users\\zach", run=run)
        self.assertEqual(len(entries), 1)
        entry = entries[0]
        self.assertEqual(entry["path"], "dexter:C:\\Users\\zach\\hello.ps1")
        self.assertEqual(entry["preview"], "echo remote hello")
        self.assertIn("sha256", entry)

    def test_scan_remote_path_redacts_secret_content(self):
        content = base64.b64encode(b"api_key=super-secret-value").decode()
        run = _fake_ssh_ndjson([{"path": "C:\\Users\\zach\\creds.ps1", "content_b64": content}])
        entries = senechal.scan_remote_path("dexter", "C:\\Users\\zach", run=run)
        entry = entries[0]
        self.assertIsNone(entry["preview"])
        self.assertTrue(entry["redacted"])

    def test_scan_remote_path_surfaces_remote_unreadable_files(self):
        run = _fake_ssh_ndjson([{"path": "C:\\Users\\zach\\locked.ps1", "unreadable": "Access denied"}])
        entries = senechal.scan_remote_path("dexter", "C:\\Users\\zach", run=run)
        self.assertEqual(entries[0]["path"], "dexter:C:\\Users\\zach\\locked.ps1")
        self.assertEqual(entries[0]["unreadable"], "Access denied")

    def test_scan_remote_path_flags_line_missing_content_b64(self):
        # A remote line that's neither "unreadable" nor has "content_b64" --
        # e.g. a future PowerShell-side bug that omits the field -- must be
        # flagged, not crash the whole remote scan with a KeyError.
        run = _fake_ssh_ndjson([{"path": "C:\\Users\\zach\\weird.ps1"}])
        entries = senechal.scan_remote_path("dexter", "C:\\Users\\zach", run=run)
        self.assertEqual(len(entries), 1)
        self.assertIn("unreadable", entries[0])
        self.assertNotIn("sha256", entries[0])

    def test_scan_remote_path_missing_path_key_entries_stay_distinct(self):
        # Two remote lines both missing "path" entirely must not collapse to
        # the same "host:?" label -- that would silently overwrite one
        # file's snapshot entry with the other's in _flatten_entries/diff.
        run = _fake_ssh_ndjson([
            {"content_b64": "aGk="},
            {"content_b64": "eW8="},
        ])
        entries = senechal.scan_remote_path("dexter", "C:\\Users\\zach", run=run)
        self.assertEqual(len(entries), 2)
        self.assertNotEqual(entries[0]["path"], entries[1]["path"])
        for e in entries:
            self.assertIn("unreadable", e)

    def test_scan_remote_path_flags_invalid_base64_without_crashing(self):
        # Corrupted/truncated base64 (e.g. a partial SSH read) must be
        # flagged, not crash the whole remote scan with a binascii.Error.
        run = _fake_ssh_ndjson([{"path": "C:\\Users\\zach\\bad.ps1", "content_b64": "not-valid-base64!!!"}])
        entries = senechal.scan_remote_path("dexter", "C:\\Users\\zach", run=run)
        self.assertEqual(len(entries), 1)
        self.assertIn("unreadable", entries[0])
        self.assertNotIn("sha256", entries[0])

    def test_scan_remote_path_flags_non_string_content_b64_without_crashing(self):
        # content_b64 of the wrong JSON type (e.g. a number) must be
        # flagged, not crash the whole remote scan with a TypeError.
        run = _fake_ssh_ndjson([{"path": "C:\\Users\\zach\\odd.ps1", "content_b64": 12345}])
        entries = senechal.scan_remote_path("dexter", "C:\\Users\\zach", run=run)
        self.assertEqual(len(entries), 1)
        self.assertIn("unreadable", entries[0])

    def test_scan_remote_path_flags_non_dict_json_line_without_crashing(self):
        # A line that's valid JSON but not an object (e.g. a bare number, or
        # a PowerShell serialization quirk) must be flagged, not crash the
        # whole remote scan with an AttributeError on .get().
        def run(ssh_host, script, timeout=120):
            return 0, "42\n", ""
        entries = senechal.scan_remote_path("dexter", "C:\\Users\\zach", run=run)
        self.assertEqual(len(entries), 1)
        self.assertIn("unreadable", entries[0])

    def test_scan_remote_path_flags_nonzero_ssh_exit(self):
        def run(ssh_host, script, timeout=120):
            return 255, "", "ssh: Could not resolve hostname dexter"
        entries = senechal.scan_remote_path("dexter", "C:\\Users\\zach", run=run)
        self.assertEqual(len(entries), 1)
        self.assertIn("unreadable", entries[0])
        self.assertIn("ssh exited 255", entries[0]["unreadable"])

    def test_scan_remote_path_flags_ssh_exception_without_crashing(self):
        def run(ssh_host, script, timeout=120):
            raise subprocess.TimeoutExpired(cmd="ssh", timeout=timeout)
        entries = senechal.scan_remote_path("dexter", "C:\\Users\\zach", run=run)
        self.assertEqual(len(entries), 1)
        self.assertIn("unreadable", entries[0])

    def test_build_remote_scan_script_escapes_embedded_quotes(self):
        script = senechal.build_remote_scan_script('C:\\Users\\zach\\weird "path"')
        self.assertIn('weird `"path`"', script)

    def test_take_snapshot_includes_remote_hosts(self):
        content = base64.b64encode(b"remote script").decode()
        run = _fake_ssh_ndjson([{"path": "C:\\scripts\\a.ps1", "content_b64": content}])
        config = {
            "watch": [],
            "remote_hosts": [{"name": "dexter", "ssh_host": "dexter", "watch": ["C:\\scripts"]}],
        }
        orig_scan_remote_path = senechal.scan_remote_path
        senechal.scan_remote_path = lambda ssh_host, path: orig_scan_remote_path(ssh_host, path, run=run)
        try:
            snapshot = senechal.take_snapshot(config)
        finally:
            senechal.scan_remote_path = orig_scan_remote_path
        entries = snapshot["remote_paths"]["dexter"]["C:\\scripts"]
        self.assertEqual(entries[0]["path"], "dexter:C:\\scripts\\a.ps1")
        self.assertEqual(entries[0]["preview"], "remote script")

    def test_take_snapshot_remote_hosts_not_a_list_raises_clear_error(self):
        with self.assertRaisesRegex(ValueError, "remote_hosts"):
            senechal.take_snapshot({"watch": [], "remote_hosts": "dexter"})

    def test_take_snapshot_remote_host_missing_name_raises_clear_error(self):
        with self.assertRaisesRegex(ValueError, "\"name\""):
            senechal.take_snapshot({
                "watch": [],
                "remote_hosts": [{"ssh_host": "dexter", "watch": ["C:\\scripts"]}],
            })

    def test_take_snapshot_remote_host_watch_not_a_list_raises_clear_error(self):
        with self.assertRaisesRegex(ValueError, "dexter"):
            senechal.take_snapshot({
                "watch": [],
                "remote_hosts": [{"name": "dexter", "watch": "C:\\scripts"}],
            })

    def test_take_snapshot_duplicate_remote_host_name_raises_clear_error(self):
        with self.assertRaisesRegex(ValueError, "dexter"):
            senechal.take_snapshot({
                "watch": [],
                "remote_hosts": [
                    {"name": "dexter", "ssh_host": "dexterA", "watch": ["C:\\a.txt"]},
                    {"name": "dexter", "ssh_host": "dexterB", "watch": ["C:\\b.txt"]},
                ],
            })

    def test_take_snapshot_non_string_remote_host_name_raises_clear_error(self):
        with self.assertRaisesRegex(ValueError, "\"name\""):
            senechal.take_snapshot({
                "watch": [],
                "remote_hosts": [{"name": 123, "watch": ["C:\\scripts"]}],
            })

    def test_take_snapshot_non_string_remote_host_ssh_host_raises_clear_error(self):
        with self.assertRaisesRegex(ValueError, "ssh_host"):
            senechal.take_snapshot({
                "watch": [],
                "remote_hosts": [{"name": "dexter", "ssh_host": 123, "watch": ["C:\\scripts"]}],
            })

    def test_take_snapshot_non_dict_remote_host_entry_raises_clear_error(self):
        with self.assertRaisesRegex(ValueError, "not an object"):
            senechal.take_snapshot({"watch": [], "remote_hosts": [123]})

    def test_take_snapshot_null_remote_host_entry_raises_clear_error(self):
        with self.assertRaisesRegex(ValueError, "not an object"):
            senechal.take_snapshot({"watch": [], "remote_hosts": [None]})

    def test_take_snapshot_non_string_watch_entry_raises_clear_error(self):
        with self.assertRaisesRegex(ValueError, "123"):
            senechal.take_snapshot({"watch": [123]})

    def test_take_snapshot_non_string_remote_watch_entry_raises_clear_error(self):
        with self.assertRaisesRegex(ValueError, "dexter"):
            senechal.take_snapshot({
                "watch": [],
                "remote_hosts": [{"name": "dexter", "watch": [123]}],
            })

    def test_diff_snapshots_covers_remote_paths(self):
        old = {"paths": {}, "remote_paths": {"dexter": {"C:\\scripts": [
            {"path": "dexter:C:\\scripts\\a.ps1", "sha256": "aaa"},
        ]}}}
        new = {"paths": {}, "remote_paths": {"dexter": {"C:\\scripts": [
            {"path": "dexter:C:\\scripts\\a.ps1", "sha256": "bbb"},
            {"path": "dexter:C:\\scripts\\b.ps1", "sha256": "ccc"},
        ]}}}
        changes = senechal.diff_snapshots(old, new)
        self.assertIn("dexter:C:\\scripts\\a.ps1", changes["modified"])
        self.assertIn("dexter:C:\\scripts\\b.ps1", changes["added"])

class InlineAuthorizationHeaderTest(unittest.TestCase):
    """The Authorization pattern must not require the header to start a line.

    Found by the journal auditor's own test fixture: the anchored version
    missed `curl -H "Authorization: Basic ..."`, the shape that actually
    occurs in the watched ~/.local/bin scripts.
    """

    def test_inline_basic_auth_header_is_redacted(self):
        self.assertTrue(senechal.looks_secret(
            """curl -H 'Authorization: Basic aGVsbG86d29ybGQ=' https://x"""))

    def test_inline_custom_scheme_header_is_redacted(self):
        self.assertTrue(senechal.looks_secret(
            'curl -H "Authorization: Token abc123def456" https://x'))

    def test_line_anchored_header_still_redacted(self):
        self.assertTrue(senechal.looks_secret("Authorization: Basic abc\n"))

    def test_plain_script_without_auth_header_stays_previewable(self):
        self.assertFalse(senechal.looks_secret("#!/bin/sh\necho hello\n"))


class JournalAuditTest(unittest.TestCase):
    """--audit: re-check already-written snapshots against today's patterns.

    Everything here runs against a temp journal dir; the real journal/ is
    never touched.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.journal = Path(self.tmp.name) / "journal"
        self.journal.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def write_snapshot(self, name, entries, section="paths"):
        if section == "paths":
            data = {"paths": {"/watched": entries}}
        else:
            data = {"paths": {}, "remote_paths": {"dexter": {"C:\\s": entries}}}
        (self.journal / name).write_text(json.dumps(data))

    def audit(self):
        return senechal._run_audit(self.journal)

    # --- the core case this exists for ---------------------------------
    def test_clean_snapshot_passes(self):
        self.write_snapshot("2026-01-01.json", [
            {"path": "/watched/a.sh", "sha256": "aa", "preview": "echo hello"},
            {"path": "/watched/k", "sha256": "bb", "preview": None, "redacted": True},
        ])
        self.assertEqual(self.audit(), 0)

    def test_preview_with_secret_content_is_a_finding(self):
        # The retroactive case: written when SECRET_PATTERNS was weaker, so
        # a live-looking key sits in git as plaintext today.
        self.write_snapshot("2026-01-01.json", [
            {"path": "/watched/deploy.sh", "sha256": "aa",
             "preview": "export TOKEN\ncurl -H 'Authorization: Basic aGVsbG86d29ybGQ='\n"},
        ])
        self.assertEqual(self.audit(), 1)

    def test_finding_is_reported_without_echoing_the_secret(self):
        # The auditor's own output lands in cron mail and reports; it must
        # name the file, never reproduce the offending text.
        leak = "AKIAIOSFODNN7EXAMPLE"
        snapshot = {"paths": {"/watched": [
            {"path": "/watched/aws.sh", "sha256": "aa", "preview": f"key={leak}"},
        ]}}
        findings = senechal.audit_snapshot(snapshot)
        self.assertEqual(len(findings), 1)
        path, problem = findings[0]
        self.assertEqual(path, "/watched/aws.sh")
        self.assertNotIn(leak, problem)

    def test_secret_in_remote_snapshot_section_is_also_audited(self):
        self.write_snapshot("2026-01-01.json", [
            {"path": "dexter:C:\\s\\a.ps1", "sha256": "aa",
             "preview": "$k = 'sk_live_abcdefghij1234567890'"},
        ], section="remote_paths")
        self.assertEqual(self.audit(), 1)

    # --- contract violations -------------------------------------------
    def test_redacted_flag_with_non_null_preview_is_a_finding(self):
        problems = senechal.audit_entry(
            {"path": "/p", "preview": "harmless text", "redacted": True})
        self.assertTrue(any("redacted" in p for p in problems))

    def test_binary_flag_with_non_null_preview_is_a_finding(self):
        problems = senechal.audit_entry(
            {"path": "/p", "preview": "harmless text", "binary": True})
        self.assertTrue(any("binary" in p for p in problems))

    def test_non_string_preview_is_a_finding_and_does_not_crash(self):
        problems = senechal.audit_entry({"path": "/p", "preview": 42})
        self.assertEqual(len(problems), 1)
        self.assertIn("expected string or null", problems[0])

    # --- "could not look" never reads as a pass -------------------------
    def test_missing_journal_dir_is_incomplete_not_pass(self):
        missing = Path(self.tmp.name) / "nope"
        self.assertEqual(senechal._run_audit(missing), 2)

    def test_empty_journal_dir_is_incomplete_not_pass(self):
        self.assertEqual(self.audit(), 2)

    def test_corrupt_snapshot_is_incomplete_not_pass(self):
        (self.journal / "2026-01-01.json").write_text("{not json")
        self.assertEqual(self.audit(), 2)

    def test_corrupt_snapshot_does_not_mask_a_leak_in_a_readable_one(self):
        # Severity: a real finding outranks a could-not-read, so the exit
        # code must stay 1 rather than degrading to 2.
        (self.journal / "2026-01-01.json").write_text("{not json")
        self.write_snapshot("2026-01-02.json", [
            {"path": "/watched/a.sh", "sha256": "aa", "preview": "api_key=hunter2"},
        ])
        self.assertEqual(self.audit(), 1)

    def test_snapshot_that_is_not_an_object_is_incomplete(self):
        (self.journal / "2026-01-01.json").write_text('["a list"]')
        self.assertEqual(self.audit(), 2)

    # --- malformed entries are audited, not skipped ---------------------
    def test_malformed_entry_does_not_crash_the_audit(self):
        (self.journal / "2026-01-01.json").write_text(json.dumps(
            {"paths": {"/watched": ["not an object", 42]}}))
        self.assertEqual(self.audit(), 1)

    def test_entry_missing_path_key_is_still_audited(self):
        # _flatten_entries would KeyError here; the auditor must not.
        (self.journal / "2026-01-01.json").write_text(json.dumps(
            {"paths": {"/watched": [{"sha256": "aa", "preview": "api_key=hunter2"}]}}))
        self.assertEqual(self.audit(), 1)

    def test_two_entries_sharing_one_path_are_both_audited(self):
        # _flatten_entries keys by path and would drop the first of these,
        # hiding a leak behind a later clean entry with the same path.
        snapshot = {"paths": {"/watched": [
            {"path": "/dup", "sha256": "aa", "preview": "api_key=hunter2"},
            {"path": "/dup", "sha256": "bb", "preview": "echo fine"},
        ]}}
        self.assertEqual(len(senechal.audit_snapshot(snapshot)), 1)

    # --- --audit must not need a config or write anything ---------------
    def test_audit_needs_no_config_file_and_writes_nothing(self):
        self.write_snapshot("2026-01-01.json", [
            {"path": "/watched/a.sh", "sha256": "aa", "preview": "echo hi"},
        ])
        before = sorted(p.name for p in self.journal.iterdir())
        rc = senechal.main([
            "--journal", str(self.journal),
            "--config", str(Path(self.tmp.name) / "does-not-exist.json"),
            "--audit",
        ])
        self.assertEqual(rc, 0)
        self.assertEqual(sorted(p.name for p in self.journal.iterdir()), before)


class SymlinkedDirectoryTest(unittest.TestCase):
    """A symlink to a directory inside a watched tree.

    Before this was handled, the walk followed it silently: content from
    outside the watched tree landed in a git-committed snapshot under paths
    that ran *through* the link, with nothing recording that a boundary had
    been crossed or where the link pointed.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.watched = self.root / "bin"
        self.watched.mkdir()
        self.outside = self.root / "outside"
        (self.outside / "deep").mkdir(parents=True)
        (self.outside / "deep" / "note.txt").write_text("hi")
        self.link = self.watched / "link"
        self.link.symlink_to(self.outside)

    def tearDown(self):
        self.tmp.cleanup()

    def by_path(self, entries):
        return {e["path"]: e for e in entries}

    def test_symlinked_directory_is_recorded_with_its_target(self):
        entries = self.by_path(senechal.scan_path(str(self.watched)))
        entry = entries[str(self.link)]
        self.assertEqual(entry["symlink_to"], str(self.outside))
        self.assertTrue(entry["directory"])

    def test_symlinked_directory_is_still_followed_by_default(self):
        # Stow-style ~/dotfiles layouts are entirely symlinks into a repo;
        # not following would drop real content.
        entries = self.by_path(senechal.scan_path(str(self.watched)))
        self.assertIn(str(self.link / "deep" / "note.txt"), entries)

    def test_not_following_says_so_rather_than_looking_empty(self):
        entries = self.by_path(
            senechal.scan_path(str(self.watched), follow_symlinked_dirs=False))
        self.assertNotIn(str(self.link / "deep" / "note.txt"), entries)
        self.assertIn("not followed", entries[str(self.link)]["unreadable"])

    def test_plain_directory_is_not_reported_as_a_symlink(self):
        (self.watched / "real").mkdir()
        (self.watched / "real" / "x.sh").write_text("echo x")
        entries = self.by_path(senechal.scan_path(str(self.watched)))
        self.assertNotIn(str(self.watched / "real"), entries)

    def test_repointed_symlink_shows_up_as_modified(self):
        # The entry has no sha256, so a hash-only diff would call this
        # unchanged -- but the link now points somewhere else entirely.
        old = {"paths": {"w": senechal.scan_path(str(self.watched))}}
        other = self.root / "other"
        other.mkdir()
        self.link.unlink()
        self.link.symlink_to(other)
        new = {"paths": {"w": senechal.scan_path(str(self.watched))}}
        self.assertIn(str(self.link), senechal.diff_snapshots(old, new)["modified"])

    def test_unchanged_symlink_is_not_reported_as_modified(self):
        snap = {"paths": {"w": senechal.scan_path(str(self.watched))}}
        self.assertEqual(senechal.diff_snapshots(snap, snap)["modified"], [])

    def test_config_toggle_is_honoured(self):
        config = {"watch": [str(self.watched)], "follow_symlinked_dirs": False}
        entries = self.by_path(senechal.take_snapshot(config)["paths"][str(self.watched)])
        self.assertNotIn(str(self.link / "deep" / "note.txt"), entries)

    def test_non_boolean_toggle_fails_loud(self):
        # "false" is truthy -- silently the opposite of what the config says.
        config = {"watch": [str(self.watched)], "follow_symlinked_dirs": "false"}
        with self.assertRaises(ValueError):
            senechal.take_snapshot(config)

    def test_symlink_cycle_still_terminates(self):
        (self.outside / "back").symlink_to(self.watched)
        entries = self.by_path(senechal.scan_path(str(self.watched)))
        self.assertIn(str(self.link), entries)


if __name__ == "__main__":
    unittest.main()
