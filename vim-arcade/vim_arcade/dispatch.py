"""Curses-free session-activity model and quit-time self-dev handoff for
joue's GitHub triage game. Mirrors how gh_triage.py keeps the
GitHub-fetching/level-shaping logic separate from gh_game.py's curses
front end: this module owns "what really happened this session" and
"what, if anything, should be handed to the self-dev loop (scheduler)"
-- gh_game.py only calls into it around the `Q` handler, it never
reimplements any of this, and none of it imports curses.

Design constraints this module exists to satisfy (2026-08-04 dispatch
brief):

  1. Only dispatch real work -- an ActivityRecord is only ever built for
     a LIVE action that actually succeeded (see gh_game._run_action).
     DRY RUN and FAILED: actions never reach here, so "is there anything
     to hand off" reduces to "is the activity list non-empty".
  2. The player must be able to see and decline the handoff -- this
     module only *decides and describes* what would be dispatched
     (build_dispatch_plan); it never dispatches anything on its own.
     gh_game.py's confirm screen is what actually calls run_dispatch().
  3. Multi-repo aware in shape: every ActivityRecord carries a repo, and
     resolve_project_for_repo() takes any repo string -- it is not
     hardcoded to vim-arcade. An unregistered repo is reported (project
     is None), never guessed at.
  4. `scheduler` missing from PATH fails loudly (SchedulerNotFound),
     never silently skips the handoff.
"""

import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

SCHEDULER_BIN = "scheduler"

# READ ONLY: this module reads schedule/*.conf to find out which project
# (if any) is registered for a repo -- it never writes to the scheduler
# repo, per this task's scope.
DEFAULT_SCHEDULE_DIR = Path.home() / "Documents" / "Projects" / "scheduler" / "schedule"


class SchedulerNotFound(RuntimeError):
    """`scheduler` isn't on PATH. Raised, not swallowed -- per this
    ecosystem's CLAUDE.md, "a missing guard is a finding, not an
    inconvenience.\""""


@dataclass(frozen=True)
class ActivityRecord:
    """One action that actually happened this session -- LIVE and it
    succeeded. Never constructed for a DRY RUN or a `FAILED:` action."""

    action: str  # "comment" | "close" | "merge" | "create_issue"
    kind: str  # "issue" | "pr"
    repo: Optional[str]  # "owner/name", or None if it couldn't be determined
    number: Optional[int]  # None if gh's output didn't carry one (e.g. some create_issue replies)
    title: str
    detail: str = ""  # comment text, or gh's stdout -- whatever's useful in a follow-up prompt


class SessionActivity:
    """Everything real that happened this session, in the order it
    happened. Only ever gains entries via record() -- dry-run and failed
    actions never call it."""

    def __init__(self):
        self._records: List[ActivityRecord] = []

    def record(self, rec: ActivityRecord) -> None:
        self._records.append(rec)

    @property
    def records(self) -> List[ActivityRecord]:
        return list(self._records)

    def __bool__(self) -> bool:
        return bool(self._records)

    def __len__(self) -> int:
        return len(self._records)


def parse_item_number(text: Optional[str]) -> Optional[int]:
    """Best-effort issue/PR number out of gh's stdout -- `gh issue
    create` prints the new item's URL (".../issues/42") on success.
    Returns None rather than guessing when it doesn't look like one; an
    ActivityRecord with number=None still dispatches fine, it just can't
    say '#42' in the handoff prompt."""
    if not text:
        return None
    m = re.search(r"/(?:issues|pull)/(\d+)\s*$", text.strip())
    return int(m.group(1)) if m else None


def _repo_slug(url_or_slug: Optional[str]) -> Optional[str]:
    """'owner/name' out of a git URL (https or ssh) or an already-bare
    slug. None in, None out."""
    if not url_or_slug:
        return None
    s = re.sub(r"\.git$", "", url_or_slug.strip())
    m = re.search(r"[:/]([^/:]+/[^/:]+)$", s)
    return m.group(1) if m else s


def current_repo(cwd: Optional[str] = None) -> Optional[str]:
    """'owner/name' for the repo joue is running in, via `git remote
    get-url origin` -- no GitHub API call, no credentials needed. None
    if it can't be determined; callers must treat that as "repo
    unknown", never guess vim-arcade."""
    try:
        result = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            capture_output=True,
            text=True,
            cwd=cwd,
            check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        return None
    return _repo_slug(result.stdout.strip())


def _iter_project_confs(schedule_dir: Path):
    if not schedule_dir.exists():
        return
    for path in sorted(schedule_dir.glob("*.conf")):
        if path.name.startswith("_"):
            continue  # host/rotation/runner config, not a project
        yield path


