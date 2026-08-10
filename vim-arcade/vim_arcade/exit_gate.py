"""Q's exit gate -- issue #10's core feature. `Q` must refuse to quit
while real work in the repo joue is running in (the one being triaged,
`os.getcwd()` -- same repo staleness.check_target_staleness already
looks at) is unlanded: a dirty tree, commits that never reached origin,
or a branch that exists on this host only.

Per #10's decision (Zach, 2026-08-04): unpushed/dirty is blocking; a
remote that has merely moved on is informational, never blocking. This
module doesn't grow a second copy of "is this tree durable" to draw that
line -- it calls `closeout-lint --repo <path> --strict`, the SAME
mechanism session closeout already uses elsewhere in this ecosystem
(realisateur's closeout-lint.sh), whose --repo mode exists for exactly
this "is THIS one tree durable" question and already treats a moved
remote as out of scope (it only checks the local tree against its own
origin ref, never against how far origin has moved ahead).

Kept curses-free and unit-testable, same boundary staleness.py and
dispatch.py already draw around gh_game.py's curses front end.
"""

import json
import shutil
import subprocess
from dataclasses import dataclass, field
from typing import List, Optional

CLOSEOUT_LINT_BIN = "closeout-lint"
DEFAULT_TIMEOUT = 5

# closeout-lint's own exit code table (bin/closeout-lint.sh): 0 clean,
# 1 --strict and at least one FLAG, 6 --strict and a domain was BLIND
# (existed but was not examined -- e.g. a linked worktree). Both 1 and 6
# mean "do not treat this tree as landed."
_BLOCKING_EXIT_CODES = (1, 6)


@dataclass(frozen=True)
class ExitGateStatus:
    blocked: bool
    reason: Optional[str] = None
    flags: List[str] = field(default_factory=list)
    tool_missing: bool = False
    raw_output: str = ""


