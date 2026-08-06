"""curses front-end that plays this repo's live GitHub issue/PR queue as
a vim-arcade level. Each open item is a single-tile block on an
otherwise open row -- ordinary vim motions (h/j/k/l/w/b/0/$/gg/G) walk
right up to it, no clearing required. Landing adjacent to a block opens
a detail panel with its real title/body and a small action menu:

    c = comment    x = close    m = merge (PRs only)
    R = ready (draft PRs only, issue #23)    Esc = back

From anywhere while walking, "n" opens a two-step prompt (title, then
body) and creates a brand new issue in this repo.

`m` never mutates anything sight-unseen (issue #31): it re-checks
mergeability fresh (merge_safety.py) before ever building a `gh pr
merge` command, and refuses locally -- naming the specific reason and
the next action -- on a conflict, a draft, a blocked/failing-checks
gate, or a PR whose content is already superseded on its base (the
case that motivated this: detected by content overlap, not just
GitHub's own conflict flag, because a superseded PR that still applies
*cleanly* would otherwise merge silently). A title/diff mismatch warns
with the file count instead of refusing outright, and needs a second
`m` press to actually proceed.

Each action shells out to the real `gh` CLI. Default is DRY RUN: actions
log the command they would run without running it. Pass --live to have
them actually run.

Layout is a real budget (see compute_layout), not a stack of fixed
absolute offsets -- the old code wrote as far down as `base + 22` with no
regard for how tall the terminal actually was, which is what made issue
#8 crash on a normal 80x24 terminal. Every write goes through
safe_addstr/safe_addch, which clip to the real terminal size instead of
raising.

One launcher, two zoom levels (issue #39). No-arg `vim-arcade` opens THIS
repo, exactly as always -- everything above this paragraph is
unchanged. Pressing "M" (shown in the footer, never folklore) zooms OUT
to a tile map of every repo across hf7y + media-arts-collective (#17):
name, open count, and a compact fresh/replied/draft summary per tile --
no walkable grid and no item actions at that level, because you cannot
safely press `x` on something you cannot read (see gh_map.py for why
tiles, not mini-levels). Pressing Enter on a tile zooms IN to that
repo's single-repo view -- the exact same code below, just pointed at a
different repo's items -- and "M" from there returns to the map on the
same page with the same tile focused. `joue-panes` used to be a SECOND
launcher with its OWN event loop (#32/#36); it drifted from this one the
same day both were touched (#31's merge guard existed here and not
there) -- issue #10's "two definitions of the same thing will drift" in
a new costume. It is gone now (vim_arcade/gh_multipane.py deleted); the
`joue-panes` script is a thin alias for `vim-arcade --map`, which just starts
this same run() loop already zoomed out. There is exactly one place any
action key (`m`/`x`/`c`/`n`/`R`/`Q`, motion) is dispatched, in the
`while True` loop inside run() below -- the map mode reached from that
same loop routes to it too, by construction, since zooming into a tile
does not spawn a second loop, it just rebuilds `level`/`row_items`/
`session` for a different repo and falls through to the same `mode ==
"walk"`/`"detail"`/... branches everything else already uses.

If `vim-arcade` is launched outside a git repo, or inside one with no GitHub
remote (get_repo_slug() -> None), it opens the map directly rather than
failing -- there is nothing to build a single-repo view out of.
"""

import curses
import os
import subprocess
import sys

from . import dispatch, gh_map, merge_safety, staleness
from .discovery import discover_items
from .gh_triage import (
    build_level, fetch_detail, fetch_open_items, get_repo_slug, marker_col_for, refresh,
)
from .session import Session

PLAYER_CHAR = "@"
GOAL_CHAR = "$"

# Modes whose input widget needs a panel below the grid.
PANEL_MODES = ("detail", "comment", "new_title", "new_body")

# Chrome that's always reserved, top and bottom, regardless of terminal size.
HEADER_ROWS = 3  # title, mode_note, hint
STATUS_ROWS = 1  # "buffer: ... <message>"
FOOTER_ROWS = 1  # "Q to quit" -- must always stay visible (issue #8)
MAX_LOG_ROWS = 3  # action log -- must always stay visible (issue #8)
MAX_PANEL_ROWS = 10
MIN_GRID_ROWS = 3  # floor for the level viewport once a panel is open


def _key_to_char(key) -> str:
    if key in (curses.KEY_ENTER, 10, 13):
        return "\n"
    if 0 <= key < 256:
        return chr(key)
    return ""


# ---------------------------------------------------------------------------
# Paste safety (issue #22) -- diagnosis first: _key_to_char maps
# KEY_ENTER/10/13 to "\n", and every input-mode branch below used to treat
# that as "submit". A terminal paste is delivered as an ordinary stream of
# keystrokes with no framing of its own, so every embedded newline in a
# multi-line paste fired a premature submit -- this is exactly what
# happened to issue #20: a pasted multi-line note submitted early partway
# through, and the leftover tail became issue #21's title
# (`gh issue view 20/21`, reconstructed in a comment on each -- see the PR
# description for the full trace). Confirmed by reading the diagnosis
# aloud against the actual code path before writing this fix, per the
# task's own instruction not to assume it.
#
# Fix has two parts, deliberately layered rather than relying on either
# alone:
#
# 1. Enter no longer means submit in ANY of these three modes -- it always
#    inserts a literal newline (see _SUBMIT_KEY below for what submits
#    instead). This alone already closes the reported bug even on a
#    terminal with no bracketed-paste support at all: an unwrapped paste
#    delivers its embedded newlines as ordinary Enter keystrokes one at a
#    time, and those now insert rather than submit, so a plain paste can
#    no longer fragment into multiple issues no matter what the terminal
#    supports.
#
# 2. Bracketed paste (xterm/most modern terminals -- the same mechanism
#    `paste_lesson.py`'s own module docstring gestures at wanting for a
#    real vim buffer, though that module solves a different problem with
#    real vim rather than this one) is still worth doing on top of (1):
#    without it, curses' own keypad translation can misinterpret literal
#    escape-sequence-shaped text INSIDE a paste (e.g. pasted text that
#    happens to contain "ESC[A") as a function key rather than literal
#    characters. When bracketed paste is enabled, a terminal-initiated
#    paste is wrapped as ESC[200~<content>ESC[201~, and everything
#    between the markers is taken as literal text unconditionally --
#    consuming the markers here (not inserting them into the buffer) is
#    what makes that guarantee real.
#
# Terminal that doesn't support bracketed paste: it simply never sends the
# ESC[200~ marker, so _try_consume_paste always returns None below and a
# bare Esc still cancels exactly as before -- no crash, no behavior
# change. Layer (1) above is what keeps that terminal paste-safe anyway;
# layer (2) is defense in depth for the escape-sequence-collision case,
# not the only thing standing between a paste and a premature submit.
# ---------------------------------------------------------------------------

_BRACKETED_PASTE_START = "[200~"  # the ESC that precedes this is read by the
# caller as the ordinary key==27 check, so this constant starts right after it.
_BRACKETED_PASTE_END = "\x1b[201~"


def _match_escape_sequence(read_key, sequence):
    """Try to read `sequence` (a plain str) one key at a time via
    `read_key()` (anything shaped like curses' getch(): returns an int,
    or -1/curses.ERR when nothing is pending). Returns (True, []) on a
    full match, or (False, consumed) with the actual key codes read so
    far on any mismatch -- the caller pushes those back (curses.ungetch)
    so a false start never eats real input, e.g. a bare Escape keypress
    or some other escape sequence curses didn't recognize as a function
    key. Pure control flow, no curses dependency -- trivially unit
    testable with a plain iterator standing in for read_key.
    """
    consumed = []
    for expected_ch in sequence:
        k = read_key()
        if k == -1:
            return False, consumed
        consumed.append(k)
        if not (0 <= k < 256 and chr(k) == expected_ch):
            return False, consumed
    return True, []  # full match consumed exactly `sequence` -- nothing to push back


