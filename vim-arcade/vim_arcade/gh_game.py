"""curses front-end that plays this repo's live GitHub issue/PR queue as
a vim-arcade level. Each open item is a single-tile block on an
otherwise open row -- ordinary vim motions (h/j/k/l/w/b/0/$/gg/G) walk
right up to it, no clearing required. Landing adjacent to a block opens
a detail panel with its real title/body and a small action menu:

    c = comment    x = close    m = merge (PRs only)
    R = ready (draft PRs only, issue #23)    Esc = back

From anywhere while walking, "n" opens a two-step prompt (title, then
body) and creates a brand new issue in this repo.

## Every key, in one place (issue #10's "vim keys for motion, GitHub-web
letters for actions" acceptance box: documented once, not scattered
across this module's comments -- two copies of the same mapping is
exactly the drift issue #10 itself warns about, see the `joue-panes`
history above)

    MOTION (vim):    h j k l   w/b   0/$   gg/G   (walk mode, in either
                      the single-repo view or the repo-map's tiles)
    DETAIL (web-letter actions, opened by walking onto a block):
        c = comment    x = close    m = merge (PRs only, see below)
        R = ready (draft PRs only, issue #23)    Esc = back to walk
    WALK-WIDE:
        n = new issue, two-step title/body prompt, from anywhere
        A = merge every PR row in this view in one press (issue #49/
            #65/#66 -- reuses `m`'s own per-PR safety check for each,
            never a second merge path; a row that would only WARN on a
            first `m` is skipped and listed, never bulk-overridden)
        V = start a visual LINE selection of rows, then j/k/gg/G/counts
            extend it; ":" opens a read-only preview enumerating every
            selected item (issue #49 slice 1 -- the AoE spell's
            selection mechanics: this never calls
            close_command/comment_command/merge_command/ready_command,
            and never reaches grid.clear_wall either -- see
            gh_triage.selected_items and PANEL_MODES' "preview" entry).
            From the preview panel, "y" hands the whole work order to
            the self-dev loop via dispatch.build_selection_plan/#24's
            `scheduler -i` path (issue #49 slice 2) -- DRY RUN only logs
            what would run, LIVE actually dispatches. This is a
            preview-mode-only meaning of "y", unrelated to the grid
            operator of the same letter below: it never reaches
            session.feed_key, so it cannot unlock or bypass the locked
            `y` operator. "s" (issue #49 slice 3) closes every selected
            PR whose content is demonstrably already on trunk --
            merge_safety's CODE_SUPERSEDED, the same per-PR overlap
            check `m` already runs, reused via superseded_selection/
            handle_close_key rather than a second "is this done" check.
            Deliberately NOT #41's subsumption (contained in a still-
            open sibling) -- that PR's content isn't on trunk yet, only
            redundant, so closing it here would be evidence-free. Every
            item skipped (not a PR, not superseded) is logged with its
            own reason -- partial success is the normal case, never a
            silent "done". Esc, from either walk or the preview panel,
            cancels the selection. `d`/`y`/`v`/Ctrl-v (as GRID
            operators) stay locked in this level.
        M = zoom to/from the repo map (issue #39)
        e = edit this repo's config (issue #88) -- ~/.config/vim-arcade/
            repos/<owner>__<name>.ini, created from a template on first
            use. In map mode, edits the focused tile's repo; with no
            tile focused there's nothing to edit and it says so.
        E = edit the global config (issue #88) -- ~/.config/vim-arcade/
            config.ini, same create-on-first-use behavior. Available
            from map mode and walk mode alike.
    QUIT (mirrors vim's `:q` / `:q!` exactly, issue #10's core feature):
        Q = quit; refused with a specific reason if real work in this
            checkout is unlanded (exit_gate.py, same source of truth as
            closeout-lint)
        Q again, at the refusal screen = force through anyway (`Q!`) --
            never traps the player, but files a real issue naming what
            was abandoned before it exits
        w, at the refusal screen, only when a [worktrees] flag is
            showing = examine linked worktrees right here; r on that
            screen removes every one classified clean-and-landed
        f, when offered after a LIVE merge (issue #46) = sync this
            checkout to what was just merged

`m` never mutates anything sight-unseen (issue #31): it re-checks
mergeability fresh (merge_safety.py) before ever building a `gh pr
merge` command, and refuses locally -- naming the specific reason and
the next action -- on a conflict, a draft, a blocked/failing-checks
gate, a PR already CONTAINED IN another still-open PR's head (issue
#41 -- checked first, ahead of everything else below: this is the case
that actually broke `main`, PRs #35/#36 both showed MERGEABLE/CLEAN
while #37 already carried both of their commits), or a PR whose content
is already superseded on its base (the case that motivated the original
guard: detected by content overlap, not just GitHub's own conflict flag,
because a superseded PR that still applies *cleanly* would otherwise
merge silently). A title/diff mismatch warns with the file count
instead of refusing outright, and needs a second `m` press to actually
proceed.

Each action shells out to the real `gh` CLI. Default is LIVE (issue
#50, shipped 2026-08-08): actions actually run. Pass --dry-run to log
the command instead of running it. `--live` is still accepted, as a
no-op, so old invocations and docs keep working.

Layout is a real budget (see compute_layout), not a stack of fixed
absolute offsets -- the old code wrote as far down as `base + 22` with no
regard for how tall the terminal actually was, which is what made issue
#8 crash on a normal 80x24 terminal. Every write goes through
safe_addstr/safe_addch, which clip to the real terminal size instead of
raising.

One launcher, two zoom levels (issue #39). No-arg `joue` opens THIS
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
`joue-panes` script is a thin alias for `joue --map`, which just starts
this same run() loop already zoomed out. There is exactly one place any
action key (`m`/`x`/`c`/`n`/`R`/`Q`, motion) is dispatched, in the
`while True` loop inside run() below -- the map mode reached from that
same loop routes to it too, by construction, since zooming into a tile
does not spawn a second loop, it just rebuilds `level`/`row_items`/
`session` for a different repo and falls through to the same `mode ==
"walk"`/`"detail"`/... branches everything else already uses.

If `joue` is launched outside a git repo, or inside one with no GitHub
remote (get_repo_slug() -> None), it opens the map directly rather than
failing -- there is nothing to build a single-repo view out of.
"""

import curses
import os
import subprocess
import sys
import threading
from datetime import date, timedelta

from . import backlog, config, dispatch, exit_gate, gh_map, glossary, issue_types, merge_safety, staleness
from .discovery import discover_items
from .gh_triage import (
    build_level, fetch_detail, fetch_open_items, fetch_open_numbers, get_repo_slug,
    item_age_days, marker_col_for, number_overlay_cols, numbers_from_items, queue_delta,
    refresh, selected_items,
)
from .session import Session


