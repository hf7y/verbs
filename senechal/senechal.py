#!/usr/bin/env python3
"""senechal: retrospective observer of Zach's Linux laptop environment.

Snapshots the shape of a set of watched paths (custom bin/ scripts, dotfiles,
keybinding/WM config) over time so a fresh machine can be reconstructed from
the journal instead of memory. Secrets are redacted before anything is
written to disk, since this journal is meant to be committed to git.
"""
import argparse
import base64
import binascii
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import date
from pathlib import Path

# The config belongs to the MACHINE, not to any checkout: XDG config,
# which outlives every build, worktree and clone (hf7y/senechal#67). The
# journal deliberately stays in the checkout: it is tracked, and
# committing it over time IS the record.
DEFAULT_CONFIG = Path(
    os.environ.get("SENECHAL_CONFIG")
    or Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    / "senechal" / "senechal.json"
)
DEFAULT_JOURNAL = Path(__file__).parent / "journal"

# Patterns that mean "don't ever write this file's content, hash-only."
SECRET_PATTERNS = [
    # [A-Z ]* both before and after "PRIVATE KEY" -- covers plain PEM
    # headers ("RSA PRIVATE KEY", "OPENSSH PRIVATE KEY") as well as GPG's
    # own export format, which has trailing words before the closing
    # dashes ("-----BEGIN PGP PRIVATE KEY BLOCK-----"). A version of this
    # pattern requiring "PRIVATE KEY" immediately before "-----" missed
    # that shape entirely -- confirmed by hand before this fix.
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY[A-Z ]*-----"),
    # No leading \b before the keyword: \b treats "_" as a word char, so a
    # strict \bsecret\b would miss real-world snake_case shapes like
    # "aws_secret_access_key = ..." or "access_token = ..." (the "_" before
    # the keyword means there's no boundary there at all). The trailing
    # (?![a-z]) still excludes "secretary=", "tokenizer=", etc.
    # ["']? before \s*[:=] handles JSON/quoted-key shapes like
    # `"password": "hunter2"`, where a closing quote sits between the key
    # and the colon and would otherwise break the immediately-following match.
    re.compile(r"(?i)api[_-]?key(?![a-z])[a-z0-9_-]*[\"']?\s*[:=]"),
    re.compile(r"(?i)token(?![a-z])[a-z0-9_-]*[\"']?\s*[:=]"),
    re.compile(r"(?i)password(?![a-z])[a-z0-9_-]*[\"']?\s*[:=]"),
    re.compile(r"(?i)secret(?![a-z])[a-z0-9_-]*[\"']?\s*[:=]"),
    re.compile(r"(?i)serial[_-]?key(?![a-z])[a-z0-9_-]*[\"']?\s*[:=]"),  # e.g. Synergy.conf's serialKey=
    re.compile(r"AKIA[0-9A-Z]{16}"),  # AWS access key ID
    re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"),  # GitHub classic personal/app tokens
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),  # GitHub fine-grained PATs
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),  # Slack tokens
    # These three carry their own unambiguous prefix, so (unlike api_key=/
    # token= etc. above) they're worth matching even with no keyword nearby
    # -- a bare Stripe/Google/npm key hardcoded in a script has no "key="
    # to anchor on but is still unambiguously a live secret.
    re.compile(r"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{10,}"),  # Stripe secret/restricted keys
    re.compile(r"AIza[0-9A-Za-z_-]{35}"),  # Google API keys
    re.compile(r"npm_[A-Za-z0-9]{36}"),  # npm access tokens
    re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._-]{10,}"),  # generic bearer tokens
    # Any Authorization header line, e.g. "Authorization: Basic <base64>" or
    # "Authorization: Token abc123" -- these don't fit the bearer pattern
    # above (different scheme keyword) or the api_key=/token= keyword
    # patterns (no "=" or ":" right after the keyword, it's after
    # "Authorization" instead). The header's value is credential material
    # by definition, so redact the whole line rather than trying to match
    # every auth-scheme keyword individually.
    #
    # NOT anchored with ^\s* (an earlier version was): the single most
    # common real shape in a watched ~/.local/bin script is an inline
    # `curl -H "Authorization: Basic <b64>"`, where the header sits
    # mid-line behind -H and a quote. The anchored version missed exactly
    # that, and the `bearer` pattern above only covered it by accident
    # when the scheme happened to be Bearer -- Basic and custom schemes
    # fell through to a plaintext preview. Unanchored over-redacts prose
    # mentioning "Authorization:", which is the direction this project
    # prefers when a pattern is ambiguous (README.md).
    re.compile(r"(?i)authorization\s*:\s*\S+"),
    re.compile(r"eyJ[A-Za-z0-9_-]{5,}\.eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}"),  # JWTs
    re.compile(r"(?im)^\s*machine\s+\S+\s+login\s+\S+\s+password\s+\S+"),  # .netrc entries
    # Credentials embedded in a connection-string URL, e.g.
    # postgres://user:hunter2@host/db or redis://:hunter2@host. Requires a
    # non-empty password segment between ":" and "@" so plain
    # scheme://user@host (no password, e.g. git/ssh remotes) isn't flagged.
    re.compile(r"[a-zA-Z][a-zA-Z0-9+.-]*://[^/\s:@]*:[^/\s@]+@"),
]