def _read_until_paste_end(read_key):
    """Reads keys via `read_key()` until _BRACKETED_PASTE_END is seen
    (consuming it), returning everything before it verbatim -- embedded
    newlines included, which is the entire point (issue #22). If the
    stream ends early (-1) before the terminator ever arrives, returns
    whatever was collected rather than hanging or raising -- a truncated
    paste is better than a stuck game."""
    end = _BRACKETED_PASTE_END
    buf = []
    while True:
        k = read_key()
        if k == -1:
            break
        ch = chr(k) if 0 <= k < 256 else ""
        buf.append(ch)
        if len(buf) >= len(end) and "".join(buf[-len(end):]) == end:
            return "".join(buf[: -len(end)])
    return "".join(buf)


def _try_consume_paste(stdscr):
    """Call this immediately after reading key == 27 (ESC) in an input
    mode. Peeks (non-blocking) for the rest of the bracketed-paste start
    marker; if found, blocks to read the pasted content up to the end
    marker and returns it as a single string with CRLF/CR normalized to
    LF. If the marker isn't there -- no bracketed paste support, or this
    really was just Escape -- pushes back every peeked key so normal
    handling (Esc == cancel) still sees them, and returns None.

    The peek must be non-blocking (nodelay(True)): a bare Escape keypress
    is not followed by anything, so a blocking read here would hang the
    whole game waiting on a key that's never coming. nodelay is always
    restored to False (this mode's normal blocking-read setting) before
    returning, whichever path is taken.
    """
    stdscr.nodelay(True)
    try:
        matched, consumed = _match_escape_sequence(stdscr.getch, _BRACKETED_PASTE_START)
    finally:
        stdscr.nodelay(False)
    if not matched:
        for k in reversed(consumed):
            curses.ungetch(k)
        return None
    text = _read_until_paste_end(stdscr.getch)
    return text.replace("\r\n", "\n").replace("\r", "\n")


_SUBMIT_KEY = 4  # Ctrl-D (EOT). Enter now always inserts a literal newline in
# comment/new_title/new_body -- see the module note above for why -- so a
# distinct key is needed to actually submit. Ctrl-D was picked because it's
# available on every terminal with no escape-sequence ambiguity (unlike
# trying to special-case Ctrl-Enter, which most terminals don't transmit
# as anything distinguishable from plain Enter at all) and matches the
# "end of input" convention already familiar from shells/heredocs/mutt.


def _set_bracketed_paste(enable: bool) -> None:
    """Toggle the terminal's bracketed-paste mode by writing the raw
    DEC private mode sequence directly to stdout (curses has no built-in
    call for this). Enabling is idempotent -- xterm and its descendants
    treat a repeat DECSET as a no-op -- so this is safe to call on every
    entry into an input mode rather than needing extra state to track
    'already on'. Guarded: a stdout that isn't a real terminal (e.g. under
    a test harness) must never crash the game over a cosmetic escape
    sequence.
    """
    seq = "\x1b[?2004h" if enable else "\x1b[?2004l"
    try:
        sys.stdout.write(seq)
        sys.stdout.flush()
    except (OSError, ValueError):
        pass


def close_command(item):
    kind = "issue" if item.kind == "issue" else "pr"
    cmd = ["gh", kind, "close", str(item.number)]
    if item.repo:  # issue #32/#17: --repo, not the process cwd, targets the action
        cmd += ["--repo", item.repo]
    return cmd


def merge_command(item):
    cmd = ["gh", "pr", "merge", str(item.number), "--squash"]
    if item.repo:
        cmd += ["--repo", item.repo]
    return cmd


def ready_command(item):
    """Issue #23/#31: undrafting is a visible act other people react to,
    so it lives on its own explicit key (R), never chained onto a merge
    -- see the 'R' branch in run() and merge_safety.MergeDecision's
    next_action for a draft, which names this command."""
    return ["gh", "pr", "ready", str(item.number)]


def mergeability_snapshot_lines(item):
    """PR mergeability summary from the startup list snapshot
    (gh_triage.fetch_open_items -- no extra `gh` call), shown in the
    detail panel BEFORE `m` is pressed (issue #31: 'mergeability
    visible before the keypress'). Returns a short LIST of lines rather
    than one long one -- a single line carrying state + base name +
    the staleness caveat runs well past 40 columns and the base name
    (the one fact a refusal actually needs to be actionable) was the
    part getting elided first; splitting keeps state+base on their own
    line so it survives a narrow terminal.

    Explicitly labelled 'as of last fetch' -- this is exactly the value
    that goes stale between fetch and keypress, which is why the `m`
    handler re-checks fresh via merge_safety.check_mergeability rather
    than trusting this snapshot."""
    if item.kind != "pr":
        return []
    lines = []
    if item.is_draft:
        lines.append("DRAFT -- needs [R] ready before it can be merged")
    if item.mergeable:
        base = f" with '{item.base_ref_name}'" if item.base_ref_name else ""
        state = f" ({item.merge_state_status})" if item.merge_state_status else ""
        lines.append(f"{item.mergeable}{base}{state}")
    if item.review_decision:
        lines.append(f"review: {item.review_decision}")
    if not lines:
        lines.append("mergeability unknown")
    lines.append("(as of last fetch -- re-checked on [m])")
    return lines


def comment_command(item, text):
    kind = "issue" if item.kind == "issue" else "pr"
    cmd = ["gh", kind, "comment", str(item.number), "--body", text]
    if item.repo:
        cmd += ["--repo", item.repo]
    return cmd


def create_issue_command(title, body, repo=None):
    cmd = ["gh", "issue", "create", "--title", title, "--body", body]
    if repo:  # optional: this builder has no TriageItem to carry a repo,
        cmd += ["--repo", repo]  # callers pass one explicitly (e.g. a focused pane's repo)
    return cmd


def _run_action(
    cmd, live, log, verb, *, activity=None, action=None, kind=None, number=None,
    title=None, repo=None, detail="",
):
    """Run one gh action. DRY RUN only ever logs the command (requirement:
    only dispatch real work -- nothing was actually created, so there is
    nothing to hand off). On a LIVE run that actually succeeds, also
    record it into `activity` (a dispatch.SessionActivity) so quitting
    can offer to hand real work to the self-dev loop; a LIVE run that
    fails (`FAILED:`) is never recorded either.

    Returns True only for a LIVE run that actually succeeded -- issue
    #46's post-merge sync offer uses this to know whether a real merge
    just landed, rather than re-deriving it from the log's text."""
    if live:
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            out = result.stdout.strip()
            status = f"ok -- {out}" if out else "ok"
            if activity is not None and action is not None:
                resolved_number = number if number is not None else dispatch.parse_item_number(out)
                activity.record(dispatch.ActivityRecord(
                    action=action, kind=kind, repo=repo, number=resolved_number,
                    title=title or "", detail=detail or out,
                ))
            log.append(f"LIVE {verb} -- {status}")
            return True
        status = f"FAILED: {result.stderr.strip()[:120]}"
        log.append(f"LIVE {verb} -- {status}")
        return False
    log.append(f"DRY RUN would run: {' '.join(cmd)}")
    return False


