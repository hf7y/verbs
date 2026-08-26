#!/usr/bin/env python3
"""boundary -- classify every senechal mechanism as fleet, taste, shared or meta.

Zach, 2026-08-23: "Senechal needs to be broken up into a project that is
necessary for self-dev and mandark/zach/taste layer not needed on the
other machines." That there IS a boundary is decided; WHERE it runs is
this registry (registry/boundary.json), not a table in a markdown file
someone forgets to read.

Test applied per entry, Zach's own words: would another machine's
unattended nightly-batch/health run (monkey, dexter, potato, a future
host...) ever need to read this? If yes: fleet. If its failure is only
ever noticed by Zach at his own keyboard (desktop/WM/browser/hardware/
dotfile taste): taste. shared/meta cover files that don't reduce to one
side (see registry/boundary.json's _classes for the exact definitions).

MERGED 2026-08-25 (hf7y/senechal#408). Two independent classifiers of the
same tree existed a day apart, ~900 lines solving one problem twice:
hf7y/senechal#401 (this file, an in-code dict, wired into estate-health.sh
via --audit, carrying DISPOSITION) and hf7y/senechal#397
(tools/repo-boundary.py + registry/repo-boundary.json, a tracked-file
sweep via `git ls-files`, JSON storage, and the shared/meta classes, never
wired into anything). This file now takes: the registry as JSON
(registry/boundary.json, the right shape now the taste half is content,
not code -- Zach, 2026-08-24), the tracked-file sweep (catches files
outside health/remedies/tools -- lib/, bin/, provision/, workstation/,
registry/*.json, man/*.1 -- that a directory walk of three folders
missed), and shared/meta. tools/repo-boundary.py and
registry/repo-boundary.json are deleted; every entry they carried was
folded in, and 23 files the two disagreed on were reconciled by hand
against #396's own criterion (see the commit that landed this for the
per-file reasoning) rather than picked mechanically.

RECONCILED 2026-08-24 (pre-merge). Three overlapping classifications of
these same files existed, and two of them disagreed:

  #348   build-time vs on-a-host, plus a personal-utilities evict list
  #396   fleet vs taste vs ambiguous -- this file's predecessor
  the /ideate pass of 2026-08-24  code vs content

  * ambiguous IS GONE as a class. Zach, 2026-08-24: default to fleet.
    The costs are asymmetric -- a taste item wrongly in the fleet is dead
    weight, a fleet item wrongly in taste is a broken unattended run on
    another host. Former entries keep their reasoning, prefixed
    "was ambiguous".
  * #348 phase 3 ("taste to its own repo") is SUPERSEDED by DISPOSITION
    below: the taste half is content, not a second codebase.
  * #348 phase 2's evict list (appimage-integrate, browse, home-declutter,
    spawn-here) is absorbed as disposition "drop" -- the two rules agree
    on those four, so the list stops living in issue prose.
    appimage-integrate.sh was the first actually dropped (#410, 2026-08-25);
    it carries no entry or disposition row here any more, git history is
    the record.

This registry answers "what would the split look like" without doing
the split itself (new repo, history, every consumer's wiring) -- that
part is still #396's open half.

Usage:
    tools/boundary.py <path>              # classify one file
    tools/boundary.py --list [--class fleet|taste|shared|meta]  # taste rows show [disposition]
    tools/boundary.py --audit             # is every tracked mechanism file registered?

Exit (single-path form): 0 fleet/shared (ships in a fleet build) /
1 taste/meta (does not) / 2 unregistered.
Exit (--audit): RC_PASS (0) clean / RC_FAIL (1) an unregistered file or a
bad class value / RC_WARN (3) only staleness or a missing disposition /
RC_INCOMPLETE (2) the registry or tree could not be read -- same shared
contract as tools/dead-config-keys.py, so estate-health.sh can drive
both the same way.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
REGISTRY_PATH = ROOT / "registry" / "boundary.json"

RC_PASS, RC_FAIL, RC_INCOMPLETE, RC_WARN = 0, 1, 2, 3

CLASSES = ("fleet", "taste", "shared", "meta")
DISPOSITIONS = ("content", "split", "drop", "blocked", "open")


def load_registry(path):
    with open(path) as fh:
        return json.load(fh)


_REGISTRY = load_registry(REGISTRY_PATH)

# Backward-compatible in-memory views, used by classify()/classify_config_key()/
# disposition() below and by every caller that imports this module (e.g.
# tools/absorb-notices.py's `boundary.classify_config_key(target)`).
FILES = {p: (v["class"], v["why"]) for p, v in _REGISTRY["entries"].items()}
CONFIG_KEYS = {k: (v["class"], v["why"]) for k, v in _REGISTRY.get("config_keys", {}).items()}
DISPOSITION = {p: (v["what"], v["why"]) for p, v in _REGISTRY.get("disposition", {}).items()}
TEST_OVERRIDES = {p: (v["class"], v["why"]) for p, v in _REGISTRY.get("test_overrides", {}).items()}


def disposition(rel_path):
    """Return (what, why) for a taste file, or None if it has none."""
    return DISPOSITION.get(rel_path.strip().lstrip("./"))


def _strip_test_prefix(name):
    if name.startswith("_test-"):
        return name[len("_test-"):]
    if name.startswith("test-"):
        return name[len("test-"):]
    return None


def _classify_test_file(rel_path):
    """A test file inherits its target's class. Returns (cls, reason) or None."""
    if rel_path in TEST_OVERRIDES:
        return TEST_OVERRIDES[rel_path]
    directory, _, name = rel_path.rpartition("/")
    target_name = _strip_test_prefix(name)
    if target_name is None:
        return None
    target_path = f"{directory}/{target_name}" if directory else target_name
    if target_path in FILES:
        cls, reason = FILES[target_path]
        return cls, f"inherits {target_path}: {reason}"
    return None