def _parse_conf(path: Path):
    project = None
    repo_url = None
    try:
        text = path.read_text()
    except OSError:
        return None, None
    for line in text.splitlines():
        line = line.strip()
        m = re.match(r'^PROJECT="([^"]*)"', line)
        if m:
            project = m.group(1)
        m = re.match(r'^REPO_URL="([^"]*)"', line)
        if m:
            repo_url = m.group(1)
    return project, repo_url


def resolve_project_for_repo(
    repo: Optional[str], schedule_dir: Path = DEFAULT_SCHEDULE_DIR
) -> Optional[str]:
    """Which scheduler project (if any) is registered for `repo`
    ("owner/name"). READ ONLY -- reads schedule/*.conf, never writes.
    Returns None (not a guess) when nothing is registered, so an
    unregistered repo is reported plainly instead of dispatched to the
    wrong project."""
    target = _repo_slug(repo)
    if not target:
        return None
    for path in _iter_project_confs(schedule_dir):
        project, repo_url = _parse_conf(path)
        if project and _repo_slug(repo_url) == target:
            return project
    return None


_ACTION_LABELS = {
    "create_issue": "created issue",
    "comment": "commented on",
    "close": "closed",
    "merge": "merged",
    "ready": "marked ready",
}


def describe_record(rec: ActivityRecord) -> str:
    label = _ACTION_LABELS.get(rec.action, rec.action)
    ref = f"#{rec.number}" if rec.number is not None else "(number unknown)"
    title = rec.title or "(untitled)"
    return f'{label} {rec.kind} {ref} "{title}"'


def build_prompt(records: List[ActivityRecord]) -> str:
    """A specific, concrete ask for `scheduler -i` -- named items, not a
    vague 'go work the queue'. See build_dispatch_plan for why -i is
    preferred over `scheduler run` here."""
    items = "; ".join(describe_record(r) for r in records)
    return (
        "Follow up on this vim-arcade session's real GitHub activity, just "
        f"handed off at quit time: {items}."
    )


@dataclass(frozen=True)
class DispatchAction:
    """One planned handoff, grouped by repo. project=None means "no
    scheduler project is registered for this repo" -- argv/prompt are
    also None in that case, and gh_game.py must report it rather than
    dispatch it."""

    repo: str
    project: Optional[str]
    argv: Optional[List[str]]
    prompt: Optional[str]
    records: List[ActivityRecord] = field(default_factory=list)


def build_dispatch_plan(
    activity: SessionActivity, schedule_dir: Path = DEFAULT_SCHEDULE_DIR
) -> List[DispatchAction]:
    """Group this session's real activity by repo and decide, per repo,
    what to hand to the self-dev loop. Purely local (never invokes
    `scheduler` itself), so it is safe to call before the player has
    confirmed anything -- this is what the confirm screen renders.

    Always prefers `scheduler -i <project> "<prompt>"`: every session
    that reaches here has concrete items (issue/PR numbers + titles), so
    there is always a specific ask to name, and `-i` names it instead of
    sending the self-dev loop back to general queue-triage (`scheduler
    run`) with no memory of what just happened. `scheduler run` is not
    emitted by this function today -- it stays available as
    dispatch's contract for a future caller with a genuinely non-specific
    "go work the queue" ask (e.g. a batch of only-declined items), which
    the quit-time handoff never has.
    """
    if not activity:
        return []
    by_repo = {}
    for rec in activity.records:
        by_repo.setdefault(rec.repo, []).append(rec)

    plans = []
    for repo, records in by_repo.items():
        project = resolve_project_for_repo(repo, schedule_dir) if repo else None
        if project is None:
            plans.append(
                DispatchAction(
                    repo=repo or "(repo unknown)",
                    project=None,
                    argv=None,
                    prompt=None,
                    records=records,
                )
            )
            continue
        prompt = build_prompt(records)
        argv = [SCHEDULER_BIN, "-i", project, prompt]
        plans.append(
            DispatchAction(repo=repo, project=project, argv=argv, prompt=prompt, records=records)
        )
    return plans


def scheduler_available(scheduler_bin: str = SCHEDULER_BIN) -> bool:
    return shutil.which(scheduler_bin) is not None


def dispatch_one(action: DispatchAction, scheduler_bin: str = SCHEDULER_BIN):
    """Actually invoke `scheduler` for one DispatchAction. Raises
    SchedulerNotFound loudly if the binary isn't on PATH. Never called
    against a real project in this repo's own test suite -- tests point
    scheduler_bin at a temp-PATH echo shim and assert on argv."""
    if action.project is None or action.argv is None:
        raise ValueError(f"cannot dispatch: no scheduler project registered for {action.repo}")
    if shutil.which(scheduler_bin) is None:
        raise SchedulerNotFound(
            f"`{scheduler_bin}` is not on PATH -- cannot hand off to the self-dev loop. "
            "Install/symlink it (see ~/.local/bin) or run it by hand: "
            + " ".join(action.argv)
        )
    return subprocess.run(action.argv, capture_output=True, text=True)