def handle_merge_key(
    item, live, log, activity, session_repo, mismatch_seen, repo_dir,
    *, check_mergeability=merge_safety.check_mergeability,
):
    """The whole of issue #31's decision, pulled out of run()'s event
    loop so it's directly unit-testable with no curses involved (see
    tests/test_merge_safety.py's 'no mutation on refusal' tests) --
    mirrors why _run_action itself is a free function rather than
    inlined. `check_mergeability` is injected (defaults to the real
    one) purely so tests can stub the one `gh pr view` + local-git call
    it makes without touching subprocess directly.

    Returns the new mode ("walk" on a refusal or a completed merge,
    "detail" to stay put after a first-time mismatch warning) --
    callers assign it, this function never touches curses state itself.

    `mismatch_seen` is keyed by (session_repo, item.number), not just
    item.number: issue #39 made a single session able to act on items
    from more than one repo (walk a repo, zoom to the map, zoom into a
    different repo) -- two different repos can easily both have a PR
    #5, and keying on the bare number would let a mismatch warning
    already shown for one repo's #5 silently suppress the warning for a
    different repo's unrelated #5.
    """
    key = (session_repo, item.number)
    decision = check_mergeability(item.number, repo_dir, repo=session_repo)
    if not decision.allowed:
        mismatch_seen.discard(key)
        # next_action leads, and the prefix is kept short -- log lines
        # are a single un-wrapped row (issue #8's safe_addstr elides
        # past the terminal edge rather than wrapping), so at 40
        # columns the actionable part must survive truncation even if
        # the descriptive reason after it does not.
        log.append(
            f"REFUSED #{item.number}: {decision.next_action} ({decision.reason})"
        )
        return "walk"
    if decision.warning and key not in mismatch_seen:
        # First press surfacing a title/diff mismatch: warn and stop --
        # never auto-fix, never merge on the same keypress that first
        # shows the human the mismatch. A second [m] (now informed)
        # proceeds. Same lead-with-the-action, short-prefix ordering as
        # the refusal log line above.
        mismatch_seen.add(key)
        log.append(
            f"WARN #{item.number}: press [m] again -- {decision.warning}"
        )
        return "detail"
    mismatch_seen.discard(key)
    _run_action(
        merge_command(item), live, log, f"merged pr #{item.number}",
        activity=activity, action="merge", kind=item.kind, number=item.number,
        title=item.title, repo=session_repo,
    )
    return "walk"


def post_merge_sync_offer(repo_dir, check_target_staleness=staleness.check_target_staleness):
    """After a LIVE merge actually lands (issue #46: "if I just merged a
    PR, I would always want that as my check out"), check whether THIS
    checkout -- the one `vim-arcade` is running in, not necessarily the repo
    the merged PR belonged to -- is now behind its own origin, and
    return (log_line, offerable). Never automatic: `offerable` only ever
    makes the 'f' key live for one keypress, the caller still has to
    press it.

    Returns (None, False) when there's nothing to say (still up to date,
    or the probe couldn't tell) -- a clean bill of health after a merge
    is not itself news worth a log line."""
    status = check_target_staleness(repo_dir)
    if status.state == staleness.STATE_BEHIND:
        refusal = staleness.target_update_blocked_reason(status)
        if refusal is not None:
            return f"this checkout is now behind -- {refusal.describe()}", False
        return "merged -- this checkout is now behind; press [f] to fast-forward", True
    if status.state == staleness.STATE_DIVERGED:
        refusal = staleness.target_update_blocked_reason(status)
        return f"this checkout has diverged -- {refusal.describe()}", False
    return None, False


def _fast_forward_checkout(
    repo_dir=None, check_target_staleness=staleness.check_target_staleness,
    update_target=staleness.update_target,
):
    """Re-checks staleness FRESH at keypress time (same "state goes
    stale between fetch and keypress" discipline handle_merge_key uses
    for mergeability) rather than trusting the status captured when the
    offer first fired, then runs the real fast-forward -- never a second
    hand-rolled git call. Returns a message for the status line."""
    repo_dir = repo_dir if repo_dir is not None else os.getcwd()
    status = check_target_staleness(repo_dir)
    result = update_target(repo_dir, status)
    return f"checkout: {result}"


# ---------------------------------------------------------------------------
# Safe, clipped drawing -- every stdscr write in this module goes through one
# of these two, so nothing can ever throw past a small/oddly-sized terminal
# (issue #8) and long text gets an elided "..." instead of just vanishing
# off the edge (issue #1) or silently truncating input the human typed
# (issue #2).
# ---------------------------------------------------------------------------


def safe_addstr(stdscr, row, col, text, attr=0):
    height, width = stdscr.getmaxyx()
    if row < 0 or row >= height or col < 0 or col >= width or not text:
        return
    avail = width - col
    if avail <= 0:
        return
    if len(text) > avail:
        text = text[: avail - 1] + "…" if avail > 1 else text[:1]
    try:
        stdscr.addstr(row, col, text, attr)
    except curses.error:
        pass  # e.g. the bottom-right cell -- ncurses can still refuse this


def safe_addch(stdscr, row, col, ch, attr=0):
    height, width = stdscr.getmaxyx()
    if row < 0 or row >= height or col < 0 or col >= width:
        return
    try:
        stdscr.addch(row, col, ch, attr)
    except curses.error:
        pass


# ---------------------------------------------------------------------------
# Map mode (issue #39) -- the zoom-out tile view. gh_map.py owns the pure
# layout/paging/focus math (tested there without curses); everything here
# is drawing plus the pink-tile color pair, ported from the old
# gh_multipane.py (now deleted) since this is the only front end left
# that needs it.
# ---------------------------------------------------------------------------

PINK_PAIR = 1


def init_color(stdscr) -> bool:
    """Set up the pink color pair for media-arts-collective tiles (#17),
    degrading gracefully where color is unavailable -- curses.has_colors()
    is the documented way to ask, and a terminal that answers False here
    must render everything else identically, never crash over cosmetics.

    has_colors() itself is wrapped too, not just start_color()/init_pair():
    it raises curses.error ("must call initscr() first") when there is no
    real curses session at all, which is exactly the case for every test
    that drives run() against a FakeStdscr directly rather than through
    curses.wrapper -- that must degrade to no-color, not blow up the
    whole event loop over a cosmetic."""
    try:
        if not curses.has_colors():
            return False
        curses.start_color()
        curses.init_pair(PINK_PAIR, curses.COLOR_MAGENTA, curses.COLOR_BLACK)
        return True
    except curses.error:
        return False


def _pink_attr(has_color: bool) -> int:
    if not has_color:
        return curses.A_BOLD
    try:
        return curses.color_pair(PINK_PAIR)
    except curses.error:
        # Defense in depth: has_color is only ever True after init_color()
        # actually ran curses.start_color() successfully, but a caller
        # that passes has_color=True without a real curses context (a
        # test, or a future refactor) must still degrade rather than
        # crash -- same "colour-less terminal never a hard stop" rule
        # #17 asks for, just covering a second way to reach it.
        return curses.A_BOLD


def _render_tile(stdscr, tile, rect, focused, has_color):
    top, left, w, h = rect
    if w < 4 or h < 1:
        return
    attr = _pink_attr(has_color) if tile.pink else 0
    if focused:
        attr |= curses.A_REVERSE if not tile.pink else curses.A_BOLD
    name = f"{'*' if focused else ' '}{tile.repo}"
    safe_addstr(stdscr, top, left, name[: max(0, w - 1)], attr)
    if h > 1:
        counts = f"{tile.total} open  f:{tile.fresh} r:{tile.replied} d:{tile.draft}"
        safe_addstr(stdscr, top + 1, left, counts[: max(0, w - 1)], attr)


