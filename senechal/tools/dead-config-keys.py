#!/usr/bin/env python3
"""senechal: which senechal.json keys does no code read any more?

GUARD: config keys that outlived their reader
RUNNER: health/estate-health.sh
GUARD-TEST: tools/test-dead-config-keys.py

WHY THIS EXISTS
---------------
Retiring a script does not retire its configuration. On 2026-08-15
health/project-unwired.sh was removed (hf7y/senechal#311) along with the two
keys it read in senechal.json.example -- and the LIVE config at
~/.config/senechal/senechal.json kept all three, because that file is
untracked and no diff ever showed them. Nothing noticed. Nothing could.

A key nothing reads is not merely clutter. It reads as configuration: the
next person to see `self_dev.project_registry` pointing at a path assumes
something consults it, and tunes it instead of deleting it. senechal has
already paid for that shape once -- senechal.json.example's own comments
record a five-day false alarm caused by two registries naming the same units
where updating one did not update the other.

HOW IT DECIDES, AND WHY IT IS DELIBERATELY LOOSE
------------------------------------------------
A key counts as READ if either:

  1. some tracked file contains `cfg <dotted.path>` -- the shell accessor, or
  2. some tracked file mentions the key's LEAF NAME anywhere at all.

(2) is far looser than a real reference check, and that is the point. Keys
are reached by several routes this cannot follow: `cfg_devices` walks
estate.devices, `cfg_footprint` walks estate.footprint, and the Python tools
navigate the parsed JSON directly (`declutter.stale_downloads.roots` is read
by home-declutter.py without the dotted path ever appearing). A strict check
called 23 of 43 keys dead, of which 20 were live -- a guard with a 87% false
alarm rate is one nobody reads twice. The loose rule reports 3, and all 3 are
genuinely dead.

The bias is therefore toward UNDER-reporting, and that is correct here: a
false "this key is dead" invites deleting live configuration, which is a much
worse outcome than an unnoticed dead key. This is a nag, never a gate.

senechal.json.example is excluded from the source corpus on purpose. It is a
copy of the config, not a reader of it, so a key documented there and read
nowhere would otherwise vouch for itself.

THE ONE BUG IT MUST NOT HAVE
----------------------------
"I could not read the config" must never render as "no dead keys". Every
unreadable path exits 2 (RC_INCOMPLETE), never 0.
"""
import argparse
import json
import os
import subprocess
import sys

RC_PASS, RC_INCOMPLETE, RC_WARN = 0, 2, 3

# Never treated as source: a copy of the config vouching for itself, and the
# committed snapshots, which contain previews of the config's own text.
EXCLUDE_PREFIXES = ("journal/",)
EXCLUDE_FILES = ("senechal.json.example",)


def config_path():
    if os.environ.get("SENECHAL_CONFIG"):
        return os.environ["SENECHAL_CONFIG"]
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "senechal", "senechal.json")


def leaf_paths(obj, prefix=""):
    """Dotted path per leaf. A list is a leaf; keys starting with _ are prose."""
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k.startswith("_"):
                continue
            q = f"{prefix}.{k}" if prefix else k
            out += leaf_paths(v, q) if isinstance(v, dict) else [q]
    return out


def tracked_source(root):
    files = subprocess.run(["git", "-C", root, "ls-files"],
                           capture_output=True, text=True).stdout.split()
    chunks = []
    for f in files:
        if f.startswith(EXCLUDE_PREFIXES) or f in EXCLUDE_FILES:
            continue
        try:
            with open(os.path.join(root, f), errors="ignore") as fh:
                chunks.append(fh.read())
        except OSError:
            continue
    return "\n".join(chunks)


def dead_keys(cfg, src):
    return [p for p in leaf_paths(cfg)
            if f"cfg {p}" not in src and p.split(".")[-1] not in src]


def main(argv=None):
    ap = argparse.ArgumentParser(description="config keys no code reads")
    ap.add_argument("--config", default=None)
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    path = args.config or config_path()
    try:
        with open(path) as fh:
            cfg = json.load(fh)
    except (OSError, ValueError) as e:
        print(f"dead-config-keys: cannot read {path}: {e}", file=sys.stderr)
        return RC_INCOMPLETE

    src = tracked_source(args.root)
    if not src.strip():
        print(f"dead-config-keys: no tracked source under {args.root}", file=sys.stderr)
        return RC_INCOMPLETE

    all_keys, dead = leaf_paths(cfg), dead_keys(cfg, src)
    if args.json:
        json.dump({"config": path, "keys": len(all_keys), "dead": dead}, sys.stdout, indent=2)
        print()
    else:
        print(f"dead-config-keys -- {len(all_keys)} leaf key(s) in {path}")
        if dead:
            print(f"  WARN {len(dead)} key(s) that no tracked file reads:")
            for p in dead:
                print(f"      {p}")
            print("      A key nothing reads still looks like configuration, so the")
            print("      next reader tunes it instead of deleting it. Remove them.")
        else:
            print("  every key has a reader")
    return RC_WARN if dead else RC_PASS


if __name__ == "__main__":
    sys.exit(main())
