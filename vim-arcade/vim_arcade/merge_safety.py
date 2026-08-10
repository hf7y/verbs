"""Local merge-safety decision for `m` in gh_game.py -- issue #31.

## The incident this exists for

2026-08-04, right after merging #30: pressing `m` on PRs #29, #27, #25
issued three real `gh pr merge` mutations that GitHub refused with
"Pull Request has merge conflicts". All three had been CONFLICTING the
whole time (`gh pr list` already said so) because #30 had landed their
content on trunk under different commits (a hand-written integration,
not a merge of those branches) -- each PR now conflicted with its own
base. `joue` had the information to refuse locally and instead found
out by attempting three real API mutations.

The damage-free outcome was luck, not design: had those same PRs been
superseded but still *applying cleanly* -- no conflict, because nothing
overlapped at the diff-hunk level even though the content is already on
the base -- `m` would have merged them silently and successfully,
corrupting the queue with no error at all. **Conflict is not the safety
mechanism here.** That is why this module always computes the
content-overlap check (see `overlap_fraction` below), not only when
`mergeable == CONFLICTING`.

## Design

Kept curses-free and unit-testable, mirroring how staleness.py is
separated from gh_game.py: this module owns every subprocess call
(one `gh pr view` plus local git plumbing) and the pure decision of
whether `m` may proceed; gh_game.py owns turning that into a screen and
an action-log line, and is the only thing that ever calls
`gh pr merge`.

Two independent signals feed the decision, gathered by `fetch_merge_check`
(the ONE `gh` call per press -- issue #31's explicit budget) plus
`compute_overlap_fraction` (local `git fetch`/`git diff`, not a `gh`
call, mirroring staleness.py's own git-plumbing-is-free-of-the-gh-budget
precedent):

  1. GitHub's own verdict -- `mergeable` / `mergeStateStatus` /
     `isDraft` / `reviewDecision` / `statusCheckRollup`.
  2. Content overlap -- what fraction of the head branch's added lines,
     file by file, already appear verbatim in the base's CURRENT
     version of that file. This is what actually distinguishes
     "superseded" from "conflicts for an unrelated reason": git
     ancestry (`rev-list`) is blind to this once the content lands via
     a squash or a hand-written integration commit rather than a real
     merge of the branch, which is exactly what #30 did. Content
     comparison sees through that. Verified live against #25/#27/#29
     (see tests/test_merge_safety_live.py): staleness.py hit 100%
     overlap, the touched slice of gh_game.py ~96% after later edits
     moved lines around -- comfortably over SUPERSEDED_OVERLAP_THRESHOLD.

Decision priority, most dangerous first: superseded beats a plain
conflict beats draft beats blocked/review/checks beats a title/diff
mismatch (the last is a warning, not a refusal -- see MergeDecision
below). "Never auto-fix" (per #31): every refused code stops `m` from
reaching `gh pr merge` at all; nothing here ever runs `gh pr ready`,
rebases, or edits anything.
"""

import json
import re
import subprocess
from dataclasses import dataclass, field
from typing import Dict, List, Optional

from .refusal import Refusal

DEFAULT_TIMEOUT = 6  # seconds -- short enough a hung network call never
# reads as "the game froze" (same rationale as staleness.DEFAULT_TIMEOUT).

MERGE_VIEW_FIELDS = (
    "number,title,baseRefName,headRefName,isDraft,mergeable,"
    "mergeStateStatus,reviewDecision,statusCheckRollup,files"
)

# Fraction of a head branch's own added lines that must already appear
# verbatim, file by file, in the base's CURRENT content before this
# calls it "superseded" rather than a plain conflict. Calibrated against
# the real #25/#27/#29 incident: 1.0 for a file introduced wholesale
# (staleness.py), ~0.96 for a file trunk kept editing after the fact
# (gh_game.py) -- see tests/test_merge_safety_live.py for the exact
# numbers this was checked against. Deliberately well below 1.0 so later,
# unrelated edits to the same file (e.g. a docstring reflow) don't mask
# a real supersession, and well above what an unrelated PR that merely
# touches the same file would hit by chance.
SUPERSEDED_OVERLAP_THRESHOLD = 0.85

