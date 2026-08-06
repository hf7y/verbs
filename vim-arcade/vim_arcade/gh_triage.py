"""Turn this repo's live open GitHub issues/PRs into a playable
vim-arcade level -- one row per item, with a single-tile block you walk
up to (not a full wall) and interact with. gh_game.py owns what
"interact" means (a detail panel + real gh actions); this module only
owns fetching the data and shaping the grid.
"""

import functools
import json
import os
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from .grid import Level

BLOCK_COL = 4  # fallback column used only when a level has no per-row
# staggered layout (e.g. the empty-queue placeholder level).

# Grid width is bounded by the caller's terminal, never by title length --
# see build_level(max_width=...). 76 keeps an 80-col terminal's grid clear
# of the right edge with a small margin.
DEFAULT_MAX_WIDTH = 76

# Fields fetched up front, one `gh <kind> list` call per kind at startup
# (and again on refresh) -- NOT a per-item call. `comments` gives us
# enough to compute fresh-vs-replied without a second round trip; the
# full body still waits for fetch_detail. `labels` drives batch-seen
# (see batch_has_seen) and `updatedAt` is the change-marker for
# viewer-seen (see is_seen) -- both cost nothing extra since they ride
# the same list call. `mergeable`/`mergeStateStatus`/`reviewDecision`/
# `baseRefName` (PRs only) are issue #31's "visible before `m` is
# pressed" requirement -- widening this one existing call, not a new
# one. This is a snapshot only: gh_game.py's `m` handler re-checks fresh
# via merge_safety.check_mergeability before ever mutating anything,
# because this snapshot can go stale between fetch and keypress -- that
# staleness is exactly how the real incident behind #31 happened.
_ISSUE_LIST_FIELDS = "number,title,comments,labels,updatedAt"
_PR_LIST_FIELDS = (
    "number,title,comments,isDraft,labels,updatedAt,"
    "mergeable,mergeStateStatus,reviewDecision,baseRefName"
)


# ---------------------------------------------------------------------------
# Seen state -- two independent axes (issue #20/#21, reconstructed after the
# #22 paste bug split the original note across both):
#
#   1. Seen BY THE VIEWER -- has the human opened this item in `vim-arcade`. Local
#      state, since GitHub has no concept of "the signed-in user looked at
#      this." Persisted under ~/.local/share/vim-arcade/ (never in the
#      repo -- this is per-machine, not shared history), keyed by repo +
#      item number + the item's own `updatedAt`, so an item that changes
#      after being seen goes back to unseen rather than hiding an edit.
#
#   2. Seen BY THE BATCH -- has nightly-batch's own answer-loop already
#      processed this item. This is NOT a second local ledger (issue #10's
#      warning: a local copy of what an external process did will drift
#      from what it actually did). It's derived straight from GitHub
#      evidence already on the item: nightly-batch.md's documented
#      contract is "question" + "answered" together, acted on, then
#      closed -- so for an item that's still OPEN (the only kind this UI
#      ever shows; fetch_open_items only asks for --state open), carrying
#      both labels is the one state that contract actually defines as
#      "the batch's loop has already engaged with this," short of having
#      closed it out. See batch_has_seen().
# ---------------------------------------------------------------------------


def _state_path() -> Path:
    """~/.local/share/vim-arcade/seen.json by default; overridable via
    VIM_ARCADE_STATE_HOME so tests never touch the real machine-wide file."""
    base = os.environ.get("VIM_ARCADE_STATE_HOME")
    root = Path(base) if base else Path.home() / ".local" / "share" / "vim-arcade"
    return root / "seen.json"


def load_seen_state() -> Dict[str, str]:
    """Maps 'repo#number' -> the updatedAt value it was seen at. A missing
    or corrupt file reads as 'nothing seen yet' rather than crashing the
    game on startup -- losing seen-state is recoverable (everything just
    looks unseen again once), refusing to launch is not."""
    try:
        return json.loads(_state_path().read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def save_seen_state(state: Dict[str, str]) -> None:
    path = _state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2, sort_keys=True))