def classify(rel_path):
    """Return (cls, reason) for a repo-relative path, or None if unclassified."""
    rel_path = rel_path.strip().lstrip("./")
    if rel_path in FILES:
        return FILES[rel_path]
    return _classify_test_file(rel_path)


def classify_config_key(key):
    """Return (cls, reason) for a senechal.json[.example] key, or None."""
    return CONFIG_KEYS.get(key)


# --- tracked-file sweep (hf7y/senechal#397's contribution) ------------------
#
# What counts as a "mechanism file": health/*.sh, remedies/**/*.sh,
# remedies/*.md, tools/**/*.{sh,py} plus extension-less executables and
# man-page (.1) files directly under tools/, bin/**, provision/**,
# lib/*.sh, senechal.py, workstation/**, man/*.1, and registry/*.json --
# the things that would actually have to move (or not) if the split
# happened. Test files (test-*, test_*, _test-*), ceiling/baseline/
# quarantine files, and *.example files are never mechanism files: they
# travel with whatever they test or configure, not as independent
# boundary decisions.
TEST_PREFIXES = ("test-", "test_", "_test-")
NEVER_MECHANISM_SUFFIXES = (".ceiling", ".baseline", ".quarantine", ".example", ".md.pyc")
NEVER_MECHANISM_NAMES = (".prose-ratchet",)


def _is_test_or_data(path):
    base = path.rsplit("/", 1)[-1]
    if base.startswith(TEST_PREFIXES):
        return True
    if path.endswith(NEVER_MECHANISM_SUFFIXES):
        return True
    if base in NEVER_MECHANISM_NAMES:
        return True
    return False


def is_mechanism_file(path):
    if _is_test_or_data(path):
        return False
    if path.startswith("health/") and path.endswith(".sh"):
        return True
    if path.startswith("remedies/") and (path.endswith(".sh") or path.endswith(".md")):
        return True
    if path.startswith("tools/"):
        if path.endswith(".sh") or path.endswith(".py"):
            return True
        # extension-less executables, or a bare .1 man page, directly under
        # tools/ (e.g. browse, spawn-here, home-declutter.1) -- but not
        # tools/lib/ data or __pycache__ noise.
        rest = path[len("tools/"):]
        if "/" in rest:
            return False
        return "." not in rest or rest.endswith(".1")
    if path.startswith("bin/"):
        return True
    if path.startswith("provision/"):
        return True
    if path.startswith("lib/") and path.endswith(".sh"):
        return True
    if path == "senechal.py":
        return True
    if path.startswith("workstation/"):
        return True
    if path.startswith("man/") and path.endswith(".1"):
        return True
    if path.startswith("registry/") and path.endswith(".json"):
        return True
    return False


def _tracked_files(root):
    out = subprocess.run(["git", "-C", str(root), "ls-files"],
                          capture_output=True, text=True)
    if out.returncode != 0:
        return None
    return [f for f in out.stdout.split("\n") if f]


