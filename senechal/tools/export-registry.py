#!/usr/bin/env python3
"""senechal: version the estate registry in the repo, and never destroy it.

WHY THIS EXISTS (Zach's call, 2026-08-13)
-----------------------------------------
senechal.json is deliberately NOT in this checkout (README.md; the cost
of getting it wrong was hf7y/gardien#7). Right for the LIVE config, wrong
for its CONTENTS: the registry is the estate's memory and its only copy
off this machine was whatever gardien's last rsync caught, overwritten in
place, with no history. So a normalized copy lands here as
`registry/senechal-registry.json`, and `git log -p registry/` is the
versioning.

WHAT IS EXPORTED, AND WHAT IS REFUSED
-------------------------------------
Only `estate` and `health` -- the registry proper; the rest of the file
is host-local wiring. THE REFUSAL IS THE POINT: this file gets committed,
so it runs the gate the journal runs, senechal's own looks_secret(), and
a credential-shaped value writes NOTHING and exits RC_FAIL. The gate has
teeth because estate.secrets registers credentials by path, purpose and
mint runbook, never by value (health/secret-registry.sh).

WHAT IT IS NOT ALLOWED TO DESTROY (hf7y/senechal#537)
-----------------------------------------------------
Not a mirror since #411: absorb-notices.py writes every FLEET door filing
straight into the export, so for those keys the export is CANONICAL and
the live config is not a source at all -- nor current, holding rows that
`61fb8f7` reaped. A whole-block copy deleted 13 absorbed filings and
every `corrections` list #534 writes; #537 measures it. So a key
comes from the live config only if no fleet door owns it; the rest is
carried over verbatim, including a key this script has never heard of,
and what was carried is PRINTED -- dropping a live-config edit silently
is the same defect pointed the other way. Ownership comes from
registry/front-doors.json classified by tools/boundary.py.

USAGE
  tools/export-registry.py [--write]  # dry run reports; --write exports

EXIT CONTRACT (lib/common.sh: 0 pass / 1 real mismatch / 2 could-not-look)
  0  the export already matches -- or, under --write, it was written
  1  DRY RUN found the export stale (the registry moved and nothing
     versioned it), or a secret-looking value was found and the export
     REFUSED. Exit 1 on a stale dry run makes this a health check too.
  2  could not look -- the config, the export or the doors contract
     missing or unparseable, so what must be preserved is unknowable
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, REPO)
sys.path.insert(0, HERE)
import boundary  # which config keys are fleet vs taste

RC_PASS, RC_FAIL, RC_INCOMPLETE = 0, 1, 2

# The registry proper. Everything else in senechal.json is host-local
# wiring or a path list for one machine, and does not belong in a shared,
# committed history.
EXPORTED_BLOCKS = ("estate", "health")

DEFAULT_OUT = os.path.join(REPO, "registry", "senechal-registry.json")
DOORS = os.path.join(REPO, "registry", "front-doors.json")


def default_config():
    if os.environ.get("SENECHAL_CONFIG"):
        return os.environ["SENECHAL_CONFIG"]
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "senechal", "senechal.json")


def load_looks_secret():
    """senechal.py's own redaction test, or None if it cannot be had.

    Imported rather than reimplemented: a second copy of the rule would
    drift, and the whole value of the gate is that it is the SAME rule
    the journal is held to.
    """
    try:
        import senechal
    except Exception:
        return None
    return getattr(senechal, "looks_secret", None)


def door_owned_keys(doors_path):
    """Config keys a FLEET door writes into the export -- read from the
    contract, so a new door is owned the moment it exists."""
    with open(doors_path) as fh:
        doors = json.load(fh)["doors"]
    owned = set()
    for door in doors.values():
        target = door.get("target")
        if not target:
            continue
        cls = boundary.classify_config_key(target)
        if cls and cls[0] == "fleet":
            owned.add(target)
    return owned


def merge(live, existing, owned):
    """The live blocks, with what it is not the source of carried over."""
    payload, carried = {}, []
    for block in EXPORTED_BLOCKS:
        live_block = live.get(block)
        held = existing.get(block)
        if not isinstance(live_block, dict) or not isinstance(held, dict):
            # No per-key source to reason about: the live copy stands.
            if live_block is not None:
                payload[block] = live_block
            elif held is not None:
                payload[block] = held
                carried.append(block)
            continue
        merged = dict(live_block)
        for key, value in held.items():
            path = "%s.%s" % (block, key)
            if key not in live_block or path in owned:
                merged[key] = value
                carried.append(path)
        payload[block] = merged
    return payload, carried


def walk_strings(node, path="$"):
    """Yield (json-path, string) for every string value in the tree."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield from walk_strings(v, "%s.%s" % (path, k))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk_strings(v, "%s[%d]" % (path, i))
    elif isinstance(node, str):
        yield path, node


