# CONTRACT -- `juge`

perceive this system's state and judge what matters

Derived 2026-07-30 from the tooling that actually existed in `realisateur`.
Where there was no stated contract before, this is the first one; that
is a finding about the old tree, recorded rather than hidden.

## The promise

```
juge <subcommand> [args...]
```

| subcommand | promises | backed by |
|---|---|---|
| `check-project-busy` | whatever `bin/check-project-busy.sh` promised | `bin/check-project-busy.sh` |
| `closeout-lint` | whatever `bin/closeout-lint.sh` promised | `bin/closeout-lint.sh` |
| `ecosim-sensor-tick` | whatever `bin/ecosim-sensor-tick.sh` promised | `bin/ecosim-sensor-tick.sh` |
| `ecosystem-survey` | whatever `bin/ecosystem-survey.sh` promised | `bin/ecosystem-survey.sh` |
| `focus-commit` | whatever `bin/focus-commit.sh` promised | `bin/focus-commit.sh` |
| `hygiene-lint` | whatever `bin/hygiene-lint.sh` promised | `bin/hygiene-lint.sh` |
| `incubation-audit` | whatever `bin/incubation-audit.sh` promised | `bin/incubation-audit.sh` |
| `install-shims` | whatever `bin/install-shims.sh` promised | `bin/install-shims.sh` |
| `install-silence-audit` | whatever `bin/install-silence-audit.sh` promised | `bin/install-silence-audit.sh` |
| `make-bootstrap-branch` | whatever `bin/make-bootstrap-branch.sh` promised | `bin/make-bootstrap-branch.sh` |
| `milestone-audit` | whatever `bin/milestone-audit.sh` promised | `bin/milestone-audit.sh` |
| `notify-senechal` | whatever `bin/notify-senechal.sh` promised | `bin/notify-senechal.sh` |
| `precipitation-scan` | whatever `bin/precipitation-scan.sh` promised | `bin/precipitation-scan.sh` |
| `reach-lint` | whatever `bin/reach-lint.sh` promised | `bin/reach-lint.sh` |
| `restamp-discipline` | whatever `bin/restamp-discipline.sh` promised | `bin/restamp-discipline.sh` |
| `session-marker` | whatever `bin/session-marker.sh` promised | `bin/session-marker.sh` |
| `silence-audit` | whatever `bin/silence-audit.sh` promised | `bin/silence-audit.sh` |
| `steward-survey` | whatever `bin/steward-survey.sh` promised | `bin/steward-survey.sh` |
| `weight-audit` | whatever `bin/weight-audit.sh` promised | `bin/weight-audit.sh` |
| `inject-suggestions` | whatever `fable-like/inject-suggestions.sh` promised | `fable-like/inject-suggestions.sh` |
| `liveness-audit` | whatever `fable-like/projects/scheduler/bin/liveness-audit.sh` promised | `fable-like/projects/scheduler/bin/liveness-audit.sh` |

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

The same assertions run against the legacy tooling and against `juge`.
That is what makes "keeps the same contract" a measurement, not a claim.
