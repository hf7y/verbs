# realisateur, bashified

The **verb-declaring** branch of `realisateur`. A project declares a verb by
carrying an executable `bin/<name>` and a matching `man/<name>.1` here; the
nightly cut assembles every project's declarations into `hf7y/verbs`, and a
host installs them into `/usr/local/bin`.

```
bin/gh                  sign every GitHub comment this account writes
bin/consigne            deposit prose into the vault
bin/check-project-busy  is a dispatched job running against <project>?
bin/claim-drift         has a PR grown since it was presented as done?
bin/closeout-lint       what did today's session leave behind?
bin/discipline          print the baseline every project is held to
bin/notify-senechal     file a machine-config fact through the typed door
bin/silence-audit       can a sensor tell nothing-there from could-not-look?

man/<name>.1            the other half of the declaration
CONTRACT.md             the promise every verb here keeps
test/                   contract assertions, runnable against any implementation
```

Everything under `bin/` except `bin/lib/` is a FRONT DOOR: something a person
or another project types. An internal that happens to be executable is not a
verb, and does not become one by acquiring a man page.

## Why these six arrived 2026-08-18

They were the last thing on a self-dev account that needed a `realisateur`
clone. Each was a generated `~/.local/bin` shim that exec'd into
`$HOME/Documents/Projects/realisateur/bin/<name>.sh`, so every account
carried a checkout of this repository to run six commands. As verbs they
install host-wide and the clone is deletable.

## Why this is a branch and not a repository

The purge here is **total**: everything this tree carries beyond the tools
themselves is gone from these files. It is not lost — it is on `main`, one
`git log main` away.

**That is the only reason a total purge is safe.** Extracting this branch
into a standalone repository would destroy the archive that justifies the
purge, and leave defensive code standing with no visible cause — which is how
hard-won guards get deleted by the next reader.

Files here that also exist on `main` are REPLICAS, and `bin/carry-drift.sh`
fails the build if the two stop matching. Edit `main`, then re-carry.
