---
scope: user
description: Session-closing rite -- reconcile every branch against the remote, run the closeout lint, file residue as issues/PRs (never repo prose), surface decisions. Does not build.
---

<!-- Source: hf7y/realisateur:.claude/commands/cloture.md -- installed verbatim at
     USER level, so "this repo" below means realisateur, not your cwd. Edit it
     there, never the installed copy. -->

`/cloture` is the closing counterpart to `/ideate`'s opening posture: a rhythm
to run after a big job, so a session ends "clear to clear" instead of trailing
off. A session can end with local branches that reconcile cleanly on lint yet
have no PR at all -- the lint checks "is the content safe", not "can the next
reader find it without asking". Repo prose is never the residue channel:
GitHub issues and PR bodies already are one, are searchable, and do not need
this repo to keep growing to hold them.

**Posture: report, route, and surface — do NOT build.** If closing
reveals unfinished work, file it where something dispatches from (a
GitHub issue in the owning repo) or land it as a PR/draft PR — never
start building it at the end of a session, and never park it only in
this conversation. The one exception is finishing what the lint flags as
*undurable*: committing and pushing work this session already did isn't
new work, it's the session not having landed yet.

## 1. Branch reconciliation — no dangling branches for later discovery

**Every local branch this session touched or leaves behind must resolve
to one of three states, checked directly against the remote, not
asserted:**

- **Reflects `main`** — merged (`git cherry` against `origin/main` shows
  nothing new) or its tip is reachable from a remote ref already. Nothing
  to do.
- **Has an open PR** — pushed, and `gh pr view` finds it. Draft is fine
  if the work or the decision isn't finished; ready (with or without
  `DECISION:`, per the grammar in `bin/lib/body-grammar.sh`) if it is. This is what
  makes the remote the source of truth for "what's outstanding" instead
  of this checkout.
- **Documented as an intentional exception** — a repo whose registration
  is itself missing/stale (no check for this exists now; #511 deleted
  `closeout-lint`'s `[missing-repo]` row — say so by hand), a branch
  deliberately parked mid-experiment, etc. Say so in the session close
  (step 4) with the branch name and why — not as a new repo file, just
  in what you tell Zach.

`closeout-lint` used to clear all of this in one run; #511 deleted it for
reporting clean without looking. Check each branch by hand instead, against
`origin` not this checkout, and handle anything left over the same way:

```
git status                                          # uncommitted, and is it this run's or pre-existing
git cherry origin/main                               # anything not yet on main
git merge-base --is-ancestor <branch> <remote-ref>    # tip already reachable via another remote ref
gh pr list --head <branch>                            # an open PR already covers it
```

- **Uncommitted changes `git status` shows** -> commit (via a message file) or
  discard deliberately. Paths that predate this session are NOT that: leave
  them alone, since committing or reverting them adopts or destroys a
  concurrent run's work.
- **Committed but unpushed, no PR** -> push and open one. A one-line draft PR
  beats a branch only this host knows exists.
- **Pushed with an open PR** -> re-read the body against the grammar in
  `bin/lib/body-grammar.sh` (what `gh-sign` refuses at write time): does it
  still say what is true now (draft vs ready, `DECISION:` vs none)? `gh-sign`
  refuses a bad body AT THE WRITE; a body edited afterward is not re-read by
  anything, so read it yourself, for anything you touched.

## 2. Name the philosophy delta, or say "none"

Did this session change what the ecosystem *believes* -- a rule in
`PROSE-REAPING.md` or `CLAUDE.md`?
Those two are the doctrine still in this repo; the rest were consigned to the
vault in #366 and cannot be edited as part of a commit here.

If yes: name the delta in one sentence and confirm the file was actually
edited and is in a commit or PR from step 1, not merely described in chat. If
no, **say "philosophy delta: none" explicitly** -- silence here is
indistinguishable from forgetting to look.

## 3. Every cross-project write, and every piece of residue, is a GitHub issue or a PR — not repo prose

**Nothing from this session gets appended to `.scheduler/FOCUS.md`,
`BLOCKERS.md`, or `QUESTIONS.md`.** Those surfaces were RETIRED by
hf7y/scheduler#66 on 2026-08-07 and do not exist in this repo. Prose lives
in issues and PRs — searchable, closeable, and not something every
project's clone has to carry forever. If you find one of those files
anywhere, it is a finding (hf7y/realisateur#230), not a destination.

For each of the following, file a GitHub issue in the **owning** repo
(the repo the write/finding/decision is actually about — run
`check-project-busy <target>` first if you're about to write into a
repo that isn't this one) rather than a row in a file:

- **A cross-project write** (including reverted ones, and any second
  account/host touched) — the CLAUDE.md subagent rule, applied to
  yourself. One issue (or a comment on the relevant PR) per write, with
  repo + sha, so a run that can't see this conversation can still act on
  it.
- **A deferred write** because `check-project-busy` said BUSY — same
  destination. Re-check before filing: locks are short, and if it now
  reports `free`, do the write for real instead of filing about it.
  Carry the actual payload in the issue body, not a pointer back to this
  chat — an issue nobody but you can decode is a second dropped write
  wearing a filed one's clothes.
- **A decision blocked on Zach** — an issue, titled as the question,
  in the repo it's about. He answers by commenting and leaving it open
  (`etiquette` prints the grammar and derives the label) — not by closing
  it, not by labelling it, and not by editing a file back.
- **An insight true beyond this session** — if it's a *rule*, it goes in
  a doctrine file for real (step 2). If it's a fact or a finding rather
  than a rule, it's an issue. If it's neither — just interesting — it
  does not need a durable home at all.

**Retire check, every time.** Grepping the session for "deferred", "BUSY",
"left undone" catches the common phrasings, but the rule is **structural, not
lexical**: every FLAG, gap or defect this session named and did not fix --
whatever words named it -- needs an issue URL or a PR URL before step 4.

realisateur#165, 2026-08-11: a close named a real shim-drift defect with
*"Not something I fixed -- flagging it"* and stopped. That sentence contains
none of the trigger words and was exactly the un-filed residue this step
exists to catch; Zach had to ask "who did you tell about this?" **A close that
names a defect and attaches no URL has not routed it, however it is worded.**

## 4. Close

Before writing anything, re-read what you are about to say. **Every clause
naming a problem, gap, defect or FLAG must be immediately followed by an
issue/PR URL, or the words "documented exception" with the step-1 reasoning.**
Never a bare statement of fact. If a clause fails that test, go file it
(step 3) before finishing. Same check as the retire check, applied where it
matters: to what you are about to hand Zach.

State plainly, with **links, not descriptions**: which branches got a PR and
which URL, which issues got filed and which URL, what was pushed and where
(with revert shas), and what was left as a documented exception and why. Zach
should never have to ask whether something landed -- the answer is a URL, not
a sentence promising one exists.
