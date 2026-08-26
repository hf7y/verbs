---
description: Nightly thorough pass -- environment-journal hardening/features for senechal, scoped by the GitHub issue queue
---

Read the open issues at https://github.com/hf7y/senechal/issues first
(`gh issue list -R hf7y/senechal`), then run `discipline` for the
autonomy policy and `tools/standing-answers.py` for decisions Zach has
already given — do not re-ask those. Build first, don't just analyze: pick the
most reasonable interpretation of the stated focus and build it, flagged
as an issue and in the report. Only actually stop and wait for
the user when the action itself can't be reverted -- an ordinary commit
or branch never qualifies, but this repo's standing caution around never
writing unredacted secret content into `journal/` still applies: when
genuinely unsure whether something is safe to preview, redact instead of
guessing.

This command is designed to run unattended overnight, with no human
review step until the morning.

## 1. Orient

`git log --oneline -10`, `README.md`, and `gh issue list -R
hf7y/senechal`. If a
previous nightly run left work in progress (check the last report under
`~/reports/senechal/`), pick up from there rather than starting over.

**Read the comments on open issues and process any answers.** Zach
answers by COMMENTING and usually LEAVES THE ISSUE OPEN, so issue state
is not an answer signal -- read the comments. Treat an answer as
authoritative: act on it, and say in the issue what was done.

## 2. Re-verify before building further

Run `python3 -m unittest test_senechal -v` before building on top of
existing code -- don't trust a prior run's own claims about what works.

## 3. Push forward, building rather than just analyzing

Scope = the open issue queue's stated priorities. Keep every new code path
unit-testable against temp directories the same way `senechal.py`
already is. Do NOT run a real scan against Zach's actual home directory
and commit the resulting `journal/*.json` as part of an unattended
run -- that's real personal data, and a nightly run should not decide
unattended what's safe to commit from a live scan. Build and test the
scanning/redaction logic itself; leave the first real scan of Zach's
actual machine for him to run and review by hand.

**Reading the live estate is fine. Changing it follows the acting
authority `discipline` prints -- run it before touching anything outside
this repo.** In short: **senechal acts.** Reversible fixes (restart a
user service, clear a cache, re-run a failed backup, rotate a log) you do
unattended, logging each in the report. **Privileged or hard-to-undo
changes you do not** -- those become `remedies/<concern>.sh` with
`enable` + `verify`, which you write, test, and commit. **Never run a
remedy's `enable` verb.** Zach runs that himself.

Testing a remedy needs **three** scratch things, not one: `HOME`,
`SENECHAL_CONFIG` (`lib/common.sh` reads the config at source time and
exits 2 without one), and `SENECHAL_DEPLOYED_ROOT` if the remedy writes
any path down -- otherwise `enable` can only ever be observed refusing.
`health/remedy-shape.sh` checks the shape; it cannot check those.

A problem in another project's domain gets **fixed, in whatever repo it
lives in**, and landed as a PR there. Filing an issue in place of an
available fix is not a first move, and neither is leaving a finding "for
a human" -- nothing reads a paragraph in a report. `scheduler -i
<project>` is for a genuine judgment call that is someone else's to make.
(The old "another project's domain: file it, don't fix it" rule was
retired 2026-08-11; it survived in this file until 2026-08-25 and was
still producing deferrals.) See `ESTATE.md` for who owns what.

Running `health/estate-health.sh` unattended is fine and encouraged --
it is read-only by contract.

Two traps this repo has already hit, both worth re-reading before
writing a verify:

- Cron has **no `DISPLAY`**, so any window-manager check cannot run
  unattended. Route it to `skip` (exit 2 = "could not look"), never a
  pass, and say in the report that you verified to the daemon's edge and
  not to the glass.
- `wmctrl -l | grep ...` returns the **pipeline's** exit status, so a
  missing display silently reads as success. Guard with `have_display`.

## 4. Stress-test what you built

Try edge cases a first pass misses -- a watched path that doesn't exist,
a binary file, a symlink, an empty file, a file that's all secret-looking
content. Fix what breaks; note what's genuinely out of scope for tonight.

## 5. Flag what you built, and anything needing the user's own judgment

What was BUILT belongs in the commit messages and the report, not in a
log file -- git is already a changelog. What needs Zach belongs in the
issue queue:

- A genuine judgment call needing the user's own decision -- one issue
  each, titled `DECISION: <the question>`. Don't manufacture others.
- Comment on the issue a build closed out, rather than opening a new one
  to announce it.

## 6. Write the report

`~/reports/senechal/$(date +%Y-%m-%d).md`, and update
`~/reports/senechal/LATEST.md` to match. Cover what shipped, what broke
and got fixed, what was deferred and why, and any issue filed or
answered.

## 7. Before finishing

Confirm every meaningful change has a real commit, pushed to origin. An
overnight run that is not saved anywhere didn't happen.
