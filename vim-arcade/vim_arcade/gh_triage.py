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
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

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
# `createdAt` (issue #38) is what age_marker_cols below buckets into a
# grid column -- discovery.py's multi-repo path already fetched this for
# #75's age number; this single-repo path did not, so build_level's
# column position was reading item.created_at as always-None.
_ISSUE_LIST_FIELDS = "number,title,comments,labels,updatedAt,createdAt"
_PR_LIST_FIELDS = (
    "number,title,comments,isDraft,labels,updatedAt,createdAt,"
    "mergeable,mergeStateStatus,reviewDecision,baseRefName,headRefName"
)


# ---------------------------------------------------------------------------
# Seen state -- two independent axes (issue #20/#21, reconstructed after the
# #22 paste bug split the original note across both):
#
#   1. Seen BY THE VIEWER -- has the human opened this item in `joue`. Local
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
    head_ref_name: Optional[str] = None  # PRs only (issue #41) -- lets
    # merge_safety.check_subsumption test containment against other open
    # PRs' heads using local git, with no extra `gh` call: this rides the
    # same startup list fetch base_ref_name already widened.
    contained_in_number: Optional[int] = None  # PRs only (issue #41's
    # second box) -- the OTHER open PR whose head already contains this
    # one's. NOT fetched from `gh`: gh_game.py's annotate_subsumption()
    # sets this after the fact, once per refresh, via
    # merge_safety.subsumption_map (local git only). None means "not
    # known to be contained" -- absence is never a safety signal, only
    # a display one; `m`/`A` always re-verify fresh before refusing.
    contained_in_title: Optional[str] = None
    created_at: Optional[str] = None  # GitHub's createdAt -- issue #75's
    # age number reads from this. Only discovery.py's multi-repo search
    # populates it today; the single-repo fetch_open_items() path leaves
    # it None since nothing yet needs age there.

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
                head_ref_name=row.get("headRefName"),
                created_at=row.get("createdAt"),
            ))
    return items


def fetch_open_numbers(repo: str = None, limit: int = 100, timeout: int = 10) -> Dict[str, Set[int]]:
    """Issue #26's background poll wants to know COUNT AND DIRECTION of
    change, never content -- so this asks `gh` for `number` only (no
    comments/labels/title/body), one call per kind, same shape as
    fetch_open_items but as cheap as a queue-changed poll can be.
    Bounded by `timeout` so a hung `gh` degrades the poll (see
    queue_delta's caller, QueueWatcher in gh_game.py) instead of hanging
    the background thread forever -- same discipline as staleness.py's
    own timeout-bounded subprocess calls (issue #18), applied here to a
    different subprocess (`gh`, not `git`)."""
    repo_args = ["--repo", repo] if repo else []
    result: Dict[str, Set[int]] = {}
    for kind in ("issue", "pr"):
        out = subprocess.run(
            ["gh", kind, "list", "--state", "open", "--limit", str(limit),
             "--json", "number", *repo_args],
            capture_output=True, text=True, check=True, timeout=timeout,
        )
        result[kind] = {row["number"] for row in json.loads(out.stdout)}
    return result


def numbers_from_items(items) -> Dict[str, Set[int]]:
    """The same {"issue": {...}, "pr": {...}} shape as fetch_open_numbers,
    but read off of TriageItems already on screen -- lets QueueWatcher
    compare a live poll against "what's currently displayed" without a
    second `gh` call."""
    result: Dict[str, Set[int]] = {"issue": set(), "pr": set()}
    for item in items:
        result.setdefault(item.kind, set()).add(item.number)
    return result


def queue_delta(baseline: Dict[str, Set[int]], current: Dict[str, Set[int]]) -> Optional[str]:
    """Compare two numbers_from_items()/fetch_open_numbers() snapshots and
    describe the difference as a count and direction (issue #26's own
    requirement) -- never which items, since naming them would need the
    full fetch this poll deliberately avoids. None means no visible
    change, which is also what a degraded (failed) poll reports -- a
    failure must never read as "the queue is unchanged" to a caller that
    can't tell the difference, so QueueWatcher never calls this on a
    failed poll at all."""
    new_count = 0
    gone_count = 0
    for kind in set(baseline) | set(current):
        b = baseline.get(kind, set())
        c = current.get(kind, set())
        new_count += len(c - b)
        gone_count += len(b - c)
    if not new_count and not gone_count:
        return None
    parts = []
    if new_count:
        parts.append(f"{new_count} new")
    if gone_count:
        parts.append(f"{gone_count} gone")
    return "queue changed (" + ", ".join(parts) + ") -- press r"


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
    wrong for any item that isn't from the repo `joue` happened to be
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
    """Column of the block on a given row. Column position encodes each
    item's age (see age_marker_cols) so this is per-row, not one global
    column -- gh_game must call this with the player's *current* row for
    adjacency checks."""
    cols = getattr(level, "marker_cols", None)
    if cols:
        return cols.get(row, min(BLOCK_COL, max(level.width - 2, 0)))
    return min(BLOCK_COL, max(level.width - 2, 0))


