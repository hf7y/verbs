#!/usr/bin/env python3
"""senechal: do senechal.json and senechal.json.example still tell the same story?

GUARD: prose that diverged between the live config and its committed copy
RUNNER: health/estate-health.sh
GUARD-TEST: tools/test-config-prose-drift.py

WHY THIS EXISTS
---------------
senechal.json is untracked (it holds real addresses and thresholds) and
senechal.json.example is its committed copy. Values are ALLOWED to differ --
that is the whole point of an example. The PROSE is not: `why`, `retire`,
`notes` and the `_comment` fields are explanation, identical in both by
intent, and the only place several of senechal's decisions are written down.

When they diverge, one of them is wrong and neither says which. That is not
hypothetical here. senechal.json.example's own comments record five days of
false backups-are-gone alarm caused by exactly this shape -- two registries
naming the same units, one updated, the other not -- and closes with the line
this guard exists to mechanise:

    "A must-remain entry that names a retired unit does not fail safe: it
     cries wolf, and the next reader learns to discount the loudest guard
     in the file."

Measured 2026-08-15: 17 prose fields diverged. One of them asserted "As of
2026-08-11, fauche list reports every repo KEEP status", which was false by
then -- baudin and crt were REMOVABLE -- and cited a document reaped to the
vault four days later. A false claim inside a live check's own retire
instruction; reconciled in both copies, which is why the baseline holds 17
and not 18.

WHAT IT COMPARES, AND WHAT IT DELIBERATELY DOES NOT
---------------------------------------------------
Only fields named in PROSE_FIELDS, plus any key beginning with `_`, and only
where BOTH files have that field. A field the example omits is not drift: the
example is a template and may legitimately carry fewer entries. A field whose
VALUE differs -- a hostname, a threshold, a path -- is never reported, because
that is what an example config is for.

So this cannot answer "is the live config correct". It answers the one
question that has a right answer: do the two copies of the same sentence
still match.

THE ONE BUG IT MUST NOT HAVE
----------------------------
Either file being unreadable must exit 2, never 0. "I could not compare them"
and "they agree" are the same output only to a guard nobody should trust.
"""
import argparse
import json
import os
import re
import sys

RC_PASS, RC_FAIL, RC_INCOMPLETE, RC_WARN = 0, 1, 2, 3

PROSE_FIELDS = ("why", "retire", "notes", "reason", "note")


def config_path():
    if os.environ.get("SENECHAL_CONFIG"):
        return os.environ["SENECHAL_CONFIG"]
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "senechal", "senechal.json")


def is_prose(key):
    return key.startswith("_") or key in PROSE_FIELDS


def drift(live, example, path=""):
    """Prose fields present in both and differing. Lists align by `id`, then
    by position -- an inventory that reordered is not an inventory that
    changed its explanations."""
    out = []
    if isinstance(live, dict) and isinstance(example, dict):
        for k, v in live.items():
            if k not in example:
                continue
            here = f"{path}.{k}" if path else k
            if is_prose(k):
                if isinstance(v, str) and isinstance(example[k], str) and v != example[k]:
                    out.append(here)
            else:
                out += drift(v, example[k], here)
    elif isinstance(live, list) and isinstance(example, list):
        keyed = all(isinstance(x, dict) and "id" in x for x in live + example)
        if keyed:
            ex_by_id = {x["id"]: x for x in example}
            for item in live:
                if item["id"] in ex_by_id:
                    out += drift(item, ex_by_id[item["id"]], f"{path}[{item['id']}]")
        else:
            for i, (a, b) in enumerate(zip(live, example)):
                out += drift(a, b, f"{path}[{i}]")
    return out


def load(p):
    with open(p) as fh:
        return json.load(fh)


_PATH_TOKEN = re.compile(r"\[[^\]]*\]|[^.\[\]]+")


def field_present(obj, path):
    """Walk a dotted/bracketed path as drift() builds it (`a.b[id].c`).
    False if any segment is missing -- a baseline entry naming an absent
    field cannot be compared, so it must never be reported as healed."""
    cur = obj
    for tok in _PATH_TOKEN.findall(path):
        if tok.startswith("["):
            key = tok[1:-1]
            if not isinstance(cur, list):
                return False
            if key.isdigit() and int(key) < len(cur):
                cur = cur[int(key)]
                continue
            match = next((x for x in cur
                          if isinstance(x, dict) and str(x.get("id")) == key), None)
            if match is None:
                return False
            cur = match
        else:
            if not isinstance(cur, dict) or tok not in cur:
                return False
            cur = cur[tok]
    return True


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", default=None)
    ap.add_argument("--example", default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "senechal.json.example"))
    ap.add_argument("--baseline", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "config-prose-drift.baseline"))
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    cfg_path = args.config or config_path()
    try:
        live, example = load(cfg_path), load(args.example)
    except (OSError, ValueError) as e:
        print(f"config-prose-drift: cannot compare: {e}", file=sys.stderr)
        return RC_INCOMPLETE

    diverged = drift(live, example)

    # A BASELINE, NOT A COUNT. 17 fields diverged when this was written, each
    # needing a per-field judgement about which copy is current (11 where the
    # example is fuller, 6 where the live config is) -- that is Zach's call
    # per field, not something to bulk-resolve. Reporting "17 diverged" every
    #   [rest: vault:senechal/header-archaeology-20260818.md]
    baseline = set()
    if os.path.exists(args.baseline):
        with open(args.baseline) as fh:
            baseline = {ln.strip() for ln in fh
                        if ln.strip() and not ln.startswith("#")}
    new = [p for p in diverged if p not in baseline]
    # A baseline path not in `diverged` either genuinely agrees now, or its
    # field is simply absent from this host's config (sparse config, or the
    # field was removed) -- field_present() tells those apart. Only the
    # former is "healed"; the latter cannot be vouched for and must stay in
    # the baseline, or a host with a fuller config would see it resurface as
    # unbaselined "new" drift.
    healed = sorted(p for p in (baseline - set(diverged))
                     if field_present(live, p) and field_present(example, p))
    if args.json:
        json.dump({"config": cfg_path, "example": args.example,
                   "drift": diverged, "new": new, "healed": healed},
                  sys.stdout, indent=2)
        print()
        return RC_FAIL if new else (RC_WARN if healed else RC_PASS)

    print(f"config-prose-drift -- {len(diverged)} diverged, {len(baseline)} known")
    if new:
        print(f"  FLAG [prose-drift] {len(new)} field(s) NEWLY diverged:")
        for p in new:
            print(f"      {p}")
        print("      Two copies of the same sentence stopped agreeing. Fix the")
        print("      stale one, or add the path to config-prose-drift.baseline")
        print("      in a reviewable diff -- the baseline may only shrink.")
        return RC_FAIL
    if healed:
        print(f"  {len(healed)} baseline entr(y/ies) no longer diverge -- remove from")
        print(f"  {os.path.basename(args.baseline)}, or the debt can be re-borrowed:")
        for p in healed:
            print(f"      {p}")
        return RC_WARN
    print("  no new drift")
    return RC_PASS


if __name__ == "__main__":
    sys.exit(main())
