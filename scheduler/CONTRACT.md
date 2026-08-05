# CONTRACT -- `dose`

apportion this ecosystem's scheduled work

Derived 2026-07-30 from the tooling that actually existed in `scheduler`.
Where there was no stated contract before, this is the first one; that
is a finding about the old tree, recorded rather than hidden.

## The promise

```
dose <subcommand> [args...]
```

| subcommand | promises | backed by |
|---|---|---|
| `blockers-freshness-check` | whatever `bin/blockers-freshness-check.sh` promised | `bin/blockers-freshness-check.sh` |
| `build-services-view` | whatever `bin/build-services-view.sh` promised | `bin/build-services-view.sh` |
| `check-witness-lint` | whatever `bin/check-witness-lint.sh` promised | `bin/check-witness-lint.sh` |
| `collect-feedback` | whatever `bin/collect-feedback.sh` promised | `bin/collect-feedback.sh` |
| `deploy-drift-check` | whatever `bin/deploy-drift-check.sh` promised | `bin/deploy-drift-check.sh` |
| `freeze-check` | whatever `bin/freeze-check.sh` promised | `bin/freeze-check.sh` |
| `lint-replies` | whatever `bin/lint-replies.sh` promised | `bin/lint-replies.sh` |
| `morning-report` | whatever `bin/morning-report.sh` promised | `bin/morning-report.sh` |
| `overnight-dev` | whatever `bin/overnight-dev.sh` promised | `bin/overnight-dev.sh` |
| `publish-report` | whatever `bin/publish-report.sh` promised | `bin/publish-report.sh` |
| `questions-lint` | whatever `bin/questions-lint.sh` promised | `bin/questions-lint.sh` |
| `rotation-lint` | whatever `bin/rotation-lint.sh` promised | `bin/rotation-lint.sh` |
| `scheduler` | whatever `bin/scheduler` promised | `bin/scheduler` |
| `scheduler-completion.bash` | whatever `bin/scheduler-completion.bash` promised | `bin/scheduler-completion.bash` |
| `scheduler-dev-cycle` | whatever `bin/scheduler-dev-cycle.sh` promised | `bin/scheduler-dev-cycle.sh` |
| `scheduler-run` | whatever `bin/scheduler-run` promised | `bin/scheduler-run` |
| `sync-crontab` | whatever `bin/sync-crontab.sh` promised | `bin/sync-crontab.sh` |
| `token-usage` | whatever `bin/token-usage.sh` promised | `bin/token-usage.sh` |
| `tracker-bug-sweep-precheck` | whatever `bin/tracker-bug-sweep-precheck.sh` promised | `bin/tracker-bug-sweep-precheck.sh` |
| `unprinted-facts` | whatever `bin/unprinted-facts.sh` promised | `bin/unprinted-facts.sh` |
| `usage-gate` | whatever `bin/usage-gate.sh` promised | `bin/usage-gate.sh` |
| `usage-paced-runner` | whatever `bin/usage-paced-runner.sh` promised | `bin/usage-paced-runner.sh` |
| `verdict` | whatever `bin/verdict.sh` promised | `bin/verdict.sh` |
| `nightly-batch-loop` | whatever `examples/nightly-batch-loop.sh` promised | `examples/nightly-batch-loop.sh` |
| `vkv-inventory-bug-sweep-loop` | whatever `examples/vkv-inventory-bug-sweep-loop.sh` promised | `examples/vkv-inventory-bug-sweep-loop.sh` |

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

The same assertions run against the legacy tooling and against `dose`.
That is what makes "keeps the same contract" a measurement, not a claim.
