#!/usr/bin/env python3
import argparse
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone

RC_PASS = 0  # claimed -- proceed
RC_FAIL = 1  # someone else holds a live claim -- skip this issue
RC_INCOMPLETE = 2  # could not look, or the issue is not open

DEFAULT_REPO = "hf7y/senechal"
DEFAULT_TTL_SECONDS = 6 * 60 * 60  # one nightly-batch run, with room to spare

CLAIM_RE = re.compile(
    r"<!-- claim-issue: marker=(?P<marker>\S+) claimed=(?P<claimed>\S+) "
    r"ttl=(?P<ttl>\d+)s -->"
)


class CannotLook(Exception):
    pass


def latest_claim(comments):
    found = None
    for comment in comments:
        m = CLAIM_RE.search(comment.get("body") or "")
        if m:
            found = m
    return found


def parse_claimed_at(value):
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError:
        raise CannotLook("claim timestamp '%s' is not ISO 8601 UTC" % value)


def decide(issue, now, marker, ttl_seconds):
    if issue.get("state") != "OPEN":
        return "closed", "issue is %s, not OPEN" % issue.get("state", "unknown")

    m = latest_claim(issue.get("comments") or [])
    if m is None:
        return "claim", "no existing claim"

    if m.group("marker") == marker:
        return "claim", "already claimed by this marker -- refreshing"

    claimed_at = parse_claimed_at(m.group("claimed"))
    age = (now - claimed_at).total_seconds()
    if age >= ttl_seconds:
        return "claim", "prior claim by %s is %ds old (>= ttl %ds) -- treating as abandoned" % (
            m.group("marker"),
            age,
            ttl_seconds,
        )

    return "blocked", "claimed by %s %ds ago (< ttl %ds)" % (
        m.group("marker"),
        age,
        ttl_seconds,
    )


def claim_comment(marker, now, ttl_seconds):
    stamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    return (
        "<!-- claim-issue: marker=%s claimed=%s ttl=%ds -->\n"
        "Claimed by `%s` for work this run (`tools/claim-issue.py`, "
        "hf7y/senechal#485). Best-effort only -- not a lock, and this "
        "claim expires in %ds if the run never follows up."
        % (marker, stamp, ttl_seconds, marker, ttl_seconds)
    )


def run_gh(args, check=True):
    if not shutil.which("gh"):
        raise CannotLook("gh not found on PATH")
    proc = subprocess.run(["gh"] + args, capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise CannotLook(
            "gh %s failed (%d): %s"
            % (" ".join(args), proc.returncode, proc.stderr.strip())
        )
    return proc


def fetch_issue(repo, number):
    proc = run_gh(
        [
            "issue",
            "view",
            str(number),
            "--repo",
            repo,
            "--json",
            "state,comments",
        ]
    )
    try:
        issue = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise CannotLook("gh returned unparseable JSON: %s" % exc)
    if not isinstance(issue, dict):
        raise CannotLook("gh returned %s, expected an object" % type(issue).__name__)
    return issue


def post_claim(repo, number, comment):
    run_gh(["issue", "comment", str(number), "--repo", repo, "--body", comment])


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Claim a GitHub issue before working it, so a second "
        "agent reading it first can see the first one got there."
    )
    parser.add_argument("number", type=int, help="issue number")
    parser.add_argument("--repo", default=DEFAULT_REPO, help="owner/name")
    parser.add_argument(
        "--marker",
        default=None,
        help="who is claiming (default: $CLAIM_ISSUE_MARKER or "
        "whoami@hostname)",
    )
    parser.add_argument(
        "--ttl-seconds",
        type=int,
        default=DEFAULT_TTL_SECONDS,
        help="how long a claim stays live (default: %d)" % DEFAULT_TTL_SECONDS,
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="decide and report, but post nothing",
    )
    args = parser.parse_args(argv)

    marker = args.marker
    if not marker:
        import os
        import socket

        marker = os.environ.get("CLAIM_ISSUE_MARKER")
        if not marker:
            try:
                user = os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"
                host = socket.gethostname().split(".")[0]
                marker = "%s@%s" % (user, host)
            except OSError:
                marker = "unknown"

    now = datetime.now(timezone.utc)

    try:
        issue = fetch_issue(args.repo, args.number)
        verdict, detail = decide(issue, now, marker, args.ttl_seconds)
    except CannotLook as exc:
        print("claim-issue: CANNOT LOOK -- %s" % exc, file=sys.stderr)
        return RC_INCOMPLETE

    if verdict == "closed":
        print("claim-issue: #%d -- %s" % (args.number, detail))
        return RC_INCOMPLETE

    if verdict == "blocked":
        print("claim-issue: #%d BLOCKED -- %s" % (args.number, detail), file=sys.stderr)
        return RC_FAIL

    if args.dry_run:
        print("claim-issue: #%d WOULD CLAIM (%s) -- dry run, nothing posted" % (args.number, detail))
        return RC_PASS

    try:
        post_claim(args.repo, args.number, claim_comment(marker, now, args.ttl_seconds))
    except CannotLook as exc:
        print("claim-issue: CANNOT LOOK -- %s" % exc, file=sys.stderr)
        return RC_INCOMPLETE

    print("claim-issue: #%d claimed by %s (%s)" % (args.number, marker, detail))
    return RC_PASS


if __name__ == "__main__":
    sys.exit(main())