class QueueWatcher:
    """Issue #26: notice work that lands in the open queue while the
    player is looking at a single-repo view, without ever redrawing the
    map underneath them -- Zach's own bar ("'queue changed' feels safe").

    Polls in a daemon background thread on a plain interval; the render
    loop in run() only ever *reads* peek_message(), never blocks on this
    thread, and nothing here ever touches level/row_items/session -- `r`
    (refresh) remains the only thing that rebuilds those, exactly as
    before this issue. A poll that raises (gh missing, network down, a
    timeout, bad json) is caught and simply produces no message -- the
    issue's own "degrade silently" requirement -- so a flaky network
    reads as "nothing new" rather than an error on screen.

    The baseline is "whatever is currently on screen", frozen at
    start()/reset_baseline() time: every poll after that compares against
    that same frozen snapshot, so the count keeps growing (or shrinking)
    to reflect total drift since the player last looked, not since the
    last poll. reset_baseline() is what `r` calls to say "the screen
    matches reality again"."""

    def __init__(self, repo, poll_interval=45, fetch=fetch_open_numbers):
        self.repo = repo
        self.poll_interval = poll_interval
        self._fetch = fetch
        self._lock = threading.Lock()
        self._baseline = None
        self._message = None
        self._stop = threading.Event()
        self._thread = None

    def start(self, baseline):
        self._baseline = baseline
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()

    def reset_baseline(self, baseline):
        with self._lock:
            self._baseline = baseline
            self._message = None

    def peek_message(self):
        with self._lock:
            return self._message

    def _loop(self):
        while not self._stop.wait(self.poll_interval):
            self.poll_once()

    def poll_once(self):
        """One poll, run synchronously -- the background thread's own
        body, but also called directly by tests so they never have to
        wait out a real poll_interval."""
        try:
            current = self._fetch(repo=self.repo)
        except Exception:
            return
        with self._lock:
            if self._baseline is None:
                return
            note = queue_delta(self._baseline, current)
            if note:
                self._message = note


PLAYER_CHAR = "@"
GOAL_CHAR = "$"

# Modes whose input widget needs a panel below the grid.
PANEL_MODES = ("detail", "comment", "new_title", "new_body", "preview", "diagnostics")

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


def close_command(item, comment=None):
    kind = "issue" if item.kind == "issue" else "pr"
    cmd = ["gh", kind, "close", str(item.number)]
    if comment:  # issue #49 slice 3: bulk close-with-evidence leaves the
        # evidence ON the item, not just in this session's own log --
        # `gh ... close --comment` posts it as part of the same call.
        cmd += ["--comment", comment]
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
    next_action for a draft, which names this command.

    Issue #83: this was the one action builder issue #32/#17 missed --
    every sibling here (close/merge/comment/create) carries --repo, but
    `ready` still let `gh` infer the target from the process cwd, which
    is exactly the "not a git repository" failure #83 reproduced on
    PR #102 while `m` (merge) succeeded on #97 in the same session."""
    cmd = ["gh", "pr", "ready", str(item.number)]
    if item.repo:
        cmd += ["--repo", item.repo]
    return cmd


def rebase_recipe(head_ref, base_ref):
    """The exact commands that resolve a CONFLICTING PR, not just an
    instruction to go do it -- issue #72: 'I need to be told exactly how
    to rebase or whatever else the problem is.' Text only: this game
    never runs any of these itself, same as merge_safety.py's own rule
    ('never auto-fix, never rebase, never edit anything') -- #72 also
    asks for a buffer that types real git/gh commands from inside the
    game, which is a separate, undecided design question (see the
    issue) that this does not attempt. Falls back to a placeholder ref
    name rather than omitting the recipe when the snapshot is missing
    one."""
    head = head_ref or "<branch>"
    base = base_ref or "<base>"
    return [
        f"  git fetch origin {base} {head}",
        f"  git checkout {head} && git rebase origin/{base}",
        "  # resolve conflicts, then per file: git add <file>",
        "  git rebase --continue   (repeat until 'no rebase in progress')",
        "  git push --force-with-lease",
    ]


_DIAG_TIMEOUT = 6  # seconds -- same rationale as merge_safety.DEFAULT_TIMEOUT:
# a hung network call must not read as "the game froze".


