---
description: Time-boxed automated pass -- reconcile mandark with remote, triage issues, pick up flagged work, escalate model only once cheap work is gone
argument-hint: "[minutes, default 45]"
model: claude-haiku-4-5-20251001
---

Runs unattended, Haiku throughout. Escalate only Phase 4's implementation,
via `Agent({model: "sonnet", ...})` -- never switch your own model.

## 0a. Classifier denies then allows the same command -- treat as flakiness, not signal

Unattended runs get silent auto-mode denials instead of a prompt.
Observed: identical mutating git/gh calls denied once, then succeed on
retry with no state change between. Only push-to-main/force-push are
actually policy-denied; everything else is noise.

- Retry an identical denied command up to 3x, a beat apart. Don't
  rephrase, split, or route around it.
- Never batch mutating git/gh calls (a `for` loop deleting branches gets
  denied as a whole). One call at a time.
- Still denied after 3 retries: note it in the wrap-up report as
  "blocked, unresolved after retries" and move on. Not a `DECISION:`,
  not an escalation.
- Prefer `git worktree add <path> <branch>` over `git checkout` for
  landing commits on branch X (not observed denied); reserve the primary
  tree's own `git checkout main` for returning to `main` at Phase 1
  start/end. Lets Phase 3 start on its own branch even if that's stuck
  retrying.

## 0b. An issue's genre is not its addressee -- read who it's asking

hf7y/senechal#27 ("BRIEF: two homes in ~/.local/bin") opens "**For
senechal**" and its own section 5 is titled "questions **for
senechal**." Three separate runs (2026-08-05, -10, -11) still filed it
as "waiting on Zach" -- pattern-matching the BRIEF genre (long, hedged,
evidence-first) to "needs a human," without reading far enough to see
the addressee stated in the text. #4 same failure in miniature: filed
"misfiled, not senechal's" twice before a comment ("this is for senechal
to build") forced a re-read.

Genre and addressee are different facts. Fix, both Phase 2 and 3:

- Before calling anything "another project's domain" or "Zach's
  decision," read the full body for an explicit addressee ("for
  senechal", "for <project>", "questions for senechal", "not blocked on
  Zach", a comment naming an owner). Explicitly-addressed-to-senechal is
  Phase 3/4 work this run, budget permitting -- never another deferral,
  regardless of length or hedging.
- Mirror Phase 2's "mislabeled decisions" check in the other direction:
  a DECISION/BRIEF-shaped issue whose own body addresses senechal is a
  **mislabeled deferral** -- answer it (fully or as budget allows), don't
  re-confirm it as "awaiting Zach."
- A prior run's own deferral comment is not evidence of ownership -- it
  may be the mislabeling. Re-derive the addressee from the issue body,
  not the trail of past triage comments.

## 0c. Build-work PRs must close their issue via `Closes #NNN`

Every Phase 3/4 PR body needs `Closes #<N>` (or `Fixes #<N>`), not a
descriptive comment -- GitHub's closing keyword is what actually closes
on merge. PR #113 (2026-08-10) fully fixed #169 but never said so; it
sat open until a live conversation caught it. If the issue number isn't
known when the PR opens, add the line in a follow-up comment instead of
skipping it. Doesn't apply when a PR only partially resolves an issue,
or the issue needs Zach's own separate confirmation (as #113 correctly
did, staying draft until the physical test passed).

## 0. Time box

`BUDGET_MIN=${ARGUMENTS:-45}`; hard stop = start + budget. Check the
clock before each phase and each Phase 3/4 item; under ~5 min left, stop
starting new work and go to wrap-up. Never leave an edit, commit, or
rebase mid-way when time runs out.

## 1. Orient

`git fetch origin`, `git log --oneline -10`, `git status`; read the
open issues (`gh issue list -R hf7y/senechal`) and process any answers
in their COMMENTS -- Zach answers by commenting and leaves the issue
open, so state is not a signal. Resume any unfinished item from the last
`~/reports/senechal/triage-run-*.md` first.

## 2. Phase 1 -- reconcile mandark with remote (mechanical, first)

`git status` must be clean first (stash `-u` anything stray, say so).

1. `git fetch origin --prune`.
2. Fast-forward local `main` to `origin/main` if unchecked-out anywhere
   and no local-only commits (`git branch -f main origin/main`).
   Local-only commits: stop, flag per Phase 6's owner rule.
