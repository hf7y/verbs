"""Multi-repo discovery for joue's pane world (#32, building on #17 and
the prerequisite fixed in gh_triage.py/gh_game.py: every action must
carry --repo before any of this is safe to act on).

The world is every repo on `hf7y` plus every repo in the
`media-arts-collective` org (#17), discovered LIVE -- never a hardcoded
list, because a hand-maintained list is exactly the kind of thing that
drifts (new repos/orgs since the last edit, silently missing).

Cost discipline (#17/#32): one `gh search issues` call per OWNER, not one
`gh <kind> list` call per repo. 40+ repos on `hf7y` alone would be 80+
calls done the naive way; `gh search issues --owner <o> --state open`
covers an entire owner's open issues *and* PRs in a single call (PRs are
issues to this endpoint once --include-prs is set), so discovery costs
exactly len(owners) gh calls, independent of how many repos exist or how
many of them have anything open.

What this trades away: gh search issues's --json fields (verified
2026-08-04 via `gh search issues --json bogus` to list them) do not
include an item's last-comment author or a PR's draft status the way
`gh <kind> list` does for a single repo. Items built here therefore
default `last_comment_by=None` and `is_draft=False` -- both refine
themselves the moment fetch_detail() is called on the item (the existing
lazy-detail path), rather than spending a second call per repo up front
just to get them right before the player has even looked. This is a
documented degradation, not a silent one.
"""

import json
import subprocess
from typing import Dict, List

from .gh_triage import TriageItem, get_viewer_login, is_seen, load_seen_state

# hf7y is the account itself; media-arts-collective is the one org on it
# (confirmed via `gh api user/orgs` -- see #17 and this task's own
# verification step). Not exhaustive of "every owner that could ever
# exist" -- if a new org appears, #17's own acceptance criterion is that
# discovery is live, so re-deriving this tuple (or, better, deriving it
# from `gh api user/orgs` directly) is the fix, not hardcoding the new
# name in here by hand.
DEFAULT_OWNERS = ("hf7y", "media-arts-collective")

PINK_OWNER = "media-arts-collective"

_SEARCH_FIELDS = "repository,number,title,isPullRequest,labels,updatedAt"


def repo_owner(repo: str) -> str:
    return repo.split("/", 1)[0] if repo and "/" in repo else repo or ""


def is_pink(repo: str) -> bool:
    """media-arts-collective repos render pink (#17) -- everything else
    doesn't. Pure function of the repo slug so it's trivially testable
    without any curses/color-pair machinery involved."""
    return repo_owner(repo) == PINK_OWNER


def _search_owner(owner: str, limit: int) -> List[dict]:
    out = subprocess.run(
        [
            "gh", "search", "issues", "--owner", owner, "--state", "open",
            "--include-prs", "--limit", str(limit), "--json", _SEARCH_FIELDS,
        ],
        capture_output=True, text=True, check=True,
    )
    return json.loads(out.stdout)


def discover_items(
    owners: tuple = DEFAULT_OWNERS, limit: int = 1000
) -> Dict[str, List[TriageItem]]:
    """One `gh search issues` call per owner. Returns repo ("owner/name")
    -> its open TriageItems, sorted by repo name. A repo with zero open
    items across both owners simply never becomes a key here -- callers
    (the pane layout) use "is this repo a key in this dict" to decide
    whether it gets a pane at all (#17: "repos with zero open items do
    not occupy a pane")."""
    viewer_login = get_viewer_login()
    seen_state = load_seen_state()
    by_repo: Dict[str, List[TriageItem]] = {}
    for owner in owners:
        for row in _search_owner(owner, limit):
            repo_field = row.get("repository")
            repo = (
                repo_field.get("nameWithOwner")
                if isinstance(repo_field, dict)
                else repo_field
            )
            if not repo:
                continue  # can't act on an item whose repo we can't name -- drop, don't guess
            labels = [l["name"] for l in (row.get("labels") or [])]
            updated_at = row.get("updatedAt")
            kind = "pr" if row.get("isPullRequest") else "issue"
            item = TriageItem(
                kind=kind,
                number=row["number"],
                title=row["title"],
                is_draft=False,  # refined by fetch_detail -- see module docstring
                last_comment_by=None,  # refined by fetch_detail -- see module docstring
                viewer_login=viewer_login,
                labels=labels,
                updated_at=updated_at,
                repo=repo,
                seen_by_viewer=is_seen(repo, row["number"], updated_at, seen_state),
            )
            by_repo.setdefault(repo, []).append(item)

    for repo, items in by_repo.items():
        items.sort(key=lambda i: i.number)

    return dict(sorted(by_repo.items()))
