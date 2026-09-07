# GAPS -- what each shipped verb does not do

Recorded 2026-07-30, rewritten since as verbs ship. `recense` ships (#405); `debarrasse` and `lance` shipped alongside it but were reversed 2026-09-05 (#699) -- the 2026-08-27 reap order they had quietly undone stands.

## Python that was never given a shell contract (2 files)

These do real work but are not reachable through a verb, because they
have no stated argv/output promise to wrap:

- `senechal.py`
- `test_senechal.py`

## Standing gap: the cost baseline

No before-measurement exists for what the previous implementation cost per call, so the saving from mechanising it is **unmeasured, not zero and not assumed**. Closing this needs a real measurement, not an estimate.

## `installe` (2026-07-31)

All nine rows of THE PAGE TEST pass by machine, plus five safety assertions (`test/installe-test.sh`, 37 assertions). What it does not do:

- **It does not clean up after other generators.** 31 of the 64 entries in `~/.local/bin` are `generated` -- scheduler loop scripts and realisateur shims. `installe retire` on one is refused (exit 7) and correctly so: rerunning the generator puts it straight back. Retiring those means retiring them at the generator, and no verb does that yet.
- **`unknown` is a residue, not a verdict.** 22 entries are plain files with nothing declaring their origin. `installe` classifies them as unknown and stops; deciding what they are is a human act, and the tool is built not to guess at it.
- **It is not wired to PATH itself.** The bootstrap is unavoidable: the verb that puts verbs on the path has to be put on the path by hand once.
- **No `adopt`.** There is no way to tell `installe` "this entry is mine now" short of retiring it with `--force` and reinstalling it. That would turn 4 `repo-link` entries into owned ones in a single pass, and it is the obvious next verb-shaped hole.

## `recense`

`recense`'s THE PAGE TEST passes by machine. Gap:

- flat namespace -- a shadowed `$PATH` match isn't named except via `where`/`paths`; no cross-check against `installe`'s manifest.