def looks_secret(text):
    return any(p.search(text) for p in SECRET_PATTERNS)


def load_config(path):
    with open(path) as f:
        return json.load(f)


def is_binary(raw):
    return b"\x00" in raw


def _build_file_entry(path_str, raw):
    """Classify raw file bytes into a journal entry -- shared by local and
    remote scanning so redaction runs through exactly one code path.
    """
    entry = {"path": path_str, "sha256": hashlib.sha256(raw).hexdigest()}
    if is_binary(raw):
        entry["preview"] = None
        entry["binary"] = True
    else:
        text = raw.decode(errors="ignore")
        if looks_secret(text):
            entry["preview"] = None
            entry["redacted"] = True
        else:
            entry["preview"] = text[:2000]
    return entry


def _walk_files(root, follow_symlinked_dirs=True):
    """Manually walk root, returning
    (files, unreadable_dirs, special_files, dir_symlinks).

    Unlike Path.rglob, this catches PermissionError per-directory instead of
    silently dropping the whole subtree — an inaccessible directory should be
    visible in the snapshot, not indistinguishable from an empty one.

    A symlink *to a directory* is reported in its own right (dir_symlinks)
    rather than only being walked through. Two reasons, both real for this
    estate:
      - Walking through it silently leaves the watched tree. One
        `~/.local/bin/x -> ~/Documents/Projects/somerepo` would pull that
        whole repo into a snapshot that gets committed to git, with nothing
        in the output saying a boundary was crossed. `~/.local/bin` is
        exactly where this estate's symlinks live (see the scheduler
        entries in the issue tracker), so this is a shape that can actually turn up.
      - The recorded paths run *through* the link (".../x/deep/file"), so a
        snapshot alone can't tell that `x` is a link at all, let alone where
        it points -- and "reconstruct a fresh machine from the journal"
        means recreating the symlink, not materialising a copy of its target.
    Following is still the default (`follow_symlinked_dirs`): a stow-style
    `~/dotfiles` layout, planned since 2026-07-26, is
    entirely symlinks into a repo, and refusing to follow would drop real
    content. The point here is that the crossing stops being invisible.
    """
    files = []
    unreadable_dirs = []
    special_files = []
    dir_symlinks = []
    seen = set()
    stack = [root]
    while stack:
        d = stack.pop()
        try:
            real = d.resolve()
        except OSError:
            real = d
        if real in seen:
            continue  # symlink cycle guard
        seen.add(real)
        try:
            with os.scandir(d) as it:
                children = list(it)
        except OSError as e:
            unreadable_dirs.append((d, str(e)))
            continue
        for child in children:
            p = Path(child.path)
            if child.is_dir(follow_symlinks=True):
                if child.is_symlink():
                    try:
                        target = os.readlink(p)
                    except OSError as e:
                        target = f"<unreadable link target: {e}>"
                    dir_symlinks.append((p, target))
                    if not follow_symlinked_dirs:
                        continue
                stack.append(p)
            elif child.is_symlink():
                # Three distinct outcomes, and only the first is a normal
                # file. The other two used to be silently dropped -- the
                # same vanish-with-no-trace class already fixed for plain
                # special files below, just reached via a symlink:
                #   - dangles (target deleted): a real estate finding in its
                #     own right, e.g. an orphaned ~/.local/bin entry whose
                #     script was removed. "Absent from the snapshot" is
                #     indistinguishable from "never existed", which is
                #     exactly the memory this journal is supposed to keep.
                #   - resolves to a socket/device/FIFO: can't be hashed, but
                #     shouldn't disappear either.
                if not p.exists():
                    special_files.append((p, "broken symlink"))
                elif p.is_file():
                    files.append(p)
                else:
                    special_files.append((p, "not a regular file or directory"))
            elif child.is_file(follow_symlinks=False):
                files.append(p)
            else:
                # A device, socket, FIFO, or other special file found while
                # walking a watched directory -- not a regular file, so it
                # can't be hashed/read, but it shouldn't vanish from the
                # snapshot the way it would if this branch just did nothing.
                # (scan_path already flags this shape when it's the watch
                # root itself; this is the same case one level deeper.)
                special_files.append((p, "not a regular file or directory"))
    return files, unreadable_dirs, special_files, dir_symlinks


