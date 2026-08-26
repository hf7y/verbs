#!/usr/bin/env python3
"""senechal: close machine-filed RECEIPT issues, mechanically, with no
model in the loop (hf7y/senechal#83).

WHY THIS EXISTS
---------------
senechal's inbox is GitHub issues. That is the right front door for a
*finding* and the wrong one for a *receipt* -- "the symlink now points
at X" records that something already happened: nothing to triage,
nothing to decide, and the filing footer already says closing IS the
acknowledgement. Adopting one verb build filed 29 receipts in 132
seconds; real work was buried under them.

WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT
---------------------------------------------
Not a triage bot, and it must never become one. It contains no judgment.
It closes an issue only when that issue matches, character for
character, a receipt sentence one specific tool is known to emit -- see
RECEIPT_PATTERNS. Label and filing channel are NOT sufficient evidence;
only the sentence is. A misfiled work item is far worse than an
uncleaned receipt, so the bias runs hard toward under-closing.

Under-closing is correct; under-REPORTING is not. BACKLOG_CEILING fixes
that half: past it, "I recognised nothing" is reported as could-not-look
(exit 2), never as a pass. No issue is closed that was not closable
before.

THE SEVEN GATES
---------------
An issue is closed only if ALL of these hold:

  1. It is open, and is an issue (not a PR).
  2. Its body carries the machine-filed footer -- `filed <date> via
     `scheduler -i <repo>`/`notify-senechal` on <host>`. A hand-written
     issue can never match, because a human does not type that.
  3. Its TITLE matches a receipt pattern's title regex. Titles arrive
     truncated mid-word from `scheduler -i`, so title regexes are
     prefix-anchored only.
  4. Its BODY, with the footer stripped, matches that same pattern's
     body regex ANCHORED AT BOTH ENDS. The body is not truncated, so
     this is the real check: the issue must be that one sentence and
     nothing else. A receipt with a "Known gap:" paragraph appended
     fails here and stays open.
  5. Its labels are a subset of ALLOWED_LABELS plus `from:<project>`
     (machine-applied by `scheduler -i` itself). Any label a human added
     is a triage decision, and disqualifies the issue permanently.
  6. Nobody has touched it: zero comments, zero reactions, no assignee,
     no milestone.
  7. It is at least --min-age-hours old (default MIN_AGE_HOURS), so a
     run that is still in flight can finish and follow up on its own
     receipt before anything sweeps it.

REOPENING IS STICKY, ON PURPOSE
-------------------------------
Closing leaves a comment saying why and how to reopen. That comment is
itself gate 6: an issue this tool has closed can never be closed by it
again, because it now has a comment. Reopen it and it stays open
forever, with no further argument.

IDEMPOTENCE
-----------
There is no ledger and no state file. The gates are computed fresh from
the live GitHub state on every run, and "is open" is one of them, so a
second run over the same repo finds nothing to do. Safe to run
unattended, on a schedule, forever.

USAGE
-----
  tools/issue-janitor.py                  # DRY RUN (default): print what
                                          # would close, close nothing
  tools/issue-janitor.py --apply          # actually close them
  tools/issue-janitor.py --json           # machine-readable report
  tools/issue-janitor.py --min-age-hours 24
  tools/issue-janitor.py --repo hf7y/senechal

EXIT CONTRACT (lib/common.sh: 0 pass / 1 real mismatch / 2 could-not-look)
  0  nothing to sweep -- or, under --apply, every close succeeded
  1  DRY RUN found receipts sitting open (the mismatch: the inbox is
     dirty and nothing has swept it), or --apply failed to close one
  2  could not look -- gh missing, gh unauthenticated, the repo could
     not be determined, the API returned something unparseable, OR the
     inbox holds >= BACKLOG_CEILING issues this tool cannot read

Exit 1 on a dirty dry run is what makes this usable as a health check as
well as a broom: `issue-janitor.py` with no arguments answers "are
receipts accumulating?" loudly, and never by exiting 0 on a run that
could not look.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone

# --- exit contract, mirrored from lib/common.sh ------------------------
RC_PASS = 0
RC_FAIL = 1
RC_INCOMPLETE = 2

DEFAULT_REPO = "hf7y/senechal"

# How many unrecognised open issues constitute a buried inbox. Not a
# triage threshold -- this tool still closes nothing it cannot read
# character for character. It is the point past which "I recognised
# nothing" stops being reassurance and becomes a could-not-look, so the
# broom reports the burial it was built to prevent instead of exiting 0
# beside it. Measured 2026-08-15: 57 open, 0 recognised, exit 0.
BACKLOG_CEILING = 25

# Hours a receipt must sit before it is eligible. Not about the human --
# nobody reads these -- but about the writer: a run that files a receipt
# mid-flight may still append a finding to it, or file a correction, and
# a few hours is enough for that run to be over. Raise it, never lower
# it, if that assumption stops holding.
MIN_AGE_HOURS = 4

# A label this tool did not expect means a human triaged the issue.
# Keep this set as small as it can possibly be. `from:<project>` is
# machine-applied by `scheduler -i` itself (recording the calling
# project), not a human triage decision, so it is allowed alongside
# `idea` rather than added here as a fixed string -- see ALLOWED_LABEL_RE.
ALLOWED_LABELS = frozenset({"idea"})
ALLOWED_LABEL_RE = re.compile(r"^from:[A-Za-z0-9._-]+$")

# Hard ceiling on the substantive body, independent of the regexes. A
# receipt is one sentence; anything longer is prose, whatever it matches.
MAX_RECEIPT_BODY_CHARS = 500

# The footer `scheduler -i` / `notify-senechal` stamp onto every issue
# they file. Its presence proves the issue was machine-filed; its
# position marks where the substantive body ends.
FOOTER_RE = re.compile(
    r"\n---\nfiled \d{4}-\d\d-\d\d \d\d:\d\d "
    r"via `(?:scheduler -i [A-Za-z0-9._-]+|notify-senechal)` on \S+",
)

# --- the receipt patterns ---------------------------------------------
# THE ENTIRE SAFETY OF THIS TOOL LIVES IN THIS LIST. Adding an entry is
# not a refactor; it is a decision that a specific sentence, emitted by a
# specific tool, can never be a work item. Each entry needs:
#   [rest: vault:senechal/header-archaeology-20260818.md]
RECEIPT_PATTERNS = (
    {
        "name": "installe-path-add",
        "what": "installe declaring a new ~/.local/bin symlink it owns",
        # Kept to the shortest unambiguous prefix: `scheduler -i` cuts
        # the title at an unspecified length, and a shorter cut than the
        # ones seen so far must not silently stop matching. Safe to be
        # loose here -- the body regex below is the real gate.
        "title": re.compile(r"^installe: [A-Za-z0-9._-]+ is now on PATH at /"),
        "body": re.compile(
            r"^installe: (?P<verb>[A-Za-z0-9._-]+) is now on PATH at "
            r"(?P<link>/\S+) -> (?P<target>/\S+) "
            r"\(owned by [A-Za-z0-9._-]+'s installe; "
            r"remove with: installe retire (?P=verb)\)$"
        ),
    },
    {
        "name": "installe-path-remove",
        "what": "installe declaring a ~/.local/bin symlink it removed",
        "title": re.compile(r"^installe: [A-Za-z0-9._-]+ is no longer on PATH \("),
        "body": re.compile(
            r"^installe: (?P<verb>[A-Za-z0-9._-]+) is no longer on PATH "
            r"\(removed (?P<link>/\S+); its target was not deleted\)$"
        ),
    },
)


class CannotLook(Exception):
    """Something made the question unanswerable -- exit RC_INCOMPLETE."""


# --- classification (pure: no network, no clock beyond `now`) ----------


def substantive_body(body):
    """The issue body with the machine-filed footer stripped.

    Returns None if the footer is absent -- i.e. the issue was not filed
    by a machine, so it is out of scope no matter what it says.
    """
    if not body:
        return None
    m = FOOTER_RE.search(body)
    if not m:
        return None
    return body[: m.start()].strip()


def has_reactions(issue):
    for group in issue.get("reactionGroups") or []:
        users = group.get("users") or {}
        if users.get("totalCount", 0):
            return True
    return False


def age_hours(issue, now):
    created = issue.get("createdAt")
    if not created:
        raise CannotLook("issue %s has no createdAt" % issue.get("number"))
    stamp = datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=timezone.utc
    )
    return (now - stamp).total_seconds() / 3600.0


def classify(issue, now, min_age_hours=MIN_AGE_HOURS):
    """Decide one issue's fate.

    Returns (verdict, pattern_name, reason) where verdict is one of
    "close", "hold" (a receipt, but not yet eligible) or "keep".
    """
    labels = {label["name"] for label in issue.get("labels") or []}

    # A TYPED DOOR FILING IS NOT A RECEIPT (2026-08-16). Since notify-senechal
    # stopped accepting prose, a `door`-labelled issue carries a payload that
    # tools/absorb-notices.py has to WRITE into the live config before it may
    # be closed -- closing it here would discard the filing silently, which is
    #   [rest: vault:senechal/header-archaeology-20260818.md]
    if "door" in labels:
        return "keep", None, "typed door filing -- tools/absorb-notices.py owns closing it"

    body = substantive_body(issue.get("body") or "")
    if body is None:
        return "keep", None, "not machine-filed (no scheduler or notify footer)"

    if len(body) > MAX_RECEIPT_BODY_CHARS:
        return "keep", None, "body is prose (%d chars > %d)" % (
            len(body),
            MAX_RECEIPT_BODY_CHARS,
        )

    pattern = None
    for candidate in RECEIPT_PATTERNS:
        if candidate["title"].match(issue.get("title") or "") and candidate[
            "body"
        ].match(body):
            pattern = candidate
            break
    if pattern is None:
        return "keep", None, "matches no receipt pattern"

    name = pattern["name"]

    extra = {
        label
        for label in labels - ALLOWED_LABELS
        if not ALLOWED_LABEL_RE.match(label)
    }
    if extra:
        return "keep", name, "human-applied label(s): %s" % ", ".join(sorted(extra))
    if issue.get("comments"):
        return "keep", name, "has %d comment(s)" % len(issue["comments"])
    if has_reactions(issue):
        return "keep", name, "has reaction(s)"
    if issue.get("assignees"):
        return "keep", name, "assigned"
    if issue.get("milestone"):
        return "keep", name, "in a milestone"

    hours = age_hours(issue, now)
    if hours < min_age_hours:
        return "hold", name, "only %.1fh old (< %gh grace)" % (hours, min_age_hours)

    return "close", name, "receipt, untouched, %.1fh old" % hours


def closing_comment(pattern_name, repo):
    return (
        "Auto-closed by `tools/issue-janitor.py` "
        "(%s#83), non-agentically -- no model read this issue.\n"
        "\n"
        "It matched the receipt pattern **`%s`**: a machine-filed record that "
        "something *already happened* on a host, not a work item. It was filed "
        "via `scheduler -i` / `notify-senechal`, its body was that one sentence "
        "and nothing else, it carried no label beyond `idea`, and it had no "
        "comment, reaction, assignee or milestone -- nothing a human had "
        "touched.\n"
        "\n"
        "Closing IS the acknowledgement, as the filing footer says. The estate "
        "record lives in `ESTATE.md` and the journal, not in this issue.\n"
        "\n"
        "**If this was wrong: just reopen it.** Reopening is permanent -- this "
        "comment disqualifies the issue from ever being auto-closed again."
        % (repo, pattern_name)
    )


# --- GitHub plumbing ---------------------------------------------------


def run_gh(args, check=True):
    if not shutil.which("gh"):
        raise CannotLook("gh not found on PATH")
    proc = subprocess.run(
        ["gh"] + args, capture_output=True, text=True
    )
    if check and proc.returncode != 0:
        raise CannotLook(
            "gh %s failed (%d): %s"
            % (" ".join(args), proc.returncode, proc.stderr.strip())
        )
    return proc


def fetch_open_issues(repo, limit=500):
    proc = run_gh(
        [
            "issue",
            "list",
            "--repo",
            repo,
            "--state",
            "open",
            "--limit",
            str(limit),
            "--json",
            "number,title,body,labels,createdAt,comments,assignees,"
            "milestone,reactionGroups,url",
        ]
    )
    try:
        issues = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise CannotLook("gh returned unparseable JSON: %s" % exc)
    if not isinstance(issues, list):
        raise CannotLook("gh returned %s, expected a list" % type(issues).__name__)
    return issues


def close_issue(repo, number, comment):
    run_gh(
        [
            "issue",
            "close",
            str(number),
            "--repo",
            repo,
            "--reason",
            "completed",
            "--comment",
            comment,
        ]
    )


# --- reporting ---------------------------------------------------------


def build_report(issues, now, min_age_hours):
    report = {"close": [], "hold": [], "keep": 0, "by_pattern": {}}
    for issue in issues:
        verdict, name, reason = classify(issue, now, min_age_hours)
        if verdict == "keep":
            report["keep"] += 1
            continue
        report[verdict].append(
            {
                "number": issue["number"],
                "pattern": name,
                "reason": reason,
                "title": issue["title"],
            }
        )
        if verdict == "close":
            report["by_pattern"][name] = report["by_pattern"].get(name, 0) + 1
    return report


def print_report(report, total, apply_mode, min_age_hours, closed=None, failed=None):
    verb = "CLOSED" if apply_mode else "WOULD CLOSE"
    print("senechal issue-janitor -- %d open issue(s) examined" % total)
    print("  %s: %d" % (verb, len(report["close"])))
    for name, count in sorted(report["by_pattern"].items()):
        print("      %-22s %d" % (name, count))
    for row in report["close"]:
        print("      #%-5d %s" % (row["number"], row["title"][:88]))
    if report["hold"]:
        print(
            "  HELD (receipt, inside the %gh grace window): %d"
            % (min_age_hours, len(report["hold"]))
        )
        for row in report["hold"]:
            print("      #%-5d %s -- %s" % (row["number"], row["pattern"], row["reason"]))
    print("  LEFT ALONE (not a recognised receipt): %d" % report["keep"])
    if report["keep"] >= BACKLOG_CEILING:
        print(
            "  UNSWEPT: %d unrecognised issues is a buried inbox (ceiling %d).\n"
            "      This tool cannot read them and will not guess -- that part of\n"
            "      the design stands. But it no longer calls that a pass: this\n"
            "      run exits 2 (could-not-look), not 0. A human sweeps these."
            % (report["keep"], BACKLOG_CEILING)
        )
    if failed:
        print("  FAILED TO CLOSE: %d -- %s" % (len(failed), ", ".join(map(str, failed))))
    if not apply_mode and report["close"]:
        print()
        print("  dry run -- nothing was closed. Re-run with --apply to close.")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Close machine-filed receipt issues. Dry run by default."
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="actually close the issues (default: dry run, close nothing)",
    )
    parser.add_argument("--repo", default=DEFAULT_REPO, help="owner/name")
    parser.add_argument(
        "--min-age-hours",
        type=float,
        default=MIN_AGE_HOURS,
        help="grace window before a receipt is eligible (default: %d)" % MIN_AGE_HOURS,
    )
    parser.add_argument("--json", action="store_true", help="machine-readable report")
    args = parser.parse_args(argv)

    try:
        issues = fetch_open_issues(args.repo)
    except CannotLook as exc:
        print("issue-janitor: CANNOT LOOK -- %s" % exc, file=sys.stderr)
        return RC_INCOMPLETE

    now = datetime.now(timezone.utc)
    try:
        report = build_report(issues, now, args.min_age_hours)
    except CannotLook as exc:
        print("issue-janitor: CANNOT LOOK -- %s" % exc, file=sys.stderr)
        return RC_INCOMPLETE

    closed, failed = [], []
    if args.apply:
        for row in report["close"]:
            try:
                close_issue(args.repo, row["number"], closing_comment(row["pattern"], args.repo))
                closed.append(row["number"])
            except CannotLook as exc:
                print(
                    "issue-janitor: failed to close #%d -- %s" % (row["number"], exc),
                    file=sys.stderr,
                )
                failed.append(row["number"])

    if args.json:
        print(
            json.dumps(
                {
                    "repo": args.repo,
                    "examined": len(issues),
                    "apply": args.apply,
                    "min_age_hours": args.min_age_hours,
                    "close": report["close"],
                    "hold": report["hold"],
                    "keep": report["keep"],
                    "by_pattern": report["by_pattern"],
                    "closed": closed,
                    "failed": failed,
                },
                indent=2,
            )
        )
    else:
        print_report(
            report,
            len(issues),
            args.apply,
            args.min_age_hours,
            closed=closed,
            failed=failed,
        )

    if failed:
        return RC_FAIL
    if not args.apply and report["close"]:
        # The mismatch: receipts are sitting open and nothing swept them.
        return RC_FAIL
    if report["keep"] >= BACKLOG_CEILING:
        # "I examined N and recognised none of them" is COULD-NOT-LOOK, not
        # a pass. Returning 0 here is what let 57 issues -- 21 of them
        # receipt-shaped -- read as a clean inbox while this tool exited 0
        # on every run. Under-closing is the correct bias; under-REPORTING
        # is not, and they were the same line of code.
        return RC_INCOMPLETE
    return RC_PASS


if __name__ == "__main__":
    sys.exit(main())