# statusCheckRollup entries carry either `conclusion` (CheckRun) or
# `state` (StatusContext) -- these are the values GitHub uses for "this
# gate did not pass."
_FAILING_CHECK_VALUES = {"FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"}

CODE_CLEAN = "clean"
CODE_SUBSUMED = "subsumed"
CODE_SUPERSEDED = "superseded"
CODE_CONFLICTING = "conflicting"
CODE_DRAFT = "draft"
CODE_CHECKS_FAILING = "checks_failing"
CODE_CHANGES_REQUESTED = "changes_requested"
CODE_REVIEW_REQUIRED = "review_required"
CODE_BLOCKED = "blocked"
CODE_UNKNOWN = "unknown"


class MergeCheckFailed(Exception):
    """Internal signal that a probe step didn't get an answer. Every
    public fetch/compute function catches this and degrades rather than
    letting it propagate -- a failed probe must refuse to merge (fail
    loud, not fail open), never crash the game."""


def _run(cmd, cwd, timeout):
    try:
        result = subprocess.run(
            cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise MergeCheckFailed(f"{' '.join(cmd)}: timed out after {timeout}s") from exc
    except (FileNotFoundError, OSError) as exc:
        raise MergeCheckFailed(f"{' '.join(cmd)}: {exc}") from exc
    if result.returncode != 0:
        raise MergeCheckFailed(f"{' '.join(cmd)}: {result.stderr.strip()}")
    return result.stdout


@dataclass
class MergeCheck:
    """Raw facts about one PR, gathered fresh at `m`-press time (state
    goes stale between the startup fetch and the keypress -- that is
    exactly how the real incident bit). `overlap_fraction` is None when
    it couldn't be computed (offline, branch deleted, etc.) -- absence
    is never silently read as 'not superseded'; see decide()."""

    number: int
    title: str
    base_ref: str
    head_ref: str
    is_draft: bool
    mergeable: str  # "MERGEABLE" | "CONFLICTING" | "UNKNOWN"
    merge_state_status: str  # "CLEAN" | "BLOCKED" | "DIRTY" | "BEHIND" | "UNSTABLE" | "DRAFT" | "HAS_HOOKS" | "UNKNOWN"
    review_decision: str  # "" | "APPROVED" | "REVIEW_REQUIRED" | "CHANGES_REQUESTED"
    failing_checks: List[str] = field(default_factory=list)
    file_paths: List[str] = field(default_factory=list)
    overlap_fraction: Optional[float] = None
    overlap_error: Optional[str] = None  # why overlap_fraction is None, for diagnostics


@dataclass
class MergeDecision:
    """The whole point of this module. `allowed=False` means gh_game.py
    must not build/run a `gh pr merge` command -- the caller enforces
    this by construction (see gh_game.py's `m` handler), not by
    convention. `reason` always names the specific state; `next_action`
    always names what the human should do -- '"Cannot merge" teaches
    nothing' is issue #31's own words. `warning`, when set, does not
    block: it is the title/diff-mismatch case, which requires the human
    to see it and press `m` again rather than a hard refusal."""

    allowed: bool
    code: str
    reason: str
    next_action: str
    warning: Optional[str] = None
    # Issue #46: every refusal here is built from a shared refusal.Refusal
    # (reason + evidence + next_action -- the same shape staleness.py's
    # dirty-tree refusal now uses) so a wording fix to one cannot leave
    # the other behind (#42's "two copies of a truth" drift). `evidence`
    # is exposed here too rather than only living inside `reason`'s text.
    evidence: List[str] = field(default_factory=list)

    @classmethod
    def refuse(cls, code: str, refusal: Refusal, warning: Optional[str] = None) -> "MergeDecision":
        return cls(
            allowed=False, code=code, reason=refusal.reason,
            next_action=refusal.next_action, warning=warning, evidence=refusal.evidence,
        )


def _failing_check_names(rollup) -> List[str]:
    names = []
    for entry in rollup or []:
        state = entry.get("conclusion") or entry.get("state") or ""
        if state.upper() in _FAILING_CHECK_VALUES:
            name = entry.get("name") or entry.get("context") or "a check"
            names.append(name)
    return names


_FILENAME_RE = re.compile(r"[\w][\w\-./]*\.[A-Za-z0-9]+")


def title_diff_mismatch(title: str, file_paths: List[str]) -> Optional[str]:
    """None when the title makes no specific claim about which files
    change (nothing to check), or when every file it names accounts for
    the diff. Otherwise a warning string with the file count -- #31's
    "warn with the file count before proceeding", citing #7 (titled as
    a one-file change to nightly-batch.md, actually 9 files) and #24
    (an unmentioned .claude/FOCUS.md among 5 files).

    Heuristic, not a parser: only fires when the title names at least
    one filename-shaped token AND the diff touches more files than it
    names AND at least one changed file's basename isn't among the
    named ones -- a title that correctly names every file it touches
    never warns, however many files that is.
    """
    named = set(_FILENAME_RE.findall(title))
    if not named:
        return None
    named_basenames = {n.rsplit("/", 1)[-1] for n in named}
    unnamed = [p for p in file_paths if p.rsplit("/", 1)[-1] not in named_basenames]
    if not unnamed or len(file_paths) <= len(named):
        return None
    shown = ", ".join(unnamed[:3])
    more = "" if len(unnamed) <= 3 else f" (+{len(unnamed) - 3} more)"
    return (
        f"title names {len(named)} file(s) but the diff touches "
        f"{len(file_paths)}: includes {shown}{more}"
    )


@dataclass
class OpenPR:
    """Just enough of another open PR to test containment against --
    issue #41. Built from data `gh_triage.fetch_open_items` already
    fetched at startup/refresh (widening that one existing list call,
    same precedent as `base_ref_name`), never a second `gh` call."""

    number: int
    title: str
    head_ref: str


def _is_ancestor(repo_dir: str, ancestor_ref: str, descendant_ref: str, timeout: int) -> bool:
    """`git merge-base --is-ancestor` exits 0 (true) or 1 (false) for a
    real answer either way -- only >1 means it could not be determined
    (bad ref, not fetched, etc). `_run` treats every nonzero exit as a
    failure, which would wrongly turn a real 'false' into an error, so
    this checks the return code directly instead of reusing `_run`."""
    try:
        result = subprocess.run(
            ["git", "merge-base", "--is-ancestor", ancestor_ref, descendant_ref],
            cwd=repo_dir, capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise MergeCheckFailed(f"merge-base --is-ancestor: timed out after {timeout}s") from exc
    except (FileNotFoundError, OSError) as exc:
        raise MergeCheckFailed(f"merge-base --is-ancestor: {exc}") from exc
    if result.returncode in (0, 1):
        return result.returncode == 0
    raise MergeCheckFailed(f"merge-base --is-ancestor: {result.stderr.strip()}")


def check_subsumption(
    repo_dir: str, number: int, head_ref: str, other_open_prs: List[OpenPR], timeout: int = DEFAULT_TIMEOUT,
) -> "tuple[Optional[OpenPR], Optional[str]]":
    """(container, error) -- container is the other open PR whose head
    already contains this PR's head commit (issue #41: PRs #35/#36 were
    both ancestors of #37, which existed specifically to merge them
    together and fix the break where they collide; merging #35/#36
    individually skipped that fix and broke `main`). None, None when
    there's nothing to check or nothing contains this PR; (None, error)
    when it couldn't be determined -- decide()-adjacent callers must
    treat that as 'cannot verify', never as 'not subsumed'.

    Local git only (one batched `git fetch` for every ref involved, then
    one `--is-ancestor` per candidate) -- no `gh` call, same
    git-plumbing-is-free-of-the-gh-budget precedent as
    compute_overlap_fraction. Distinct from that function's job: this
    asks whether this branch is CONTAINED IN a sibling PR that is still
    open, not whether its content already landed on the base."""
    candidates = [pr for pr in other_open_prs if pr.number != number and pr.head_ref]
    if not head_ref or not candidates:
        return None, None
    refs = [head_ref] + [pr.head_ref for pr in candidates]
    try:
        _run(["git", "fetch", "origin", *refs], repo_dir, timeout)
    except MergeCheckFailed as exc:
        return None, str(exc)
    for pr in candidates:
        try:
            contained = _is_ancestor(
                repo_dir, f"origin/{head_ref}", f"origin/{pr.head_ref}", timeout,
            )
        except MergeCheckFailed as exc:
            return None, str(exc)
        if contained:
            return pr, None
    return None, None


def subsumption_map(
    repo_dir: str, open_prs: List[OpenPR], timeout: int = DEFAULT_TIMEOUT,
) -> Dict[int, OpenPR]:
    """Containment for a WHOLE set of open PRs at once, computed with a
    single batched `git fetch` regardless of how many PRs are in the set
    -- issue #41's second acceptance box, "constituent PRs of an open
    integration PR are marked as such in the queue view," which needs
    every PR's containment up front rather than one at a time. Calling
    `check_subsumption` once per PR would re-fetch the same refs
    n times; this fetches once and reuses `_is_ancestor`'s local-only
    check for every pair.

    Returns {pr_number: container} only for PRs that ARE contained --
    a PR with no entry is not (or couldn't be determined, which this
    treats the same as "not contained" since it's a display enrichment,
    not the safety gate: `m`/`A` always re-verify via `check_subsumption`
    before ever refusing a real merge, so a false negative here costs a
    missing marker, never a missed refusal."""
    candidates = [pr for pr in open_prs if pr.head_ref]
    if len(candidates) < 2:
        return {}
    refs = [pr.head_ref for pr in candidates]
    try:
        _run(["git", "fetch", "origin", *refs], repo_dir, timeout)
    except MergeCheckFailed:
        return {}
    result: Dict[int, OpenPR] = {}
    for pr in candidates:
        for other in candidates:
            if other.number == pr.number:
                continue
            try:
                contained = _is_ancestor(
                    repo_dir, f"origin/{pr.head_ref}", f"origin/{other.head_ref}", timeout,
                )
            except MergeCheckFailed:
                continue
            if contained:
                result[pr.number] = other
                break
    return result


def decide(check: MergeCheck) -> MergeDecision:
    """Pure decision, no subprocess involved -- trivially unit-testable
    against a hand-built MergeCheck. Priority, most dangerous first:
    superseded (the case that actually happened, and the one a
    conflict-only check would miss) > plain conflict > draft > gate
    (blocked/review/checks) > clean, with title/diff mismatch as a
    non-blocking warning layered onto whatever the primary code is."""
    warning = title_diff_mismatch(check.title, check.file_paths)

    if check.overlap_fraction is not None and check.overlap_fraction >= SUPERSEDED_OVERLAP_THRESHOLD:
        pct = round(check.overlap_fraction * 100)
        return MergeDecision.refuse(
            CODE_SUPERSEDED,
            Refusal(
                reason=(
                    f"this looks superseded -- {pct}% of its lines already appear "
                    f"on '{check.base_ref}'"
                ),
                next_action="close it, do not merge it",
            ),
            warning=warning,
        )

    if check.mergeable == "CONFLICTING" or check.merge_state_status == "DIRTY":
        return MergeDecision.refuse(
            CODE_CONFLICTING,
            Refusal(
                reason=f"conflicts with '{check.base_ref}'",
                next_action="rebase and resolve -- retrying will not help",
            ),
            warning=warning,
        )

    if check.is_draft or check.merge_state_status == "DRAFT":
        return MergeDecision.refuse(
            CODE_DRAFT,
            Refusal(
                reason="this PR is a draft",
                next_action=f"run `gh pr ready {check.number}` first (separate key -- never automatic)",
            ),
            warning=warning,
        )

    if check.failing_checks:
        names = ", ".join(check.failing_checks[:3])
        more = "" if len(check.failing_checks) <= 3 else f" (+{len(check.failing_checks) - 3} more)"
        return MergeDecision.refuse(
            CODE_CHECKS_FAILING,
            Refusal(
                reason=f"failing check(s): {names}{more}",
                next_action="fix the check(s) and push, then re-check",
                evidence=list(check.failing_checks),
            ),
            warning=warning,
        )

    if check.review_decision == "CHANGES_REQUESTED":
        return MergeDecision.refuse(
            CODE_CHANGES_REQUESTED,
            Refusal(
                reason="changes were requested during review",
                next_action="address the review feedback and re-request review",
            ),
            warning=warning,
        )

    if check.review_decision == "REVIEW_REQUIRED" or check.merge_state_status == "BLOCKED":
        return MergeDecision.refuse(
            CODE_REVIEW_REQUIRED if check.review_decision == "REVIEW_REQUIRED" else CODE_BLOCKED,
            Refusal(
                reason=(
                    "review is required and has not happened yet"
                    if check.review_decision == "REVIEW_REQUIRED"
                    else "a required status is blocking the merge"
                ),
                next_action="get the required review/status, then re-check",
            ),
            warning=warning,
        )

    if check.mergeable == "UNKNOWN" or check.merge_state_status == "UNKNOWN":
        return MergeDecision.refuse(
            CODE_UNKNOWN,
            Refusal(
                reason="GitHub has not finished computing mergeability yet",
                next_action="wait a moment and re-check before merging (walk away and back, or press r)",
            ),
            warning=warning,
        )

    return MergeDecision(
        allowed=True,
        code=CODE_CLEAN,
        reason=f"mergeable against '{check.base_ref}'",
        next_action="",
        warning=warning,
    )


def fetch_merge_check(number: int, repo: Optional[str] = None, timeout: int = DEFAULT_TIMEOUT) -> MergeCheck:
    """The ONE `gh` call per `m` press (issue #31's explicit budget --
    no extra `gh` calls at startup, one call for one item at press
    time). Raises MergeCheckFailed on any subprocess problem; callers
    must treat that as "cannot verify, refuse" rather than "assume
    clean" (see gh_game.py's `m` handler)."""
    repo_args = ["--repo", repo] if repo else []
    out = _run(
        ["gh", "pr", "view", str(number), "--json", MERGE_VIEW_FIELDS, *repo_args],
        None, timeout,
    )
    data = json.loads(out)
    return MergeCheck(
        number=number,
        title=data.get("title") or "",
        base_ref=data.get("baseRefName") or "",
        head_ref=data.get("headRefName") or "",
        is_draft=bool(data.get("isDraft")),
        mergeable=data.get("mergeable") or "UNKNOWN",
        merge_state_status=data.get("mergeStateStatus") or "UNKNOWN",
        review_decision=data.get("reviewDecision") or "",
        failing_checks=_failing_check_names(data.get("statusCheckRollup")),
        file_paths=[f.get("path", "") for f in (data.get("files") or [])],
    )


def compute_overlap_fraction(
    repo_dir: str, base_ref: str, head_ref: str, file_paths: List[str], timeout: int = DEFAULT_TIMEOUT,
) -> "tuple[Optional[float], Optional[str]]":
    """(fraction, error). Local git only -- not a `gh` call, so it does
    not count against the one-call budget (same precedent as
    staleness.py's own `git fetch`). Fetches `base_ref`/`head_ref` fresh
    from origin, then for each changed file compares the head branch's
    ADDED lines (relative to their merge-base, i.e. what this branch
    itself contributed) against the base's CURRENT content for that
    file, verbatim line-for-line. A high fraction means the branch's
    own contribution already exists on the base under different
    commits -- exactly the #30 shape, which git ancestry cannot see.

    Returns (None, reason) rather than raising or guessing when it
    can't get an answer (offline, head branch deleted, no files) --
    decide() then falls through to the conflict/clean codes on GitHub's
    own verdict alone, same "degrade, never lie" discipline as
    staleness.py.
    """
    if not file_paths:
        return None, "no files to compare"
    try:
        _run(["git", "fetch", "origin", base_ref, head_ref], repo_dir, timeout)
        merge_base = _run(
            ["git", "merge-base", f"origin/{base_ref}", f"origin/{head_ref}"], repo_dir, timeout,
        ).strip()
    except MergeCheckFailed as exc:
        return None, str(exc)

    total_added = 0
    total_matched = 0
    for path in file_paths:
        try:
            diff_out = _run(
                ["git", "diff", merge_base, f"origin/{head_ref}", "--", path], repo_dir, timeout,
            )
        except MergeCheckFailed:
            continue
        added = [
            line[1:] for line in diff_out.splitlines()
            if line.startswith("+") and not line.startswith("+++") and line[1:].strip()
        ]
        if not added:
            continue
        try:
            base_content = _run(["git", "show", f"origin/{base_ref}:{path}"], repo_dir, timeout)
        except MergeCheckFailed:
            base_lines: set = set()
        else:
            base_lines = set(base_content.splitlines())
        total_added += len(added)
        total_matched += sum(1 for line in added if line in base_lines)

    if total_added == 0:
        return None, "branch contributes no added lines to compare"
    return total_matched / total_added, None


def check_mergeability(
    number: int, repo_dir: str, repo: Optional[str] = None, timeout: int = DEFAULT_TIMEOUT,
    other_open_prs: Optional[List[OpenPR]] = None,
) -> MergeDecision:
    """Convenience wrapper gh_game.py actually calls: one `gh pr view`
    plus the local overlap probe, folded into one MergeDecision. A
    fetch failure refuses rather than allowing -- an unverifiable PR is
    not a mergeable one.

    `other_open_prs`, when given, is checked FIRST (issue #41) -- most
    dangerous first, same ordering principle as decide() itself: a PR
    already contained in a still-open sibling is the case that actually
    broke `main` (#35/#36 both applied cleanly against `main`, so every
    check decide() runs today would have said "clean"). A subsumption
    probe that can't get an answer degrades to the ordinary checks below
    rather than refusing on its own -- same "a failed probe must never
    trap a real merge" stance compute_overlap_fraction already takes,
    not the harder "unverifiable = refuse" stance the primary `gh pr
    view` fetch above takes, because this is a secondary, best-effort
    signal layered on top of a fetch that already succeeded."""
    try:
        check = fetch_merge_check(number, repo=repo, timeout=timeout)
    except MergeCheckFailed as exc:
        return MergeDecision(
            allowed=False,
            code=CODE_UNKNOWN,
            reason=f"could not verify mergeability ({exc})",
            next_action="re-check (walk away and back, or press r) before merging",
        )

    if other_open_prs:
        container, _subsumption_error = check_subsumption(
            repo_dir, number, check.head_ref, other_open_prs, timeout=timeout,
        )
        if container is not None:
            return MergeDecision.refuse(
                CODE_SUBSUMED,
                Refusal(
                    reason=f"contained in #{container.number} '{container.title}'",
                    next_action=f"merge #{container.number} instead, then close this",
                ),
                warning=title_diff_mismatch(check.title, check.file_paths),
            )

    overlap, error = compute_overlap_fraction(
        repo_dir, check.base_ref, check.head_ref, check.file_paths, timeout=timeout,
    )
    check.overlap_fraction = overlap
    check.overlap_error = error
    return decide(check)