def check_unlanded_work(
    repo_dir, timeout=DEFAULT_TIMEOUT, closeout_lint_bin=CLOSEOUT_LINT_BIN, run=subprocess.run
) -> ExitGateStatus:
    """Never raises and never blocks on a probe failure -- a missing
    binary, a timeout, or an unexpected exit code degrades to "not
    blocked" (with `reason` explaining why the gate couldn't check),
    same "a probe failure must never crash or block" stance
    staleness.py already takes. Only a real, successfully-read FLAG/BLIND
    from closeout-lint itself blocks the quit."""
    if shutil.which(closeout_lint_bin) is None:
        return ExitGateStatus(
            blocked=False,
            tool_missing=True,
            reason=(
                f"`{closeout_lint_bin}` is not on PATH -- cannot check for unlanded "
                "work; quitting without the exit gate."
            ),
        )

    try:
        result = run(
            [closeout_lint_bin, "--repo", repo_dir, "--strict"],
            cwd=repo_dir, capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return ExitGateStatus(
            blocked=False,
            reason=f"{closeout_lint_bin} timed out after {timeout}s -- quitting without the exit gate.",
        )
    except OSError as exc:
        return ExitGateStatus(
            blocked=False,
            reason=f"{closeout_lint_bin} failed to run ({exc}) -- quitting without the exit gate.",
        )

    flags = [
        line.strip() for line in result.stdout.splitlines()
        if "FLAG [" in line or "BLIND [" in line
    ]

    if result.returncode == 0:
        return ExitGateStatus(blocked=False, raw_output=result.stdout)

    if result.returncode in _BLOCKING_EXIT_CODES:
        if flags:
            shown = "; ".join(flags[:3])
            more = "" if len(flags) <= 3 else f" (+{len(flags) - 3} more)"
            reason = shown + more
        else:
            tail = result.stdout.strip().splitlines()
            reason = tail[-1] if tail else f"closeout-lint exited {result.returncode}"
        return ExitGateStatus(blocked=True, reason=reason, flags=flags, raw_output=result.stdout)

    # An unexpected exit code (e.g. 2, closeout-lint's own usage error) is
    # our bug or a misconfigured environment, not evidence of unlanded
    # work -- never trap the player over it.
    return ExitGateStatus(
        blocked=False,
        reason=f"closeout-lint exited unexpectedly ({result.returncode}) -- quitting without the exit gate.",
        raw_output=result.stdout,
    )


@dataclass(frozen=True)
class WorktreeCandidate:
    """One linked worktree (`git worktree list --porcelain`), classified
    for whether Q's exit gate can clean it up in-game without ever
    leaving curses: `removable` only when the tree is clean AND its
    branch's content is already landed -- either a true ancestor of the
    main tree's HEAD (fast-forward/real merge) or GitHub reports a
    merged PR from that branch (the common case for a squash-merge,
    where the branch tip is never a literal ancestor even though
    nothing in it is unlanded -- the actual shape of the
    `rescue/tmux-pane-mechanic` worktree that motivated this). A dirty
    or unmerged worktree is reported,
    never removed; that one still has to be landed by hand. This is the
    'solvable in game' answer to BLIND [worktrees] -- closeout-lint's
    own --repo mode deliberately does not recurse into linked worktrees
    (see the module docstring), so this is the first thing in the
    ecosystem that actually looks."""

    path: str
    branch: str
    clean: bool
    merged: bool

    @property
    def removable(self):
        return self.clean and self.merged


def _is_landed(main_tree, branch_name, timeout, run):
    """Is `branch_name`'s content already in `main_tree`'s HEAD? Tries
    the cheap true-ancestor check first (fast-forward or a real, non-
    squash merge). A squash-merged PR's branch tip is never a literal
    ancestor even though nothing in it is unlanded -- comparing trees
    to detect that is unreliable once other, unrelated commits have
    since touched the same files (the merge-base can be arbitrarily far
    back), so this asks GitHub itself instead: `gh pr list --head
    <branch> --state merged`, the same source of truth gh_triage.py
    already reads live issue/PR state from elsewhere in this module's
    ecosystem. No `gh` on PATH, or no PR at all (a branch pushed
    straight without one), degrades to False -- not landed, so not
    removable -- same "a probe failure must never crash or over-claim"
    stance as the rest of this module."""
    try:
        ancestor = run(
            ["git", "merge-base", "--is-ancestor", branch_name, "HEAD"],
            cwd=main_tree, capture_output=True, text=True, timeout=timeout,
        )
        if ancestor.returncode == 0:
            return True
    except (subprocess.TimeoutExpired, OSError):
        return False

    if shutil.which("gh") is None:
        return False
    try:
        pr = run(
            ["gh", "pr", "list", "--head", branch_name, "--state", "merged", "--json", "number"],
            cwd=main_tree, capture_output=True, text=True, timeout=timeout,
        )
    except (subprocess.TimeoutExpired, OSError):
        return False
    if pr.returncode != 0:
        return False
    try:
        return len(json.loads(pr.stdout or "[]")) > 0
    except ValueError:
        return False


def list_worktree_candidates(repo_dir, timeout=DEFAULT_TIMEOUT, run=subprocess.run):
    """Never raises; any probe failure yields an empty list -- same
    "a probe failure must never crash or block" stance check_unlanded_work
    takes. An empty list just means the in-game cleanup screen has
    nothing to offer, not that the gate itself lies about being
    blocked."""
    try:
        result = run(
            ["git", "worktree", "list", "--porcelain"],
            cwd=repo_dir, capture_output=True, text=True, timeout=timeout,
        )
    except (subprocess.TimeoutExpired, OSError):
        return []
    if result.returncode != 0:
        return []

    entries = []
    current = None
    for line in result.stdout.splitlines():
        if line.startswith("worktree "):
            if current is not None:
                entries.append(current)
            current = {"path": line[len("worktree "):].strip()}
        elif line.startswith("branch ") and current is not None:
            current["branch"] = line[len("branch "):].strip()
    if current is not None:
        entries.append(current)

    if not entries:
        return []
    main_tree = entries[0]["path"]

    candidates = []
    for entry in entries[1:]:  # entries[0] is the main tree itself
        path = entry["path"]
        branch = entry.get("branch", "")
        branch_name = branch[len("refs/heads/"):] if branch.startswith("refs/heads/") else branch

        clean = False
        try:
            status_result = run(
                ["git", "status", "--porcelain"],
                cwd=path, capture_output=True, text=True, timeout=timeout,
            )
            clean = status_result.returncode == 0 and not status_result.stdout.strip()
        except (subprocess.TimeoutExpired, OSError):
            clean = False

        merged = _is_landed(main_tree, branch_name, timeout, run) if branch_name else False

        candidates.append(
            WorktreeCandidate(path=path, branch=branch_name, clean=clean, merged=merged)
        )
    return candidates


def remove_worktree(repo_dir, path, timeout=DEFAULT_TIMEOUT, run=subprocess.run):
    """`git worktree remove <path>` -- only ever called by gh_game.py on
    a candidate list_worktree_candidates already marked `removable`
    (clean + merged), never on raw player input. Returns (ok, message)
    instead of raising so the in-game cleanup screen can show a failure
    inline rather than crashing the game."""
    try:
        result = run(
            ["git", "worktree", "remove", path],
            cwd=repo_dir, capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return False, f"git worktree remove timed out after {timeout}s"
    except OSError as exc:
        return False, f"git worktree remove failed to run ({exc})"
    if result.returncode != 0:
        tail = (result.stderr or result.stdout).strip().splitlines()
        return False, tail[-1] if tail else f"git worktree remove exited {result.returncode}"
    return True, f"removed {path}"


def abandoned_work_issue_command(status: ExitGateStatus):
    """The `gh` command line that files what `Q!` forced past -- built,
    not run, so gh_game.py can hand it to `_run_action` the same way
    every other action command (close_command, merge_command, ...) is:
    logged-only in DRY RUN, only actually filed and recorded into
    session activity when `live`. A quit-time filing that ran for real
    even in a dry-run practice session would be a real surprise GitHub
    issue nobody asked for -- exactly the inconsistency `_run_action`
    exists to prevent everywhere else in this module."""
    lines = [f"- {line}" for line in (status.flags or [status.reason or "unlanded work"])]
    body = "`Q!` forced past the exit gate with unlanded work still in the tree:\n\n" + "\n".join(lines)
    return ["gh", "issue", "create", "--title", "Q! abandoned unlanded work", "--body", body]