def seen_key(repo: str, number: int) -> str:
    return f"{repo}#{number}"


def is_seen(repo: Optional[str], number: int, updated_at: Optional[str], state: Dict[str, str]) -> bool:
    if not repo or updated_at is None:
        return False  # nothing to key on -- never claim "seen" on a guess
    return state.get(seen_key(repo, number)) == updated_at


def mark_seen(repo: Optional[str], item: "TriageItem") -> None:
    """Persist that `item` has been opened at its current updatedAt, and
    reflect that immediately on the in-memory item so the very next render
    shows it without waiting for a refetch."""
    if not repo or item.updated_at is None:
        return  # can't key a durable record without both; skip, don't guess
    state = load_seen_state()
    state[seen_key(repo, item.number)] = item.updated_at
    save_seen_state(state)
    item.seen_by_viewer = True


def batch_has_seen(labels: List[str]) -> bool:
    """True once nightly-batch's own documented loop (.claude/commands/
    nightly-batch.md step 1) has engaged with this item: it carries both
    `question` and `answered`. Derived from GitHub, not a local ledger --
    see the module docstring above for why."""
    return "question" in labels and "answered" in labels


@functools.lru_cache(maxsize=1)
def get_repo_slug() -> Optional[str]:
    """The current repo's own 'owner/name', resolved once per process --
    used to key seen-state consistently even when the caller never passes
    an explicit --repo."""
    try:
        out = subprocess.run(
            ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
            capture_output=True, text=True, check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    slug = out.stdout.strip()
    return slug or None


@functools.lru_cache(maxsize=1)
def get_viewer_login() -> Optional[str]:
    """The authenticated gh user's login, resolved once per process (not
    once per item) and cached -- so 'replied by Zach' works for whoever
    is actually signed in, not a hardcoded name."""
    try:
        out = subprocess.run(
            ["gh", "api", "user", "-q", ".login"],
            capture_output=True, text=True, check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    login = out.stdout.strip()
    return login or None


# Diacritic overlay on the issue letter only -- see symbol_for's docstring
# for why PRs/drafts don't get one. Independent of case (fresh/replied),
# so each of i/I gets its own acute/grave/circumflex variant.
_ISSUE_SEEN_DIACRITIC = {
    ("i", "viewer"): "í", ("I", "viewer"): "Í",
    ("i", "batch"): "ì", ("I", "batch"): "Ì",
    ("i", "both"): "î", ("I", "both"): "Î",
}


def symbol_for(
    kind: str,
    is_draft: bool,
    replied_by_viewer: bool,
    seen_by_viewer: bool = False,
    seen_by_batch: bool = False,
) -> str:
    """Pure symbol-selection table, kept separate from TriageItem so it's
    trivial to unit test every combination directly.

    issue: i (fresh) / I (replied by viewer) -- each further overlaid with
    a diacritic marking the seen axis (issue #20/#21): plain = unseen by
    either, acute (í/Í) = seen by you only, grave (ì/Ì) = seen by the
    batch only, circumflex (î/Î) = seen by both.
    pr:    p (fresh) / P (replied by viewer)
    draft pr: d (fresh) / D (replied by viewer) -- always distinct from
    a ready PR, regardless of reply state.

    PRs/drafts do NOT get a seen diacritic: p/d have no standard
    precomposed accented form in Latin-1 or Latin Extended-A the way i
    does (the only options live in Latin Extended Additional -- e.g.
    U+1E55 -- which is far less likely to be in a monospace terminal
    font), so encoding it there risked an invisible or box-glyph
    character rather than a legible one. Zach's own reconstructed
    request named "a family of I characters with diacritics" specifically
    -- this keeps the seen axis to the family that's actually safe to
    render, rather than silently encoding fewer states on a letter that
    can't carry them.
    """
    if kind == "pr" and is_draft:
        base = "d"
    elif kind == "pr":
        base = "p"
    else:
        base = "i"
    ch = base.upper() if replied_by_viewer else base
    if base != "i":
        return ch
    if seen_by_viewer and seen_by_batch:
        variant = "both"
    elif seen_by_viewer:
        variant = "viewer"
    elif seen_by_batch:
        variant = "batch"
    else:
        return ch
    return _ISSUE_SEEN_DIACRITIC[(ch, variant)]


@dataclass
class TriageItem:
    kind: str  # "issue" or "pr"
    number: int
    title: str
    body: Optional[str] = None  # fetched lazily, see fetch_detail
    url: Optional[str] = None
    is_draft: bool = False
    last_comment_by: Optional[str] = None  # login, or None if no comments
    viewer_login: Optional[str] = None  # resolved once per fetch, stored per item
    labels: List[str] = field(default_factory=list)
    updated_at: Optional[str] = None  # GitHub's updatedAt -- the seen change-marker
    repo: Optional[str] = None  # owner/name, used to key persisted seen-state
    seen_by_viewer: bool = False  # from local state at fetch time, or set live by mark_seen
    # PRs only (issue #31) -- a snapshot from the startup list call, shown
    # in the detail panel so mergeability is visible before `m` is
    # pressed. NEVER used to decide whether a merge may proceed -- that
    # re-checks fresh via merge_safety.check_mergeability at press time.
    mergeable: Optional[str] = None
    merge_state_status: Optional[str] = None
    review_decision: Optional[str] = None
    base_ref_name: Optional[str] = None

    @property
    def symbol(self) -> str:
        replied_by_viewer = bool(
            self.last_comment_by
            and self.viewer_login
            and self.last_comment_by == self.viewer_login
        )
        return symbol_for(
            self.kind, self.is_draft, replied_by_viewer,
            seen_by_viewer=self.seen_by_viewer,
            seen_by_batch=batch_has_seen(self.labels),
        )


def fetch_open_items(repo: str = None, limit: int = 100) -> List[TriageItem]:
    items: List[TriageItem] = []
    repo_args = ["--repo", repo] if repo else []
    viewer_login = get_viewer_login()
    resolved_repo = repo or get_repo_slug()
    seen_state = load_seen_state()  # one read for the whole fetch, not per item
    for kind, fields in (("issue", _ISSUE_LIST_FIELDS), ("pr", _PR_LIST_FIELDS)):
        out = subprocess.run(
            ["gh", kind, "list", "--state", "open", "--limit", str(limit),
             "--json", fields, *repo_args],
            capture_output=True, text=True, check=True,
        )
        for row in json.loads(out.stdout):
            comments = row.get("comments") or []
            last_comment_by = comments[-1]["author"]["login"] if comments else None
            labels = [l["name"] for l in (row.get("labels") or [])]
            updated_at = row.get("updatedAt")
            items.append(TriageItem(
                kind=kind,
                number=row["number"],
                title=row["title"],
                is_draft=bool(row.get("isDraft")),
                last_comment_by=last_comment_by,
                viewer_login=viewer_login,
                labels=labels,
                updated_at=updated_at,
                repo=resolved_repo,
                seen_by_viewer=is_seen(resolved_repo, row["number"], updated_at, seen_state),
                mergeable=row.get("mergeable"),
                merge_state_status=row.get("mergeStateStatus"),
                review_decision=row.get("reviewDecision"),
                base_ref_name=row.get("baseRefName"),
            ))
    return items


def refresh(repo: str = None, limit: int = 100) -> Tuple[Level, Dict[int, "TriageItem"]]:
    """Re-fetch open items and rebuild the level from scratch. This is
    the whole 'refresh' capability: closed-during-session items vanish
    because fetch_open_items only ever asks for --state open, and newly
    created ones appear because it's a fresh gh call, not a cached list.
    gh_game.py calls this; it does not reimplement any part of it."""
    items = fetch_open_items(repo=repo, limit=limit)
    return build_level(items)


def fetch_detail(item: TriageItem) -> TriageItem:
    """Fill in body/url the first time an item is actually opened --
    fetching every item's full body up front doesn't scale and isn't
    needed until the player walks up to it. This is also the single
    chokepoint gh_game.py calls every time the player walks up to a block
    (body-fetch itself is memoized below, but every call still means "the
    player is looking at this item right now") -- so it's exactly where
    viewer-seen gets marked and persisted (issue #20).

    Passes --repo whenever the item carries one (issue #32/#17): `gh`
    otherwise resolves the target repo from the process's cwd, which is
    wrong for any item that isn't from the repo `vim-arcade` happened to be
    launched in -- right number, wrong repo, exit 0, no error."""
    mark_seen(item.repo, item)
    if item.body is not None:
        return item
    kind = "issue" if item.kind == "issue" else "pr"
    repo_args = ["--repo", item.repo] if item.repo else []
    out = subprocess.run(
        ["gh", kind, "view", str(item.number), "--json", "body,url", *repo_args],
        capture_output=True, text=True, check=True,
    )
    data = json.loads(out.stdout)
    item.body = data.get("body") or "(no description)"
    item.url = data.get("url") or ""
    return item


def marker_col_for(level: Level, row: int = 0) -> int:
    """Column of the block on a given row. Rows are staggered (see
    _stagger_cols) so this is per-row, not one global column -- gh_game
    must call this with the player's *current* row for adjacency checks."""
    cols = getattr(level, "marker_cols", None)
    if cols:
        return cols.get(row, min(BLOCK_COL, max(level.width - 2, 0)))
    return min(BLOCK_COL, max(level.width - 2, 0))


def _stagger_cols(n_rows: int, width: int) -> Dict[int, int]:
    """Zigzag each row's block across the available columns instead of
    stacking every block in the same column -- issue #3 ("more spaced
    out rather than vertically stacked"): walking row to row now exercises
    real h/l motion, not just j/k down a single column."""
    lo, hi = 2, max(2, width - 3)
    if hi <= lo:
        return {r: lo for r in range(n_rows)}
    span = hi - lo
    period = span * 2
    cols = {}
    for r in range(n_rows):
        pos = r % period
        offset = pos if pos <= span else period - pos
        cols[r] = lo + offset
    return cols


def build_level(
    items: List[TriageItem], max_width: int = DEFAULT_MAX_WIDTH
) -> Tuple[Level, Dict[int, TriageItem]]:
    if not items:
        level = Level(
            name="gh triage -- nothing open",
            introduces=["h", "j", "k", "l"],
            ascii_map=["S.........@"],
        )
        return level, {}

    # Width is bounded by the caller's terminal (max_width), never by how
    # long a title is (issue #1) -- long titles get elided where they're
    # actually displayed as text, not allowed to blow out the grid.
    width = max(20, min(max_width, 60))
    marker_cols = _stagger_cols(len(items), width)
    rows = []
    row_items: Dict[int, TriageItem] = {}
    for idx, item in enumerate(items):
        row_items[idx] = item
        chars = ["."] * width
        chars[marker_cols[idx]] = "#"
        if idx == 0:
            chars[0] = "S"
        rows.append("".join(chars))
    rows.append("." * (width - 1) + "@")

    level = Level(
        # Deliberately movement-only: no "d"/"y"/"v"/"V"/Ctrl-v. Those
        # operators call grid.clear_wall directly, which would silently
        # turn a block to floor with no gh call at all -- the interaction
        # panel (gh_game.py) is the only path that's allowed to act on an
        # item, so the operators that could bypass it stay locked.
        name=f"gh triage -- {len(items)} open item(s)",
        introduces=["h", "j", "k", "l", "0", "$", "gg", "G", "w", "b"],
        ascii_map=rows,
    )
    level.marker_cols = marker_cols  # per-row lookup, see marker_col_for()
    return level, row_items
