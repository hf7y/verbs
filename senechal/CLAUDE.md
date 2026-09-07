# CLAUDE.md

This repo deleted a prior `CLAUDE.md` (see README.md's "Where the rules
live" for when and why) because prose claims about *state* rot -- a stale
test command, a superseded policy line. This file only carries what that
one couldn't: policy for how an unattended run behaves, and pointers to
where each factual claim is actually enforced. If a bullet below starts
drifting from the code, fix the code's pointer, not this file's wording.

## What this is

Majordomo of Zach's estate: journals device configuration and watches
device health. See `README.md` for the mission and running it,
`ESTATE.md` for the device registry and delegation model.

## Commands

See README.md's "Running it" section -- the config bootstrap, the scan/audit
commands, and the full test invocation (including the UNQUOTED extglob
requirement) are kept there, not duplicated here.

## Operating model -- read before doing autonomous/nightly work

- **GitHub issues -- https://github.com/hf7y/senechal/issues** -- the
  backlog and the two-way interface. `gh issue list -R hf7y/senechal`
  first. Zach answers by commenting and leaving the issue OPEN, so open
  is not evidence nothing's been decided -- read comments, not just
  titles/state.
- `tools/standing-answers.py` -- decisions Zach already gave; don't
  re-ask. `--audit` fails when a decision's own mechanism has been
  deleted, so a passing audit means every answer here is still live.
- **`schedule/_run-procedure.md` in `hf7y/scheduler`** -- the shared
  step-by-step nightly contract (orient -> re-verify tests -> build ->
  stress-test -> file/comment on issues -> commit+PR), spliced into the
  dispatched prompt by `schedule/senechal.conf`'s
  `BATCH_PROMPT="@@FRAGMENT:run-procedure@@"`. You are already reading it
  if you're running as that job. Everything below is what THIS repo
  alone adds on top of it.
- Reports land at `~/reports/senechal/$(date +%Y-%m-%d).md` (and
  `LATEST.md`), outside this repo.

## Hazards specific to this repo's unattended runs

- **Never run a real scan against Zach's actual home directory and
  commit the resulting `journal/*.json` from an unattended run.** That's
  real personal data, and a nightly run should not decide unattended
  what's safe to commit from a live scan. Build and test the
  scanning/redaction logic against temp dirs (`senechal.py` already
  does); leave the first real scan for Zach to run and review by hand.
- **Never write unredacted secret content into `journal/`.** See
  README's "Where the rules live" table and `looks_secret` -- when
  genuinely unsure whether something is safe to preview, redact instead
  of guessing.
- **Reversible fixes you just do and log** (restart a user service,
  clear a cache, re-run a failed backup, rotate a log) -- "senechal
  acts" (README's mission section). **Privileged or hard-to-undo
  changes become `remedies/<concern>.sh`** with `enable` + `verify`,
  which you write, test and commit. **Never run a remedy's `enable`
  verb** -- Zach runs that himself.
- **Testing a remedy needs three scratch things**, not one: `HOME`,
  `SENECHAL_CONFIG` (`lib/common.sh` reads the config at source time and
  exits 2 without one), and `SENECHAL_DEPLOYED_ROOT` if the remedy
  writes any path down -- otherwise `enable` can only ever be observed
  refusing. `health/remedy-shape.sh` checks the shape; it cannot check
  those three.
- **Cron has no `DISPLAY`.** Any window-manager check cannot run
  unattended -- route it to `skip` (exit 2, "could not look"), never a
  pass. Say in the report that you verified to the daemon's edge and not
  to the glass.
- **`wmctrl -l | grep ...` returns the pipeline's exit status**, not
  `wmctrl`'s -- a missing display silently reads as success. Guard with
  `have_display`.
- Run `tools/absorb-and-pr.sh` each pass (#484).
  `health/estate-health.sh` is read-only by contract and safe unattended.

## Ecosystem protocols

Three verbs are the interface when a change reaches outside this repo.
Each prints its own contract; none of it is restated here.

- `notify-senechal <door> <field>=<value>` -- file a crontab, device or
  footprint change on senechal's own registry.
- `check-project-busy <project>` -- before writing DIRECTLY into another
  project's files.
- `consulte` -- read the estate's own prose.

`discipline` and `BUILD-DISCIPLINE.md` were deleted by
hf7y/realisateur#687: the rows a mechanism already enforced are enforced
by that mechanism, and the rest were unenforced prose. Do not reinstate
either here.