def render_map(stdscr, map_state, message, has_color):
    """Draw one frame of the tile map. Pure with respect to state (never
    mutates map_state) -- same discipline render() uses for the
    single-repo view. Returns the layout dict so the caller's input
    handling (which needs `per_page`/`cols` for move_focus/paging) never
    has to recompute it out of sync with what was actually drawn."""
    height, width = stdscr.getmaxyx()
    tiles = map_state.tiles
    layout = gh_map.compute_map_layout(len(tiles), height, width)
    stdscr.erase()

    safe_addstr(stdscr, 0, 0, "vim-arcade -- map (h/j/k/l move, Enter open, n/p page, r refresh)")
    page = gh_map.current_page(map_state.focus, layout)
    if tiles:
        page_note = f"page {page + 1}/{layout['page_count']}  repos: {len(tiles)}"
    else:
        page_note = "nothing open in any repo"
    safe_addstr(stdscr, 1, 0, page_note)
    if message:
        safe_addstr(stdscr, layout["status_row"], 0, message)

    per_page = layout["per_page"]
    page_start = page * per_page
    page_tiles = tiles[page_start : page_start + per_page]
    for slot, tile in enumerate(page_tiles):
        idx = page_start + slot
        rect = gh_map.tile_rect(slot, layout)
        _render_tile(stdscr, tile, rect, idx == map_state.focus, has_color)

    safe_addstr(stdscr, layout["quit_row"], 0, "Q to quit   Enter: open repo")
    stdscr.refresh()
    return layout


# ---------------------------------------------------------------------------
# Wrapping -- issue #2: comment>/title>/body> input must wrap instead of
# scrolling off to the right forever.
# ---------------------------------------------------------------------------


def _hard_wrap(text, width):
    """Word-wrap `text` to `width`, hard-breaking any single token (e.g. a
    long URL typed with no spaces) that's wider than `width` on its own --
    plain word-wrap alone would leave that one token running off-screen."""
    if width <= 0:
        return [text]
    lines = []
    line = ""
    for word in text.split(" "):
        while len(word) > width:
            if line:
                lines.append(line)
                line = ""
            lines.append(word[:width])
            word = word[width:]
        candidate = f"{line} {word}".strip() if line else word
        if len(candidate) > width:
            lines.append(line)
            line = word
        else:
            line = candidate
    lines.append(line)
    return lines


def _wrap_all(text, width):
    """Wrap every paragraph, keeping all of it. Callers that only have
    room for part of it do the windowing themselves -- see body_lines."""
    lines = []
    for para in text.replace("\r", "").split("\n"):
        lines.extend(_hard_wrap(para, width))
    return lines


def _wrap(text, width, max_lines):
    return _wrap_all(text, width)[:max_lines]


def _clamp_scroll(scroll, total, budget):
    """Keep a scroll offset inside the scrollable range, so j past the
    end or k past the top parks at the edge instead of showing a blank
    panel."""
    if budget <= 0:
        return 0
    return max(0, min(scroll, max(0, total - budget)))


def _wrap_input(prefix, buffer, width, max_lines):
    """Wrap a live input widget (prefix + what's been typed so far),
    keeping the caret (end of buffer) visible by showing the *tail* of the
    wrapped lines once there are more than max_lines -- so typing past the
    bottom of the panel scrolls the input up rather than hiding the caret.

    Newline-aware (issue #22's fix depends on this): a multi-line paste
    now lands as real "\\n" characters in `buffer` (see
    _try_consume_paste), so this has to treat "\\n" as a hard break the
    same way _wrap_all does for item bodies -- a plain _hard_wrap call
    alone only splits on spaces and would show embedded newlines as odd
    mid-word characters instead of actual line breaks, which is exactly
    the "not visible while editing" gap this fix has to close.
    """
    max_lines = max(1, max_lines)
    width = max(1, width)
    paragraphs = (prefix + buffer).split("\n")
    lines = []
    for para in paragraphs:
        lines.extend(_hard_wrap(para, width))
    lines = lines or [""]
    return lines[-max_lines:]


# ---------------------------------------------------------------------------
# Layout budget -- pure function of (height, width, mode), no curses
# involved, so it's directly unit-testable. This replaces the old code's
# fixed absolute offsets (`base + 22` etc.) that assumed an arbitrarily
# tall terminal.
# ---------------------------------------------------------------------------


def compute_layout(height, width, mode):
    quit_row = height - 1
    log_h = max(0, min(MAX_LOG_ROWS, height - (HEADER_ROWS + STATUS_ROWS) - FOOTER_ROWS))
    log_top = quit_row - log_h

    top_fixed = HEADER_ROWS + STATUS_ROWS  # first row free for grid/panel
    available = max(0, log_top - top_fixed)

    panel_needed = mode in PANEL_MODES
    if panel_needed and available > 0:
        panel_h = min(MAX_PANEL_ROWS, max(0, available - MIN_GRID_ROWS))
        # If there isn't room to keep the grid floor, let the panel take
        # whatever's left rather than the grid winning by default -- the
        # panel is what the player asked to see by walking up to a block.
        if available - panel_h < 0:
            panel_h = available
        grid_h = available - panel_h
    else:
        panel_h = 0
        grid_h = available

    grid_top = top_fixed
    panel_top = grid_top + grid_h if panel_h else None

    return {
        "header_rows": (0, 1, 2),
        "status_row": HEADER_ROWS,
        "grid_top": grid_top,
        "grid_h": grid_h,
        "panel_top": panel_top,
        "panel_h": panel_h,
        "log_top": log_top,
        "log_h": log_h,
        "quit_row": quit_row,
    }


def _viewport_top(player_row, level_height, grid_h):
    """Scroll offset for the level grid so it follows the player instead
    of drawing rows that are off-screen (load-bearing once there are more
    items than fit -- 9 open issues already nearly fills 80x24)."""
    if grid_h <= 0 or level_height <= grid_h:
        return 0
    top = player_row - grid_h // 2
    return max(0, min(top, level_height - grid_h))


def body_lines(item, width):
    """Every wrapped line of an item's body -- no truncation. The panel
    shows a window onto this; `run()` needs the full length to clamp
    scrolling, so the wrapping happens in one place for both."""
    return _wrap_all(item.body or "", max(1, width))


def _panel_lines(
    mode, item, comment_buffer, new_title, new_body, panel_h, width, body_scroll=0
):
    if panel_h <= 0:
        return []
    input_width = max(1, width - 1)
    if mode == "detail":
        header = f"{item.kind} #{item.number}: {item.title}"
        menu = "[c] comment  [x] close"
        if item.kind == "pr":
            menu += "  [m] merge"
            if item.is_draft:
                menu += "  [R] ready"
        menu += "  [Esc] back"
        header_lines = [header] + mergeability_snapshot_lines(item)
        body_budget = max(0, panel_h - 1 - len(header_lines))
        # Issue bodies are routinely longer than the panel (the design
        # issues in this very repo run to thousands of characters). The
        # old code wrapped at a hardcoded width of 100 and threw away
        # everything past body_budget lines, with nothing on screen to
        # say it had done so -- Zach hit exactly this reading #12 and
        # reported it as "cannot see the entire issue, ends with 'and
        # that is a'". So: wrap to the real width, show a window, and
        # always say when there is more.
        all_lines = body_lines(item, width)
        total = len(all_lines)
        top = _clamp_scroll(body_scroll, total, body_budget)
        window = all_lines[top : top + body_budget] if body_budget else []
        if total > body_budget and body_budget:
            shown_end = min(top + body_budget, total)
            menu = f"[{top + 1}-{shown_end}/{total} j/k scroll]  " + menu
        lines = header_lines + window
        lines = lines[: max(1, panel_h - 1)]
        lines.append(menu)
        return lines[:panel_h]
    if mode == "comment":
        header = f"{item.kind} #{item.number}: {item.title}"
        hint = "Enter: newline  Ctrl-D: submit  Esc: cancel"
        input_budget = max(1, panel_h - 2)
        lines = [header] + _wrap_input("comment> ", comment_buffer, input_width, input_budget)
        lines = lines[: max(1, panel_h - 1)]
        lines.append(hint)
        return lines[:panel_h]
    if mode == "new_title":
        hint = "Enter: newline  Ctrl-D: continue to body  Esc: cancel"
        input_budget = max(1, panel_h - 2)
        lines = ["New issue -- title:"] + _wrap_input(
            "title> ", new_title, input_width, input_budget
        )
        lines = lines[: max(1, panel_h - 1)]
        lines.append(hint)
        return lines[:panel_h]
    if mode == "new_body":
        hint = "Enter: newline  Ctrl-D: create  Esc: cancel"
        input_budget = max(1, panel_h - 2)
        lines = [f"New issue -- title: {new_title}"] + _wrap_input(
            "body> ", new_body, input_width, input_budget
        )
        lines = lines[: max(1, panel_h - 1)]
        lines.append(hint)
        return lines[:panel_h]
    return []