def _diag_run(cmd, cwd, timeout=_DIAG_TIMEOUT):
    """One git call for git_diagnostics -- returns (ok, stdout, message)
    rather than raising, since a probe failure here is a display line,
    never a crash (same degrade-not-crash discipline as
    merge_safety._run's callers)."""
    try:
        result = subprocess.run(
            cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return False, "", f"timed out after {timeout}s"
    except (FileNotFoundError, OSError) as exc:
        return False, "", str(exc)
    if result.returncode != 0:
        return False, result.stdout, result.stderr.strip()[:200]
    return True, result.stdout, ""


def git_diagnostics(head_ref, base_ref, cwd, timeout=_DIAG_TIMEOUT):
    """Issue #72's next slice past rebase_recipe's static text: actually
    RUN real, read-only git commands against the current checkout and
    show real output -- 'I need to be told exactly how to rebase' becomes
    'and I can see the actual state without leaving the game', without
    attempting the mutating half of #72/#81/#84's ask (a typed command
    buffer, in-game rebase, in-game conflict resolution). That mutating
    half stays deliberately unbuilt: it would mean running `git checkout`
    against whatever real dev clone `joue` happens to be running inside,
    which can carry someone's own uncommitted work, and #72's own comment
    already flagged that this needs a design decision this function does
    not make.

    Every command here is read-only with respect to the working tree --
    `git fetch` only moves remote-tracking refs, never touches HEAD or
    the index, so this is safe to run no matter what else is checked out
    or in progress in this clone. Never raises; a failed probe becomes an
    'ERROR:' display line, same as merge_safety's own probes."""
    if not head_ref or not base_ref:
        return ["git diagnostics unavailable -- missing head/base ref"]

    lines = [f"$ git fetch origin {base_ref} {head_ref}"]
    ok, _, msg = _diag_run(["git", "fetch", "origin", base_ref, head_ref], cwd, timeout)
    if not ok:
        lines.append(f"  ERROR: {msg}")
        return lines
    lines.append("  ok")

    ok, out, msg = _diag_run(
        ["git", "rev-list", "--left-right", "--count", f"origin/{base_ref}...origin/{head_ref}"],
        cwd, timeout,
    )
    if ok:
        parts = out.split()
        if len(parts) == 2:
            behind, ahead = parts
            lines.append(f"{head_ref} is {ahead} ahead, {behind} behind origin/{base_ref}")
    else:
        lines.append(f"  ERROR checking ahead/behind: {msg}")

    lines.append("$ git status --short (this checkout)")
    ok, out, msg = _diag_run(["git", "status", "--short"], cwd, timeout)
    if ok:
        dirty = out.strip()
        if dirty:
            lines.append("  WARNING: local changes here -- resolving in this checkout would touch them:")
            dirty_lines = dirty.splitlines()
            lines.extend(f"  {l}" for l in dirty_lines[:10])
            if len(dirty_lines) > 10:
                lines.append(f"  ... and {len(dirty_lines) - 10} more")
        else:
            lines.append("  clean")
    else:
        lines.append(f"  ERROR: {msg}")

    return lines


def age_summary_line(item, now=None):
    """One-line 'opened Nd ago' for the detail panel -- issue #38's own
    discoverability constraint: the grid's column position now encodes
    age, so a player who walks a certain distance to reach an item must
    be able to see, in the same panel, the exact number that distance
    stands for -- not just a description in the glossary. Empty list
    (not a placeholder line) when created_at is missing, same
    "omit rather than guess" convention item_age_days already uses."""
    age = item_age_days(item, now)
    if age is None:
        return []
    days = int(age)
    return [f"opened {days}d ago" if days else "opened today"]


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
    if item.contained_in_number is not None:
        # Issue #41's own prescribed wording, and its most dangerous
        # case -- shown first, ahead of GitHub's own mergeable/draft/
        # review snapshot below, the same priority order `m`'s real
        # refusal already gives subsumption over everything else.
        lines.append(
            f"contained in #{item.contained_in_number} "
            f"'{item.contained_in_title}' -- merge that instead, then close this"
        )
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
    if item.mergeable == "CONFLICTING" or item.merge_state_status == "DIRTY":
        lines.append("resolve by rebasing:")
        lines.extend(rebase_recipe(item.head_ref_name, item.base_ref_name))
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
    #46/#73's post-merge auto-sync uses this to know whether a real merge
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


def handle_close_key(item, live, log, activity, *, comment=None):
    """The one call site for close_command -- both the single-item `x`
    (detail mode) and issue #49 slice 3's bulk close-with-evidence (the
    preview panel's `s`) go through here, mirroring why handle_merge_key
    is the one call site for merge_command rather than each caller
    building its own close/merge command. `comment`, when given, is
    posted as part of the same `gh ... close` call (see close_command)
    so the evidence lands on the item itself, not only this session's
    log. Returns True only for a LIVE close that actually succeeded,
    same contract as _run_action itself."""
    verb = f"closed {item.kind} #{item.number}"
    if comment:
        verb += " (superseded)"
    return _run_action(
        close_command(item, comment=comment), live, log, verb,
        activity=activity, action="close", kind=item.kind, number=item.number,
        title=item.title, repo=item.repo, detail=comment or "",
    )


def handle_type_key(item, live, log, activity):
    """The one call site for issue_types.type_label_command -- the [t]
    key in detail mode, mirroring why handle_close_key is the one call
    site for close_command. Cycles item's type label (unset ->
    decayable -> durable -> unset, per issue_types.next_type) and, on a
    LIVE call that actually succeeds OR any DRY RUN (nothing to fail),
    updates `item.labels` in place so the header/menu reflect the new
    state immediately and a repeat press continues the cycle -- a LIVE
    call that fails leaves `item.labels` untouched, same "never claim a
    mutation that didn't happen" contract _run_action already enforces
    for every other action."""
    new_type = issue_types.next_type(item.labels)
    verb = f"typed issue #{item.number} as {new_type or 'untyped'}"
    succeeded = _run_action(
        issue_types.type_label_command(item, new_type), live, log, verb,
        activity=activity, action="type", kind=item.kind, number=item.number,
        title=item.title, repo=item.repo, detail=new_type or "",
    )
    if succeeded or not live:
        item.labels = [l for l in item.labels if l not in issue_types.TYPE_LABELS]
        if new_type:
            item.labels.append(new_type)
    return succeeded


def superseded_selection(items, repo_dir, *, check_mergeability=merge_safety.check_mergeability):
    """Classify a V-selection for issue #49 slice 3: an item is
    closeable-with-evidence only when its OWN content is demonstrably
    already on trunk -- merge_safety.check_mergeability's CODE_SUPERSEDED,
    the exact signal #31 already computes per PR (one `gh pr view` plus a
    local content-overlap diff), reused here rather than a second "is
    this done" check. Deliberately NOT #41's CODE_SUBSUMED (containment
    in a still-open sibling): a subsumed PR's content isn't on trunk yet,
    only redundant with another PR that hasn't merged either -- closing
    it "with evidence" would be a lie, so `other_open_prs` is never
    passed here (see check_mergeability's own docstring: omitting it
    skips the subsumption probe entirely rather than running it and
    ignoring the answer).

    Returns (closeable, skipped): closeable is [(item, evidence)] where
    evidence is decision.reason (already names the overlap percentage
    and the base branch, e.g. "this looks superseded -- 96% of its
    lines already appear on 'main'"); skipped is [(item, reason)] for
    every item this bulk action does NOT touch -- issues (the
    superseded-on-trunk check only has meaning for a PR) and PRs that
    come back anything other than superseded, each with its own reason
    so a bulk run's log is never silently partial (#49's own "partial
    success is the normal case" rule)."""
    closeable, skipped = [], []
    for item in items:
        if item.kind != "pr":
            skipped.append((item, "not a PR -- superseded-on-trunk check only applies to PRs"))
            continue
        decision = check_mergeability(item.number, repo_dir, repo=item.repo)
        if decision.code == merge_safety.CODE_SUPERSEDED:
            closeable.append((item, decision.reason))
        else:
            skipped.append((item, decision.reason))
    return closeable, skipped


def annotate_subsumption(row_items, repo_dir=None):
    """Issue #41's second acceptance box: mark constituent PRs in the
    queue view, not just refuse the merge on `m`. Computed ONCE per
    refresh (called right after every place row_items gets rebuilt --
    startup, `r`, map zoom-in) via merge_safety.subsumption_map, a
    single batched `git fetch` for the whole set rather than one per PR,
    and written onto each TriageItem's own contained_in_number/title
    fields so render() and mergeability_snapshot_lines can show it for
    free afterward -- no git call per step or per keypress, which is
    exactly the walk-time cost this issue's own comment ruled out for
    the detail-panel half of this box.

    Scoped per repo (#39: a view -- or the repo map's own item lists --
    can hold PRs from more than one repo, and a head ref match across
    repos is coincidence, not containment, same reasoning
    other_open_prs_for already applies)."""
    repo_dir = repo_dir or os.getcwd()
    values = row_items.values() if hasattr(row_items, "values") else row_items
    by_repo = {}
    for item in values:
        if item.kind == "pr" and item.head_ref_name:
            by_repo.setdefault(item.repo, []).append(item)
    for prs in by_repo.values():
        if len(prs) < 2:
            for i in prs:  # nothing to compare against -- same reset reasoning as below
                i.contained_in_number = None
                i.contained_in_title = None
            continue
        open_prs = [
            merge_safety.OpenPR(number=i.number, title=i.title, head_ref=i.head_ref_name)
            for i in prs
        ]
        contained = merge_safety.subsumption_map(repo_dir, open_prs)
        for i in prs:
            # Explicit reset, not just set-when-found: a map-view tile
            # can hand back the SAME TriageItem objects across two
            # zoom-ins with no rebuild in between (map_state.by_repo is
            # cached by _ensure_map_built), so a container relationship
            # that was true last call and isn't anymore must be cleared
            # here rather than left stale from a previous call.
            container = contained.get(i.number)
            i.contained_in_number = container.number if container else None
            i.contained_in_title = container.title if container else None


def other_open_prs_for(items, item):
    """Every other open PR in `items` (a list or dict-of-TriageItem, from
    the same `row_items` `run()` already holds -- no extra `gh` call),
    shaped for merge_safety.check_subsumption -- issue #41. `items` from
    a repo-map view can hold PRs from more than one repo, but this PR's
    head can only be contained in a sibling from ITS OWN repo (a
    cross-repo head ref match would be coincidence, not containment), so
    this filters to `item.repo` before handing anything to a local git
    check keyed only by ref name."""
    values = items.values() if hasattr(items, "values") else items
    return [
        merge_safety.OpenPR(number=i.number, title=i.title, head_ref=i.head_ref_name)
        for i in values
        if i.kind == "pr" and i.number != item.number and i.repo == item.repo and i.head_ref_name
    ]


def handle_merge_key(
    item, live, log, activity, session_repo, mismatch_seen, repo_dir,
    *, check_mergeability=merge_safety.check_mergeability, other_open_prs=None,
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

    `other_open_prs` (issue #41) is a list of merge_safety.OpenPR built
    from data already fetched -- see other_open_prs_for -- so
    check_mergeability can refuse a PR that's already contained in a
    still-open sibling before ever building a merge command.
    """
    key = (session_repo, item.number)
    decision = check_mergeability(
        item.number, repo_dir, repo=session_repo, other_open_prs=other_open_prs,
    )
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


def handle_merge_all_key(
    items, live, log, activity, mismatch_seen, repo_dir,
    *, handle_merge=handle_merge_key,
):
    """[M] -- merge every PR row in one press. Zach, 2026-08-05: "I just
    need the automerge AoE spell inside vim-arcade to merge everything in
    a repo in one blast."

    This is a LOOP OVER `handle_merge_key`, never a second merge path.
    Every safety property of `[m]` therefore holds per-PR here by
    construction rather than by being re-implemented and kept in sync:
    issue #31's local decision runs fresh for each PR immediately before
    that PR's merge, so a queue whose earlier merges invalidate a later
    one (each merge moves the base, which is exactly how #30 happened)
    refuses the later one on its own re-check rather than acting on a
    verdict gathered before the blast started.

    THE MISMATCH WARNING IS NOT BULK-OVERRIDDEN. A PR whose first press
    would surface a title/diff mismatch returns "detail" from
    `handle_merge_key` and is COUNTED AND SKIPPED here, never merged.
    `[m]`'s invariant is that a human is never shown a mismatch and has
    it merged by the same keypress; a bulk key that quietly satisfied
    the "second press" itself would repeal that invariant for exactly
    the PRs it was written to protect. Those PRs are listed by number so
    the follow-up is a visible, deliberate `[m]` on each.

    Issues are untouched -- `[x]` closes those, and conflating "merge
    every PR" with "close every issue" in one key is how an AoE becomes
    a thing you are afraid to press.

    Returns "walk" always: there is no single item left to zoom into.
    """
    prs = [item for item in items if item.kind == "pr"]
    if not prs:
        log.append("MERGE ALL: no PR rows here -- nothing to do")
        return "walk"

    merged, refused, warned = 0, 0, []
    for item in prs:
        before = len(log)
        # item.repo, not a single session repo: #39 lets one session hold
        # items from several repos, and each PR must be judged against
        # the repo it actually belongs to.
        mode = handle_merge(
            item, live, log, activity, item.repo, mismatch_seen, repo_dir,
            other_open_prs=other_open_prs_for(items, item),
        )
        if mode == "detail":
            warned.append(item.number)
        elif any(
            entry.startswith(f"REFUSED #{item.number}")
            for entry in log[before:]
        ):
            refused += 1
        else:
            merged += 1

    # Same log-prefix idiom the [m] handler already uses to detect a
    # landed live merge -- one summary line, since at 40 columns a
    # per-PR recap would push the actionable part off the edge.
    summary = f"MERGE ALL: {merged} merged, {refused} refused"
    if warned:
        summary += (
            f", {len(warned)} need a second [m]: "
            + " ".join(f"#{n}" for n in warned)
        )
    log.append(summary)
    return "walk"


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


def _delta_str(delta):
    """issue #75: '(?)' means no prior local snapshot (not zero change);
    otherwise a signed count, e.g. '(+3)'/'(-1)'/'(+0)'."""
    return "(?)" if delta is None else f"({'+' if delta >= 0 else ''}{delta})"


def _age_str(age_days):
    return "age~?" if age_days is None else f"age~{age_days:.0f}d"


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
        # issue #47: a fraction, not a bare open count -- "0 open" and "0
        # of 40 need Zach" read as the same headline number and are not
        # the same fact.
        counts = f"{tile.needs_owner}/{tile.total} need Zach {_delta_str(tile.delta)}"
        safe_addstr(stdscr, top + 1, left, counts[: max(0, w - 1)], attr)
    if h > 2:
        # issue #75: derivative and age share this row with f/r/d --
        # f/r/d moved here from the counts row to make room.
        detail = f"f:{tile.fresh} r:{tile.replied} d:{tile.draft} {_age_str(tile.oldest_age_days)}"
        safe_addstr(stdscr, top + 2, left, detail[: max(0, w - 1)], attr)


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
        total = sum(t.total for t in tiles)
        needs_owner = sum(t.needs_owner for t in tiles)
        # issue #75: the ecosystem-wide headline number + its first
        # derivative -- rising/falling, per #75, matters more than the
        # absolute count. issue #47: headline as needs-Zach/total, not a
        # bare open count -- 0/N means no Zach blockers regardless of N.
        page_note = (
            f"page {page + 1}/{layout['page_count']}  repos: {len(tiles)}  "
            f"backlog: {needs_owner}/{total} need Zach {_delta_str(map_state.total_delta)}"
        )
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

    safe_addstr(stdscr, layout["quit_row"], 0, "Q to quit   Enter: open repo   ?: glossary   e/E: edit config")
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
    mode, item, comment_buffer, new_title, new_body, panel_h, width, body_scroll=0,
    selected=None, diag_lines=None,
):
    if panel_h <= 0:
        return []
    if mode == "preview":
        # Issue #49 slice 1: read-only work order for a "V" + motion
        # selection. `selected` is a plain list of TriageItems -- no
        # grid/level state involved, and nothing in THIS function ever
        # mutates anything. Windowed with the same j/k-scroll discipline
        # the "detail" body panel uses below, so a selection bigger than
        # the panel is still fully reachable, not silently cut off
        # (issue #12's regression, same fix reused).
        #
        # Issue #49 slice 2: "y" (handled in run()'s key loop, not here)
        # hands this exact list to dispatch.build_selection_plan -- the
        # preview already enumerates every item, so it doubles as the
        # confirmation step the issue's own "shippable first slice"
        # section asks for, rather than a second confirm screen.
        selected = selected or []
        total = len(selected)
        budget = max(0, panel_h - 2)
        top = _clamp_scroll(body_scroll, total, budget)
        window = selected[top : top + budget] if budget else []
        header = f"AoE preview -- {total} item(s) selected"
        if total > budget and budget:
            shown_end = min(top + budget, total)
            header = f"[{top + 1}-{shown_end}/{total} j/k scroll]  " + header
        lines = [header]
        for it in window:
            lines.append(f"{it.kind} #{it.number}: {it.title}")
        lines = lines[: max(1, panel_h - 1)]
        lines.append("[s] close superseded  [y] dispatch to self-dev  [Esc] back")
        return lines[:panel_h]
    if mode == "diagnostics":
        # Issue #72's real-output slice: git_diagnostics already ran (see
        # the "g" handler in detail mode) -- this only renders its output,
        # windowed the same j/k-scroll way "preview"/"detail" body text
        # is, so a long WARNING (e.g. a dirty checkout) is never silently
        # cut off.
        diag = diag_lines or []
        total = len(diag)
        budget = max(0, panel_h - 2)
        top = _clamp_scroll(body_scroll, total, budget)
        window = diag[top : top + budget] if budget else []
        header = "git diagnostics (read-only -- fetch + status; never checks out, rebases, or pushes)"
        if total > budget and budget:
            shown_end = min(top + budget, total)
            header = f"[{top + 1}-{shown_end}/{total} j/k scroll]  " + header
        lines = [header] + window
        lines = lines[: max(1, panel_h - 1)]
        lines.append("[Esc] back")
        return lines[:panel_h]
    input_width = max(1, width - 1)
    if mode == "detail":
        header = f"{item.kind} #{item.number}: {item.title}"
        menu = "[c] comment  [x] close"
        if item.kind == "issue":
            header += f"  [{issue_types.current_type(item.labels) or 'untyped'}]"
            menu += "  [t] type"
        if item.kind == "pr":
            menu += "  [m] merge  [A] merge all"
            if item.is_draft:
                menu += "  [R] ready"
            if item.mergeable == "CONFLICTING" or item.merge_state_status == "DIRTY":
                menu += "  [g] git diagnostics"
        menu += "  [Esc] back"
        header_lines = [header] + age_summary_line(item) + mergeability_snapshot_lines(item)
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
    selected=None,
    diag_lines=None,
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

    # Issue #49 slice 1: "the selection is visible" -- a running item
    # count on the status line, visible the instant "V" is pressed, well
    # before ":" opens the full preview panel below.
    sel_lo = sel_hi = None
    if (
        mode == "walk"
        and getattr(session, "visual_active", False)
        and getattr(session, "visual_kind", None) == "line"
    ):
        sel_lo, sel_hi = sorted((session.visual_anchor[0], session.player_pos[0]))
        n_selected = sum(1 for r in range(sel_lo, sel_hi + 1) if r in row_items)
        status = f"-- VISUAL LINE -- {n_selected} item(s) selected  [: preview  Esc cancel]"
    else:
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
        # Issue #28: the item's number, overlaid on the floor columns
        # right after its block ("i6", not a bare "i") -- computed once
        # per row rather than per column below.
        number_cols = (
            number_overlay_cols(
                marker_col_for(level, r), row_items[r].number, level.width,
                contained_in=row_items[r].contained_in_number,
            )
            if r in row_items else {}
        )
        row_attr = curses.A_REVERSE if (sel_lo is not None and sel_lo <= r <= sel_hi) else 0
        for c in range(level.width):
            ch = level.char_at(r, c)
            if ch == "@":
                ch = GOAL_CHAR
            elif ch == "#" and r in row_items:
                # Display-only symbol overlay (issue #9). The tile stays
                # "#" in the grid so grid.py's wall/movement logic is
                # untouched -- only what the player *sees* changes.
                ch = getattr(row_items[r], "symbol", "#") or "#"
            elif c in number_cols:
                ch = number_cols[c]
            safe_addch(stdscr, grid_top + screen_r, c, ch, row_attr)
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
    elif layout["panel_h"] and mode == "preview":
        for i, line in enumerate(
            _panel_lines(
                mode, None, comment_buffer, new_title, new_body,
                layout["panel_h"], width, body_scroll, selected=selected,
            )
        ):
            safe_addstr(stdscr, layout["panel_top"] + i, 0, line)
    elif layout["panel_h"] and mode == "diagnostics":
        for i, line in enumerate(
            _panel_lines(
                mode, None, comment_buffer, new_title, new_body,
                layout["panel_h"], width, body_scroll, diag_lines=diag_lines,
            )
        ):
            safe_addstr(stdscr, layout["panel_top"] + i, 0, line)

    for i, line in enumerate(log[-layout["log_h"] :] if layout["log_h"] else []):
        safe_addstr(stdscr, layout["log_top"] + i, 0, line)

    # "M: map" here is issue #39's discoverability requirement made
    # literal: the footer is the one place that's ALWAYS visible
    # regardless of mode, so this is where "how do I get back to the
    # map" lives -- never folklore, never only in a hint line that
    # scrolls out of relevance once you're deep in a detail panel.
    safe_addstr(stdscr, layout["quit_row"], 0, "Q to quit   M: map   ?: glossary")
    stdscr.refresh()


# ---------------------------------------------------------------------------
# Startup staleness prompt (issue #18) -- runs once, before the event loop.
# All git/gh probing lives in staleness.py; this is only the screen and the
# pure decision of what it offers, both directly unit-testable.
# ---------------------------------------------------------------------------


def engine_dir():
    """Repo root that contains vim_arcade/ and .git -- same directory the
    `joue` launcher computes as ENGINE_DIR and puts on PYTHONPATH."""
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
    level, row_items = build_level(items, max_width=max_width)
    annotate_subsumption(row_items)
    return level, row_items


def run(stdscr, items, live=False, startup_note=None):
    """The one event loop (issue #39). `items` is the current repo's
    open items for the ordinary no-arg case; it is None when there is
    no current repo to show at all -- launched outside a git repo, in a
    repo with no GitHub remote, or via the `joue --map` path
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

    # session_repo is always the repo joue is actually RUNNING in (the
    # cwd checkout exit_gate.check_unlanded_work inspects) -- distinct
    # from view_repo, which changes as the map (#39) is navigated to a
    # different repo's tiles. The exit gate always judges the local
    # checkout, never whichever repo happens to be on screen.
    session_repo = dispatch.current_repo()

    if items is not None:
        level, row_items = _build_level_for_stdscr(stdscr, items)
        session = Session(level_index=0, levels=[level])
        mode = "walk"  # "walk" | "detail" | "comment" | "new_title" | "new_body" | "map" | "preview"
    else:
        level, row_items, session = None, {}, None
        mode = "map"

    # Issue #49 slice 1: the AoE work order -- a plain list of
    # TriageItems a "V" + motion selection produced, shown read-only by
    # "preview" mode below. Never written to except by the ":" handler
    # in walk mode; never fed back into anything that could mutate a
    # level.
    preview_items = []

    # Issue #26: background poll for queue changes, single-repo view
    # only (see QueueWatcher's own docstring for why -- #17's multi-repo
    # cost concern is explicitly future work, not this slice). `r` is
    # still the only thing that ever rebuilds level/row_items; this only
    # ever sets a status-line note.
    queue_watcher = QueueWatcher(view_repo) if (items is not None and view_repo) else None
    if queue_watcher is not None:
        queue_watcher.start(numbers_from_items(items))
    queue_note = ""

    map_state = gh_map.MapState()
    map_built = False

    def _snapshot_map_backlog():
        # issue #75: exactly one call per data refresh (build or `r`),
        # never per render frame -- see backlog.snapshot_and_diff's own
        # docstring for why calling it more often would zero out every
        # delta by comparing a snapshot against itself.
        diff = backlog.snapshot_and_diff(map_state.by_repo)
        map_state.deltas = diff.deltas
        map_state.total_delta = diff.total_delta

    def _ensure_map_built():
        nonlocal map_built
        if not map_built:
            map_state.by_repo = discover_items()
            _snapshot_map_backlog()
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
    diag_lines = []  # issue #72: real output from the last [g] git diagnostics run
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
    mode_note = (
        "LIVE -- actions really comment/close/merge/create for real."
        if live
        else "DRY RUN -- actions only log the gh command (omit --dry-run to really act)."
    )
    hint = "Walk up to a block (h/j/k/l/w/b) to open it. n = new issue, r = refresh, e/E = edit config."

    # Quit-time self-dev handoff (2026-08-04): what this session actually
    # did (live, succeeded), and which repo it did it in -- see
    # dispatch.py. Only ever grows via _run_action's `activity=` recording
    # of a real success; DRY RUN and FAILED: actions never touch it.
    activity = dispatch.SessionActivity()
    quit_reason = None

    while True:
        if queue_watcher is not None:
            note = queue_watcher.peek_message()
            if note:
                queue_note = note

        if mode == "map":
            layout = render_map(stdscr, map_state, message, has_color)
        else:
            display_message = f"{message}  {queue_note}" if (message and queue_note) else (message or queue_note)
            render(
                stdscr, level, row_items, session, mode, active_row, comment_buffer,
                new_title, new_body, display_message, log, mode_note, hint, body_scroll,
                selected=preview_items, diag_lines=diag_lines,
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
                _snapshot_map_backlog()
                gh_map.focus_on_repo(map_state, focused_repo)
                message = "refreshed."
            elif ch == "?":
                _run_glossary(stdscr)
            elif ch == "e":
                focused = gh_map.focused_tile(map_state)
                if focused is not None:
                    _run_edit_config(stdscr, config.ensure_repo_config(focused.repo))
                    message = f"edited config for {focused.repo}."
                else:
                    message = "no repo focused -- move onto a tile first."
            elif ch == "E":
                _run_edit_config(stdscr, config.ensure_global_config())
                message = "edited global config."
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
                    annotate_subsumption(row_items)
                    marker_col = marker_col_for(level)
                    session = Session(level_index=0, levels=[level])
                    active_row = None
                    was_adjacent_row = None
                    if queue_watcher is not None:
                        queue_watcher.reset_baseline(numbers_from_items(row_items.values()))
                    queue_note = ""
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

        if mode == "diagnostics":
            # Issue #72: read-only real-output panel. Esc/Q are the only
            # actions -- there is no key here that runs anything beyond
            # what [g] already ran to build diag_lines.
            if key == ord("Q"):
                should_quit, _ = _attempt_quit(
                    stdscr, live=live, log=log, activity=activity, session_repo=session_repo,
                )
                if should_quit:
                    quit_reason = "Q"
                    break
                continue
            if key == 27:
                mode = "detail"
                body_scroll = 0  # this was scrolled through diag_lines, not item's body
            elif key in (ord("j"), ord("k")):
                budget = max(0, compute_layout(*stdscr.getmaxyx(), "diagnostics")["panel_h"] - 2)
                total = len(diag_lines)
                body_scroll = _clamp_scroll(
                    body_scroll + (1 if key == ord("j") else -1), total, budget
                )
            continue

        if mode == "preview":
            # Issue #49 slice 1: read-only selection mechanics. No branch
            # here calls close_command/comment_command/merge_command/
            # ready_command, and none ever will -- the interaction panel
            # (mode == "detail") stays the only path to those. j/k
            # scroll to reach every selected item even when the panel is
            # shorter than the selection (see _panel_lines' "preview"
            # branch).
            #
            # Issue #49 slice 2: "y" is the one exception -- it hands
            # `preview_items` to dispatch.build_selection_plan/
            # run_dispatch, the SAME #24 scheduler -i mechanism the quit
            # screen already uses (dispatch.py), never a second one. The
            # preview already lists every item, so it IS the
            # confirmation the issue's own slice section asks for --
            # there is no second "are you sure" screen here.
            if key == ord("Q"):
                should_quit, _ = _attempt_quit(
                    stdscr, live=live, log=log, activity=activity, session_repo=session_repo,
                )
                if should_quit:
                    quit_reason = "Q"
                    break
                continue
            if key == ord("M"):
                _ensure_map_built()
                mode = "map"
            elif key == 27:  # Esc: back to walk AND clear the selection,
                # matching real vim's "Esc always exits visual mode" --
                # reuses session's own clearing logic rather than a
                # second copy of it here.
                session.feed_key("\x1b")
                mode = "walk"
            elif key in (ord("j"), ord("k")):
                budget = max(0, compute_layout(*stdscr.getmaxyx(), "preview")["panel_h"] - 2)
                total = len(preview_items)
                body_scroll = _clamp_scroll(
                    body_scroll + (1 if key == ord("j") else -1), total, budget
                )
            elif key == ord("y"):
                plans = dispatch.build_selection_plan(preview_items)
                if not any(p.project is not None for p in plans):
                    message = "nothing dispatchable -- no scheduler project registered for this repo."
                elif live:
                    results = dispatch.run_dispatch(plans)
                    for r in results:
                        if r.ok:
                            log.append(f"LIVE dispatch [{r.action.project}] -- ok: {r.message}")
                        else:
                            log.append(
                                f"LIVE dispatch [{r.action.project or r.action.repo}] -- FAILED: {r.message}"
                            )
                    ok_count = sum(1 for r in results if r.ok)
                    message = f"dispatched {ok_count}/{len(results)} batch(es) to self-dev."
                    session.feed_key("\x1b")  # clear the selection, same as Esc
                    preview_items = []
                    mode = "walk"
                else:
                    for p in plans:
                        if p.project is not None:
                            log.append(f"DRY RUN would run: {' '.join(p.argv)}")
                    message = "DRY RUN -- would dispatch (omit --dry-run to really hand off to scheduler)."
            elif key == ord("s"):
                # Issue #49 slice 3: close every selected PR that is
                # demonstrably already superseded on trunk -- the one
                # mechanical, verifiable consolidation the issue's own
                # "shippable first slice" section names as the FIRST
                # automated one, ahead of any fuzzier dedupe/merge
                # judgment. See superseded_selection's own docstring for
                # why this is never #41's subsumption check.
                closeable, skipped = superseded_selection(preview_items, os.getcwd())
                for skipped_item, reason in skipped:
                    log.append(f"SKIP {skipped_item.kind} #{skipped_item.number}: {reason}")
                if not closeable:
                    message = f"bulk close: nothing closeable -- {len(skipped)} item(s) not superseded."
                elif live:
                    closed = 0
                    for close_item, evidence in closeable:
                        comment = (
                            f"Closing -- {evidence} (bulk close-with-evidence, issue #49 slice 3)."
                        )
                        if handle_close_key(close_item, live, log, activity, comment=comment):
                            closed += 1
                    message = (
                        f"bulk close: closed {closed}/{len(closeable)} superseded, "
                        f"skipped {len(skipped)}."
                    )
                    session.feed_key("\x1b")  # clear the selection, same as Esc/y
                    preview_items = []
                    mode = "walk"
                else:
                    for close_item, evidence in closeable:
                        log.append(f"DRY RUN would close {close_item.kind} #{close_item.number}: {evidence}")
                    message = (
                        f"DRY RUN -- would close {len(closeable)} superseded, "
                        f"skip {len(skipped)} (omit --dry-run to really close)."
                    )
            continue

        if mode == "detail":
            item = row_items[active_row]
            if key == ord("Q"):
                should_quit, _ = _attempt_quit(
                    stdscr, live=live, log=log, activity=activity, session_repo=session_repo,
                )
                if should_quit:
                    quit_reason = "Q"
                    break
                continue
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
                handle_close_key(item, live, log, activity)
                mode = "walk"
            elif key == ord("t") and item.kind == "issue":
                # Issue #77: type the issue under the cursor by decay
                # rate. Stays in detail mode (unlike [x], this doesn't
                # remove the item from view) so the header's updated
                # [type] is visible immediately and a repeat press
                # keeps cycling.
                handle_type_key(item, live, log, activity)
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
                    other_open_prs=other_open_prs_for(row_items, item),
                )
                # Issue #46/#73: "if I just merged a PR, I would always
                # want that as my check out" -- and waiting on a keypress
                # to notice was the actual failure mode #73 filed (a
                # deployed checkout stayed stale, silently, because
                # nobody pressed [f]). A live merge just appended exactly
                # one "LIVE merged pr #N -- ok..." line (a refusal or a
                # warning never does) -- that's the signal to sync THIS
                # checkout automatically now, or log loudly why not.
                if live and any(
                    entry.startswith(f"LIVE merged pr #{item.number} -- ok")
                    for entry in log[pre_merge_log_len:]
                ):
                    sync_note = staleness.sync_after_merge(os.getcwd())
                    if sync_note:
                        log.append(sync_note)
            elif key == ord("A"):
                # The AoE: merge every PR row at once.
                #
                # WAS [M] and that was DEAD CODE -- `M` already opens the
                # map at the top of this same if/elif chain, so this
                # branch was unreachable and the detail menu advertised a
                # key that did nothing. Bound to [A] instead: free, and
                # "fire at all of them" reads the way `A` appends at the
                # end of the line rather than at the cursor.
                #
                # Deliberately NOT a `d`-style range: `d` clears rows
                # (which CLOSES a pr), and a range that sometimes closes
                # and sometimes merges depending on which key started it
                # is not an ambiguity worth having on an irreversible
                # action.
                pre_merge_log_len = len(log)
                mode = handle_merge_all_key(
                    list(row_items.values()), live, log, activity,
                    mismatch_seen, os.getcwd(),
                )
                # Issue #46/#73's automatic sync, once for the whole
                # blast rather than once per PR -- the checkout can only
                # be behind by one answer no matter how many landed.
                if live and any(
                    entry.startswith("LIVE merged pr #") and " -- ok" in entry
                    for entry in log[pre_merge_log_len:]
                ):
                    sync_note = staleness.sync_after_merge(os.getcwd())
                    if sync_note:
                        log.append(sync_note)
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
            elif key == ord("g") and item.kind == "pr" and (
                item.mergeable == "CONFLICTING" or item.merge_state_status == "DIRTY"
            ):
                # Issue #72's real-output slice: run the actual, read-only
                # git commands (fetch + ahead/behind + local status)
                # instead of only telling the player what to type. Never
                # a mutating command -- see git_diagnostics' own docstring
                # for why the checkout/rebase/push half of #72/#81/#84
                # stays unbuilt here.
                diag_lines = git_diagnostics(item.head_ref_name, item.base_ref_name, os.getcwd())
                body_scroll = 0
                mode = "diagnostics"
            continue

        # mode == "walk"
        if key == ord("Q"):
            should_quit, _ = _attempt_quit(
                stdscr, live=live, log=log, activity=activity, session_repo=session_repo,
            )
            if should_quit:
                quit_reason = "Q"
                break
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
        if key == ord("e"):
            if view_repo:
                _run_edit_config(stdscr, config.ensure_repo_config(view_repo))
                message = f"edited config for {view_repo}."
            else:
                message = "couldn't determine this repo -- nothing to edit."
            continue
        if key == ord("E"):
            _run_edit_config(stdscr, config.ensure_global_config())
            message = "edited global config."
            continue
        if key == ord("r"):
            level, row_items = refresh(repo=view_repo)
            annotate_subsumption(row_items)
            marker_col = marker_col_for(level)
            session = Session(level_index=0, levels=[level])
            active_row = None
            was_adjacent_row = None
            message = "refreshed."
            if queue_watcher is not None:
                queue_watcher.reset_baseline(numbers_from_items(row_items.values()))
            queue_note = ""
            continue
        if key == ord("?"):
            _run_glossary(stdscr)
            continue
        char = _key_to_char(key)
        if not char:
            continue

        if char == ":":
            # Issue #49 slice 1: preview a "V" + motion selection.
            # Read-only -- this is the ONLY thing ":" does; it never
            # reaches close_command/comment_command/merge_command, and
            # session.feed_key is never called for it, so it can't be
            # misread as some future vim ":" command either.
            if session.visual_active and session.visual_kind == "line":
                lo, hi = sorted((session.visual_anchor[0], session.player_pos[0]))
                work_order = selected_items(row_items, lo, hi)
                if work_order:
                    preview_items = work_order
                    body_scroll = 0
                    mode = "preview"
                else:
                    message = "Nothing selected -- the range covers no items."
            else:
                message = "Press V then a motion to select rows, then : to preview."
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

    if queue_watcher is not None:
        queue_watcher.stop()

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


def render_quit_blocked(stdscr, status):
    """Q's exit gate (issue #10): drawn instead of quitting when
    exit_gate.check_unlanded_work() reports blocked work in this repo.
    Same safe_addstr discipline as the rest of this module -- must
    render without crashing at any terminal size."""
    stdscr.erase()
    height, width = stdscr.getmaxyx()
    lines = ["Q refused -- unlanded work in this repo:"]
    if status.flags:
        lines.extend(f"  {f}" for f in status.flags[:6])
        if len(status.flags) > 6:
            lines.append(f"  (+{len(status.flags) - 6} more)")
    elif status.reason:
        lines.append(f"  {status.reason}")
    lines.append("")
    lines.append("Q again = force quit anyway (files what's abandoned as a GitHub issue).")
    if any("[worktrees]" in f for f in status.flags):
        lines.append("w = examine/clean up linked worktrees, right here.")
    lines.append("Any other key = stay and land it first.")
    for i, line in enumerate(lines[: max(0, height - 1)]):
        safe_addstr(stdscr, i, 0, line)
    stdscr.refresh()


def render_worktree_cleanup(stdscr, candidates, message=""):
    """The 'w' screen off the exit gate: makes BLIND [worktrees] solvable
    without leaving curses. Only ever offers to remove a candidate
    exit_gate.list_worktree_candidates has already classified as clean
    AND merged -- a dirty or unmerged worktree is shown so the player
    knows it exists, never auto-removed. Same safe_addstr discipline as
    every other screen in this module."""
    stdscr.erase()
    height, width = stdscr.getmaxyx()
    lines = ["Linked worktrees (issue #10's BLIND [worktrees] flag):"]
    if not candidates:
        lines.append("  none found -- nothing to clean up here.")
    for c in candidates:
        tag = "removable (clean, merged)" if c.removable else "NOT removable -- land it by hand"
        lines.append(f"  {c.path} [{c.branch}] -- {tag}")
    if message:
        lines.append("")
        lines.append(message)
    lines.append("")
    removable_count = sum(1 for c in candidates if c.removable)
    if removable_count:
        lines.append(f"r = remove all {removable_count} removable worktree(s) now.")
    lines.append("Any other key = back to the exit gate.")
    for i, line in enumerate(lines[: max(0, height - 1)]):
        safe_addstr(stdscr, i, 0, line)
    stdscr.refresh()


def render_glossary(stdscr):
    """The '?' screen (issue #48): every single-character symbol `joue`
    renders, in one place, reusing glossary.glossary_lines as the single
    source of truth so this can never drift from what a mechanical
    linter (test_glossary.py) already checks is complete. Same
    safe_addstr discipline as every other screen in this module -- must
    render without crashing at any terminal size."""
    stdscr.erase()
    height, width = stdscr.getmaxyx()
    footer = ["", "Any key = back."]
    # Footer is PINNED, not appended-then-hoped-to-survive-truncation:
    # issue #41's queue-marker section widened the table enough that a
    # plain "content + footer, then clip at height" (the original shape)
    # silently dropped the footer at a real 80x24 terminal -- exactly
    # the kind of "clip the wrong end" bug #8's own layout-budget
    # discipline exists to prevent. Content clips first; the footer
    # always has its two rows, as long as the terminal has at least two
    # rows at all.
    content_h = max(0, height - len(footer))
    for i, line in enumerate(glossary.glossary_lines(width)[:content_h]):
        safe_addstr(stdscr, i, 0, line)
    for i, line in enumerate(footer):
        row = content_h + i
        if 0 <= row < height:
            safe_addstr(stdscr, row, 0, line)
    stdscr.refresh()


def _run_edit_config(stdscr, path):
    """Issue #88: the one place gh_game.py hands the terminal to an
    external editor rather than drawing with curses itself -- mirrors
    paste_lesson.py's real-vim invocation, which is likewise the one
    spot in that module explicitly excluded from curses discipline.
    def_prog_mode/reset_prog_mode (not a second initscr) is the
    documented way to lend curses' terminal to a child process and get
    it back looking the way it did before, per Python's curses docs."""
    editor = os.environ.get("EDITOR", "vi")
    curses.def_prog_mode()
    curses.endwin()
    try:
        subprocess.run([editor, str(path)])
    finally:
        curses.reset_prog_mode()
        stdscr.refresh()


def _run_glossary(stdscr):
    """Read-only sub-screen, reachable from any mode that lists it in its
    footer -- draws the glossary and blocks for exactly one keypress,
    same shape as _run_worktree_cleanup's confirmation screen. Never
    touches game/session state, so returning is always safe regardless
    of what mode called it."""
    render_glossary(stdscr)
    stdscr.getch()


def _run_worktree_cleanup(stdscr, repo_dir):
    """Runs from _attempt_quit on 'w'. Never touches `live`/DRY RUN --
    `git worktree remove` is a local, reversible (re-`git worktree add`)
    operation on this host's own checkout, not a `gh` side effect on a
    shared remote, so it is not gated the way comment/close/merge are."""
    candidates = exit_gate.list_worktree_candidates(repo_dir)
    render_worktree_cleanup(stdscr, candidates)
    key = stdscr.getch()
    if key != ord("r"):
        return
    removed, failed = [], []
    for c in candidates:
        if not c.removable:
            continue
        ok, note = exit_gate.remove_worktree(repo_dir, c.path)
        (removed if ok else failed).append(note)
    parts = []
    if removed:
        parts.append(f"removed {len(removed)}: " + "; ".join(removed))
    if failed:
        parts.append(f"failed {len(failed)}: " + "; ".join(failed))
    render_worktree_cleanup(
        stdscr, exit_gate.list_worktree_candidates(repo_dir), "; ".join(parts) or "nothing removable."
    )
    stdscr.getch()


def _attempt_quit(stdscr, live=False, log=None, activity=None, session_repo=None, repo_dir=None):
    """Q's exit gate (issue #10): refuse to quit while real work in the
    target repo (the one joue is running in) is unlanded per
    exit_gate.check_unlanded_work -- the same closeout-lint mechanism
    session closeout already uses elsewhere, not a second copy of "is
    this tree durable". Returns (should_quit, forced): should_quit is
    False if the player backed off; forced is True only for a Q! that
    pushed through blocked work (and has already filed it, per #10's
    "Q! must file what was abandoned" requirement -- `Q` must never trap
    the player, so a second Q always exits, blocked or not).

    The filing goes through `_run_action` like every other gh action in
    this module, so it is DRY-RUN-only (logged, not actually filed) in a
    `--dry-run` session -- a quit-time filing that ran for real even in
    a practice session would be a surprise real GitHub issue, exactly
    the inconsistency `_run_action` exists to prevent everywhere else.

    A BLIND [worktrees] flag additionally makes 'w' live -- "solvable in
    game": examine/clean the linked worktrees right here instead of the
    only paths being "force past it" or "go do it in a shell". The gate
    is re-checked after cleanup, so landing everything in-game reaches
    an ordinary unblocked quit, not just a smaller refusal."""
    repo_dir = repo_dir or os.getcwd()
    while True:
        status = exit_gate.check_unlanded_work(repo_dir)
        if not status.blocked:
            return True, False
        render_quit_blocked(stdscr, status)
        key = stdscr.getch()
        if key == ord("Q"):
            _run_action(
                exit_gate.abandoned_work_issue_command(status), live, log if log is not None else [],
                "filed abandoned-work issue (Q!)",
                activity=activity, action="create_issue", kind="issue", number=None,
                title="Q! abandoned unlanded work", repo=session_repo, detail=status.reason or "",
            )
            return True, True
        if key == ord("w") and any("[worktrees]" in f for f in status.flags):
            _run_worktree_cleanup(stdscr, repo_dir)
            continue
        return False, False


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


# Issue #50: LIVE became the default on this date, not before. Anyone
# who ran an older checkout kept the safe DRY RUN default; the banner
# below exists so the flip is loud for exactly the week after it ships,
# then goes silent -- same "state it loudly, then stop" shape as any
# other one-time migration notice in this codebase.
LIVE_DEFAULT_SINCE = date(2026, 8, 8)


def parse_live(argv):
    """LIVE is the default (issue #50); --dry-run opts back into the old
    safe default. --live is still accepted, as a no-op, so scripts and
    docs written before this flip keep working unchanged."""
    return "--dry-run" not in argv


def live_default_banner(today=None):
    """Printed once at startup for the week after the #50 flip, then
    None forever after -- "state that loudly... then go silent about
    it," taken literally rather than left to whoever reads the
    docstring."""
    today = today or date.today()
    if today - LIVE_DEFAULT_SINCE >= timedelta(days=7):
        return None
    return (
        "gh-triage: actions are LIVE by default as of 2026-08-08 (issue #50) "
        "-- pass --dry-run to only log what would run. This notice stops "
        "appearing after 2026-08-15."
    )


def main():
    argv = sys.argv[1:]
    live = parse_live(argv)
    banner = live_default_banner()
    if banner:
        print(banner)
    # --map (#39): joue-panes now aliases to `joue --map`, forcing the
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
