# Build discipline — lessons every scaffolded project inherits

**The rule of this file: prefer a mechanical guard — a test, a lint, a CI
check — over a paragraph.** Prose decays; guards don't. Where a row names a
guard, the guard is the authority and this text is a pointer. Applied to
itself, 2026-08-26: the 21 numbered failure patterns are in the vault at
`realisateur/build-discipline-patterns-20260826.md`, and the rules that were
stated here but never printed are now printed below or are named guards.

Retired here, because something enforces them now:

- *Subagents work on branches; a dirty tree at exit is a failed run* —
  `hooks/subagent-closeout.sh` (SubagentStop, exits 2 to block the stop),
  witnessed by `bin/tests/subagent-closeout.test.sh`.
- *A carried file matches its source* — `bin/carry.sh` performs it,
  `bin/tests/carry-drift.test.sh` fails when it is owed.
- *A clock takes a lock* — `bin/lib/cron-lock.sh` and
  `bin/lib/cron-invoked.tsv`, graded both ways by `bin/tests/cron-lock.test.sh`.

## The baseline (ONE file, read through the `discipline` command)

```
## Build discipline (realisateur baseline — see realisateur/BUILD-DISCIPLINE.md)
Before marking anything done:
- [ ] Fails **loud**? (no exit-0 no-ops; pipefail+SIGPIPE guarded)
- [ ] "Working" backed by a **test name or human-sense witness**, not exit code alone?
- [ ] Config read from **one source**, not retyped per file?
- [ ] Deploy verified against a **git ref**; drift fails loud?
- [ ] **No secret** in a tracked file; tree clean of build debris?
- [ ] **Shared-host footprint declared** and retired entries actually removed?
- [ ] Claims about system state **re-probed, not quoted**?
- [ ] Verified **where the consumer reads it** (pushed to the ref the job clones)?
- [ ] **Wire-on-commit** — nothing is done until something runs it on the real path.
- [ ] **Named what you retire?** A new mechanism that overlaps an old one says
      which one is dead.
- [ ] **Wrote the mechanism, not the weather** — say what a thing DOES and must
      keep doing; correct at the source, never by a comment beside it.
- [ ] **No `2>/dev/null` on a privileged probe** — discarding stderr turns "not
      permitted" into "not present".
- [ ] **The runner writes the verdict**, not the actor.
- [ ] **Nothing exists only on this host?** A branch with no remote ref is a
      blocker; the test is the remote **ref**, never the tracking config:
      `git for-each-ref --format='%(refname:short)' refs/heads/ | while read -r b; do git rev-parse --verify -q "origin/$b" >/dev/null || echo "$b exists only here"; done`
- [ ] Multi-line or shell-quoting commit message written with
      **`git commit -F <file>`**, not `-m`?
- [ ] Pull request body follows the grammar `gh-sign` enforces at write
      time (refuses a noncompliant body) — canonical source is
      **`bin/lib/body-grammar.sh`**; do NOT paraphrase it into a brief.
- [ ] Before writing `DECISION:`, ask the cheaper question: did the human
      already explicitly ask for this exact change, with verified evidence it
      does what was asked? If yes there is no decision. Not mechanically
      checkable (#125).

## Ecosystem protocols (realisateur baseline)
The checklist above governs work inside this repo. These govern anything that
reaches OUTSIDE it. Each is a command on `PATH`. If a command is missing, say
so loudly rather than doing the step by hand: a missing guard is a finding,
not an inconvenience.

- **Changing machine-wide config** — crontab, `~/.claude` settings hooks,
  systemd units, autostart, WM config, `~/.local/bin`. Run:
  `notify-senechal <door> <field>=<value>` — TYPED since 2026-08-16
  (realisateur#352); the prose form exits 2. `--doors` lists them. None yet
  carries a crontab entry (senechal#325), so cron changes are filed by hand
  and must say so. The project that generates machine config **owns** it;
  `senechal` owns **knowing it exists**. Do this unasked, and now.

- **Writing into another project's repo** — run `check-project-busy <project>`
  first. On `BUSY`, defer the write and note what was deferred.

- **Asking for research** — `bibliothecaire` answers research requests through
  a command, not a cross-write. Run:
  `consulte --claim '<the claim>' --falsifier '<what would falsify it>' --from <this project>`
  It files a GitHub issue on `hf7y/bibliothecaire`, so it needs no clone and no
  push access. `--falsifier` is required: a request that names nothing that
  would settle it against you is asking for agreement, not research.
  Then `consulte list --from <this project>` and `consulte show <n>`.
  **Filing is free; answering is metered** — ask once and read the queue first.

- **Finding something fixable** — fix it in whatever repo it lives in and PR it
  there. Reversible fixes run unattended; privileged ones wait, as a tested
  script. An issue or a finding "left for" someone is not a move: nothing reads prose.

- **Filing during the v1 freeze** — `realisateur` takes `durable` only: a bug, a
  broken guard, a missing credential. Anything `decayable` — an idea or a build
  that may be obviated before it is reached — goes where v2 lives:
  `defere '<line>' --project scheduler` (hf7y/scheduler#303-308). The two words
  are the pair already in `bin/lib/labels.tsv`; this is not new vocabulary.
  **The freeze is enforced at the channel, not here**: once the monthly cut
  predicate is deployed (realisateur#602), a merge to realisateur `main` does
  not reach any host until the next window, or until Zach approves a
  `workflow_dispatch` with `force_cut: true`. So this bullet is a routing rule,
  and the thing that actually holds is the cadence.
```