def render(
    stdscr,
    level,
    row_items,
    session,
    mode,
    active_row,
    comment_buffer,
    new_title,
    new_body,
    message,
    log,
    mode_note,
    hint,
    body_scroll=0,
):
    """Draw one frame. Pure with respect to state (never mutates it) --
    all state changes happen in the input-handling half of run(). Kept
    separate from the event loop so it's testable against a fake stdscr
    at any terminal size."""
    height, width = stdscr.getmaxyx()
    layout = compute_layout(height, width, mode)

    stdscr.erase()

    safe_addstr(stdscr, 0, 0, f"vim-arcade gh-triage -- {level.name}")
    safe_addstr(stdscr, 1, 0, mode_note)
    safe_addstr(stdscr, 2, 0, hint)

    status = f"buffer: {session.key_buffer}"
    if message:
        status = f"{status}   {message}"
    safe_addstr(stdscr, layout["status_row"], 0, status)

    grid_top, grid_h = layout["grid_top"], layout["grid_h"]
    prow, pcol = session.player_pos
    vtop = _viewport_top(prow, level.height, grid_h)
    for screen_r in range(grid_h):
        r = vtop + screen_r
        if r >= level.height:
            break
        for c in range(level.width):
            ch = level.char_at(r, c)
            if ch == "@":
                ch = GOAL_CHAR
            elif ch == "#" and r in row_items:
                # Display-only symbol overlay (issue #9). The tile stays
                # "#" in the grid so grid.py's wall/movement logic is
                # untouched -- only what the player *sees* changes.
                ch = getattr(row_items[r], "symbol", "#") or "#"
            safe_addch(stdscr, grid_top + screen_r, c, ch)
    if grid_top <= grid_top + (prow - vtop) < grid_top + grid_h:
        safe_addch(stdscr, grid_top + (prow - vtop), pcol, PLAYER_CHAR, curses.A_BOLD)

    if layout["panel_h"] and mode in ("detail", "comment") and active_row is not None:
        item = row_items[active_row]
        for i, line in enumerate(
            _panel_lines(
                mode, item, comment_buffer, new_title, new_body,
                layout["panel_h"], width, body_scroll,
            )
        ):
            safe_addstr(stdscr, layout["panel_top"] + i, 0, line)
    elif layout["panel_h"] and mode in ("new_title", "new_body"):
        for i, line in enumerate(
            _panel_lines(mode, None, comment_buffer, new_title, new_body, layout["panel_h"], width)
        ):
            safe_addstr(stdscr, layout["panel_top"] + i, 0, line)

    for i, line in enumerate(log[-layout["log_h"] :] if layout["log_h"] else []):
        safe_addstr(stdscr, layout["log_top"] + i, 0, line)

    # "M: map" here is issue #39's discoverability requirement made
    # literal: the footer is the one place that's ALWAYS visible
    # regardless of mode, so this is where "how do I get back to the
    # map" lives -- never folklore, never only in a hint line that
    # scrolls out of relevance once you're deep in a detail panel.
    safe_addstr(stdscr, layout["quit_row"], 0, "Q to quit   M: map")
    stdscr.refresh()


# ---------------------------------------------------------------------------
# Startup staleness prompt (issue #18) -- runs once, before the event loop.
# All git/gh probing lives in staleness.py; this is only the screen and the
# pure decision of what it offers, both directly unit-testable.
# ---------------------------------------------------------------------------


def engine_dir():
    """Repo root that contains vim_arcade/ and .git -- same directory the
    `vim-arcade` launcher computes as ENGINE_DIR and puts on PYTHONPATH."""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def startup_actions(engine_status, target_status):
    """Pure decision of what the startup prompt offers, given the two
    staleness reports -- no curses, so this is unit-testable without a
    stdscr. Four states (behind / diverged / wrong-branch / detached) are
    all "stale" for the engine; a fifth, up-to-date-or-unknown, needs no
    prompt at all (never blocks the UI to say nothing is wrong).
    STATE_DIVERGED (#46) is always shown -- it's always blocked (a
    fast-forward cannot apply), so it never becomes offerable, but the
    player still needs to see the rebase instruction."""
    engine_stale = engine_status.state in (
        staleness.STATE_BEHIND, staleness.STATE_DIVERGED,
        staleness.STATE_WRONG_BRANCH, staleness.STATE_DETACHED,
    )
    target_stale = target_status.state in (staleness.STATE_BEHIND, staleness.STATE_DIVERGED)

    engine_blocked = staleness.engine_update_blocked_reason(engine_status) if engine_stale else None
    target_blocked = staleness.target_update_blocked_reason(target_status) if target_stale else None

    return {
        "needs_prompt": engine_stale or target_stale,
        "engine_stale": engine_stale,
        "engine_offerable": engine_stale and engine_blocked is None,
        "engine_blocked_reason": engine_blocked,
        "target_stale": target_stale,
        "target_offerable": target_stale and target_blocked is None,
        "target_blocked_reason": target_blocked,
    }


def render_startup_prompt(stdscr, engine_status, target_status):
    """Draw the one-time startup screen. Every write goes through
    safe_addstr (issue #8) and long lines wrap through _hard_wrap rather
    than running off the edge, same discipline as render(). Returns the
    startup_actions() dict so callers/tests don't have to recompute it."""
    actions = startup_actions(engine_status, target_status)
    height, width = stdscr.getmaxyx()
    stdscr.erase()

    row = 0

    def put(text, attr=0):
        nonlocal row
        for line in _hard_wrap(text, max(1, width)):
            safe_addstr(stdscr, row, 0, line, attr)
            row += 1

    put("vim-arcade startup check", curses.A_BOLD)
    row += 1

    if actions["engine_stale"]:
        put(f"engine: {engine_status.message}")
        for pr in engine_status.merged_prs:
            put(f"  latest: {pr}")
        if actions["engine_blocked_reason"]:
            # Issue #31/#46: a refusal always names the reason AND the
            # next action -- refusal.Refusal.describe() is the one
            # shared formatter (see merge_safety.py's log line for the
            # other caller of the same shape).
            put(f"  cannot update automatically: {actions['engine_blocked_reason'].describe()}")
        row += 1

    if actions["target_stale"]:
        put(f"this repo: {target_status.message}")
        if actions["target_blocked_reason"]:
            put(f"  cannot fast-forward automatically: {actions['target_blocked_reason'].describe()}")
        row += 1

    # Enter/continue must ALWAYS be fully legible on its own bottom row
    # -- override is never allowed to be a hard stop (#18). The optional
    # [u]/[t] actions go on the row(s) above, wrapped through _hard_wrap
    # rather than sharing (and risking truncating) continue's line.
    always = "[Enter] continue on this copy"
    optional = []
    if actions["engine_offerable"]:
        optional.append("[u] update engine & restart")
    if actions["target_offerable"]:
        optional.append("[t] fast-forward this repo")
    menu_lines = _hard_wrap("   ".join(optional), max(1, width)) if optional else []
    menu_lines.append(always)
    menu_top = max(0, height - len(menu_lines))
    for i, line in enumerate(menu_lines):
        safe_addstr(stdscr, menu_top + i, 0, line)
    stdscr.refresh()
    return actions