def main():
    ap = argparse.ArgumentParser(
        description="Export the estate registry into the repo. Dry run by default."
    )
    ap.add_argument("--write", action="store_true",
                    help="actually write the export (default: report only)")
    ap.add_argument("--config", default=None, help="path to senechal.json")
    ap.add_argument("--out", default=DEFAULT_OUT, help="path to write")
    args = ap.parse_args()

    cfg_path = args.config or default_config()

    # Could-not-look is not a pass, and is not the same as "nothing to do".
    if not os.path.exists(cfg_path):
        print("export-registry: CANNOT LOOK -- no config at %s" % cfg_path,
              file=sys.stderr)
        return RC_INCOMPLETE
    try:
        with open(cfg_path) as fh:
            cfg = json.load(fh)
    except Exception as exc:
        print("export-registry: CANNOT LOOK -- %s did not parse: %s"
              % (cfg_path, exc), file=sys.stderr)
        return RC_INCOMPLETE

    if not any(k in cfg for k in EXPORTED_BLOCKS):
        print("export-registry: CANNOT LOOK -- %s has none of %s"
              % (cfg_path, ", ".join(EXPORTED_BLOCKS)), file=sys.stderr)
        return RC_INCOMPLETE

    # CANNOT LOOK: an unreadable export is one whose filings cannot be
    # preserved, so overwriting it anyway is the destruction guarded here.
    existing, existing_obj = None, {}
    if os.path.exists(args.out):
        try:
            with open(args.out) as fh:
                existing = fh.read()
            existing_obj = json.loads(existing)
        except Exception as exc:
            print("export-registry: CANNOT LOOK -- %s did not read as JSON "
                  "(%s); refusing to overwrite an export whose contents "
                  "cannot be preserved" % (args.out, exc), file=sys.stderr)
            return RC_INCOMPLETE
    try:
        owned = door_owned_keys(DOORS)
    except Exception as exc:
        print("export-registry: CANNOT LOOK -- %s did not read (%s); it is "
              "what says which keys a front door owns" % (DOORS, exc),
              file=sys.stderr)
        return RC_INCOMPLETE

    payload, carried = merge(cfg, existing_obj, owned)

    # --- the gate ---------------------------------------------------
    looks_secret = load_looks_secret()
    if looks_secret is None:
        print("export-registry: CANNOT LOOK -- could not import senechal.py's "
              "looks_secret; refusing to commit an unscreened registry",
              file=sys.stderr)
        return RC_INCOMPLETE

    offenders = [(p, s) for p, s in walk_strings(payload) if looks_secret(s)]
    if offenders:
        print("export-registry: REFUSED -- %d exported value(s) look like "
              "credentials, and this file is committed to git:" % len(offenders),
              file=sys.stderr)
        for p, _ in offenders:
            # The path, never the value. Printing the offending string
            # would put it in a terminal, a log, and probably a CI record.
            print("  %s" % p, file=sys.stderr)
        print("  estate.secrets registers credentials by path, purpose and "
              "mint runbook -- never by value. Move the value out, and "
              "record how to mint a new one instead.", file=sys.stderr)
        return RC_FAIL

    # Sorted keys and a trailing newline so the committed diff reflects a
    # real change in the registry, not dict ordering.
    rendered = json.dumps(payload, indent=2, sort_keys=True) + "\n"

    if carried:
        print("export-registry: carried over from the export, not taken from "
              "the live config: %s" % ", ".join(sorted(carried)))

    if existing == rendered:
        print("export-registry: up to date (%s)" % os.path.relpath(args.out, REPO))
        return RC_PASS

    counts = ", ".join(
        "%s.%s=%d" % (b, k, len(v))
        for b in EXPORTED_BLOCKS if isinstance(payload.get(b), dict)
        for k, v in sorted(payload[b].items()) if isinstance(v, list)
    )

    if not args.write:
        state = "absent" if existing is None else "stale"
        print("export-registry: %s is %s -- the live registry has moved and "
              "nothing has versioned it" % (os.path.relpath(args.out, REPO), state))
        print("  would write: %s" % (counts or "no list blocks"))
        print("  run: tools/export-registry.py --write")
        return RC_FAIL

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as fh:
        fh.write(rendered)
    print("export-registry: wrote %s (%s)"
          % (os.path.relpath(args.out, REPO), counts or "no list blocks"))
    print("  commit it -- git history is the versioning: git log -p %s"
          % os.path.relpath(os.path.dirname(args.out), REPO))
    return RC_PASS


if __name__ == "__main__":
    sys.exit(main())