def scan_path(watched_path, follow_symlinked_dirs=True):
    root = Path(watched_path).expanduser()
    entries = []
    if not root.exists():
        if root.is_symlink():
            # Exists as a symlink but dangles. Distinct from "this watched
            # path isn't on this machine" (the plain-return case below): the
            # path IS there, it just points at nothing, which is a finding.
            return [{"path": str(root), "unreadable": "broken symlink"}]
        return entries
    if root.is_file():
        paths, unreadable_dirs, special_files, dir_symlinks = [root], [], [], []
    elif root.is_dir():
        paths, unreadable_dirs, special_files, dir_symlinks = _walk_files(
            root, follow_symlinked_dirs=follow_symlinked_dirs
        )
        paths.sort()
    else:
        # A device, socket, FIFO, or other special file listed directly in
        # the watch list — not a regular file or directory, so don't label
        # it "directory: True" (misleading) or try to scandir/read it.
        return [{"path": str(root), "unreadable": "not a regular file or directory"}]
    for d, reason in sorted(unreadable_dirs, key=lambda item: str(item[0])):
        entries.append({"path": str(d), "unreadable": reason, "directory": True})
    for p, reason in sorted(special_files, key=lambda item: str(item[0])):
        entries.append({"path": str(p), "unreadable": reason})
    for p, target in sorted(dir_symlinks, key=lambda item: str(item[0])):
        entry = {"path": str(p), "symlink_to": target, "directory": True}
        if not follow_symlinked_dirs:
            # Say so in the entry itself: "no files under this path" must not
            # be readable as "the target was empty".
            entry["unreadable"] = "symlinked directory not followed (follow_symlinked_dirs is false)"
        entries.append(entry)
    for p in paths:
        if not p.is_file():
            # Raced: the file was here during the walk and isn't now (or
            # was replaced by a non-regular file). Record it rather than
            # dropping it -- a silent disappearance would read in tomorrow's
            # diff as a deliberate removal.
            entries.append({"path": str(p), "unreadable": "vanished or changed type during scan"})
            continue
        try:
            raw = p.read_bytes()
        except OSError as e:
            entries.append({"path": str(p), "unreadable": str(e)})
            continue
        entries.append(_build_file_entry(str(p), raw))
    return entries


