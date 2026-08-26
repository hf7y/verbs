#!/usr/bin/env python3
"""Give a truth value to workstation/manifest.json.

The manifest holds evidence. This holds the ladder. Status is DERIVED on
every run and never written back, so a fact cannot be promoted by editing
a field -- only by acquiring a probe that passes.

  claim      no probe, no source -- somebody asserted it, that is all
  researched no probe, but a source -- somebody read it somewhere
  blind      probe exists, cannot run here (tool missing)
  refuted    probe ran, expectation did not hold
  verified   probe ran, expectation held

Exit codes follow lib/common.sh: 0 pass, 1 refuted, 2 could not check.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys

RC_PASS, RC_FAIL, RC_INCOMPLETE = 0, 1, 2

MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "manifest.json")


def check(expect, out):
    """True if stdout satisfies the expectation. One key per expectation."""
    if "equals" in expect:
        return out == expect["equals"]
    if "matches" in expect:
        return re.search(expect["matches"], out, re.M) is not None
    if "max" in expect:
        return float(out) <= expect["max"]
    if "min" in expect:
        return float(out) >= expect["min"]
    raise ValueError("unknown expectation: %s" % sorted(expect))


def evaluate(fact):
    """Return (status, evidence) for one fact."""
    probe = fact.get("probe")
    if not probe:
        return ("researched" if fact.get("source") else "claim"), fact.get("source", "")

    missing = [b for b in fact.get("requires", []) if not shutil.which(b)]
    if missing:
        return "blind", "missing: " + ", ".join(missing)

    try:
        p = subprocess.run(["bash", "-c", probe], capture_output=True,
                           text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return "blind", "probe timed out"

    out = p.stdout.strip()
    if p.returncode != 0:
        return "blind", (p.stderr.strip() or "exit %d" % p.returncode)[:100]
    try:
        ok = check(fact["expect"], out)
    except (ValueError, KeyError) as e:
        return "blind", str(e)
    return ("verified" if ok else "refuted"), out[:100]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--manifest", default=MANIFEST)
    args = ap.parse_args()

    try:
        with open(args.manifest) as f:
            manifest = json.load(f)
    except (OSError, ValueError) as e:
        print("manifest unreadable: %s" % e, file=sys.stderr)
        return RC_INCOMPLETE

    results = []
    for fact in manifest["facts"]:
        status, evidence = evaluate(fact)
        results.append({"id": fact["id"], "status": status,
                        "claim": fact["claim"], "evidence": evidence})

    if args.json:
        json.dump({"target": manifest["target"], "results": results}, sys.stdout, indent=2)
        print()
    else:
        print(manifest["target"] + "\n")
        width = max(len(r["id"]) for r in results)
        for r in results:
            print("%-10s %-*s  %s" % (r["status"], width, r["id"], r["evidence"]))
        tally = {}
        for r in results:
            tally[r["status"]] = tally.get(r["status"], 0) + 1
        print("\n" + "  ".join("%s=%d" % kv for kv in sorted(tally.items())))

    statuses = {r["status"] for r in results}
    if "refuted" in statuses:
        return RC_FAIL
    if "blind" in statuses:
        return RC_INCOMPLETE
    return RC_PASS


if __name__ == "__main__":
    sys.exit(main())
