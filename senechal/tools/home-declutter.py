#!/usr/bin/env python3
"""senechal: heuristic $HOME decluttering with a hardlink guard and a
garde-backed recoverability check. Never deletes a live file directly --
`quarantine` only ever moves (mv, same filesystem by construction: the
quarantine root lives under $HOME) into ~/.senechal-quarantine/<date>/,
and `purge` -- the only irreversible step -- is always a manual,
explicit action (the acting-authority rules `discipline` prints: this repo's own
mission change makes reversible ops like a quarantine move an unattended
"act, then report" case, but it draws the line at anything hard to
undo).

A candidate only reaches quarantine after clearing TWO independent
gates:

  1. hardlink guard -- belt: every file under the candidate has
     st_nlink == 1 (no other directory entry anywhere on this
     filesystem points at the same inode). suspenders: for anything
     that trips the belt, `find <declutter roots> -xdev -samefile`
     independently locates the sibling path(s), so the report names
     what it's linked to instead of just refusing silently. (nlink and
     `find -samefile` both ultimately read the same inode metadata, so
     this is not protection against a lying filesystem -- it is
     protection against a bug in how *this script* reads or interprets
     that metadata, and it turns a bare refusal into an actionable
     "linked from X".)
  2. recoverability -- either the candidate matches a declared
     "regenerable" pattern (caches, __pycache__, *.tmp -- expected to
     be recreated, not restored), or `garde <path>` confirms it has an
     off-machine copy. Real content with no backup and no regenerable
     classification is left alone and reported as such, never
     quarantined on a guess.

Candidate discovery classes:

  - regenerable -- pattern match across a whole tree (roots configured
    narrow, e.g. Downloads/Desktop); a matched directory is quarantined
    whole and not descended into further.
  - stale_download -- extension + age match, top-level only within its
    roots.
  - debris -- name-shaped stray-leftover signals (pre-migration backup
    suffixes like *.pre-*-migration.*, conflict-resolution snapshot
    suffixes like *.conflicted-snapshot-*, temp/tmp-token names), plus,
    independent of name, zero-byte files. Walks its roots recursively
    like regenerable, but is deliberately files-only -- a directory
    whose name happens to match is never quarantined whole, since that
    blast radius is bigger than intended for this class. This is NOT
    "regenerable": it is real leftover content that just happens to be
    junk-shaped by its name, so it still needs garde coverage like
    stale_download does. Added 2026-08-04 after an interactive session
    with Zach identified this naming pattern recurring outside
    Downloads (e.g. a stray `.pre-mixes-migration.<date>` config copy,
    a `.conflicted-snapshot-<date>` doc, a bare `tempblockers.md`).

See ESTATE.md finding 1 (closed 2026-08-04), and
gardien-garde's `garde <path>` for the backup half this leans on.
"""
import argparse
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = REPO_ROOT / "senechal.json"

RC_PASS, RC_FAIL, RC_INCOMPLETE, RC_WARN = 0, 1, 2, 3

DEFAULT_DECLUTTER_CONFIG = {
    "quarantine_root": "~/.senechal-quarantine",
    "purge_after_days": 30,
    "exclude": [],
    "regenerable": {"roots": [], "patterns": []},
    "stale_downloads": {"roots": [], "stale_days": 180, "extensions": []},
    "debris": {"roots": [], "patterns": [], "treat_zero_byte_as_debris": True},
}

# temp/tmp as a whole token/prefix/suffix segment of the basename -- NOT a
# blind substring search. "tempblockers.md" and "old.tmp.bak" match (temp/tmp
# starts or ends a segment); "attempt.md" and "contemplate.txt" do not (temp
# is buried mid-word, not at a segment boundary).
_TEMP_TOKENS = ("temp", "tmp")


def _looks_like_temp_name(name):
    lower = name.lower()
    stem = lower.rsplit(".", 1)[0] if "." in lower else lower
    segments = [s for s in re.split(r"[^a-z0-9]+", lower) if s]
    if any(seg in _TEMP_TOKENS for seg in segments):
        return True
    return any(
        lower.startswith(tok) or stem.endswith(tok) for tok in _TEMP_TOKENS
    )


def expand(p):
    return Path(p).expanduser().resolve(strict=False)