def run_startup_prompt(stdscr, engine_status, target_status):
    """Interactive loop for the startup screen. Nothing here is stale ->
    no prompt at all, straight through (a clean bill of health is never
    a hard stop). Otherwise: [u]/[t] act (only when offerable -- a
    blocked action isn't a selectable key), Enter/Esc always continues on
    the copy as-is, because override must always be available (#18)."""
    actions = render_startup_prompt(stdscr, engine_status, target_status)
    if not actions["needs_prompt"]:
        return None
    while True:
        key = stdscr.getch()
        if key in (curses.KEY_ENTER, 10, 13, 27):
            return None
        if key == ord("u") and actions["engine_offerable"]:
            return "update_engine"
        if key == ord("t") and actions["target_offerable"]:
            return "update_target"


def _build_level_for_stdscr(stdscr, items):
    """Same width budget the top-level launch has always used
    (max_width bounded by the terminal, never by title length -- issue
    #1), factored out so zooming into a map tile (#39) builds its
    single-repo view identically instead of a second, slightly
    different copy of this math."""
    term_h, term_w = stdscr.getmaxyx()
    max_width = max(20, min(76, term_w - 4))
    return build_level(items, max_width=max_width)


def run(stdscr, items, live=False, startup_note=None):
    """The one event loop (issue #39). `items` is the current repo's
    open items for the ordinary no-arg case; it is None when there is
    no current repo to show at all -- launched outside a git repo, in a
    repo with no GitHub remote, or via the `vim-arcade --map` path
    `joue-panes` now aliases to (main() resolves all three the same
    way: no items, start at the map). Either way the map and the
    single-repo view share this exact loop -- zooming into a tile just
    rebuilds `level`/`row_items`/`session`/`view_repo` for that repo and
    falls into the same mode == "walk"/"detail"/... branches every
    other repo view already uses; there is nothing here that dispatches
    an action key a second way.
    """
    curses.curs_set(0)
    stdscr.nodelay(False)
    has_color = init_color(stdscr)

    # view_repo is "whichever repo the single-repo view below is
    # currently showing" -- dispatch.current_repo() for the ordinary
    # no-arg case, or a tile's repo once a zoom-in has happened. Used
    # for create_issue/refresh, which have no single `item` to read a
    # repo off of; every other action reads item.repo directly instead
    # (a TriageItem always carries its own repo -- see gh_triage.py).
    view_repo = dispatch.current_repo() if items is not None else None

    if items is not None:
        level, row_items = _build_level_for_stdscr(stdscr, items)
        session = Session(level_index=0, levels=[level])
        mode = "walk"  # "walk" | "detail" | "comment" | "new_title" | "new_body" | "map"
    else:
        level, row_items, session = None, {}, None
        mode = "map"

    map_state = gh_map.MapState()
    map_built = False

    def _ensure_map_built():
        nonlocal map_built
        if not map_built:
            map_state.by_repo = discover_items()
            gh_map.focus_on_repo(map_state, view_repo)
            map_built = True

    if mode == "map":
        _ensure_map_built()

    active_row = None
    was_adjacent_row = None
    comment_buffer = ""
    new_title = ""
    new_body = ""
    body_scroll = 0
    message = startup_note or ""
    log = []
    # Issue #31: a title/diff mismatch WARNS rather than refuses, but
    # must never merge silently on the first press that surfaces it --
    # the human has to see the warning and press [m] again. Tracks
    # (repo, item number) pairs whose warning has already been shown
    # once this session (keyed on repo too, not just number, since #39
    # lets one session touch more than one repo's items -- see
    # handle_merge_key's docstring); any refusal code clears an item
    # back out (a fresh refusal always needs a fresh look, never a
    # stale confirmation carried past it).
    mismatch_seen = set()
    # Issue #46: set by a live merge that leaves this checkout behind
    # (post_merge_sync_offer); makes the 'f' key live for exactly one
    # fast-forward, never automatic -- see the 'm' handler in "detail"
    # mode below and the 'f' handlers in "detail"/"walk".
    pending_ff = False
    mode_note = (
        "LIVE -- actions really comment/close/merge/create for real."
        if live
        else "DRY RUN -- actions only log the gh command (pass --live to really act)."
    )
    hint = "Walk up to a block (h/j/k/l/w/b) to open it. n = new issue, r = refresh."

    # Quit-time self-dev handoff (2026-08-04): what this session actually
    # did (live, succeeded), and which repo it did it in -- see
    # dispatch.py. Only ever grows via _run_action's `activity=` recording
    # of a real success; DRY RUN and FAILED: actions never touch it.
    activity = dispatch.SessionActivity()
    quit_reason = None

    while True:
        if mode == "map":
            layout = render_map(stdscr, map_state, message, has_color)
        else:
            render(
                stdscr, level, row_items, session, mode, active_row, comment_buffer,
                new_title, new_body, message, log, mode_note, hint, body_scroll,
            )

        key = stdscr.getch()

        if mode == "map":
            # No item actions at this zoom level (#39: "you cannot
            # safely press x on something you cannot read") -- only
            # navigation, paging, refresh, zoom-in, and quit.
            if key == ord("Q"):
                quit_reason = "Q"
                break
            ch = _key_to_char(key)
            if ch in ("h", "j", "k", "l"):
                gh_map.move_focus(map_state, ch, layout)
            elif key in (curses.KEY_ENTER, 10, 13):
                tile = gh_map.focused_tile(map_state)
                if tile is not None:
                    tile_items = map_state.by_repo.get(tile.repo, [])
                    level, row_items = _build_level_for_stdscr(stdscr, tile_items)
                    session = Session(level_index=0, levels=[level])
                    view_repo = tile.repo
                    active_row = None
                    was_adjacent_row = None
                    body_scroll = 0
                    message = ""
                    mode = "walk"
            elif ch == "n":
                gh_map.next_page(map_state, layout)
            elif ch == "p":
                gh_map.prev_page(map_state, layout)
            elif ch == "r":
                focused_repo = gh_map.focused_tile(map_state)
                focused_repo = focused_repo.repo if focused_repo else None
                map_state.by_repo = discover_items()
                gh_map.focus_on_repo(map_state, focused_repo)
                message = "refreshed."
            continue

        if mode == "comment":
            _set_bracketed_paste(True)  # idempotent -- see its docstring
            if key in (curses.KEY_BACKSPACE, 127, 8):
                comment_buffer = comment_buffer[:-1]
            elif key == _SUBMIT_KEY:  # Ctrl-D submits
                item = row_items[active_row]
                _run_action(
                    comment_command(item, comment_buffer), live, log,
                    f"commented on {item.kind} #{item.number}",
                    activity=activity, action="comment", kind=item.kind, number=item.number,
                    title=item.title, repo=item.repo, detail=comment_buffer,
                )
                comment_buffer = ""
                _set_bracketed_paste(False)
                mode = "detail"
            elif key in (curses.KEY_ENTER, 10, 13):  # Enter inserts a newline
                comment_buffer += "\n"
            elif key == 27:  # Esc, unless it's a bracketed paste (issue #22)
                pasted = _try_consume_paste(stdscr)
                if pasted is not None:
                    comment_buffer += pasted
                else:
                    comment_buffer = ""
                    _set_bracketed_paste(False)
                    mode = "detail"
            else:
                char = _key_to_char(key)
                if char and char.isprintable():
                    comment_buffer += char
            continue

        if mode == "new_title":
            _set_bracketed_paste(True)
            if key in (curses.KEY_BACKSPACE, 127, 8):
                new_title = new_title[:-1]
            elif key == _SUBMIT_KEY:  # Ctrl-D continues to the body step
                if new_title.strip():
                    _set_bracketed_paste(False)
                    mode = "new_body"
            elif key in (curses.KEY_ENTER, 10, 13):  # Enter inserts a newline
                new_title += "\n"
            elif key == 27:  # Esc, unless it's a bracketed paste (issue #22)
                pasted = _try_consume_paste(stdscr)
                if pasted is not None:
                    new_title += pasted
                else:
                    new_title = ""
                    _set_bracketed_paste(False)
                    mode = "walk"
            else:
                char = _key_to_char(key)
                if char and char.isprintable():
                    new_title += char
            continue

        if mode == "new_body":
            _set_bracketed_paste(True)
            if key in (curses.KEY_BACKSPACE, 127, 8):
                new_body = new_body[:-1]
            elif key == _SUBMIT_KEY:  # Ctrl-D creates the issue
                _run_action(
                    create_issue_command(new_title, new_body, repo=view_repo), live, log,
                    f"created issue {new_title!r}",
                    activity=activity, action="create_issue", kind="issue", number=None,
                    title=new_title, repo=view_repo, detail=new_body,
                )
                if live:
                    # Real issue now exists on GitHub -- pull it onto the
                    # map without restarting. In DRY RUN nothing was
                    # actually created, so a refresh here would just be a
                    # no-op fetch; skip it rather than imply a fake row.
                    # repo=view_repo (#39): without this, refreshing while
                    # zoomed into a tile would silently refetch the LAUNCH
                    # repo instead of the one actually being viewed.
                    level, row_items = refresh(repo=view_repo)
                    marker_col = marker_col_for(level)
                    session = Session(level_index=0, levels=[level])
                    active_row = None
                    was_adjacent_row = None
                new_title = ""
                new_body = ""
                _set_bracketed_paste(False)
                mode = "walk"
            elif key in (curses.KEY_ENTER, 10, 13):  # Enter inserts a newline
                new_body += "\n"
            elif key == 27:  # Esc, unless it's a bracketed paste (issue #22)
                pasted = _try_consume_paste(stdscr)
                if pasted is not None:
                    new_body += pasted
                else:
                    new_title = ""
                    new_body = ""
                    _set_bracketed_paste(False)
                    mode = "walk"
            else:
                char = _key_to_char(key)
                if char and char.isprintable():
                    new_body += char
            continue

        if mode == "detail":
            item = row_items[active_row]
            if key == ord("Q"):
                quit_reason = "Q"
                break
            if key == ord("M"):
                _ensure_map_built()
                mode = "map"
            elif key == 27:
                mode = "walk"
            elif key in (ord("j"), ord("k")):
                # Detail mode doesn't walk, so j/k are free to do the
                # vim-consistent thing and scroll the body. Clamped
                # against the same wrap the panel renders, so the
                # indicator and the window can't disagree.
                _, term_w = stdscr.getmaxyx()
                budget = max(0, compute_layout(*stdscr.getmaxyx(), "detail")["panel_h"] - 2)
                total = len(body_lines(item, term_w))
                body_scroll = _clamp_scroll(
                    body_scroll + (1 if key == ord("j") else -1), total, budget
                )
            elif key == ord("c"):
                fetch_detail(item)
                comment_buffer = ""
                mode = "comment"
            elif key == ord("x"):
                _run_action(
                    close_command(item), live, log, f"closed {item.kind} #{item.number}",
                    activity=activity, action="close", kind=item.kind, number=item.number,
                    title=item.title, repo=item.repo,
                )
                mode = "walk"
            elif key == ord("m") and item.kind == "pr":
                # Issue #31: decide LOCALLY before ever building a `gh pr
                # merge` command -- see handle_merge_key's docstring.
                # A refusal is never a mutation attempt. This is the
                # SAME handle_merge_key whether `item` came from the
                # no-arg current-repo view or a repo reached via the map
                # (#39) -- there is no second copy of this decision.
                pre_merge_log_len = len(log)
                mode = handle_merge_key(
                    item, live, log, activity, item.repo, mismatch_seen, os.getcwd(),
                )
                # Issue #46: "if I just merged a PR, I would always want
                # that as my check out." A live merge just appended
                # exactly one "LIVE merged pr #N -- ok..." line (a
                # refusal or a warning never does) -- that's the signal
                # to check whether THIS checkout fell behind and offer
                # the one-keypress fast-forward, never automatic.
                if live and any(
                    entry.startswith(f"LIVE merged pr #{item.number} -- ok")
                    for entry in log[pre_merge_log_len:]
                ):
                    note, pending_ff = post_merge_sync_offer(os.getcwd())
                    if note:
                        log.append(note)
            elif key == ord("R") and item.kind == "pr":
                # Issue #23: draft -> ready is its own explicit key,
                # never chained after `m`. Undrafting is visible to
                # other people, so it only ever happens on a keypress
                # that means exactly that and nothing else.
                _run_action(
                    ready_command(item), live, log, f"marked pr #{item.number} ready",
                    activity=activity, action="ready", kind=item.kind, number=item.number,
                    title=item.title, repo=item.repo,
                )
                mode = "walk"
            elif key == ord("f") and pending_ff:
                # Issue #46: the one-keypress offer from the merge above
                # (or never automatic -- only live when the offer fired).
                message = _fast_forward_checkout()
                pending_ff = False
            continue

        # mode == "walk"
        if key == ord("Q"):
            quit_reason = "Q"
            break
        if key == ord("f") and pending_ff:
            message = _fast_forward_checkout()
            pending_ff = False
            continue
        if key == ord("M"):
            # Zoom out to the map (#39) -- the one discoverable way
            # back, always shown in the footer. Never rebuilds
            # map_state if it already exists, so returning here lands
            # on exactly the same page/focus the player left.
            _ensure_map_built()
            mode = "map"
            continue
        if key == ord("n"):
            new_title = ""
            mode = "new_title"
            continue
        if key == ord("r"):
            level, row_items = refresh(repo=view_repo)
            marker_col = marker_col_for(level)
            session = Session(level_index=0, levels=[level])
            active_row = None
            was_adjacent_row = None
            message = "refreshed."
            continue
        char = _key_to_char(key)
        if not char:
            continue

        event = session.feed_key(char)
        message = f"'{char}' isn't unlocked yet." if event == "locked" else ""

        prow2, pcol2 = session.player_pos
        row_marker_col = marker_col_for(level, prow2)
        adjacent_row = prow2 if (prow2 in row_items and abs(pcol2 - row_marker_col) == 1) else None
        if adjacent_row is not None and adjacent_row != was_adjacent_row:
            active_row = adjacent_row
            fetch_detail(row_items[active_row])
            body_scroll = 0  # each item opens at the top of its own body
            mode = "detail"
        was_adjacent_row = adjacent_row

        if event == "game_complete":
            stdscr.erase()
            safe_addstr(stdscr, 0, 0, "Done browsing. Press any key to exit.")
            stdscr.refresh()
            stdscr.getch()
            break

    if quit_reason == "Q":
        return _quit_dispatch_flow(stdscr, activity)
    return None


