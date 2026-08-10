"""Does this clone's cached `origin/HEAD` still agree with the remote?

Issue #61's root cause, twice over. A clone caches the remote's default
branch once, at clone time, in `refs/remotes/origin/HEAD`. Nothing ever
refreshes it -- not `git fetch`, not `git pull`. When the repo's default
branch changes on GitHub, every existing clone keeps pointing at the old
one, silently, forever, until someone runs `git remote set-head origin -a`
by hand.

Two clones on host `monkey` were stale that way at once: the cached ref
said `tmux-pane-mechanic` while `git remote show origin` -- which asks
GitHub live -- said `main`. Anything that resolves "the default branch"
from the cached ref (the nightly-batch wrapper does, when BRANCH is
unset) therefore worked on, committed to, and pushed a side branch for
four passes, reporting rc=0 each time. Nothing asked the one question
that would have caught it: do these two answers agree?

That question is this module.

## Why it cannot answer "probably fine"

`check_origin_head` has exactly one way to return ok=True: both values
were read successfully AND they are equal. A missing ref, an offline
remote, a timeout, a git that is not installed -- every one of those is
UNKNOWN, which is not ok, and whose CLI exit code is non-zero.

This is deliberate and is the whole point. The failure this guard exists
to catch is a check that could not run reading as a check that passed;
degrading to ok=True on a probe error would rebuild that failure inside
the guard against it. A guard that cannot see must say it cannot see.

Kept subprocess-injectable and curses-free, the same boundary
exit_gate.py and staleness.py already draw.
"""

import subprocess
from dataclasses import dataclass
from typing import Optional

DEFAULT_TIMEOUT = 15

#: Both values read, and they agree. The only ok state.
MATCH = "MATCH"
#: Both values read, and they disagree. This clone is stale.
MISMATCH = "MISMATCH"
#: At least one value could not be read. NOT a pass.
UNKNOWN = "UNKNOWN"


@dataclass(frozen=True)
class OriginHeadCheck:
    status: str
    cached: Optional[str] = None
    live: Optional[str] = None
    reason: str = ""

    @property
    def ok(self) -> bool:
        return self.status == MATCH

    @property
    def exit_code(self) -> int:
        """0 only for MATCH. 1 for a real disagreement, 2 for "could not
        tell" -- distinguished so a caller can page differently, never so
        one of them can be treated as success."""
        if self.status == MATCH:
            return 0
        if self.status == MISMATCH:
            return 1
        return 2

    def message(self) -> str:
        if self.status == MATCH:
            return f"origin/HEAD ok: cached and remote both say '{self.cached}'"
        if self.status == MISMATCH:
            return (
                f"origin/HEAD STALE: this clone's cached refs/remotes/origin/HEAD "
                f"says '{self.cached}', but the remote's live default branch is "
                f"'{self.live}'. Anything resolving the default branch from the "
                f"cache is working on the wrong branch (issue #61). "
                f"Fix: git remote set-head origin -a"
            )
        return f"origin/HEAD UNDETERMINED (not a pass): {self.reason}"


def _git(repo_dir, args, timeout, run):
    return run(
        ["git", "-C", str(repo_dir)] + list(args),
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def read_cached_head(repo_dir, timeout=DEFAULT_TIMEOUT, run=subprocess.run) -> Optional[str]:
    """The locally cached default branch, short name, or None.

    `git symbolic-ref refs/remotes/origin/HEAD` prints e.g.
    `refs/remotes/origin/main`; it exits non-zero when the ref is absent
    (a clone made with --no-checkout, or one where it was deleted).
    """
    try:
        proc = _git(repo_dir, ["symbolic-ref", "refs/remotes/origin/HEAD"], timeout, run)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    ref = (proc.stdout or "").strip()
    prefix = "refs/remotes/origin/"
    if not ref.startswith(prefix):
        return None
    branch = ref[len(prefix):]
    return branch or None


def read_live_head(repo_dir, timeout=DEFAULT_TIMEOUT, run=subprocess.run) -> Optional[str]:
    """The remote's own default branch, short name, or None.

    `git remote show origin` contacts the remote, so this is the live
    answer, not another cache. Its "  HEAD branch: main" line is the one
    piece we want. A network failure, an auth failure or a timeout all
    land here as None -- which the caller must treat as UNKNOWN, never as
    agreement.
    """
    try:
        proc = _git(repo_dir, ["remote", "show", "origin"], timeout, run)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    for line in (proc.stdout or "").splitlines():
        stripped = line.strip()
        if stripped.startswith("HEAD branch:"):
            branch = stripped[len("HEAD branch:"):].strip()
            # git prints "(unknown)" for a remote whose HEAD it could not
            # resolve -- that is an absence, not a branch name.
            if not branch or branch == "(unknown)":
                return None
            return branch
    return None


def check_origin_head(repo_dir, timeout=DEFAULT_TIMEOUT, run=subprocess.run) -> OriginHeadCheck:
    cached = read_cached_head(repo_dir, timeout=timeout, run=run)
    live = read_live_head(repo_dir, timeout=timeout, run=run)

    if cached is None and live is None:
        return OriginHeadCheck(
            UNKNOWN,
            reason=(
                "could read NEITHER the cached refs/remotes/origin/HEAD nor the "
                "remote's live HEAD branch (not a git repo, no origin remote, "
                "git missing, or the remote is unreachable)"
            ),
        )
    if cached is None:
        return OriginHeadCheck(
            UNKNOWN,
            live=live,
            reason=(
                "could not read this clone's cached refs/remotes/origin/HEAD "
                f"(the remote's live HEAD branch is '{live}'). Run: "
                "git remote set-head origin -a"
            ),
        )
    if live is None:
        return OriginHeadCheck(
            UNKNOWN,
            cached=cached,
            reason=(
                "could not reach the remote to read its live HEAD branch, so the "
                f"cached value '{cached}' could not be checked against anything"
            ),
        )
    if cached == live:
        return OriginHeadCheck(MATCH, cached=cached, live=live)
    return OriginHeadCheck(MISMATCH, cached=cached, live=live)
