---
scope: user
description: Halve a repo's prose by deleting the mechanisms that manufacture it, halve its foreign-owned mechanism, and close 75% of its issues by working them.
argument-hint: "<repo-name>"
---

<!-- Source: hf7y/realisateur:.claude/commands/reap.md -- installed verbatim at
     USER level, so "this repo" below means realisateur, not your cwd. Edit it
     there, never the installed copy. -->

Reap `$ARGUMENTS`. Three targets: **prose in half, foreign mechanism in half,
75% of issues closed by working them.** realisateur was the test case —
19,458 → 9,670 prose lines, 50 of 66 issues closed (hf7y/realisateur#366).

## 1. Measure first

`gh issue list --state open | length` and the prose count from the repo's
`.prose-ratchet`. Write both numbers down; every later claim is against them.

**A repo with no prose guard adopts one in six lines**, calling
`hf7y/etalon/.github/workflows/guard.yml@main`. Never copy the script: it is
maintained in `hf7y/etalon` and nowhere else, and every vendored copy this
estate has made has drifted or shipped broken.

## 2. Cut the generators, not the output

The step that makes the rest stick. #321 measured **84 mandatory prose lines
per 180 of mechanism** — none of them chosen. Reap the output without cutting
what mandates it and it regrows by the next PR.

**Add no guard, no convention, no document.** Zach, 2026-08-17: *"Do not
establish new policies that will go stale. Delete the old policy they would
contradict instead."* Enforcement is whatever ratchet already exists.
Recorded in hf7y/realisateur#366, which is the pass that applied it.

Hunt, ranked by what yielded:

- a doctrine file's essay half — any `.md` over ~200 lines whose mechanism is a script
- a checklist row that argues with itself — parentheses over 3 lines
- **a spec for a check that no longer exists** — grep the header's check names against the code that emits them
- a guard demanding a *reason* per declaration
- **a ledger column nothing parses** — read the consumer; `while read -r k v` means field 3+ is dead
- **prose that is load-bearing for code** — any script that greps a `.md`
- a nag aimed at repos you do not own
- an instruction to write a retired surface
- a mandate contradicted by a guard — run the guards, then read the doctrine telling you the opposite

> **Prose must never be load-bearing.** In realisateur, the shim installer
> derived shim names by grepping a doc, so one sentence in an essay was the
> only thing installing a working guard; and `ownership-audit` attached files
> by *mentioning them*, so trimming a header **detached** a suite. Fix that
> structurally before reaping near it, or your reap deletes function silently.

## 3. Reap what is left

Per paragraph: **holds → stays with a runnable witness. Held at the time → the
vault. Expired and defending a mechanism → a deletion flag, not a relocation.**

Headers keep the one-line claim, the machine-read declarations
(`RUNNER`/`GUARD-TEST`/`GATE`), and `TRAP:` lines with the command that
reproduces them. For interior comments, relocate and leave a pointer. **Never
touch a block containing TRAP, NEVER, MUST NOT or DO NOT.**

Consign to the vault and **push**. Repoint citations at
`vault:<project>/<doc>.md`, then re-grep. Before deleting a doc, check whether
anything *reads* it as opposed to citing it — in realisateur, 32 of 40
referrers were prose and exactly one was a read.

## 4. Close 75% by working them

Five dispositions; only three close without doing the work, and those three
are legitimate: **worked** (cite the commit and a witness), **routed** (draft
PR in the owner's repo + a stamped issue asking their self-dev to ready and
merge — leave it draft), **verified done** (re-probe, close with the output),
**superseded/stale**, **aggregated** (write the umbrella's index *first*).

**Re-probe before believing any issue, including your own plan.** Three
planned closures in the realisateur pass were wrong; one would have deleted
the only thing putting a working command on Zach's PATH.

**If you cannot make the change, do not close the issue.** Post the
measurement and say what blocked you.

## 5. Halve the foreign surface

Per block, largest first: does the owner repo **exist**? If not, that is the
finding — file it as a decision and stop. Otherwise `check-project-busy`, then
a draft PR carrying files + suites + workflows, then a stamped issue.
**Delete on your side only after the receiving PR merges** — a draft is not a
delivery, and the ratchet does not move on a promise.

## 6. Land it and report

Branch, PR, green checks; `git commit -F <file>`; never `git add -A`.

Expect the reap's own PR to fail the prose guard — deleting 6,728 comment
lines while adding 541 scores 74% comments. If the comment check has no reap
exemption, it is taxing the behaviour it exists to produce: give it one
(deletions count **only** for the reap comparison, never in the ratio).

Then `--accept` every ratchet that improved. Report the three before/after
numbers, the generators deleted, and — separately — **what you could not do
and why**. A reap that reports only what it cut is hiding half the answer.