def number_overlay_cols(
    marker_col: int, number: int, width: int, contained_in: Optional[int] = None,
) -> Dict[int, str]:
    """Display-only overlay placing an item's number in the floor columns
    immediately after its block (issue #28: 'i6' tells you what you're
    looking at, a bare 'i' does not). Same discipline as the symbol
    overlay in gh_game.render() -- the underlying grid stays untouched
    ('.'), only what the player sees changes, so movement/collision are
    unaffected. Silently clips at the row's edge rather than wrapping or
    raising -- a truncated number is a display nuisance, not a bug worth
    crashing a level over.

    `contained_in`, when given, appends a '>NN' marker right after the
    number (issue #41's second box: 'p12>37' means PR #12's head is
    already contained in still-open PR #37 -- merge that one instead).
    Same clip-at-the-edge discipline as the number itself; a truncated
    or fully-clipped marker is a display nuisance, never a crash."""
    cols = {}
    for i, ch in enumerate(str(number)):
        col = marker_col + 1 + i
        if col >= width:
            return cols
        cols[col] = ch
    if contained_in is None:
        return cols
    start = marker_col + 1 + len(str(number))
    for i, ch in enumerate(f">{contained_in}"):
        col = start + i
        if col >= width:
            break
        cols[col] = ch
    return cols


# Fixed age bands, in days (upper bound, exclusive, of every band before
# the last) -- issue #38: "bucket it (log scale, or fixed bands) ... an
# 'age' axis cannot let one ancient issue blow the grid out to 200
# columns." Band index becomes a column offset below, so grid width
# stays bounded by len(_AGE_BAND_DAYS) regardless of how old the oldest
# item actually is -- a 3-year-old issue and a 91-day-old one land in
# the same last band, not 3 years apart.
_AGE_BAND_DAYS = (1, 3, 7, 14, 30, 90)


def _parse_created_at(ts: Optional[str]) -> Optional[datetime]:
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


def item_age_days(item: TriageItem, now: Optional[datetime] = None) -> Optional[float]:
    """Age of `item` in days, from its own createdAt. None if the item
    has no created_at -- missing rather than guessed (same convention
    discovery.py's own age field already uses), never read as either
    the newest or the oldest item. `now` is injectable for tests, same
    pattern as backlog.oldest_age_days."""
    created = _parse_created_at(item.created_at)
    if created is None:
        return None
    now = now or datetime.now(timezone.utc)
    return (now - created).total_seconds() / 86400


def _age_band(age_days: Optional[float]) -> int:
    """Bucket age in days into one of len(_AGE_BAND_DAYS) + 1 fixed
    bands. None (unknown age) reads as band 0 -- the same band a brand
    new item gets -- rather than guessed as either newest or oldest."""
    if age_days is None:
        return 0
    for i, bound in enumerate(_AGE_BAND_DAYS):
        if age_days < bound:
            return i
    return len(_AGE_BAND_DAYS)


def age_marker_cols(
    items: List[TriageItem], width: int, now: Optional[datetime] = None
) -> Dict[int, int]:
    """Column of each row's block, encoding the item's age instead of an
    arbitrary zigzag (issue #38: "the position carries no information
    ... walking three columns to reach an item tells you nothing about
    the item"). Older items sit further from the start column -- the
    legible metaphor issue #38 names, "neglect has distance." Row order
    is unchanged (issue #3's "one item per row" still holds); only what
    each row's own column means has changed."""
    lo, hi = 2, max(2, width - 3)
    span = hi - lo
    max_band = len(_AGE_BAND_DAYS)
    now = now or datetime.now(timezone.utc)
    cols: Dict[int, int] = {}
    for idx, item in enumerate(items):
        band = _age_band(item_age_days(item, now))
        cols[idx] = lo if max_band == 0 or span <= 0 else lo + round(span * band / max_band)
    return cols


def selected_items(
    row_items: Dict[int, TriageItem], anchor_row: int, cursor_row: int
) -> List[TriageItem]:
    """Rows between anchor_row and cursor_row (inclusive) -- what a `V` +
    motion selection covers (issue #49 slice 1). Read-only by
    construction: it returns a list of TriageItems, never touches
    grid.clear_wall, so the caller cannot use this to mutate a level even
    by accident. A row with no item (the goal row's floor) is silently
    skipped, same discipline number_overlay_cols already uses for a
    clipped display."""
    lo, hi = sorted((anchor_row, cursor_row))
    return [row_items[r] for r in range(lo, hi + 1) if r in row_items]


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
    marker_cols = age_marker_cols(items, width)
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
        # Deliberately movement-only, plus one read-only exception (issue
        # #49 slice 1): "d"/"y"/"v"/Ctrl-v stay locked, because those
        # operators call grid.clear_wall directly, which would silently
        # turn a block to floor with no gh call at all -- the interaction
        # panel (gh_game.py) is the only path that's allowed to act on an
        # item, so the operators that could bypass it stay locked. "V"
        # (visual LINE mode only) is unlocked so a player can select a
        # run of rows with real vim motion -- session.py's own guard
        # already makes this safe: a bare "d"/"y" pressed while
        # visual_active is still gated on `key not in self.unlocked`
        # before it would ever call _apply_visual_operator, so an
        # unlocked "V" can never reach clear_wall through this door
        # either. gh_game.py routes the selection to a read-only preview
        # (":"), never to grid.clear_wall -- see selected_items() above.
        name=f"gh triage -- {len(items)} open item(s)",
        introduces=["h", "j", "k", "l", "0", "$", "gg", "G", "w", "b", "V"],
        ascii_map=rows,
    )
    level.marker_cols = marker_cols  # per-row lookup, see marker_col_for()
    return level, row_items
