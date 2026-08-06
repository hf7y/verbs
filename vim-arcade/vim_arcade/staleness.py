"""Git/gh staleness probing for vim-arcade's launch path -- issue #18, extended
by #46 for post-merge/quit-time sync and a non-conflating dirty check.

Kept curses-free and unit-testable, mirroring how gh_triage.py is
separated from gh_game.py: this module owns every git/gh subprocess call
and the model of "is this checkout stale", gh_game.py owns turning that
into a screen.

Two INDEPENDENT checks, per Zach's 2026-08-04 request and #18's comments:

  1. check_engine_staleness() -- is vim-arcade's OWN checkout (the engine
     running the game) stale? States that must not be conflated:
       - STATE_BEHIND        -- trunk has commits this checkout lacks,
         and this checkout has none trunk lacks -- a plain fast-forward.
       - STATE_DIVERGED      -- BOTH sides have commits the other
         lacks (#46: "behind" and "diverged" are different answers --
         one is `git pull --ff-only`, the other needs a rebase and must
         never be attempted automatically).
       - STATE_WRONG_BRANCH  -- checked out on a branch that isn't trunk.
         `git pull` would report everything fine here; this is a
         different failure (the live case: sitting on `main` while trunk
         is `tmux-pane-mechanic`).
       - STATE_UP_TO_DATE    -- reported as exactly "up to date with
         origin", never a bare "up to date" (issue #18 constraint 3).
     Also STATE_DETACHED (HEAD not on any branch) and STATE_UNKNOWN
     (probe failed/timed out/no remote -- degrade, never block).

  2. check_target_staleness() -- is the repo vim-arcade is being RUN IN (the
     cwd) behind its own origin? Same STATE_* vocabulary minus
     wrong-branch (the target repo's trunk identity isn't vim-arcade's concern
     -- only whether the checked-out branch is behind/diverged from its
     own upstream).

Both never raise and never block on the network past `timeout` seconds --
a hung `gh`/`git fetch` degrades to STATE_UNKNOWN instead of freezing the
TUI (a tool that hangs on launch gets abandoned).

## The dirty-tree check, classified not lumped (issue #46)

The real incident this fixes: a checkout 2 commits behind was refused
with "the tree is dirty -- refusing to update automatically." The entire
dirty tree was `?? .directory`, a KDE/Dolphin litter file. The exact same
fast-forward, run by hand with that file still present, succeeded
cleanly -- the guard was refusing a safe operation over noise.

`EngineStatus`/`TargetStatus` now carry the classification, not just a
bare `dirty` bool (kept for "is anything at all uncommitted" purposes,
but never itself the blocking signal):

  - `tracked_dirty`     -- modified/staged TRACKED files. Always blocks;
    a fast-forward or checkout cannot proceed with local edits in the way.
  - `untracked_blocking` -- untracked files the INCOMING commits would
    actually write to (probed via `git diff --name-only`, i.e. "which
    paths would change" -- not "is git status non-empty"). Blocks, named.
  - `untracked_safe`    -- untracked files the incoming commits never
    touch. Does NOT block -- exactly the `.directory` case. The update
    proceeds and leaves them alone.

`engine_update_blocked_reason`/`target_update_blocked_reason` return a
`refusal.Refusal` (reason + evidence + next action, issue #31's shape --
see `refusal.py`'s module docstring for why both staleness and
merge_safety route through the same one) or `None` when nothing blocks.
"""

import os
import subprocess
import sys
from dataclasses import dataclass, field
from typing import List, Optional

from .refusal import Refusal

DEFAULT_TIMEOUT = 3  # seconds -- short enough that a hung network call
# never reads as "the game froze."

STATE_UP_TO_DATE = "up_to_date"
STATE_BEHIND = "behind"
STATE_DIVERGED = "diverged"
STATE_WRONG_BRANCH = "wrong_branch"
STATE_DETACHED = "detached"
STATE_UNKNOWN = "unknown"

# The exact wording #18 requires -- "up to date with origin", never a
# bare "up to date". Commit 8ef2ecc sat stranded behind a read-only
# deploy key while looking fine from a glance; the extra words are the
# whole point.
UP_TO_DATE_TEXT = "up to date with origin"


