"""Ecosystem backlog numbers, shown on joue's map screen (issue #75).

vim-arcade's role in the backlog-as-sensor build (Zach's mapping,
2026-08-06): bibliothecaire files, ecosim monitors, scheduler runs the
mechanism, vim-arcade displays the numbers to Zach. "A number nobody
sees cannot pace anything."

Three numbers, in the order #75 asks for them:
  1. count -- open items, per repo and in total.
  2. first derivative -- rising or falling since the last time this map
     was built or refreshed, which #75 says matters more than the
     absolute value.
  3. age -- the oldest open item in a repo, in days.

Design choices that follow directly from #75's own two cautions:

- "Re-derived at display time from a live query, never carried forward
  from a previous run's cached figure" -- the COUNT always comes from a
  fresh discover_items() call (gh_game.py's job); this module never
  substitutes a stored number for that. What IS stored is the *prior*
  snapshot, because a derivative is definitionally a comparison between
  two points in time -- storing "what count did we see last time" is
  not the same mistake as displaying a stale count as if it were live.
- "Say what the number does not cover" -- see the module-level caveat
  string NOT_COVERED below, surfaced in the map's glossary (`?`).

snapshot_and_diff() is the one place history is read, diffed, and
overwritten. It must be called exactly once per data refresh (map
build, or `r`), never once per render frame -- calling it every frame
would compare each count against itself and every delta would read as
zero.
"""

import json
import os
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional

from .gh_triage import TriageItem

NOT_COVERED = (
    "Backlog numbers cover only hf7y + media-arts-collective repos "
    "(discovery.py's own scope) and only items gh search issues can see. "
    "Derivative compares to the last time THIS joue install opened or "
    "refreshed the map, not a continuous feed -- a repo opened here for "
    "the first time shows no derivative, not zero change. Age is the "
    "single oldest open item per repo, not a distribution. The needs-Zach "
    "fraction (#47) counts the `question` label, not exact last-comment "
    "authorship -- it can undercount an item that's genuinely awaiting a "
    "reply but was never labeled."
)

NEEDS_OWNER_LABEL = "question"


def needs_owner_count(items: List[TriageItem]) -> int:
    """How many of `items` are flagged as waiting on Zach -- issue #47's
    numerator ("outstanding/hanging issues" over "not yet addressed"; 0
    over any total means no Zach blockers).

    Uses the `question` label rather than
    answer_channel.is_awaiting_owner_reply, which is the exact predicate
    (whether the LAST comment is an unstamped owner reply) but needs full
    comment bodies per item -- discovery.py's multi-repo `gh search
    issues` call deliberately does not fetch those (one call per OWNER,
    not one per item; see discovery.py's own module docstring). The label
    is already free here -- `_SEARCH_FIELDS` already widens for it -- and
    nightly-batch.md's convention is that every agent-filed question
    carries it. See NOT_COVERED above for what this misses."""
    return sum(1 for item in items if NEEDS_OWNER_LABEL in item.labels)


def _history_path() -> Path:
    """~/.local/share/vim-arcade/backlog-history.json by default; same
    VIM_ARCADE_STATE_HOME override gh_triage.py's seen.json uses, so
    tests never touch the real machine-wide file."""
    base = os.environ.get("VIM_ARCADE_STATE_HOME")
    root = Path(base) if base else Path.home() / ".local" / "share" / "vim-arcade"
    return root / "backlog-history.json"


def load_history() -> Dict[str, dict]:
    """repo -> {"count": N, "at": iso8601}, the last snapshot taken. A
    missing or corrupt file reads as 'no history yet' rather than
    crashing the map on first launch -- same convention as seen.json's
    load_seen_state."""
    try:
        return json.loads(_history_path().read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def save_history(history: Dict[str, dict]) -> None:
    path = _history_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(history, indent=2, sort_keys=True))


def _parse_iso(ts: Optional[str]) -> Optional[datetime]:
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


def oldest_age_days(items: List[TriageItem], now: Optional[datetime] = None) -> Optional[float]:
    """Age in days of the oldest (earliest createdAt) item in `items`.
    None if nothing here has a usable created_at -- discovery.py's own
    degraded-field convention (missing rather than guessed) applies."""
    now = now or datetime.now(timezone.utc)
    ages = [
        (now - created).total_seconds() / 86400
        for created in (_parse_iso(getattr(item, "created_at", None)) for item in items)
        if created is not None
    ]
    return max(ages) if ages else None


@dataclass(frozen=True)
class BacklogDiff:
    deltas: Dict[str, Optional[int]] = field(default_factory=dict)
    total_count: int = 0
    total_delta: Optional[int] = None


def snapshot_and_diff(
    by_repo: Dict[str, List[TriageItem]], now: Optional[datetime] = None
) -> BacklogDiff:
    """Diff `by_repo`'s current counts against the last locally saved
    snapshot, then overwrite that snapshot with the current counts.

    Per-repo delta is None when this repo has no prior snapshot at all
    (first time joue's been pointed at it) -- distinct from a delta of
    0, which means "already tracked, unchanged." total_delta is None
    only when there is NO history file yet (this joue install's first
    ever snapshot); once any history exists, a newly-appeared repo's
    full count still counts toward total_delta, because it is a real
    rise in the tracked backlog, not a gap in coverage.

    A repo that closed its last open item vanishes from `by_repo`
    entirely (discovery.py's convention: zero open items, no key) but
    must still pull total_delta down -- so prior totals are summed from
    `history` directly, not from iterating today's `by_repo`. The saved
    history still carries that repo forward at count 0 (rather than
    dropping its key) so that if it later re-gains an open item, that
    repo's own next delta is computed against a real 0, not misread as
    "never seen before" (which would suppress a real rise back to None).
    """
    now = now or datetime.now(timezone.utc)
    history = load_history()
    counts = {repo: len(items) for repo, items in by_repo.items()}

    deltas: Dict[str, Optional[int]] = {}
    for repo, count in counts.items():
        prior = history.get(repo)
        deltas[repo] = (count - prior["count"]) if prior else None

    total_count = sum(counts.values())
    total_delta = (
        total_count - sum(v.get("count", 0) for v in history.values())
        if history
        else None
    )

    new_history = {repo: {"count": c, "at": now.isoformat()} for repo, c in counts.items()}
    for repo in history:
        if repo not in new_history:
            new_history[repo] = {"count": 0, "at": now.isoformat()}
    save_history(new_history)

    return BacklogDiff(deltas=deltas, total_count=total_count, total_delta=total_delta)
