#!/usr/bin/env python3
"""naming -- pass/fail check for senechal's confirmed naming conventions.

Replaces NAMING.md's "Confirmed conventions" table (a registry you had to
read) with a registry you can run. Conventions are added here the same way
NAMING.md said they'd be added to the table: by hand, once actually
confirmed by observing a real project name on Zach's machine -- never
guessed. An unconfirmed name is not a failure; it is a separate, honest
outcome (exit 2), same shape as this repo's health-check RC_INCOMPLETE.

Usage:
    tools/naming.py <name> [--kind KIND]
    tools/naming.py --list

Exit: 0 confirmed and matches / 1 confirmed and violates / 2 no convention
covers this name/kind yet.
"""

import argparse
import sys

# Each entry: kind -> (description, {name: meaning}). A name in the dict
# is CONFIRMED to follow the convention; the dict is the whole test --
# there is no algorithmic "is this French" check, because that would be
# guessing, which NAMING.md explicitly ruled out.
CONVENTIONS = {
    "dev-workflow-project": (
        "senechal's own dev-workflow tooling (scheduler-managed "
        "autonomous-dev-loop projects) is named with French words.",
        {
            "senechal": "steward/majordomo",
            "realisateur": "director",
            "gardien": "guardian",
        },
    ),
}

# Seen but not yet confirmed either way -- tracked as GitHub issue #166,
# not here. Kept as a comment, not a table, so there is exactly one place
# (the issue) that can go stale.
UNCONFIRMED_KIND = "dev-workflow-project"
UNCONFIRMED_NAMES = (
    "chezz", "crt", "groc-mangr", "home-assistant", "nine-speakers",
    "scheduler", "sequestria", "vkv-inventory", "wtul",
)


def check(name, kind):
    """Return (rc, message). rc: 0 pass, 1 fail, 2 unconfirmed."""
    if kind not in CONVENTIONS:
        return 2, f"no confirmed convention for kind {kind!r}"
    _desc, known = CONVENTIONS[kind]
    if name in known:
        return 0, f"{name!r} confirmed: {known[name]}"
    if name in UNCONFIRMED_NAMES and kind == UNCONFIRMED_KIND:
        return 2, f"{name!r} seen but not yet confirmed -- see issue #166"
    return 1, f"{name!r} is not in the confirmed {kind!r} registry"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("name", nargs="?")
    p.add_argument("--kind", default="dev-workflow-project")
    p.add_argument("--list", action="store_true", help="list confirmed conventions and exit")
    args = p.parse_args(argv)

    if args.list or not args.name:
        for kind, (desc, known) in CONVENTIONS.items():
            print(f"{kind}: {desc}")
            for name, meaning in known.items():
                print(f"  {name} -- {meaning}")
        return 0 if args.list else 2

    rc, msg = check(args.name, args.kind)
    print(msg)
    return rc


if __name__ == "__main__":
    sys.exit(main())