def build_remote_scan_script(remote_path):
    """PowerShell script run on a remote Windows host over SSH.

    Emits one compact JSON object per line (NDJSON) for every file under
    remote_path: either {"path", "content_b64"} or {"path", "unreadable"}.
    Content comes back as base64, not previewed/redacted remotely -- redaction
    must run through looks_secret() on this side (see _build_file_entry), the
    same single code path local scanning uses, before anything is written.
    scp/sftp don't work against this project's Windows OpenSSH setup (see
    crt/HANDOFF.md), hence the base64-over-stdout pipe instead of a file copy.
    """
    escaped = remote_path.replace("`", "``").replace('"', '`"')
    return f'''$ErrorActionPreference = "Stop"
$root = "{escaped}"
if (-not (Test-Path -LiteralPath $root)) {{ exit 0 }}
$item = Get-Item -LiteralPath $root -Force
if ($item.PSIsContainer) {{
    $files = Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue
}} else {{
    $files = @($item)
}}
foreach ($f in $files) {{
    try {{
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        $obj = [ordered]@{{ path = $f.FullName; content_b64 = [Convert]::ToBase64String($bytes) }}
    }} catch {{
        $obj = [ordered]@{{ path = $f.FullName; unreadable = $_.Exception.Message }}
    }}
    Write-Output ($obj | ConvertTo-Json -Compress)
}}
'''


