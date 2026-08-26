# GAPS -- what `veille` cannot yet do

Recorded 2026-07-30 during the bashify pass. These are to be closed
later; they are written down now so the utility never pretends.

## Python that was never given a shell contract (2 files)

These do real work but are not reachable through the verb, because they
have no stated argv/output promise to wrap:

- `senechal.py`
- `test_senechal.py`

## Standing gap: the cost baseline

No before-measurement exists for what the previous implementation cost
per call, so the saving from mechanising it is **unmeasured, not zero
and not assumed**. Closing this needs a real measurement, not an estimate.

## `recense` (2026-07-31)

The verb is complete against its page -- all nine rows of THE PAGE TEST
pass by machine (`test/recense-test.sh`, 25 assertions). What it
deliberately does **not** do:

- **It does not walk the whole home directory.** `unwired` looks only at
  conventional install directories. A full walk answers the *present*
  question (build outputs, virtualenv interpreters, vendored binaries) and
  would return thousands of lines about executables nobody installed. This
  is a stated scope, not a missing feature; it is on the page.
- **It is not wired to `PATH`.** Wiring a verb into the machine is a human
  decision and a machine-wide config change. `bin/recense` runs from the
  worktree today.
- **Ownership beyond the shim is not resolved.** A name provided by a
  version manager's shim directory is reported at the shim. What the shim
  dispatches to is a property of the moment, not of the install.

## `installe` (2026-07-31)

All nine rows of THE PAGE TEST pass by machine, plus five safety
assertions (`test/installe-test.sh`, 37 assertions). What it does not do:

- **It does not clean up after other generators.** 31 of the 64 entries in
  `~/.local/bin` are `generated` -- scheduler loop scripts and realisateur
  shims. `installe retire` on one is refused (exit 7) and correctly so:
  rerunning the generator puts it straight back. Retiring those means
  retiring them at the generator, and no verb does that yet.
- **`unknown` is a residue, not a verdict.** 22 entries are plain files with
  nothing declaring their origin. `installe` classifies them as unknown and
  stops; deciding what they are is a human act, and the tool is built not to
  guess at it.
- **It is not wired to PATH itself.** The bootstrap is unavoidable: the verb
  that puts verbs on the path has to be put on the path by hand once.
- **No `adopt`.** There is no way to tell `installe` "this entry is mine
  now" short of retiring it with `--force` and reinstalling it. That would
  turn 4 `repo-link` entries into owned ones in a single pass, and it is the
  obvious next verb-shaped hole.

## `debarrasse` (2026-08-04)

**Not built.** `test/debarrasse-test.sh` exists and `man/debarrasse.1` is
described below, but there is no `bin/debarrasse` on any branch -- the suite
tests a verb that does not ship. Until it exists, `tools/home-declutter.py`
has no door, and its page lives beside it at `tools/home-declutter.1` rather
than in `man/`: a page in `man/` with no matching `bin/` is a HALF
declaration, which `cut-verb-build.sh` refuses a build over, and which
`installe` would deploy as a manual entry for a command nobody can run
(2026-08-23).

The same is true of `ausculte`, `lance` and `recense`: suites without a
`bin/`. They are kept rather than deleted -- each encodes the contract its
verb is supposed to meet -- and tracked in hf7y/senechal#405.

`test/debarrasse-test.sh` covers exit-code translation for every reachable
code (0/6/7/8/9), both safety properties (`quarantine --dry-run` writes
nothing, `purge --force` touches only past-grace-period entries), and one
man-page sanity row. What it does not do:

- **It is not THE PAGE TEST.** `installe-test.sh` and `recense-test.sh`
  parse the SYNOPSIS out of the man page and run every form, cross-check
  the page's subcommand list against the code's `case` statement in both
  directions, and provoke every documented exit code by name. This file
  hand-writes each assertion instead. The page and the code can drift
  against each other silently in a way THE PAGE TEST would catch and this
  does not -- e.g. a subcommand added to `bin/debarrasse` and forgotten in
  `man/debarrasse.1`'s SYNOPSIS.
- **`--json` is unimplemented on every subcommand**, stated on the page
  and gapped (exit 4) rather than silently ignored, but nothing renders
  machine-readable output yet. Whoever needs to script against `scan`'s or
  `verify`'s findings hits this first.
- **No cost baseline for the Python it wraps.** `tools/home-declutter.py`
  is fast in practice (a `stat` per file, a `find -samefile` only when
  that trips, one `garde` call per stale-download candidate), but nothing
  here measures wall-clock against a large `$HOME`, unlike `recense`'s
  stated scope boundary for its own walk.