def audit(root=None, registry_path=None):
    """Return (rc, problems) -- is every tracked mechanism file registered,
    every registered file's class valid, and every taste file disposed of?

    "I could not read the registry or the tree" must never render as
    "boundary complete": both are RC_INCOMPLETE, never RC_PASS.
    """
    root = root or ROOT
    registry_path = registry_path or REGISTRY_PATH

    try:
        reg = load_registry(registry_path)
    except (OSError, ValueError):
        return RC_INCOMPLETE, [f"incomplete: could not read {registry_path}"]

    entries = reg.get("entries", {})
    if not isinstance(entries, dict):
        return RC_INCOMPLETE, [f"incomplete: {registry_path}'s entries is not a mapping"]

    disposition_map = reg.get("disposition", {})
    if not isinstance(disposition_map, dict):
        disposition_map = {}

    files = _tracked_files(root)
    if files is None:
        return RC_INCOMPLETE, [f"incomplete: could not list tracked files under {root} (git ls-files failed)"]

    mechanism = {f for f in files if is_mechanism_file(f)}
    registered = set(entries)

    problems = []

    unclassified = sorted(mechanism - registered)
    for p in unclassified:
        problems.append(f"unregistered: {p} exists in the tree but has no entry in {registry_path}")

    stale = sorted(registered - mechanism)
    for p in stale:
        problems.append(f"stale: {p} is registered but no longer exists in the tree")

    bad_class = sorted(p for p, v in entries.items()
                        if not isinstance(v, dict) or v.get("class") not in CLASSES)
    for p in bad_class:
        problems.append(f"bad class: {p} has no valid class (one of {CLASSES})")

    # Every taste file owes a disposition. Without this the reconcile rots
    # exactly the way the classification would have: a new taste file lands,
    # nobody says what becomes of it, and "content, or dropped" quietly
    # becomes "left where it is".
    undisposed = sorted(p for p, v in entries.items()
                         if isinstance(v, dict) and v.get("class") == "taste"
                         and p not in disposition_map)
    for p in undisposed:
        problems.append(f"undisposed: {p} is taste but has no disposition")

    stale_disposition = sorted(
        p for p in disposition_map
        if p not in entries or entries[p].get("class") != "taste"
    )
    for p in stale_disposition:
        problems.append(f"stale disposition: {p} has a disposition entry but is not a registered taste file")

    if unclassified or bad_class:
        rc = RC_FAIL
    elif stale or undisposed or stale_disposition:
        rc = RC_WARN
    else:
        rc = RC_PASS
    return rc, problems


def check(root, registry_path):
    """tools/repo-boundary.py-compatible view: -> (rc, unclassified, stale, bad_class)."""
    rc, _problems = audit(root, registry_path)
    if rc == RC_INCOMPLETE:
        return RC_INCOMPLETE, None, None, None
    try:
        reg = load_registry(registry_path)
        entries = reg.get("entries", {})
    except (OSError, ValueError):
        return RC_INCOMPLETE, None, None, None
    files = _tracked_files(root)
    mechanism = {f for f in files if is_mechanism_file(f)}
    registered = set(entries)
    unclassified = sorted(mechanism - registered)
    stale = sorted(registered - mechanism)
    bad_class = sorted(p for p, v in entries.items()
                        if not isinstance(v, dict) or v.get("class") not in CLASSES)
    return rc, unclassified, stale, bad_class


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("path", nargs="?")
    p.add_argument("--list", action="store_true", help="list every registered file and its class")
    p.add_argument("--class", dest="cls_filter", choices=CLASSES, help="with --list, only this class")
    p.add_argument("--audit", action="store_true", help="check every tracked mechanism file is registered")
    args = p.parse_args(argv)

    if args.audit:
        rc, problems = audit()
        if rc == RC_PASS:
            print(f"OK -- {len(FILES)} registered, none unregistered, stale or undisposed")
            return RC_PASS
        for line in problems:
            if line.startswith("unregistered:") or line.startswith("bad class:"):
                print(f"  FLAG {line}")
            elif line.startswith("incomplete:"):
                print(line, file=sys.stderr)
            else:
                print(f"WARN {line}")
        return rc

    if args.list or not args.path:
        for path in sorted(FILES):
            cls, reason = FILES[path]
            if args.cls_filter and cls != args.cls_filter:
                continue
            d = DISPOSITION.get(path)
            suffix = f"  [{d[0]}]" if d else ""
            print(f"{cls:6s} {path}{suffix} -- {reason}")
        return 0 if args.list else 2

    result = classify(args.path)
    if result is None:
        print(f"{args.path!r} is not registered -- run --audit if this is a real mechanism file")
        return 2
    cls, reason = result
    print(f"{cls}: {reason}")
    # Ships in a fleet build (fleet, shared) exits 0; does not (taste, meta) exits 1.
    return {"fleet": 0, "shared": 0, "taste": 1, "meta": 1}[cls]


if __name__ == "__main__":
    sys.exit(main())
