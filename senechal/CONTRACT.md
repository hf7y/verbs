# CONTRACT -- `veille`

keep watch over the household of machines

Derived 2026-07-30 from the tooling that actually existed in `senechal`.
Where there was no stated contract before, this is the first one; that
is a finding about the old tree, recorded rather than hidden.

## The promise

```
veille <subcommand> [args...]
```

| subcommand | promises | backed by |
|---|---|---|
| `dead-config` | whatever `health/dead-config.sh` promised | `health/dead-config.sh` |
| `estate-health` | whatever `health/estate-health.sh` promised | `health/estate-health.sh` |
| `no-self-dev` | whatever `health/no-self-dev.sh` promised | `health/no-self-dev.sh` |
| `project-unwired` | whatever `health/project-unwired.sh` promised | `health/project-unwired.sh` |
| `apt-hygiene-mandark` | whatever `remedies/apt-hygiene-mandark.sh` promised | `remedies/apt-hygiene-mandark.sh` |
| `bt-mouse-link-stability` | whatever `remedies/bt-mouse-link-stability.sh` promised | `remedies/bt-mouse-link-stability.sh` |
| `crt-dexter-ssh-key` | whatever `remedies/crt-dexter-ssh-key.sh` promised | `remedies/crt-dexter-ssh-key.sh` |
| `dexter-wsl-autostart` | whatever `remedies/dexter-wsl-autostart.sh` promised | `remedies/dexter-wsl-autostart.sh` |
| `estate-health-timer` | whatever `remedies/estate-health-timer.sh` promised | `remedies/estate-health-timer.sh` |
| `plasma-panel-visible` | whatever `remedies/plasma-panel-visible.sh` promised | `remedies/plasma-panel-visible.sh` |
| `remote-health-keys` | whatever `remedies/remote-health-keys.sh` promised | `remedies/remote-health-keys.sh` |
| `scheduler-subdir-migration` | whatever `remedies/scheduler-subdir-migration.sh` promised | `remedies/scheduler-subdir-migration.sh` |
| `smart-health` | whatever `remedies/smart-health.sh` promised | `remedies/smart-health.sh` |
| `svc-vaporwave-dispatch` | whatever `remedies/svc-vaporwave-dispatch.sh` promised | `remedies/svc-vaporwave-dispatch.sh` |
| `tmux-konsole-title` | whatever `remedies/tmux-konsole-title.sh` promised | `remedies/tmux-konsole-title.sh` |
| `verify-all` | whatever `remedies/verify-all.sh` promised | `remedies/verify-all.sh` |
| `window-spawn-desktop` | whatever `remedies/window-spawn-desktop.sh` promised | `remedies/window-spawn-desktop.sh` |
| `browse` | whatever `tools/browse` promised | `tools/browse` |
| `spawn-here` | whatever `tools/spawn-here` promised | `tools/spawn-here` |

## Universal clauses

Every subcommand, without exception:

- exits **0 only if the promise was kept**. Never an exit-0 no-op.
- exits **4 (GAP)** if the tooling does not exist, and says what is missing.
- exits **6 (BLIND)** if it cannot read its domain. "I cannot see" is
  never reported as "nothing to report".
- **cannot spend money** unless it declares `--summon`, which has no
  short form and is never implied.

## Verification

```
./test/contract-test.sh <command>
```

The same assertions run against the legacy tooling and against `veille`.
That is what makes "keeps the same contract" a measurement, not a claim.

---

# CONTRACT -- `recense`

take a census of the executables installed under a home directory

Coined 2026-07-31. Unlike `veille`, `ausculte` and `lance`, **this verb
wraps nothing.** There was no legacy script behind it; `bin/recense` is
the implementation, written after `man/recense.1` and judged against it.

## The promise

```
recense [where <name>|shadowed|unwired|paths] [flags]
```

| subcommand | promises | backed by |
|---|---|---|
| *(none)* | one line per executable installed under `$HOME`, `name<TAB>path`, first provider in search order | `bin/recense` (real) |
| `where` | which home directory provides a name, and whether the shell would actually run it | `bin/recense` (real) |
| `shadowed` | the installed names a system provider wins over | `bin/recense` (real) |
| `unwired` | executables in a conventional install directory that no path entry reaches | `bin/recense` (real) |
| `paths` | the home path entries in search order, with provider counts; duplicates printed as duplicates | `bin/recense` (real) |

## Exit vocabulary -- narrowed, deliberately

`recense` returns **0, 1, 2, 6** and nothing else. It cannot return 3
(it never summons), 4 (nothing on its page is unbuilt) or 5. The page
lists only what it can reach, and `--help` says the same, via the
`VERB_EXITS` field added to `lib/verb.sh` for this purpose. A utility
that advertises an exit code it cannot produce has failed row 4 of
THE PAGE TEST in the direction nobody checks.

`1` follows `which(1)` and `grep(1)`: nothing matched. It is a result,
not an error.

## Verification

```
./test/contract-test.sh bin/recense    # the universal assertions
./test/recense-test.sh                 # THE PAGE TEST, all nine rows
```

The second is the witness. Every row scored in a report about this verb
is scored there, by machine, so it cannot drift into being scored by eye.

---

# CONTRACT -- `installe`

govern what is reachable from a prompt

Coined 2026-07-31. Real, not a wrapper. It is the answer to a gap the
`recense` pass measured: **1 of 18 coined verbs was reachable from a
prompt.** Seventeen contracts were written, tested, and unspeakable.

## The promise

