# dose

*apportion this ecosystem's scheduled work*

This is the **bashified** branch of `scheduler`. It contains a plain shell
utility and nothing else.

```
bin/dose                     the utility -- one form: dose <project>
man/dose.1                   how to use it
CONTRACT.md                  the promise it must keep
GAPS.md                      what it cannot do yet
test/                        contract tests, runnable against any implementation

bin/dose-project.sh          } dose's own implementation -- what `dose <project>`
lib/dose-common.sh           } execs, carried beside bin/dose so $SELF finds it
                             } on a host with no scheduler checkout at all.

bin/freeze-check.sh          } NOT exec'd by dose (hf7y/scheduler#296 deleted the
bin/tempo.sh                 } subcommand table that once reached them). Carried
bin/usage-paced-runner.sh    } anyway: a no-checkout copy of the dispatch tick has
bin/verdict.sh               } uses this CLI never provided -- hf7y/scheduler#350.
lib/run-ledger.sh            } None are on PATH; each has a row in realisateur's
lib/check-witness.sh         } bin/lib/not-a-verb.tsv.
```

The first pair arrived with hf7y/scheduler#123 and #127; the second group
was the CLI's CARRIED arms until #296 deleted the arms and kept the carry.
Before #123 this branch really did hold "a plain shell utility and nothing
else", and `dose` was a facade: every subcommand exec'd into a checkout via
LEGACY_ROOT, so on a host with no clone the whole verb GAPped. Zach,
2026-08-11: *"scheduler should not need to exist as a check out on monkey for
the verbs to work ... that's true for all verbs actually, they should be
functional independent of their underlying repos."*

**A carried file must stay identical to its `main` copy.** They exist twice now
and nothing about git holds them together -- within hours of the first carry,
this branch was shipping a `freeze-check.sh` with a fail-OPEN that `main` had
already fixed, and every host adopted it. `tests/carry-drift-witness.sh` on
`main` is the guard; it derives the carried set rather than reading a list.

## Why this is a branch and not a repository

The purge here is **total** for everything that is not the tool or something
the tool runs. Everything else this tree used to carry is gone from these files. It is not lost: it is on `main`
branch of this same repository, one `git log main` away.

**That is the only reason a total purge is safe.** Extracting this
branch into a standalone repository would destroy the archive that
justifies the purge, and leave defensive code standing with no visible
cause -- which is how hard-won guards get deleted by the next reader.
Do not do it.

## Verify

```
./test/contract-test.sh bin/dose
```