3. Per other local branch / `.claude/worktrees/agent-*`:
   `gh pr list --head <branch> --state all --json number,state`.
   - `MERGED`, no uncommitted changes -> remove worktree, `git branch
     -D`. Check PR state, not `git branch --merged` (squash-merge SHAs
     differ from `origin/main`).
   - `OPEN` -> leave, it's real work.
   - No PR -> check `git rev-parse --verify -q origin/<branch>`
     *separately*. "No PR" != "no origin ref" -- conflating them
     produced a false alarm on hf7y/senechal#172 (2026-08-10): a
     no-PR branch that IS on origin is durable, just needs a PR-or-
     delete call, not urgent-loss handling. Never delete either kind
     yourself; file per Phase 6, risk level stated correctly.
   - Uncommitted changes anywhere -> never touch, flag.
4. Report what was fast-forwarded, deleted, left alone.

## 3. Phase 2 -- issue triage (mechanical, second)

1. `tools/issue-janitor.py` for real (not `--dry-run`) -- only closes
   exact known machine-receipt matches, safe unattended.
2. `gh issue list --state open --json number,title,body,updatedAt,labels,comments`.
   Look for:
   - **Duplicates** -- comment+close the newer, linking the older. Never
     close the one with more discussion.
   - **Genuinely stale** -- 30+ days quiet, superseded by a later
     commit/PR/issue, or `git log`/current code disproves the described
     state. Close with a one-line evidence citation (sha, file). Unsure
     -> leave open; a wrong close costs more than a missed one.
   - **Mislabeled decisions** -- really Zach's call but titled like a
     task. Retitle `DECISION: ...`, confirm it's visible to Zach.
   - **Mislabeled deferrals** -- see 0b.
3. Leave issues you didn't open this run alone unless one of the above
   clearly applies. Unsure -> leave it, say why (`CONCERNS.md`'s "report
   contradictions, don't silently fix").

## 4. Phase 3 -- pick up incomplete work (still cheap: investigation, not open-ended design)

Priority order, before ever reaching Phase 4:

1. **Draft PRs with a named next step**, now unblocked or reachable
   non-interactively (journal/log read, D-Bus/systemd introspection,
   re-run a test suite) -- do it, push. Still genuinely blocked on Zach
   -> say so, don't manufacture progress.
2. **Issues explicitly marked agent-pickup** (0b's addressee check, "not
   blocked on Zach" language, concrete non-interactive repro commands)
   -- prefer these over the rest of the open backlog.
3. **Branches with real unmerged commits, no PR** (from Phase 1.3) --
   finished-but-unshipped -> open a PR (draft if untested). Abandoned/
   superseded -> say so, don't delete yourself; file per Phase 6.

## 5. Phase 4 -- new work, only once Phase 1-3 exhausted or empty

Skip entirely if there isn't comfortable budget to finish one issue
AND leave time for wrap-up.

Otherwise: the highest-priority unclaimed open issue, implementation
delegated to `Agent({model: "sonnet", ...})` (self-contained prompt:
item, why, file paths, the checklist `discipline` prints). Stay on
Haiku for reviewing its diff, running tests, committing. Wanting a
stronger model for Phase 1-3 work is a sign the item belongs here (or is
genuinely Zach's) instead.

## 6. Nothing gets left undone without a named owner

Review everything touched or skipped. Every deferred item lands in
exactly one of these -- never a bare TODO, an abandoned branch, or a
vague line in a log file:

- **Another project's domain** -- `scheduler -i <project> "..."`.
- **A decision only Zach can make** -- issue titled `DECISION: <question>`.
- **Senechal's own, out of this run's budget** -- an issue worded for a
  future run to pick up non-interactively (0b/#169's pattern).

Doesn't fit one of these -> that's itself a `DECISION:` issue, not a
guess.

Exception: classifier denials (0a) aren't one of these three -- they go
in the wrap-up report only.

## 7. Wrap-up

Confirm every real change is committed, and anything meant to land is
on a pushed branch with an open PR (.githooks/pre-push refuses a direct push to main).
Write `~/reports/senechal/triage-run-$(date +%Y-%m-%d-%H%M).md`: time
per phase, cleanup done, issues triaged (closed/retitled/left, why),
work picked up, Phase 4 outcome, every Phase 6 filing with its link.
Update `~/reports/senechal/LATEST.md`. Time-out mid-phase -> say exactly
what's left so the next run resumes it (per section 1).