def load_declutter_config(config_path):
    try:
        with open(config_path) as f:
            full = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise SystemExit(f"could not read {config_path}: {e}")
    cfg = dict(DEFAULT_DECLUTTER_CONFIG)
    cfg.update(full.get("declutter", {}))
    for key, default in DEFAULT_DECLUTTER_CONFIG.items():
        if isinstance(default, dict):
            merged = dict(default)
            merged.update(cfg.get(key) or {})
            cfg[key] = merged
    return cfg


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def under_any(path, roots):
    """True if path is exactly one of roots or nested under one."""
    for r in roots:
        r = expand(r)
        if path == r or r in path.parents:
            return True
    return False


# --------------------------------------------------------------------
# candidate discovery
# --------------------------------------------------------------------

def _walk_regenerable(root, patterns, exclude):
    root = expand(root)
    if not root.is_dir():
        return
    stack = [root]
    while stack:
        d = stack.pop()
        try:
            children = list(os.scandir(d))
        except OSError:
            continue
        for child in children:
            p = Path(child.path)
            if under_any(p, exclude) or child.name == ".git":
                # .git is never a candidate and is never worth descending
                # into (real repo history, and can be huge) -- hardcoded,
                # not config, so a thin exclude list can't accidentally
                # expose it.
                continue
            name = child.name
            if any(fnmatch.fnmatch(name, pat) for pat in patterns):
                yield p, f"matches regenerable pattern"
                continue  # don't descend into a matched dir either
            if child.is_dir(follow_symlinks=False):
                stack.append(p)


def _stale_downloads(roots, stale_days, extensions, exclude):
    if not extensions:
        return
    cutoff = time.time() - stale_days * 86400
    for root in roots:
        root = expand(root)
        if not root.is_dir():
            continue
        try:
            children = list(os.scandir(root))
        except OSError:
            continue
        for child in children:
            p = Path(child.path)
            if under_any(p, exclude) or not child.is_file(follow_symlinks=False):
                continue
            if not any(p.name.lower().endswith(ext.lower()) for ext in extensions):
                continue
            try:
                mtime = child.stat().st_mtime
            except OSError:
                continue
            if mtime <= cutoff:
                age_days = int((time.time() - mtime) / 86400)
                yield p, f"stale download, {age_days}d old, matches {p.suffix or p.name}"


def _walk_debris(root, patterns, treat_zero_byte, exclude):
    """Like _walk_regenerable (same scandir+stack shape, same exclude/.git
    handling), but files-only: a directory is always descended into and
    never itself yielded as a candidate, even if its own name matches one
    of `patterns`. Whole-directory quarantine is a bigger blast radius than
    this class is meant for -- see the module docstring's `debris` entry.
    If a real case for whole-directory debris turns up, reconsider this
    restriction explicitly rather than relaxing it quietly."""
    root = expand(root)
    if not root.is_dir():
        return
    stack = [root]
    while stack:
        d = stack.pop()
        try:
            children = list(os.scandir(d))
        except OSError:
            continue
        for child in children:
            p = Path(child.path)
            if under_any(p, exclude) or child.name == ".git":
                continue
            if child.is_dir(follow_symlinks=False):
                stack.append(p)
                continue
            if not child.is_file(follow_symlinks=False):
                continue
            name = child.name
            if any(fnmatch.fnmatch(name, pat) for pat in patterns):
                yield p, "matches debris-name pattern"
                continue
            if _looks_like_temp_name(name):
                yield p, "temp/tmp-shaped stray name"
                continue
            if treat_zero_byte:
                try:
                    if child.stat(follow_symlinks=False).st_size == 0:
                        yield p, "zero-byte file"
                except OSError:
                    pass


def find_candidates(cfg):
    exclude = list(cfg["exclude"]) + [cfg["quarantine_root"]]
    candidates = []
    for root in cfg["regenerable"].get("roots") or []:
        for p, reason in _walk_regenerable(root, cfg["regenerable"].get("patterns") or [], exclude):
            candidates.append({"path": p, "reason": reason, "class": "regenerable"})
    for p, reason in _stale_downloads(
        cfg["stale_downloads"].get("roots") or [],
        cfg["stale_downloads"].get("stale_days", 180),
        cfg["stale_downloads"].get("extensions") or [],
        exclude,
    ):
        candidates.append({"path": p, "reason": reason, "class": "stale_download"})
    for root in cfg["debris"].get("roots") or []:
        for p, reason in _walk_debris(
            root,
            cfg["debris"].get("patterns") or [],
            cfg["debris"].get("treat_zero_byte_as_debris", True),
            exclude,
        ):
            candidates.append({"path": p, "reason": reason, "class": "debris"})
    return candidates


