#!/usr/bin/env python3
"""senechal: export the estate registry into the repo, so it is versioned.

WHY THIS EXISTS (Zach's call, 2026-08-13)
-----------------------------------------
senechal.json lives in ~/.config/senechal and is deliberately NOT in this
checkout (see README.md): a verb build is a replaceable directory an
upgrade repoints away from, and keeping config inside one cost this
estate a file already (hf7y/gardien#7).

That is right for the LIVE config and wrong for its CONTENTS. The
registry is the estate's memory -- every device, every footprint entry,
every credential runbook. On 2026-08-13 it held 22 footprint entries and
6 credentials, and its only copy off this machine was whatever gardien's
last rsync happened to catch: a mutable file, overwritten in place, with
no history. Losing it loses the registry; a bad edit to it is
undetectable and unrevertable.

So: the live config stays untracked, and a normalized copy lands here as
`registry/senechal-registry.json`, committed. Git history IS the
versioning -- `git log -p registry/` answers "when did this entry
change, and to what" for free. One tracked file, overwritten each run,
because a dated-snapshot-per-run directory would bury the diffs that are
the entire point.

WHAT IS EXPORTED, AND WHAT IS REFUSED
-------------------------------------
Only `estate` and `health` -- the registry proper. `watch` is a list of
paths on one machine, and the rest of the file is host-local wiring, so
neither belongs in a shared history.

THE REFUSAL IS THE POINT. This file gets committed to git, so it runs
the same gate the journal runs: senechal's own looks_secret(). If any
exported value looks like a credential, this writes NOTHING and exits
RC_FAIL. It is the same invariant senechal.py holds for journal/ --
"secret-looking content must never reach a snapshot as plaintext" --
applied to the one other thing this repo commits.

That gate has teeth here because estate.secrets exists: it registers
credentials by PATH, PURPOSE and MINT RUNBOOK and never by value
(health/secret-registry.sh). If someone ever pastes a token into a
`notes` field, this refuses to commit it and says so.

USAGE
  tools/export-registry.py            # DRY RUN: report what would change
  tools/export-registry.py --write    # write registry/senechal-registry.json
  tools/export-registry.py --write --config /path/to/senechal.json

EXIT CONTRACT (lib/common.sh: 0 pass / 1 real mismatch / 2 could-not-look)
  0  the export on disk already matches the live registry -- or, under
     --write, it was written successfully
  1  DRY RUN found the export stale (the mismatch: the registry has moved
     and nothing has versioned it), or a secret-looking value was found
     and the export was REFUSED
  2  could not look -- config missing, unreadable, or unparseable

Exit 1 on a stale dry run is what makes this usable as a health check as
well as an exporter.
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, REPO)

RC_PASS, RC_FAIL, RC_INCOMPLETE = 0, 1, 2

# The registry proper. Everything else in senechal.json is host-local
# wiring or a path list for one machine, and does not belong in a shared,
# committed history.
EXPORTED_BLOCKS = ("estate", "health")

DEFAULT_OUT = os.path.join(REPO, "registry", "senechal-registry.json")


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

    payload = {k: cfg[k] for k in EXPORTED_BLOCKS if k in cfg}
    if not payload:
        print("export-registry: CANNOT LOOK -- %s has none of %s"
              % (cfg_path, ", ".join(EXPORTED_BLOCKS)), file=sys.stderr)
        return RC_INCOMPLETE

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

    existing = None
    if os.path.exists(args.out):
        try:
            with open(args.out) as fh:
                existing = fh.read()
        except Exception:
            existing = None

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