@dataclass(frozen=True)
class DispatchResult:
    action: DispatchAction
    ok: bool
    message: str


def run_dispatch(
    plans: List[DispatchAction], scheduler_bin: str = SCHEDULER_BIN
) -> List[DispatchResult]:
    """Execute every DispatchAction that has a resolved project, in
    order. Never raises for an individual failure -- a failed handoff
    still lets the player see it and still lets `Q` finish quitting;
    only a genuinely programmer-error call (dispatch_one on a plan with
    no project) would raise, and run_dispatch never makes that call."""
    results = []
    for plan in plans:
        if plan.project is None:
            continue
        try:
            proc = dispatch_one(plan, scheduler_bin=scheduler_bin)
        except SchedulerNotFound as exc:
            results.append(DispatchResult(action=plan, ok=False, message=str(exc)))
            continue
        if proc.returncode == 0:
            results.append(
                DispatchResult(action=plan, ok=True, message=proc.stdout.strip() or "dispatched")
            )
        else:
            results.append(
                DispatchResult(
                    action=plan,
                    ok=False,
                    message=f"scheduler exited {proc.returncode}: {proc.stderr.strip()[:200]}",
                )
            )
    return results


@dataclass(frozen=True)
class QuitOutcome:
    """What happened at the quit-time confirm screen -- gh_game.run()
    returns this so main() can print it AFTER curses tears down (inside
    curses, anything printed vanishes on the next erase/refresh)."""

    plans: List[DispatchAction]
    results: List[DispatchResult]
    decision: str  # "none" | "confirmed" | "declined"
    # Issue #46: "on Q, offer to fast-forward the checkout before
    # exiting" -- set only when the player actually pressed 'f' at the
    # quit screen (never automatic). Empty string means nothing to say,
    # same "no news is no news" convention format_quit_report already
    # uses for the dispatch side.
    sync_note: str = ""


def dispatch_summary_lines(plans: List[DispatchAction]) -> List[str]:
    """Plain-text lines describing what would be dispatched -- content
    only, no layout/curses. gh_game.render_dispatch_summary windows this
    against the real terminal size."""
    lines = ["Quit -- hand this session's real GitHub activity to self-dev?"]
    if not plans:
        lines.append("Nothing to dispatch -- no live action succeeded this session.")
        return lines
    for plan in plans:
        if plan.project is None:
            lines.append(f"[SKIP] {plan.repo}: no scheduler project registered -- not dispatched.")
            for rec in plan.records:
                lines.append(f"    - {describe_record(rec)}")
            continue
        lines.append(f"[{plan.project}] {plan.repo}: {len(plan.records)} action(s)")
        for rec in plan.records:
            lines.append(f"    - {describe_record(rec)}")
        lines.append(f"    would run: {' '.join(plan.argv)}")
    return lines


def format_quit_report(outcome: Optional[QuitOutcome]) -> str:
    """What main() prints to real stdout after curses.wrapper() returns
    -- the only place this is visible, since anything printed while
    curses owns the terminal is immediately overwritten."""
    if outcome is None:
        return ""
    sync_prefix = f"vim-arcade: {outcome.sync_note}\n" if outcome.sync_note else ""
    if not outcome.plans:
        return sync_prefix + "vim-arcade: no live GitHub activity this session -- nothing to hand off to self-dev.\n"

    lines = [sync_prefix.rstrip("\n")] if sync_prefix else []
    if outcome.decision == "declined":
        lines.append("vim-arcade: self-dev handoff declined at quit -- nothing was dispatched.")
    else:
        lines.append("vim-arcade: self-dev handoff --")
        for r in outcome.results:
            if r.ok:
                lines.append(f"  [{r.action.project}] dispatched: {' '.join(r.action.argv)}")
                lines.append(f"    -> {r.message}")
                lines.append(
                    f"    check on it: scheduler status {r.action.project}"
                    f"   |   scheduler report {r.action.project}"
                )
            else:
                lines.append(
                    f"  [{r.action.project or r.action.repo}] FAILED to dispatch: {r.message}"
                )
    for p in outcome.plans:
        if p.project is None:
            lines.append(
                f"  [skipped] {p.repo}: no scheduler project registered for this repo "
                "-- not dispatched."
            )
    return "\n".join(lines) + "\n"