def _run_ssh(ssh_host, script, timeout=120):
    """Run a PowerShell script on ssh_host over ssh.

    Sent via -EncodedCommand (base64 UTF-16LE), not piped over stdin to
    `-Command -`: confirmed against the real dexter host that Windows
    PowerShell 5.1 silently mis-parses multi-line brace blocks (if/else
    spanning lines) read that way over a non-interactive SSH session --
    the run exits 0 with no output and no error, not a loud failure.
    -EncodedCommand sidesteps that whole class of stdin-parsing quirk.

    Split out so tests can substitute a fake runner instead of touching a
    real network/host -- kept as thin as possible around subprocess.
    """
    encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    proc = subprocess.run(
        ["ssh", ssh_host, "powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return proc.returncode, proc.stdout, proc.stderr


def scan_remote_path(ssh_host, remote_path, run=_run_ssh):
    label = f"{ssh_host}:{remote_path}"
    script = build_remote_scan_script(remote_path)
    try:
        returncode, stdout, stderr = run(ssh_host, script)
    except (OSError, subprocess.TimeoutExpired) as e:
        return [{"path": label, "unreadable": f"ssh failed: {e}"}]
    if returncode != 0:
        return [{"path": label, "unreadable": f"ssh exited {returncode}: {stderr.strip()}"}]
    entries = []
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            entries.append({"path": label, "unreadable": f"unparseable remote output line: {line[:200]!r}"})
            continue
        if not isinstance(obj, dict):
            entries.append({"path": label, "unreadable": f"unexpected remote output line: {line[:200]!r}"})
            continue
        if "path" not in obj:
            # A remote line with no "path" key at all would otherwise all
            # collapse to the same "host:?" label -- since journal entries
            # are keyed by path (_flatten_entries, diff_snapshots), a second
            # such file would silently overwrite the first in the snapshot
            # instead of both surviving as distinct, if malformed, entries.
            entries.append({"path": f"{ssh_host}:?:{line[:80]}", "unreadable": "remote line missing path"})
            continue
        path_str = f"{ssh_host}:{obj['path']}"
        if "unreadable" in obj:
            entries.append({"path": path_str, "unreadable": obj["unreadable"]})
            continue
        if "content_b64" not in obj:
            entries.append({"path": path_str, "unreadable": "remote line missing content_b64"})
            continue
        try:
            raw = base64.b64decode(obj["content_b64"], validate=True)
        except (binascii.Error, ValueError, TypeError) as e:
            entries.append({"path": path_str, "unreadable": f"invalid base64 from remote: {e}"})
            continue
        entries.append(_build_file_entry(path_str, raw))
    entries.sort(key=lambda e: e["path"])
    return entries


def take_snapshot(config):
    if "watch" not in config:
        raise ValueError(
            "config has no \"watch\" key -- expected a list of paths to "
            "scan (see senechal.json.example)"
        )
    if not isinstance(config["watch"], list):
        # A string would otherwise iterate silently as one bogus
        # single-character path per character instead of failing loud.
        raise ValueError(
            "config's \"watch\" key must be a list of paths, got "
            f"{type(config['watch']).__name__} (see senechal.json.example)"
        )
    follow_symlinked_dirs = config.get("follow_symlinked_dirs", True)
    if not isinstance(follow_symlinked_dirs, bool):
        # A string "false" is truthy, which would silently mean the exact
        # opposite of what a hand-edited config says.
        raise ValueError(
            "config's \"follow_symlinked_dirs\" key must be true or false, got "
            f"{follow_symlinked_dirs!r} (see senechal.json.example)"
        )
    snapshot = {"paths": {}}
    for watched in config["watch"]:
        if not isinstance(watched, str):
            # Path(123).expanduser() raises a raw TypeError with no mention
            # of which config entry caused it -- fail loud with the actual
            # offending value instead.
            raise ValueError(
                f"config's \"watch\" list has a non-string entry: {watched!r} "
                "(see senechal.json.example)"
            )
        snapshot["paths"][watched] = scan_path(
            watched, follow_symlinked_dirs=follow_symlinked_dirs
        )

    remote_hosts = config.get("remote_hosts", [])
    if not isinstance(remote_hosts, list):
        raise ValueError(
            "config's \"remote_hosts\" key must be a list of host entries "
            "(see senechal.json.example)"
        )
    if remote_hosts:
        snapshot["remote_paths"] = {}
    for host in remote_hosts:
        if not isinstance(host, dict):
            # "name" not in host would otherwise raise a raw TypeError for
            # non-iterable entries (int, None, ...) -- or silently pass for
            # a list/string that happens to not contain "name" -- neither of
            # which points at the actual malformed config entry.
            raise ValueError(
                f"a remote_hosts entry is not an object: {host!r} -- "
                "expected {\"name\": ..., \"watch\": [...]} (see senechal.json.example)"
            )
        if "name" not in host:
            raise ValueError(
                "a remote_hosts entry has no \"name\" key -- expected "
                "{\"name\": ..., \"watch\": [...]} (see senechal.json.example)"
            )
        name = host["name"]
        if not isinstance(name, str):
            # A non-string name (e.g. a stray int/null from a hand-edited
            # config) reaches subprocess.run(["ssh", ssh_host, ...]) as the
            # ssh_host argument by default (see below) and crashes deep
            # inside subprocess with an unhelpful TypeError -- confirmed by
            # hand before this fix. Fail loud here instead, at the point
            # that actually knows which config entry is wrong.
            raise ValueError(
                f"a remote_hosts entry's \"name\" must be a string, got "
                f"{name!r} (see senechal.json.example)"
            )
        if name in snapshot["remote_paths"]:
            # Without this check, a second entry with the same "name" would
            # silently overwrite the first host's scan results in the dict
            # below -- the whole first host's data vanishes from the
            # snapshot with no error, indistinguishable from it never having
            # been configured at all.
            raise ValueError(
                f"remote_hosts has more than one entry named {name!r} -- "
                "names must be unique, later entries silently overwrite "
                "earlier ones (see senechal.json.example)"
            )
        ssh_host = host.get("ssh_host", name)
        if not isinstance(ssh_host, str):
            raise ValueError(
                f"remote_hosts entry {name!r}'s \"ssh_host\" must be a "
                f"string, got {ssh_host!r} (see senechal.json.example)"
            )
        host_watch = host.get("watch", [])
        if not isinstance(host_watch, list):
            # Same silent-per-character-path bug as the top-level "watch"
            # key, just scoped to one host -- a string here would otherwise
            # iterate as bogus single-character remote paths instead of
            # failing loud.
            raise ValueError(
                f"remote_hosts entry {name!r}'s \"watch\" key must be a "
                f"list of paths, got {type(host_watch).__name__} "
                "(see senechal.json.example)"
            )
        snapshot["remote_paths"][name] = {}
        for watched in host_watch:
            if not isinstance(watched, str):
                raise ValueError(
                    f"remote_hosts entry {name!r}'s \"watch\" list has a "
                    f"non-string entry: {watched!r} (see senechal.json.example)"
                )
            snapshot["remote_paths"][name][watched] = scan_remote_path(ssh_host, watched)

    if "declared_footprint" in config:
        declared_footprint = config["declared_footprint"]
        if not isinstance(declared_footprint, list):
            raise ValueError(
                "config's \"declared_footprint\" key must be a list of "
                f"path strings, got {type(declared_footprint).__name__} "
                "(see senechal.json.example)"
            )
        for entry in declared_footprint:
            if not isinstance(entry, str):
                raise ValueError(
                    "config's \"declared_footprint\" list has a "
                    f"non-string entry: {entry!r} (see senechal.json.example)"
                )
        snapshot["footprint_reconciliation"] = reconcile_footprint(
            _flatten_entries(snapshot).keys(), declared_footprint
        )
    return snapshot


def reconcile_footprint(actual_paths, declared_paths):
    """Compare paths senechal actually found against a declared footprint.

    Both args are iterables of path strings (local paths as scanned, or
    remote paths in the "host:path" form scan_remote_path produces).
    Returns two distinct cases per the "Shared-host script/autostart
    ownership" build (issue #7): "undeclared" (present but never declared anywhere --
    a real orphan) and "missing" (declared but no longer present -- retired
    in name only, or a stale declaration). Order-independent by design: a
    project might declare its footprint before or after senechal's next
    scan picks it up.

    A declared entry may name a directory rather than an individual file --
    real "declare your host footprint" notes tend to say things like
    "installs into ~/.local/bin", not enumerate every script by name. Treat
    a declared path as covering any actual path that starts with it plus a
    "/" boundary (not just an exact string match), so declaring a directory
    doesn't flag every file under it as undeclared and the directory itself
    as missing. Exact-match declarations of individual files still work
    exactly as before.

    Declared entries are also "~"-expanded before comparison: actual paths
    always come out of scan_path/scan_remote_path already expanded (via
    Path.expanduser()), but a hand-written declared_footprint entry copied
    from prose -- a declaration literally says things like "installs into
    ~/.local/bin" -- would otherwise never match anything, false-flagging
    every real file under it as undeclared and the entry itself as missing.
    A remote "host:path" entry has no leading "~" to expand and is left as-is.
    """
    actual = set(actual_paths)
    declared = {os.path.expanduser(d) for d in declared_paths}

    def under_declared_dir(path):
        return any(path.startswith(d.rstrip("/") + "/") for d in declared)

    def has_actual_under(declared_path):
        prefix = declared_path.rstrip("/") + "/"
        return any(a.startswith(prefix) for a in actual)

    undeclared = [a for a in actual if a not in declared and not under_declared_dir(a)]
    missing = [d for d in declared if d not in actual and not has_actual_under(d)]
    return {
        "undeclared": sorted(undeclared),
        "missing": sorted(missing),
    }


def audit_entry(entry):
    """Re-check one already-written journal entry against today's rules.

    Returns a list of problem strings (empty == clean). This is the
    last-line-of-defense check on the one invariant that matters most:
    secret-looking content must never sit in a committed `journal/*.json`
    as plaintext.

    Worth running even though `_build_file_entry` already redacts at write
    time, because that check ran against *the patterns of the day the
    snapshot was written*. Every snapshot in `journal/` is committed to
    git and kept forever, so a pattern added later (the Stripe/Google/npm
    prefixes, the PGP-header fix, the Authorization-header rule -- all of
    which landed after the first snapshots) never retroactively protected
    the history that predates it. Re-auditing the whole journal with the
    current SECRET_PATTERNS is the only thing that finds those.
    """
    problems = []
    preview = entry.get("preview")

    if preview is not None and not isinstance(preview, str):
        problems.append(f"preview is {type(preview).__name__}, expected string or null")
        return problems

    if preview is not None and looks_secret(preview):
        # The serious one: plaintext in git that today's rules call secret.
        problems.append("preview contains secret-looking content but was written unredacted")

    # Contract violations -- the flags and the preview disagree. These are
    # not leaks by themselves, but they mean the writer misbehaved, so the
    # redaction guarantee can't be trusted for this entry either way.
    if entry.get("redacted") and preview is not None:
        problems.append('marked redacted:true but preview is not null')
    if entry.get("binary") and preview is not None:
        problems.append('marked binary:true but preview is not null')

    return problems


def _audit_entries(snapshot):
    """Yield every entry in a snapshot, tolerantly.

    Deliberately does NOT reuse `_flatten_entries`: that one keys by
    `e["path"]` and assumes well-formed lists, so a hand-edited or
    truncated committed snapshot would raise instead of being audited.
    An auditor that crashes on a malformed file is an auditor that
    reports "no problems found" for exactly the files most likely to
    have them. It also keys by path, which would silently collapse two
    entries sharing one path -- fine for diffing, wrong for auditing,
    where every occurrence must be checked.
    """
    for section in ("paths", "remote_paths"):
        block = snapshot.get(section)
        if not isinstance(block, dict):
            continue
        for key, value in sorted(block.items()):
            # paths: {watch_entry: [entry, ...]}
            # remote_paths: {host: {watch_entry: [entry, ...]}}
            groups = value.values() if isinstance(value, dict) else [value]
            for entries in groups:
                if not isinstance(entries, list):
                    continue
                for entry in entries:
                    label = entry.get("path", f"<no path> in {key}") \
                        if isinstance(entry, dict) else f"<malformed> in {key}"
                    yield label, entry


def audit_snapshot(snapshot):
    """Audit every entry in one snapshot. Returns [(path, problem), ...]."""
    findings = []
    for path, entry in _audit_entries(snapshot):
        if not isinstance(entry, dict):
            findings.append((path, "entry is not an object"))
            continue
        for problem in audit_entry(entry):
            findings.append((path, problem))
    return findings


def audit_journal(journal_dir):
    """Audit every snapshot file in journal_dir.

    Returns (findings, unreadable), where findings is
    [(snapshot_name, path, problem), ...] and unreadable is
    [(snapshot_name, reason), ...] -- a snapshot we could not parse is a
    "could not look", never a pass.
    """
    findings = []
    unreadable = []
    for snap in sorted(Path(journal_dir).glob("*.json")):
        try:
            data = json.loads(snap.read_text())
        except (OSError, json.JSONDecodeError) as e:
            unreadable.append((snap.name, str(e)))
            continue
        if not isinstance(data, dict):
            unreadable.append((snap.name, "snapshot is not a JSON object"))
            continue
        for path, problem in audit_snapshot(data):
            findings.append((snap.name, path, problem))
    return findings, unreadable


def _run_audit(journal_dir):
    """--audit entrypoint. Exit 0 clean / 1 findings / 2 could-not-check."""
    journal_dir = Path(journal_dir)
    if not journal_dir.exists():
        print(f"INCOMPLETE -- no journal directory at {journal_dir}; nothing audited "
              "(could not check -- not a pass)", file=sys.stderr)
        return 2

    snaps = sorted(journal_dir.glob("*.json"))
    if not snaps:
        print(f"INCOMPLETE -- no snapshots in {journal_dir}; nothing audited "
              "(could not check -- not a pass)", file=sys.stderr)
        return 2

    findings, unreadable = audit_journal(journal_dir)

    for name, reason in unreadable:
        print(f"  SKIP  {name}: {reason} (could not check -- not a pass)", file=sys.stderr)
    for name, path, problem in findings:
        # Deliberately prints the offending PATH and the problem, never the
        # preview text itself -- this tool's own output must not become a
        # second copy of the leak (it lands in reports and cron mail).
        print(f"  FAIL  {name}: {path}: {problem}", file=sys.stderr)

    if findings:
        print(f"\nFAILED -- {len(findings)} redaction problem(s) across "
              f"{len(snaps)} snapshot(s). These files are committed to git: "
              "fix SECRET_PATTERNS, then rewrite or purge the affected "
              "snapshots -- a later commit does not un-publish an earlier one.",
              file=sys.stderr)
        return 1
    if unreadable:
        print(f"\nINCOMPLETE -- {len(unreadable)} snapshot(s) could not be read.",
              file=sys.stderr)
        return 2
    print(f"OK -- {len(snaps)} snapshot(s) audited, no unredacted secret-looking "
          "previews found.")
    return 0


def _flatten_entries(snapshot):
    flat = {}
    for entries in snapshot.get("paths", {}).values():
        for e in entries:
            flat[e["path"]] = e
    for host_paths in snapshot.get("remote_paths", {}).values():
        for entries in host_paths.values():
            for e in entries:
                flat[e["path"]] = e
    return flat


def diff_snapshots(old, new):
    changes = {"added": [], "removed": [], "modified": []}
    old_by_path = _flatten_entries(old)
    new_by_path = _flatten_entries(new)
    for path, entry in new_by_path.items():
        if path not in old_by_path:
            changes["added"].append(path)
        elif (old_by_path[path].get("sha256") != entry.get("sha256")
              or old_by_path[path].get("symlink_to") != entry.get("symlink_to")):
            # A symlinked-directory entry has no sha256 (nothing to hash), so
            # comparing hashes alone would report "unchanged" for a link that
            # was repointed at a different target -- exactly the estate change
            # worth noticing. Both keys are absent (None) on regular file
            # entries, so this adds no false positives there.
            changes["modified"].append(path)
    for path in old_by_path:
        if path not in new_by_path:
            changes["removed"].append(path)
    return changes


def latest_snapshot_file(journal_dir):
    if not journal_dir.exists():
        return None
    snaps = sorted(journal_dir.glob("*.json"))
    return snaps[-1] if snaps else None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    ap.add_argument("--journal", type=Path, default=DEFAULT_JOURNAL)
    ap.add_argument("--today", help="override today's date (testing)")
    ap.add_argument(
        "--audit",
        action="store_true",
        help="re-check every committed snapshot in journal/ against today's "
             "SECRET_PATTERNS and exit (0 clean / 1 leak found / 2 could not "
             "check). Scans nothing and writes nothing.",
    )
    args = ap.parse_args(argv)

    if args.audit:
        # Runs before load_config on purpose: auditing the journal must work
        # on a checkout with no senechal.json (the config only says what to
        # scan, and --audit scans nothing).
        return _run_audit(args.journal)

    config = load_config(args.config)
    today = args.today or date.today().isoformat()
    args.journal.mkdir(parents=True, exist_ok=True)

    prev_file = latest_snapshot_file(args.journal)
    prev = {"paths": {}}
    if prev_file:
        try:
            prev = json.loads(prev_file.read_text())
        except json.JSONDecodeError as e:
            # A corrupted previous snapshot should only cost us the diff
            # against it, not block writing today's snapshot -- the new
            # scan doesn't depend on the old file at all.
            print(f"warning: {prev_file} is not valid JSON ({e}); diffing against empty history", file=sys.stderr)

    snapshot = take_snapshot(config)
    out_file = args.journal / f"{today}.json"
    out_file.write_text(json.dumps(snapshot, indent=2, sort_keys=True))

    changes = diff_snapshots(prev, snapshot)
    print(f"snapshot written: {out_file}")
    for kind in ("added", "modified", "removed"):
        for p in changes[kind]:
            print(f"  {kind}: {p}")

    reconciliation = snapshot.get("footprint_reconciliation")
    if reconciliation:
        for p in reconciliation["undeclared"]:
            print(f"  undeclared (present, never declared): {p}")
        for p in reconciliation["missing"]:
            print(f"  missing (declared, no longer present): {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