# --------------------------------------------------------------------
# gate 1: hardlink guard
# --------------------------------------------------------------------

def _files_under(path):
    if path.is_file():
        yield path
    elif path.is_dir():
        for dirpath, _dirnames, filenames in os.walk(path):
            for fn in filenames:
                yield Path(dirpath) / fn


def hardlink_check(path, search_roots):
    """Belt: nlink>1 on any contained file. Suspenders: for anything that
    trips the belt, an independent `find -xdev -samefile` sweep over the
    configured search roots, to name the sibling path rather than just a
    count. Returns (clear: bool, evidence: [str])."""
    evidence = []
    for f in _files_under(path):
        try:
            nlink = f.stat().st_nlink
        except OSError as e:
            evidence.append(f"could not stat {f}: {e}")
            continue
        if nlink > 1:
            siblings = _find_samefile(f, search_roots)
            if siblings:
                evidence.append(f"{f} has {nlink} links, also at: {', '.join(siblings)}")
            else:
                evidence.append(
                    f"{f} has {nlink} links but no sibling found under search roots "
                    "(likely linked from outside them -- treating as unsafe)"
                )
    return (not evidence, evidence)


def _find_samefile(f, search_roots):
    siblings = []
    for root in search_roots:
        root = expand(root)
        if not root.exists():
            continue
        try:
            proc = subprocess.run(
                ["find", str(root), "-xdev", "-samefile", str(f)],
                capture_output=True, text=True, timeout=60,
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        for line in proc.stdout.splitlines():
            if line and line != str(f):
                siblings.append(line)
    return siblings


# --------------------------------------------------------------------
# gate 2: recoverability
# --------------------------------------------------------------------

def garde_coverage(path):
    """Returns 'covered' / 'uncovered' / 'unknown'.

    `garde <path>` (basheur/contracts/garde-coverage.contract) prints the
    maximal uncovered subtree roots inside <path>, one per line, and its
    exit code follows diff/grep, NOT the usual pass/fail convention:
      0 = at least one uncovered path found (listed on stdout)
      1 = the whole tree was walked and everything is covered (silent)
      2 = could not fully walk it / manifest unreadable -- not a verdict
    It also only accepts a readable DIRECTORY as <path> ("not a readable
    directory" otherwise) -- a file candidate is checked via its parent
    directory, then matched against the printed uncovered roots.
    """
    target = path if path.is_dir() else path.parent
    try:
        proc = subprocess.run(
            ["garde", str(target)], capture_output=True, text=True, timeout=60
        )
    except FileNotFoundError:
        return "unknown", "garde not on PATH"
    except subprocess.TimeoutExpired:
        return "unknown", "garde timed out"

    if proc.returncode == 1 and not proc.stdout.strip():
        return "covered", None
    if proc.returncode == 0:
        uncovered_roots = [line for line in proc.stdout.splitlines() if line]
        hit = [
            r for r in uncovered_roots
            if r == str(path) or str(path).startswith(r.rstrip("/") + "/")
            or r.startswith(str(path).rstrip("/") + "/")
        ]
        if hit:
            return "uncovered", hit[:5]
        return "covered", None
    return "unknown", f"garde exited {proc.returncode}: {proc.stderr.strip()[:200]}"


def classify(candidate, cfg, search_roots):
    path = candidate["path"]
    clear, hardlink_evidence = hardlink_check(path, search_roots)
    if not clear:
        return {**candidate, "verdict": "SKIP_HARDLINK", "evidence": hardlink_evidence}

    if candidate["class"] == "regenerable":
        return {**candidate, "verdict": "SAFE", "evidence": ["regenerable, no restore needed"]}

    status, detail = garde_coverage(path)
    if status == "covered":
        return {**candidate, "verdict": "SAFE", "evidence": ["garde: fully covered off-machine"]}
    if status == "uncovered":
        return {**candidate, "verdict": "SKIP_UNCOVERED", "evidence": detail}
    return {**candidate, "verdict": "SKIP_UNKNOWN", "evidence": [detail]}


# --------------------------------------------------------------------
# manifest
# --------------------------------------------------------------------

def manifest_path(quarantine_root):
    return expand(quarantine_root) / "manifest.json"


def load_manifest(quarantine_root):
    mp = manifest_path(quarantine_root)
    if not mp.exists():
        return []
    try:
        return json.loads(mp.read_text())
    except (OSError, json.JSONDecodeError) as e:
        raise SystemExit(f"manifest at {mp} is unreadable ({e}) -- not touching quarantine "
                          "until this is fixed by hand; a corrupt manifest must never be "
                          "silently treated as empty")


def save_manifest(quarantine_root, entries):
    mp = manifest_path(quarantine_root)
    mp.parent.mkdir(parents=True, exist_ok=True)
    mp.write_text(json.dumps(entries, indent=2, sort_keys=True))


def hash_tree(path):
    """{relpath: sha256} for a file or directory, so verify can later
    confirm nothing in quarantine silently changed or partially vanished."""
    if path.is_file():
        return {path.name: sha256_file(path)}
    out = {}
    for f in _files_under(path):
        out[str(f.relative_to(path))] = sha256_file(f)
    return out


# --------------------------------------------------------------------
# verbs
# --------------------------------------------------------------------

def cmd_scan(cfg, args):
    search_roots = (
        (cfg["regenerable"].get("roots") or [])
        + (cfg["stale_downloads"].get("roots") or [])
        + (cfg["debris"].get("roots") or [])
    )
    candidates = find_candidates(cfg)
    if not candidates:
        print("no candidates found under the configured roots.")
        return RC_PASS
    results = [classify(c, cfg, search_roots) for c in candidates]
    for r in results:
        print(f"  {r['verdict']:<15} {r['path']}  -- {r['reason']}")
        for e in r["evidence"]:
            print(f"      {e}")
    safe = sum(1 for r in results if r["verdict"] == "SAFE")
    print(f"\n{safe}/{len(results)} candidate(s) clear both gates (hardlink guard + "
          "recoverability). Nothing was touched -- this is scan, not quarantine.")
    return RC_PASS


def cmd_quarantine(cfg, args):
    search_roots = (
        (cfg["regenerable"].get("roots") or [])
        + (cfg["stale_downloads"].get("roots") or [])
        + (cfg["debris"].get("roots") or [])
    )
    candidates = find_candidates(cfg)
    results = [classify(c, cfg, search_roots) for c in candidates]
    safe = [r for r in results if r["verdict"] == "SAFE"]
    skipped = [r for r in results if r["verdict"] != "SAFE"]

    for r in skipped:
        print(f"  SKIP  {r['path']} ({r['verdict']}): {'; '.join(str(e) for e in r['evidence'])}")

    if not safe:
        print("nothing cleared both gates -- quarantine moved nothing.")
        return RC_PASS

    quarantine_root = expand(cfg["quarantine_root"])
    date_dir = quarantine_root / datetime.now().strftime("%Y-%m-%d")
    manifest = load_manifest(cfg["quarantine_root"])

    home = Path.home()
    for r in safe:
        path = r["path"]
        try:
            rel = path.relative_to(home)
        except ValueError:
            rel = Path(str(path).lstrip("/"))
        dest = date_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        file_hashes = hash_tree(path)
        size_bytes = sum(f.stat().st_size for f in _files_under(path))
        _move(path, dest)
        manifest.append({
            "quarantined_at": datetime.now().isoformat(timespec="seconds"),
            "original_path": str(path),
            "quarantine_path": str(dest),
            "class": r["class"],
            "reason": r["reason"],
            "evidence": [str(e) for e in r["evidence"]],
            "file_hashes": file_hashes,
            "size_bytes": size_bytes,
            "purged_at": None,
        })
        print(f"  QUARANTINED  {path} -> {dest}")

    save_manifest(cfg["quarantine_root"], manifest)
    print(f"\n{len(safe)} item(s) moved to {date_dir}. Recoverable with a plain `mv` "
          f"back from the path in {manifest_path(cfg['quarantine_root'])} until purged. "
          f"Purge is manual: {sys.argv[0]} purge --confirm")
    return RC_PASS


def _move(src, dest):
    try:
        os.rename(src, dest)
    except OSError:
        # cross-device (quarantine_root on a different filesystem than the
        # candidate) -- fall back to copy+remove, still same semantics.
        import shutil
        if src.is_dir():
            shutil.copytree(src, dest)
            shutil.rmtree(src)
        else:
            shutil.copy2(src, dest)
            src.unlink()


def cmd_verify(cfg, args):
    quarantine_root = expand(cfg["quarantine_root"])
    if not quarantine_root.exists():
        print("SKIP  no quarantine directory yet -- nothing to verify (could not check, not a pass)")
        return RC_INCOMPLETE

    manifest = load_manifest(cfg["quarantine_root"])
    fails, warns = [], []
    purge_after = timedelta(days=cfg["purge_after_days"])
    now = datetime.now()

    for entry in manifest:
        if entry.get("purged_at"):
            continue
        qpath = Path(entry["quarantine_path"])
        if not qpath.exists():
            fails.append(f"{qpath} is in the manifest, not marked purged, but missing on disk "
                         "(manually deleted outside this tool, or tampered)")
            continue
        current = hash_tree(qpath)
        if current != entry["file_hashes"]:
            fails.append(f"{qpath} content changed since quarantine (hash mismatch)")
            continue
        quarantined_at = datetime.fromisoformat(entry["quarantined_at"])
        if now - quarantined_at > purge_after:
            warns.append(f"{qpath} has been quarantined {  (now - quarantined_at).days }d "
                         f"(> {cfg['purge_after_days']}d) -- ready for a manual purge")

    for f in fails:
        print(f"  FAIL  {f}")
    for w in warns:
        print(f"  WARN  {w}")

    if fails:
        print(f"\nFAILED -- {len(fails)} manifest/quarantine mismatch(es).")
        return RC_FAIL
    if warns:
        print(f"\nWARN -- {len(warns)} item(s) past the purge grace period, awaiting a manual purge.")
        return RC_WARN
    print(f"OK -- {len(manifest)} manifest entries, quarantine consistent.")
    return RC_PASS


def cmd_purge(cfg, args):
    if not args.confirm:
        print("refusing: purge is the one irreversible step in this tool and requires "
              "--confirm, run by hand. (acting-authority rules; run `discipline`.)")
        return RC_FAIL

    quarantine_root = expand(cfg["quarantine_root"])
    manifest = load_manifest(cfg["quarantine_root"])
    purge_after = timedelta(days=cfg["purge_after_days"])
    now = datetime.now()
    purged = 0

    for entry in manifest:
        if entry.get("purged_at"):
            continue
        quarantined_at = datetime.fromisoformat(entry["quarantined_at"])
        if now - quarantined_at <= purge_after:
            continue
        qpath = Path(entry["quarantine_path"])
        if not qpath.exists():
            print(f"  SKIP  {qpath} already gone")
            continue
        current = hash_tree(qpath)
        if current != entry["file_hashes"]:
            print(f"  SKIP  {qpath} content changed since quarantine -- not purging, "
                  "investigate by hand")
            continue
        import shutil
        if qpath.is_dir():
            shutil.rmtree(qpath)
        else:
            qpath.unlink()
        entry["purged_at"] = now.isoformat(timespec="seconds")
        purged += 1
        print(f"  PURGED  {qpath} (was {entry['original_path']})")

    save_manifest(cfg["quarantine_root"], manifest)
    print(f"\n{purged} item(s) purged.")
    return RC_PASS


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    sub = ap.add_subparsers(dest="verb", required=True)
    sub.add_parser("scan", help="report candidates and gate verdicts; touches nothing")
    sub.add_parser("quarantine", help="move SAFE candidates into quarantine_root")
    sub.add_parser("verify", help="non-mutating: manifest integrity + purge-due warnings")
    p_purge = sub.add_parser("purge", help="delete quarantined items past purge_after_days")
    p_purge.add_argument("--confirm", action="store_true", help="required; purge is irreversible")

    args = ap.parse_args(argv)
    cfg = load_declutter_config(args.config)

    if not (
        cfg["regenerable"].get("roots")
        or cfg["stale_downloads"].get("roots")
        or cfg["debris"].get("roots")
    ):
        print("declutter.regenerable.roots, declutter.stale_downloads.roots and "
              "declutter.debris.roots are all empty in senechal.json -- nothing "
              "configured to scan. See senechal.json.example.", file=sys.stderr)
        return RC_INCOMPLETE

    return {
        "scan": cmd_scan,
        "quarantine": cmd_quarantine,
        "verify": cmd_verify,
        "purge": cmd_purge,
    }[args.verb](cfg, args)


if __name__ == "__main__":
    sys.exit(main())