# ---------------------------------------------------------------------------
# Quit-time self-dev handoff (2026-08-04). "Q" ends the event loop above;
# everything from here down runs after it, still inside curses (the
# terminal doesn't get torn down until curses.wrapper() returns from
# run() back to main()) -- see main() for why the actual report print has
# to happen out there instead of in here.
# ---------------------------------------------------------------------------


def render_dispatch_summary(stdscr, plans, message="", *, sync_offerable=False, sync_note=""):
    """Draw the quit-time confirm/summary screen: exactly what would be
    handed to the self-dev loop, windowed to fit whatever terminal size
    is actually available (requirement: must render at 80x24 and a much
    smaller 40x15 without crashing) -- same safe_addstr discipline as
    the rest of this module, never a raw stdscr.addstr call.

    Issue #46 extends this SAME screen (rather than adding a second
    prompt) with the checkout-sync offer: `sync_offerable` makes '[f]'
    live in the prompt line, `sync_note` (e.g. the staleness message, or
    the result of having just pressed 'f') is shown above it."""
    stdscr.erase()
    height, width = stdscr.getmaxyx()
    lines = dispatch.dispatch_summary_lines(plans)
    if sync_note:
        lines = lines + [sync_note]

    prompt_row = max(0, height - 1)
    body_h = prompt_row  # rows [0, prompt_row) are free for the summary
    shown = lines[:body_h]
    if len(lines) > body_h and body_h > 0:
        shown = lines[: max(0, body_h - 1)] + [f"... +{len(lines) - (body_h - 1)} more"]
    for i, line in enumerate(shown):
        safe_addstr(stdscr, i, 0, line)

    can_dispatch = any(p.project is not None for p in plans)
    parts = []
    if can_dispatch:
        parts.append("[y] dispatch")
    if sync_offerable:
        parts.append("[f] fast-forward checkout")
    if parts:
        parts.append("[n/Esc/Q] quit")
        prompt = "   ".join(parts)
    else:
        prompt = "nothing dispatchable -- press any key to quit"
    if message:
        prompt = f"{message}  {prompt}"
    safe_addstr(stdscr, prompt_row, 0, prompt)
    stdscr.refresh()