class CheckFailed(Exception):
    """Internal signal that a probe step didn't get an answer (command
    failed, timed out, or the binary isn't there). Every public
    check_*_staleness() function catches this and degrades to
    STATE_UNKNOWN rather than letting it propagate -- a probe failure
    must never crash or block the launch path."""


def _run(cmd, cwd, timeout):
    try:
        result = subprocess.run(
            cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise CheckFailed(f"{' '.join(cmd)}: timed out after {timeout}s") from exc
    except (FileNotFoundError, OSError) as exc:
        raise CheckFailed(f"{' '.join(cmd)}: {exc}") from exc
    if result.returncode != 0:
        raise CheckFailed(f"{' '.join(cmd)}: {result.stderr.strip()}")
    return result.stdout.strip()


def _run_lines(cmd, cwd, timeout):
    """Same as `_run`, but returns raw stdout lines with each line's OWN
    leading/trailing whitespace intact -- `_run`'s blanket `.strip()`
    would eat porcelain status's leading space (the "unstaged" column of
    an ' M path' line), silently misparsing the very first entry. Only
    the outer newlines are trimmed."""
    try:
        result = subprocess.run(
            cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise CheckFailed(f"{' '.join(cmd)}: timed out after {timeout}s") from exc
    except (FileNotFoundError, OSError) as exc:
        raise CheckFailed(f"{' '.join(cmd)}: {exc}") from exc
    if result.returncode != 0:
        raise CheckFailed(f"{' '.join(cmd)}: {result.stderr.strip()}")
    return result.stdout.splitlines()


def _current_branch(repo_dir, timeout):
    """Returns (branch_or_none, detached: bool). 'HEAD' from
    rev-parse --abbrev-ref means detached HEAD -- not a real branch."""
    name = _run(["git", "rev-parse", "--abbrev-ref", "HEAD"], repo_dir, timeout)
    if name == "HEAD":
        return None, True
    return name, False


def _status_paths(repo_dir, timeout):
    """(tracked, untracked) path lists parsed from `git status
    --porcelain`. Any code other than '??' means the path is already
    tracked by git (staged, modified, deleted, renamed, ...) -- a rename
    ('R  old -> new') resolves to the post-rename path, the one that
    would actually collide with an incoming write."""
    lines = _run_lines(["git", "status", "--porcelain"], repo_dir, timeout)
    tracked, untracked = [], []
    for line in lines:
        if not line:
            continue
        code, path = line[:2], line[3:]
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        (untracked if code == "??" else tracked).append(path)
    return tracked, untracked


def _is_dirty(repo_dir, timeout):
    tracked, untracked = _status_paths(repo_dir, timeout)
    return bool(tracked or untracked)


def _incoming_touched_paths(repo_dir, ref, timeout):
    """Paths the commits between HEAD and `ref` add/modify/delete -- the
    real probe issue #46 asks for ("checking the incoming commits'
    paths"), not "is git status non-empty". For a pure fast-forward the
    working tree after the update IS ref's tree, so this diff is exactly
    the set of paths that would be written."""
    out = _run(["git", "diff", "--name-only", f"HEAD..{ref}"], repo_dir, timeout)
    return {p for p in out.splitlines() if p}


def _classify_untracked(repo_dir, untracked, compare_ref, timeout):
    """(blocking, safe) split of `untracked` against what `compare_ref`'s
    incoming commits would actually write. `compare_ref=None`, or the
    touched-paths probe itself failing, means "cannot prove safety" --
    treat every untracked file as blocking, the conservative answer
    ("detect automatically, never guess"), never the reverse."""
    if not untracked:
        return [], []
    if compare_ref is None:
        return list(untracked), []
    try:
        touched = _incoming_touched_paths(repo_dir, compare_ref, timeout)
    except CheckFailed:
        return list(untracked), []
    blocking = [p for p in untracked if p in touched]
    safe = [p for p in untracked if p not in touched]
    return blocking, safe


def _dirty_refusal(tracked_dirty, untracked_blocking) -> Optional[Refusal]:
    """The one place that turns a classification into a Refusal (#31's
    shape, via refusal.py) -- both check_engine_staleness's and
    check_target_staleness's blocked-reason functions call this, so a
    wording fix lands in both at once (#42's drift, closed)."""
    if not tracked_dirty and not untracked_blocking:
        return None
    evidence = list(tracked_dirty) + list(untracked_blocking)
    if tracked_dirty and untracked_blocking:
        reason = "the tree is dirty -- tracked changes, and untracked file(s) the update would overwrite"
    elif tracked_dirty:
        reason = "the tree is dirty -- tracked file(s) are modified or staged"
    else:
        reason = "the tree is dirty -- untracked file(s) would be overwritten by the update"
    return Refusal(
        reason=reason,
        evidence=evidence,
        next_action="commit or `git stash push -u -m vim-arcade` the listed file(s), then retry",
    )


def _ahead_behind(repo_dir, ref, timeout):
    """(ahead, behind) commit counts between HEAD and `ref` in one call
    -- ahead>0 and behind>0 together mean diverged (#46: needs a rebase,
    a fast-forward will refuse it anyway), never conflated with a plain
    behind."""
    out = _run(["git", "rev-list", "--left-right", "--count", f"HEAD...{ref}"], repo_dir, timeout)
    parts = out.split()
    ahead = int(parts[0]) if len(parts) > 0 and parts[0] else 0
    behind = int(parts[1]) if len(parts) > 1 and parts[1] else 0
    return ahead, behind


def _default_branch(repo_dir, timeout):
    """Trunk name per GitHub, NOT a local guess -- #18's whole point is
    that `git pull` can't see a trunk that moved to a different branch."""
    return _run(
        ["gh", "repo", "view", "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name"],
        repo_dir, timeout,
    )


def _unique_commits(repo_dir, ref, timeout, limit=5):
    """Commit subjects reachable from `ref` and from NO other local or
    remote-tracking ref -- generalises the 8ef2ecc incident (a commit
    stranded because it existed on exactly one ref, behind a read-only
    deploy key). Used to refuse switching/pulling away from work that
    would otherwise vanish from view."""
    refs_out = _run(
        ["git", "for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"],
        repo_dir, timeout,
    )
    all_refs = [r for r in refs_out.splitlines() if r]
    exclude = [r for r in all_refs if not r.endswith(f"/{ref}")]
    if not exclude:
        # Nothing to exclude against (e.g. a lone local branch with no
        # remote tracking ref) -- rev-list with no --not would list the
        # whole history, which isn't "unique." Bail out empty rather
        # than lie.
        return []
    out = _run(["git", "rev-list", ref, "--not", *exclude], repo_dir, timeout)
    shas = [s for s in out.splitlines() if s][:limit]
    subjects = []
    for sha in shas:
        subj = _run(["git", "log", "-1", "--format=%s", sha], repo_dir, timeout)
        subjects.append(f"{sha[:7]} {subj}")
    return subjects


def merged_pr_summaries(repo_dir, limit=3, timeout=DEFAULT_TIMEOUT):
    """`#15  Integrate #13 + #14, and fix the two defects at their seam`
    style lines -- a merged-PR title summarises "what changed" far
    better than a commit subject (#18/#12: this is why Zach asked for PR
    data specifically, not `git log`)."""
    import json

    try:
        out = _run(
            ["gh", "pr", "list", "--state", "merged", "--limit", str(limit),
             "--json", "number,title,mergedAt"],
            repo_dir, timeout,
        )
    except CheckFailed:
        return []
    try:
        rows = json.loads(out) if out else []
    except ValueError:
        return []
    return [f"#{row['number']}  {row['title']}" for row in rows]


# ---------------------------------------------------------------------------
# Engine staleness -- vim-arcade's own checkout
# ---------------------------------------------------------------------------


@dataclass
class EngineStatus:
    state: str
    message: str
    current_branch: Optional[str] = None
    trunk_branch: Optional[str] = None
    behind: Optional[int] = None
    ahead: Optional[int] = None
    dirty: bool = False
    detached: bool = False
    unique_commits: List[str] = field(default_factory=list)
    merged_prs: List[str] = field(default_factory=list)
    error: Optional[str] = None
    # Issue #46: classified dirt, not a bare bool -- see module docstring.
    tracked_dirty: List[str] = field(default_factory=list)
    untracked_blocking: List[str] = field(default_factory=list)
    untracked_safe: List[str] = field(default_factory=list)


def check_engine_staleness(repo_dir, timeout=DEFAULT_TIMEOUT, remote="origin") -> EngineStatus:
    try:
        tracked, untracked = _status_paths(repo_dir, timeout)
    except CheckFailed as exc:
        return EngineStatus(
            state=STATE_UNKNOWN,
            message="could not check engine staleness (git status failed).",
            error=str(exc),
        )
    dirty = bool(tracked or untracked)

    try:
        branch, detached = _current_branch(repo_dir, timeout)
    except CheckFailed as exc:
        return EngineStatus(
            state=STATE_UNKNOWN,
            message="could not check engine staleness (git rev-parse failed).",
            dirty=dirty,
            tracked_dirty=tracked,
            error=str(exc),
        )

    try:
        trunk = _default_branch(repo_dir, timeout)
    except CheckFailed as exc:
        return EngineStatus(
            state=STATE_UNKNOWN,
            message="could not check for engine updates (gh repo view failed or timed out).",
            current_branch=branch,
            dirty=dirty,
            tracked_dirty=tracked,
            detached=detached,
            error=str(exc),
        )

    if detached:
        ref = _run(["git", "rev-parse", "--short", "HEAD"], repo_dir, timeout)
        try:
            unique = _unique_commits(repo_dir, "HEAD", timeout)
        except CheckFailed:
            unique = []
        return EngineStatus(
            state=STATE_DETACHED,
            message=f"vim-arcade's HEAD is detached at {ref}; trunk is '{trunk}'.",
            trunk_branch=trunk,
            dirty=dirty,
            tracked_dirty=tracked,
            untracked_safe=untracked,
            detached=True,
            unique_commits=unique,
        )

    if branch != trunk:
        try:
            unique = _unique_commits(repo_dir, branch, timeout)
        except CheckFailed:
            unique = []
        return EngineStatus(
            state=STATE_WRONG_BRANCH,
            message=(
                f"vim-arcade is on '{branch}', but the trunk is '{trunk}'. "
                "git pull would not have caught this."
            ),
            current_branch=branch,
            trunk_branch=trunk,
            dirty=dirty,
            tracked_dirty=tracked,
            untracked_safe=untracked,
            unique_commits=unique,
        )

    try:
        _run(["git", "fetch", remote, trunk], repo_dir, timeout)
        ahead, behind = _ahead_behind(repo_dir, "FETCH_HEAD", timeout)
    except CheckFailed as exc:
        return EngineStatus(
            state=STATE_UNKNOWN,
            message="could not check for engine updates (network fetch failed or timed out).",
            current_branch=branch,
            trunk_branch=trunk,
            dirty=dirty,
            tracked_dirty=tracked,
            error=str(exc),
        )

    if ahead > 0 and behind > 0:
        # Diverged -- fast-forward is not a valid answer here (#46: this
        # needs a rebase, a different instruction, never attempted
        # automatically). Untracked classification is irrelevant to a
        # refusal that's unconditional, so it's left unclassified.
        return EngineStatus(
            state=STATE_DIVERGED,
            message=(
                f"vim-arcade has diverged from {remote}/{trunk} "
                f"({ahead} ahead, {behind} behind)."
            ),
            current_branch=branch,
            trunk_branch=trunk,
            behind=behind,
            ahead=ahead,
            dirty=dirty,
            tracked_dirty=tracked,
            untracked_safe=untracked,
        )

    if behind > 0:
        prs = merged_pr_summaries(repo_dir, limit=3, timeout=timeout)
        untracked_blocking, untracked_safe = _classify_untracked(
            repo_dir, untracked, "FETCH_HEAD", timeout,
        )
        return EngineStatus(
            state=STATE_BEHIND,
            message=f"vim-arcade is {behind} commit(s) behind {remote}/{trunk}.",
            current_branch=branch,
            trunk_branch=trunk,
            behind=behind,
            ahead=ahead,
            dirty=dirty,
            tracked_dirty=tracked,
            untracked_blocking=untracked_blocking,
            untracked_safe=untracked_safe,
            merged_prs=prs,
        )

    return EngineStatus(
        state=STATE_UP_TO_DATE,
        message=f"vim-arcade is {UP_TO_DATE_TEXT}.",
        current_branch=branch,
        trunk_branch=trunk,
        behind=0,
        ahead=ahead,
        dirty=dirty,
        tracked_dirty=tracked,
        untracked_safe=untracked,
    )


def engine_update_blocked_reason(status: EngineStatus) -> Optional[Refusal]:
    """None if it's safe to act on `status`; otherwise a Refusal (#31's
    shape) naming why an update/switch must be refused and what to run
    instead -- per #18's dirty-tree/stranded-commit requirements and
    #46's "classify, don't lump" fix."""
    if status.state == STATE_DIVERGED:
        return Refusal(
            reason=(
                f"diverged from trunk ({status.ahead} ahead, {status.behind} behind) "
                "-- a fast-forward cannot apply here"
            ),
            next_action=f"rebase: `git fetch && git rebase {status.trunk_branch}`, resolve conflicts, then retry",
        )
    refusal = _dirty_refusal(status.tracked_dirty, status.untracked_blocking)
    if refusal is not None:
        return refusal
    if status.state in (STATE_WRONG_BRANCH, STATE_DETACHED) and status.unique_commits:
        names = "; ".join(status.unique_commits[:3])
        more = "" if len(status.unique_commits) <= 3 else f" (+{len(status.unique_commits) - 3} more)"
        return Refusal(
            reason=(
                f"'{status.current_branch}' holds commits that exist on no other ref: "
                f"{names}{more}"
            ),
            next_action=(
                f"push '{status.current_branch}' somewhere first (e.g. `git push -u origin "
                f"{status.current_branch}`), then retry"
            ),
        )
    return None


def update_engine(repo_dir, status: EngineStatus, timeout=DEFAULT_TIMEOUT,
                   remote="origin", execv=os.execv, argv=None):
    """Bring the engine checkout to trunk, then re-exec so the code
    actually running is the code just pulled (#18: "updating the engine
    implies re-exec"). Returns a string describing what happened ONLY on
    refusal/no-op; on success it calls execv, which does not return.

    execv/argv are injected so this is testable without actually
    replacing the test process image.
    """
    refusal = engine_update_blocked_reason(status)
    if refusal:
        return f"refused: {refusal.describe()}"

    if status.state == STATE_WRONG_BRANCH or status.state == STATE_DETACHED:
        _run(["git", "checkout", status.trunk_branch], repo_dir, timeout)
    elif status.state == STATE_BEHIND:
        _run(["git", "pull", "--ff-only", remote, status.trunk_branch], repo_dir, timeout)
    else:
        return "nothing to update"

    real_argv = argv if argv is not None else sys.argv
    # PYTHONPATH (set by the `vim-arcade` launcher) and every other env var
    # survive execv untouched -- it replaces the process image but not
    # the environment, so the re-exec'd process resolves vim_arcade the
    # same way the shell script set it up.
    execv(sys.executable, [sys.executable, "-m", "vim_arcade.gh_game", *real_argv[1:]])
    return "re-exec did not happen"  # pragma: no cover -- unreachable if execv is real


# ---------------------------------------------------------------------------
# Target staleness -- the repo vim-arcade is being run IN, not vim-arcade itself
# ---------------------------------------------------------------------------


@dataclass
class TargetStatus:
    state: str
    message: str
    current_branch: Optional[str] = None
    upstream: Optional[str] = None
    behind: Optional[int] = None
    ahead: Optional[int] = None
    dirty: bool = False
    detached: bool = False
    error: Optional[str] = None
    # Issue #46: classified dirt, not a bare bool -- see module docstring.
    tracked_dirty: List[str] = field(default_factory=list)
    untracked_blocking: List[str] = field(default_factory=list)
    untracked_safe: List[str] = field(default_factory=list)


def check_target_staleness(repo_dir, timeout=DEFAULT_TIMEOUT, remote="origin") -> TargetStatus:
    try:
        tracked, untracked = _status_paths(repo_dir, timeout)
    except CheckFailed as exc:
        return TargetStatus(
            state=STATE_UNKNOWN,
            message="could not check this repo's staleness (git status failed -- not a git repo?).",
            error=str(exc),
        )
    dirty = bool(tracked or untracked)

    try:
        branch, detached = _current_branch(repo_dir, timeout)
    except CheckFailed as exc:
        return TargetStatus(
            state=STATE_UNKNOWN,
            message="could not check this repo's staleness (git rev-parse failed).",
            dirty=dirty,
            tracked_dirty=tracked,
            error=str(exc),
        )

    if detached:
        ref = _run(["git", "rev-parse", "--short", "HEAD"], repo_dir, timeout)
        return TargetStatus(
            state=STATE_DETACHED,
            message=f"this repo's HEAD is detached at {ref}.",
            dirty=dirty,
            tracked_dirty=tracked,
            untracked_safe=untracked,
            detached=True,
        )

    try:
        upstream = _run(
            ["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            repo_dir, timeout,
        )
    except CheckFailed as exc:
        return TargetStatus(
            state=STATE_UNKNOWN,
            message=f"this repo's '{branch}' has no upstream to compare against.",
            current_branch=branch,
            dirty=dirty,
            tracked_dirty=tracked,
            error=str(exc),
        )

    try:
        _run(["git", "fetch", remote], repo_dir, timeout)
        ahead, behind = _ahead_behind(repo_dir, upstream, timeout)
    except CheckFailed as exc:
        return TargetStatus(
            state=STATE_UNKNOWN,
            message="could not check this repo for updates (network fetch failed or timed out).",
            current_branch=branch,
            upstream=upstream,
            dirty=dirty,
            tracked_dirty=tracked,
            error=str(exc),
        )

    if ahead > 0 and behind > 0:
        return TargetStatus(
            state=STATE_DIVERGED,
            message=(
                f"this repo has diverged from {upstream} ({ahead} ahead, {behind} behind)."
            ),
            current_branch=branch,
            upstream=upstream,
            behind=behind,
            ahead=ahead,
            dirty=dirty,
            tracked_dirty=tracked,
            untracked_safe=untracked,
        )

    if behind > 0:
        untracked_blocking, untracked_safe = _classify_untracked(
            repo_dir, untracked, upstream, timeout,
        )
        return TargetStatus(
            state=STATE_BEHIND,
            message=f"this repo is {behind} commit(s) behind {upstream}.",
            current_branch=branch,
            upstream=upstream,
            behind=behind,
            ahead=ahead,
            dirty=dirty,
            tracked_dirty=tracked,
            untracked_blocking=untracked_blocking,
            untracked_safe=untracked_safe,
        )

    return TargetStatus(
        state=STATE_UP_TO_DATE,
        message=f"this repo is {UP_TO_DATE_TEXT}.",
        current_branch=branch,
        upstream=upstream,
        behind=0,
        ahead=ahead,
        dirty=dirty,
        tracked_dirty=tracked,
        untracked_safe=untracked,
    )


def target_update_blocked_reason(status: TargetStatus) -> Optional[Refusal]:
    """None if it's safe to fast-forward; otherwise a Refusal (#31's
    shape) naming why, per #46's "classify, don't lump" fix."""
    if status.state == STATE_DIVERGED:
        return Refusal(
            reason=(
                f"diverged from {status.upstream} ({status.ahead} ahead, {status.behind} behind) "
                "-- a fast-forward cannot apply here"
            ),
            next_action=f"rebase: `git fetch && git rebase {status.upstream}`, resolve conflicts, then retry",
        )
    return _dirty_refusal(status.tracked_dirty, status.untracked_blocking)


def update_target(repo_dir, status: TargetStatus, timeout=DEFAULT_TIMEOUT):
    """Fast-forward the target repo (NOT the engine -- no re-exec, this
    checkout isn't the code that's running)."""
    refusal = target_update_blocked_reason(status)
    if refusal:
        return f"refused: {refusal.describe()}"
    if status.state != STATE_BEHIND:
        return "nothing to update"
    _run(["git", "pull", "--ff-only"], repo_dir, timeout)
    return "updated"
