#!/usr/bin/env python3
"""Decisions Zach already gave, so nothing re-asks them.

These lived in CLAUDE.md until 2026-08-25, when it was deleted for drifting:
four of its factual claims were measured wrong in one session. Decisions are
not claims about state -- they do not rot -- so they were kept, but moved out
of prose into registry/standing-answers.json where a tool can check them.

    tools/standing-answers.py                # print them
    tools/standing-answers.py <substring>    # just the matching ones
    tools/standing-answers.py --audit        # every named mechanism must exist

--audit is the point: an answer whose mechanism has been deleted is an answer
nothing enforces any more, and that is exactly how a decision quietly becomes
a suggestion again.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "registry" / "standing-answers.json"

RC_PASS, RC_FAIL, RC_INCOMPLETE = 0, 1, 2


def load():
    try:
        with open(REGISTRY) as fh:
            return json.load(fh)
    except FileNotFoundError:
        print(f"INCOMPLETE: {REGISTRY} does not exist", file=sys.stderr)
        sys.exit(RC_INCOMPLETE)
    except json.JSONDecodeError as exc:
        print(f"INCOMPLETE: {REGISTRY} is not parseable: {exc}", file=sys.stderr)
        sys.exit(RC_INCOMPLETE)


def audit(reg):
    answers = reg.get("answers", {})
    if not answers:
        print("INCOMPLETE: registry has no answers", file=sys.stderr)
        return RC_INCOMPLETE
    bad = 0
    for name, a in sorted(answers.items()):
        if not a.get("decision"):
            print(f"FAIL {name}: no decision text")
            bad += 1
        if not a.get("source"):
            print(f"FAIL {name}: no source -- an answer with no provenance cannot be re-checked")
            bad += 1
        for p in a.get("mechanism_paths", []):
            if not (ROOT / p).exists():
                print(f"FAIL {name}: names mechanism {p}, which does not exist -- "
                      f"nothing enforces this decision any more")
                bad += 1
    if bad:
        print(f"\nFAILED -- {bad} problem(s) in {len(answers)} standing answer(s).")
        return RC_FAIL
    print(f"OK -- {len(answers)} standing answers, every named mechanism present.")
    return RC_PASS


def main():
    args = [a for a in sys.argv[1:]]
    reg = load()
    if "--audit" in args:
        sys.exit(audit(reg))
    needle = args[0].lower() if args else ""
    answers = reg.get("answers", {})
    shown = 0
    for name, a in sorted(answers.items()):
        hay = (name + " " + a.get("decision", "")).lower()
        if needle and needle not in hay:
            continue
        shown += 1
        print(f"\n{name}  [{a.get('source', 'no source')}]")
        print(f"  {a.get('decision', '')}")
        if a.get("mechanism"):
            print(f"  enforced by: {a['mechanism']}")
    if needle and not shown:
        print(f"no standing answer matches {needle!r}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