```
installe <path> | verb <project> <name> | retire <name> | list | audit
```

| subcommand | promises | backed by |
|---|---|---|
| *(a path)* | one executable reachable by its basename, by symlink | `bin/installe` (real) |
| `verb` | a bashified verb reachable, pinning the project's `bashified` worktree if needed | `bin/installe` (real) |
| `retire` | one name off the path and out of the manifest; the target untouched | `bin/installe` (real) |
| `list` | what `installe` owns | `bin/installe` (real) |
| `audit` | every entry in the install directory, classified by provenance | `bin/installe` (real) |

## Why the negation is in the contract and not in a later pass

A tool that can only add is how an install directory becomes a landfill:
adding costs one command, removing costs an archaeology session, so
nothing is ever removed. `retire` is half the verb, and it was written
into the page before the implementation existed, which is why the
implementation has it.

## The safety property

**`installe` removes only what `installe` installed.** Anything absent
from the manifest is refused with exit **7** -- project-specific, above 6,
and deliberately not folded into 5, because nothing broke: a guard held.
`--force` takes the decision back, and the point is that it is *taken*.

**`retire` removes links, never targets.** A retired verb is unreachable,
not deleted. That is what makes retiring something a cheap decision rather
than a frightening one, and it is asserted by test, not by intention.

## Verification

```
./test/contract-test.sh bin/installe    # the universal assertions
./test/installe-test.sh                 # THE PAGE TEST + the safety properties
```

The safety assertions inspect the disk after a dry run rather than reading
its exit code, and they run entirely inside a sandbox install directory: a
test for a tool that removes things from PATH must be provably incapable of
removing anything from the real one.

`recense` is the independent witness. It reports what the path actually
reaches, from outside, without consulting the manifest. An install
`installe` believes it made and `recense` cannot see is a broken install.

---

# CONTRACT -- `debarrasse`

clear real clutter off $HOME

Coined 2026-08-04, at Zach's request to "look at the ecosystem and learn
about the French verbs and how this would be properly wired up into the
vocabulary." Wraps `tools/home-declutter.py` on `main` (real Python, not
a stub) the way `veille` and `ausculte` wrap `health/`/`remedies/`
scripts -- exec'd via a stated, overridable `LEGACY_ROOT`, its exit code
translated into this ecosystem's vocabulary rather than passed through
raw (see `ausculte`'s own note on why passing a legacy exit code through
unmapped is a bug, not a shortcut).

## The promise

```
debarrasse scan | quarantine | verify | purge | list
```

| subcommand | promises | backed by |
|---|---|---|
| `scan` | every candidate under the configured roots and its gate verdict; touches nothing | `tools/home-declutter.py scan` (real) |
| `quarantine` | move every candidate that clears both gates into quarantine; `--dry-run` makes it behave exactly like `scan` | `tools/home-declutter.py quarantine`/`scan` (real) |
| `verify` | manifest integrity + which quarantined items are past their purge grace period | `tools/home-declutter.py verify` (real) |
| `purge` | delete quarantined items past `purge_after_days`, re-verifying each hash first; refused without `--force` | `tools/home-declutter.py purge --confirm` (real) |

## The two gates, restated as a contract

Nothing reaches `quarantine` on a guess. A candidate must clear BOTH:

1. **the hardlink guard** -- `st_nlink == 1` on every contained file, with
   an independent `find -xdev -samefile` sweep for anything that trips
   it, so the refusal names the sibling path rather than just refusing.
2. **recoverability** -- either a declared "regenerable" pattern (caches,
   `__pycache__`), or `garde <path>` (gardien-garde's real off-machine
   coverage check, not a stub) confirming a backup exists.

Real content with no backup and no regenerable classification is left
alone and reported as such. This is the whole reason the tool exists --
see `tools/home-declutter.py`'s own module docstring for the full
rationale, and `ESTATE.md` finding 1 (closed 2026-08-04) for why leaning
on `garde` rather than building a second backup mechanism was the
correct call.

## Exit vocabulary -- narrowed and extended, deliberately

`debarrasse` returns **0, 2, 4, 5, 6, 7, 8, 9**. Never 3 (`VERB_CAN_SUMMON=0`
-- nothing here is agent judgment, it is a hardlink stat and a call to
`garde`, both deterministic). `8` (FOUND) and `9` (WARN) are
project-specific, above 7, the same way `installe` reaches 8 and 9 for
concepts the shared seven codes don't name: `8` is `verify` finding a
real problem (tampered or vanished quarantine content) and `9` is
`verify` finding something merely past its purge grace period --
distinguished on purpose, the same way `lib/common.sh`'s health checks
distinguish FAIL from WARN, because folding both into one code would
make `9` unreadable as "nothing is broken."

## The safety property

**`purge` is the sole irreversible subcommand and is refused without
`--force`** -- the exact shape `installe` uses for its own unowned-entry
refusal (exit 7, `--force` takes the decision back). `scan` and
`quarantine` never need it: `quarantine` only ever moves a file within
the same machine (reversible by a plain `mv` back, per the manifest),
and `scan` never writes at all.

## Verification

```
./test/contract-test.sh bin/debarrasse    # the universal assertions
./test/debarrasse-test.sh                 # exit-code translation, both gates, the safety property
```

The exit-code-translation tests run against a fully sandboxed
`DEBARRASSE_LEGACY_ROOT` and `HOME` -- a test for a tool whose whole
purpose is deciding what is safe to lose must be provably incapable of
touching the real home directory.
