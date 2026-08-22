# Build discipline — lessons every scaffolded project inherits

The project-agnostic disciplines every new project carries from day one.
Generalized from `crt`'s first 4 days, 186 commits, then extended by each
failure the estate has actually had.

**The rule of this file: prefer a mechanical guard — a test, a lint, a CI
check — over a paragraph.** Prose decays; guards don't. Where a row names a
guard, the guard is the authority and this text is a pointer.

The full incident record for every pattern below is in the vault at
`realisateur/build-discipline-archaeology-20260817.md`. What stays here is the
claim; what left is the story.

## The recurring failure patterns (what to design against)

1. **Silent failure.** Exit 0 / no output / a healthy-looking status over a
   dead device, a truncated sync, a `pipefail`+SIGPIPE pipeline. Found by
   archaeology, not by alarm. *The #1 cost multiplier.*
2. **Build-but-don't-wire.** Finished and tested, then left disconnected from
   the path that runs it. Earliest form: finished work left uncommitted.
3. **Layer-not-replace.** A new mechanism stacked on the old one it was meant
   to supersede, retiring nothing.
4. **Hand-copy deploy loses work.** Deploy targets that aren't git clones
   drift silently.
5. **Secrets in the open.** Keys in tracked files are permanent, in history.
   Build debris tracked as if it were source.
6. **Cruft on shared hosts.** A script or unit dropped on a host the project
   doesn't own becomes unattributable the moment the project moves on.
7. **A claim outlives its verification.** Checked once, written as prose,
   believed long after it ceased to hold — by people and by audits quoting it.
   The tell: *"I looked and saw nothing"* was never distinguished from *"I did
   not look."*
8. **Warn-then-continue.** The check detected it, printed it, and proceeded.
   Distinct from silent failure: the code *knew*.
9. **The actor grades its own homework.** Whoever performs the work must not
   be the source of truth for whether it worked.
10. **A rename breaks a silent consumer.** Moving a file updates the thing
    that moved it, not the unrelated tool that hardcoded the old path.
11. **Writer and reader disagree about location.** Committed but unpushed
    when the consumer clones from origin; on `main` when the job reads
    `master`. Everything "succeeds" and nothing arrives.
12. **Prose that gets evaluated instead of stored.** Text meant as a record
    handed to something that interprets it. `git commit -m "... \`cmd\` ..."`
    executes the snippet it was quoting. The safety of the path depends on the
    *content*, so it tests clean until the content changes.
13. **A decision without a dispatch path.** Recorded where no executor reads,
    so it is never implemented and later sessions re-derive it blind.
14. **A sensor reports a negative it never checked for.** A probe reads one
    source, finds nothing, and reports absence of the thing rather than
    absence of evidence. Failing toward OK.
15. **A file's prose about its own structure gets parsed as its structure.**
    A comment describing the format becomes a row in the format.
16. **A correct refusal that nothing retries.** The guard was right and the
    work still never happened, because refusal was the end of the path.
17. **The reader that destroys what it read.** A mechanism consumes human
    input and leaves no copy, so a failure downstream loses the input too.
18. **A safeguard named for its mechanism gets removed by someone
    simplifying the mechanism.** Name a guard for the failure it prevents,
    never for how it works.
19. **The operator reaches around the system instead of through it**, and the
    system's own record of what happened is then wrong.
20. **A census is blind to a class it cannot enumerate**, and its number is
    read as complete. Report what could not be counted, or report nothing.
21. **A guard that fails safe but never clears.** An outage with better
    manners than an outage. Row 14 is a sensor failing toward OK; this is a
    guard succeeding toward stuck. **The test:** can the condition this guard
    waits on clear without a human? If not, it needs a deadline or a voice,
    not just a refusal.

## The disciplines (stated as mechanical rules)

- **Fail loud by default.** No silent no-op path.
- **"Working" needs a witness.** A test name or a human-sense observation,
  not an exit code alone.
- **Wire-on-commit.** Nothing is done until something runs it on the real path.
- **Name what you retire.** A new mechanism that overlaps an old one says
  which one is dead.
- **One source of truth for config.** Read from one place, never retyped per
  file. This is not only about config: ten failures in one day were all two
  copies of a truth with nothing watching for drift.
- **Deploy is a git operation.** Deploy targets are clones; drift fails loud.
- **No secret in a tracked file.**
- **Probe, don't quote.** Re-run the command before repeating a written claim
  about system state.
- **Write the mechanism, not the weather** (pattern 7). Say what a thing DOES
  and must keep doing; correct at the source, never by a comment beside it.
- **Never `2>/dev/null` a privileged probe.** Discarding stderr turns "not
  permitted" into "not present".
- **Verify at the consumer's location, not the producer's.**
- **The runner writes the verdict, not the actor.**
- **Commit messages go through a file, never through the shell.**
- **Subagents work on branches.** A dirty tree at exit is a failed run.

### Settled definition: "pushed" (2026-08-01, Zach)

**A host-only branch is a blocker.** A repository is not recoverable from its
remote if any branch exists only on the host. The test is the remote **ref**,
never the tracking config:

```sh
git for-each-ref --format='%(refname:short)' refs/heads/ | while read -r b; do
  git rev-parse --verify -q "origin/$b" >/dev/null || echo "$b exists only here"
  [ "$(git rev-list --count "origin/$b..$b")" = 0 ] || echo "$b is ahead"
done
```

## The baseline (ONE file, read through the `discipline` command)

**The fenced block below is the ONE SOURCE, and it is the ONLY copy.**
`discipline` prints it, and every project's `CLAUDE.md` carries one line
pointing at that command. Do not restate a row's reasoning here: a row that
needs an argument has an issue, and this block is printed on every
invocation.

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
```
