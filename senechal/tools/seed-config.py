#!/usr/bin/env python3
"""seed-config.py -- write a minimal senechal.json for a NEW host.

`cp senechal.json.example` is the documented path, and on a host that is
not mandark it is the wrong one: the example carries mandark's device
registry, so a fresh host would health-check another machine's devices.

But a config narrowed by hand is also wrong, and silently. Two committed
checks -- health/no-self-dev.sh and the estate.taste row in
health/test-alerting.sh -- assert the LIVE config's `self_dev` and
`estate.taste` blocks are identical to the tracked example, because the
example is the only copy off-host readers get. A hand-narrowed config
omits both and fails them for a reason that looks nothing like the cause.
(That is exactly what happened seeding monkey on 2026-08-16.)

So: copy the two blocks that must match, take `watch` from the caller,
and carry nothing else.

    python3 tools/seed-config.py --watch ~/.gitconfig ~/.bashrc   # preview
    python3 tools/seed-config.py --watch ... --write
"""
import argparse, json, os, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def _dest():
    return pathlib.Path(os.environ.get("SENECHAL_CONFIG") or
                        pathlib.Path(os.environ.get("XDG_CONFIG_HOME",
                                                    pathlib.Path.home() / ".config"))
                        / "senechal" / "senechal.json")


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--watch", nargs="*", default=[], help="paths for the watch list")
    ap.add_argument("--write", action="store_true", help="write it (default: preview)")
    args = ap.parse_args(argv)

    dest = _dest()
    with open(ROOT / "senechal.json.example") as f:
        example = json.load(f)
    config = {
        "_comment": "Seeded by tools/seed-config.py for this host. self_dev and "
                    "estate.taste are copied verbatim from senechal.json.example "
                    "because committed checks require them identical; every other "
                    "key is absent on purpose, and an absent key means the "
                    "caller's default is correct.",
        "watch": args.watch,
        "self_dev": example["self_dev"],
        "estate": {"taste": example["estate"]["taste"]},
    }
    out = json.dumps(config, indent=2)

    if not args.write:
        print(f"would write {dest} ({len(out)} bytes); keys: {list(config)}")
        print("re-run with --write")
        return 0

    if dest.exists():
        print(f"seed-config: {dest} already exists -- refusing to overwrite a live config",
              file=sys.stderr)
        return 1
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(out)
    dest.chmod(0o600)
    print(f"wrote {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
