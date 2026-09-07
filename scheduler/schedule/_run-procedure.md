RUN PROCEDURE -- the shared nightly-batch steps, held once. Nine repos each
carried a hand-rewritten copy (hf7y/realisateur#744); this is the one.

No project is named below -- cwd is the clone, so `gh` needs no `-R`. Test
command, hazards, and untouchables belong in `CLAUDE.md`, read at step 1.

The run is unattended overnight; nobody reviews it until morning. Stop only
when the action cannot be reverted -- a commit, branch or PR never qualifies;
running destructively against Zach's real data, hosts or hardware does.

The backlog is the open GitHub issues, nothing else. Build first, don't just
analyze: take the most reasonable reading and build it. Don't build something
merely because it's easy -- if it serves no open issue, file it and move on.

Scratch files use `$TMPDIR`/`mktemp`, never a hardcoded `/tmp/...` path -- a
fixed name can leak one tenant's content into another's PR (scheduler#576).

## 1. Orient

`git log --oneline -10`, `README.md`, `CLAUDE.md`, `gh issue list`. If the last
run left work in progress, resume it: the open PRs and branches, and the
comments on the issue it was working, are where it stopped.

Read the COMMENTS on issues you plan to touch, not just their titles. Zach
answers by commenting and leaving the issue OPEN, so an open issue is not
evidence nothing has been decided. Act on the answer; if it is a standing
decision, say so in a follow-up comment so the next run does not re-derive it.

## 2. Re-verify before building further

Run this repo's own test suite -- step 1 read where it is -- before building on
existing code. Do not trust a prior run's claims about what works, including
your own from last night. Something "deployed" but never observed working is
not done.

## 3. Push forward, building rather than just analyzing

Scope is the open issues. Commit as you finish meaningful chunks, not one giant
commit at the end. If a step genuinely needs the user's own hands, do not route
around it -- say on the issue what the wall is and what is needed from him.

If this repo carries `tools/claim-issue.py`, run `python3
tools/claim-issue.py <N>` before an issue: exit 1 means claimed elsewhere
(skip); exit 2 means it could not look (proceed). No tool, no change.

## 4. Stress-test what you built

Try the edge cases a first pass misses -- the empty case, the duplicate case, a
second run over unchanged state, an input that vanishes underneath the run. Fix
what breaks; name what is genuinely out of scope tonight.

## 5. Flag what you built, and what needs the user's judgment

- Work on an EXISTING issue: comment there saying what landed and where.
- A NEW finding: `gh issue create`, one per finding, with enough context for a
  fresh agent to execute it cold.
- A JUDGMENT CALL that is the user's own: its own issue, `--label
  needs-decision`, stating the real options. Not "should I build this" -- the
  default there is yes. Do not manufacture these.

## 6. Before finishing

Nothing is left only in memory: every meaningful change is committed, pushed,
and the tree is clean at exit -- a dirty tree is a failed run, not a handoff.