def _quit_dispatch_flow(
    stdscr, activity, repo_dir=None,
    *, check_target_staleness=staleness.check_target_staleness, update_target=staleness.update_target,
):
    """After `Q`: show what this session's real (live, succeeded)
    activity would hand off to the self-dev loop AND (issue #46, same
    screen, not a second prompt) whether this checkout is behind trunk
    and could be fast-forwarded -- let the player confirm/act or decline
    (declining still quits -- `Q` must never trap the player), and
    return a dispatch.QuitOutcome for main() to print after curses tears
    down. Never dispatches a phantom: build_dispatch_plan only ever sees
    `activity`, which _run_action only ever populated from a LIVE
    success; the fast-forward, likewise, only ever runs on an explicit
    'f' press, never automatically."""
    repo_dir = repo_dir if repo_dir is not None else os.getcwd()
    plans = dispatch.build_dispatch_plan(activity)

    target_status = check_target_staleness(repo_dir)
    sync_offerable = False
    sync_note = ""
    if target_status.state in (staleness.STATE_BEHIND, staleness.STATE_DIVERGED):
        refusal = staleness.target_update_blocked_reason(target_status)
        if refusal is not None:
            sync_note = f"checkout: {target_status.message} -- {refusal.describe()}"
        else:
            sync_note = f"checkout: {target_status.message} -- press [f] to fast-forward before quitting"
            sync_offerable = True

    if not plans and not sync_offerable:
        # Nothing ACTIONABLE -- no dispatch to confirm, and even if the
        # checkout is behind/diverged there's no live 'f' to press
        # (blocked, or simply up to date). Issue #10's "declining still
        # quits" cuts both ways: a screen that only ever needs a SECOND
        # keypress to leave is itself a trap, even if that keypress
        # always works. Quit in the one press Q already was, and still
        # say why via the printed report (QuitOutcome.sync_note),
        # not an interactive screen nobody asked to see.
        return dispatch.QuitOutcome(plans=[], results=[], decision="none", sync_note=sync_note)

    message = ""
    while True:
        render_dispatch_summary(stdscr, plans, message, sync_offerable=sync_offerable, sync_note=sync_note)
        key = stdscr.getch()
        if key == ord("f") and sync_offerable:
            result = update_target(repo_dir, target_status)
            sync_note = f"checkout: {result}"
            sync_offerable = False  # one-shot -- acted on, not re-offered
            continue
        if key in (ord("n"), ord("N"), ord("Q"), 27):
            return dispatch.QuitOutcome(plans=plans, results=[], decision="declined", sync_note=sync_note)
        if key in (ord("y"), ord("Y")):
            if not any(p.project is not None for p in plans):
                message = "nothing dispatchable."
                continue
            try:
                results = dispatch.run_dispatch(plans)
            except dispatch.SchedulerNotFound as exc:
                # Belt-and-suspenders: run_dispatch already catches this
                # per-plan and turns it into a failed DispatchResult, but
                # never let a surprise here trap the quit.
                return dispatch.QuitOutcome(
                    plans=plans,
                    results=[dispatch.DispatchResult(action=p, ok=False, message=str(exc)) for p in plans if p.project],
                    decision="confirmed",
                    sync_note=sync_note,
                )
            return dispatch.QuitOutcome(plans=plans, results=results, decision="confirmed", sync_note=sync_note)
        # any other key: ignore and redraw -- Q/n/Esc above are the exits.


def _launch(stdscr, items, live):
    """Setup portion that runs once, before the event loop: check
    staleness of both the engine and the target repo (issue #18), show
    the prompt only if either is actually stale, then hand off to run().
    Update actions only return here on refusal/no-op -- a successful
    engine update re-execs (staleness.update_engine) and never comes
    back to this function at all.

    Runs unconditionally even when `items` is None (map-first launch,
    #39): check_target_staleness degrades to STATE_UNKNOWN (no prompt)
    when os.getcwd() isn't a git repo at all, same "probe failure
    degrades, never blocks" discipline every staleness check already
    has -- there is nothing map-specific to special-case here."""
    edir = engine_dir()
    engine_status = staleness.check_engine_staleness(edir)
    target_status = staleness.check_target_staleness(os.getcwd())

    action = run_startup_prompt(stdscr, engine_status, target_status)

    startup_note = None
    if action == "update_engine":
        startup_note = staleness.update_engine(edir, engine_status)
    elif action == "update_target":
        startup_note = staleness.update_target(os.getcwd(), target_status)

    # Returned, not just called: run()'s value is the quit-time dispatch
    # outcome that main() prints after curses tears down (#24).
    return run(stdscr, items, live=live, startup_note=startup_note)


def main():
    argv = sys.argv[1:]
    live = "--live" in argv
    # --map (#39): joue-panes now aliases to `vim-arcade --map`, forcing the
    # session to start at the tile map regardless of whether the cwd
    # even has a repo. Skips the single-repo fetch entirely, same as
    # the "no repo detected" path below -- both just mean "start with
    # items=None", so run() only has one way to decide "show the map
    # first" no matter which of the two got it there.
    force_map = "--map" in argv
    repo_slug = None if force_map else get_repo_slug()

    items = None
    if repo_slug is not None:
        try:
            items = fetch_open_items()
        except subprocess.CalledProcessError as exc:
            print(f"gh-triage: failed to fetch issues/PRs: {exc.stderr}", file=sys.stderr)
            sys.exit(1)
    # Both features wrap the session: _launch owns the startup staleness
    # check (#18/#25) and run() owns the event loop, whose return value is
    # the quit-time dispatch outcome (#24). _launch therefore has to pass
    # that outcome back through -- otherwise the staleness prompt silently
    # swallows the dispatch report and Q looks like it does nothing.
    outcome = curses.wrapper(_launch, items, live)
    # Dispatch must be visible after exit (requirement 4): printed here,
    # not inside run()/curses -- anything written to the terminal while
    # curses still owns it is gone on the next erase/refresh, which is
    # exactly what makes an in-curses-only report indistinguishable from
    # a feature that silently does nothing.
    report = dispatch.format_quit_report(outcome)
    if report:
        print(report, end="")


if __name__ == "__main__":
    main()
