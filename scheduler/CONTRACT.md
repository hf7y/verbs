# CONTRACT -- `dose`

apportion this ecosystem's scheduled work

Derived 2026-07-30 from the tooling that actually existed in `scheduler`.
Where there was no stated contract before, this is the first one; that
is a finding about the old tree, recorded rather than hidden.

Rewritten 2026-08-29 (hf7y/scheduler#296): the original contract was a
25-subcommand passthrough table, one row per script discovered in the legacy
tree. Measured 2026-08-28: zero of the 25 had ever been invoked as
`dose <sub>` -- no crontab, no runtime script, no account, on any host. The
table is deleted; the promise below is what remains.

## The promise

```
dose <project> [--check|--apply]
```

`<project>` names a row in `schedule/ROSTER`. `dose <project>` makes THIS
host match that row: the account exists, its clone is present and clean, and
its crontab carries the paced-runner line at the rate the roster declares.

- `--check` (the default) reports what would change and writes nothing.
- `--apply` converges, then re-reads the crontab and verifies the write
  rather than trusting its exit code.
- A row marked `parked` arms nothing under either flag.
- A project absent from the roster exits 4 (GAP), never 0.
- Only a human edits `schedule/ROSTER`. This command converges TO it and
  never writes it.

Full detail: `man dose`, `bin/dose-project.sh`'s own header.

## Universal clauses

- exits **0 only if the promise was kept**. Never an exit-0 no-op.
- exits **4 (GAP)** if the project is not in the roster.
- exits **6 (BLIND)** if it cannot read the roster. "I cannot see" is
  never reported as "nothing to report".
- exits **7 (REFUSED)** if the roster names a different host.
- **cannot spend money** unless it declares `--summon`, which has no
  short form and is never implied. `dose` never does.

## Verification

```
./test/contract-test.sh <command>
```

The same universal assertions (`--help`, `--summon` posture, no near-miss
flags) run against any implementation. Project-form behaviour is covered by
`tests/dose-project-witness.sh` on `main`, where `bin/dose-project.sh` is
developed before it is carried here.
