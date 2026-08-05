# vim-arcade, bashified

*`entraine` — train the hands: vim motions as a game mechanic*
*`joue` — play your live GitHub issue/PR queue as a vim-arcade level*

This is the **bashified** branch of `vim-arcade`. It carries two shell
utilities, and — since 2026-08-04 — the Python engine one of them fronts.

```
bin/entraine          train the hands (a front door; the teaching logic is on main)
bin/joue              triage your live GitHub queue (self-contained; see below)
man/entraine.1        the promise entraine is judged against
man/joue.1            the promise joue is judged against
vim_arcade/           the engine joue runs -- a DERIVED copy of main's, see below
ENGINE-PROVENANCE     which sha and which tree that copy came from
bin/sync-engine.sh    carries the copy across, and proves it is still a copy
CONTRACT.md           the promises, and the reasoning for carrying an engine
GAPS.md               what these cannot do yet
test/                 the contract test, runnable against any implementation
```

## "a plain shell utility and nothing else" — no longer true, and why

This file said exactly that until 2026-08-04. It is written down rather
than quietly edited out, because a README that silently stops being true
is the defect this ecosystem cares most about.

`joue` is bash over a stdlib-only Python engine. If the engine stayed on
`main` only, then `joue` would work exactly where a vim-arcade development
clone happened to exist and nowhere else — which is the shape it was
brought here to escape. Its predecessor was `~/.local/bin/joue` pointing at
`~/Documents/Projects/vim-arcade/joue`: a hand-installed symlink into a dev
clone, owned by no installer, invisible to `install-verbs.sh`, and dead the
moment that clone was removed.

So the engine travels with the verb. **A standalone shallow clone of this
branch, on a machine with no vim-arcade checkout anywhere, is a complete
and working `joue`.** That is not a claim; see Verify.

`bin/entraine` still has the old shape — it reads `ENTRAINE_LEGACY_ROOT`
and defaults to a path under `~/Documents/Projects`. That is a gap, it is
recorded in `GAPS.md`, and it is not fixed here.

## Why this is a branch and not a repository

*Unchanged, and now load-bearing in a second way. Read the distinction in
the last paragraph before acting on either half.*

The purge here is **total**. Everything this tree used to carry beyond
the tools themselves is gone from these files. It is not lost: it is on
`main` branch of this same repository, one `git log main` away.

**That is the only reason a total purge is safe.** Extracting this
branch into a standalone repository would destroy the archive that
justifies the purge, and leave defensive code standing with no visible
cause -- which is how hard-won guards get deleted by the next reader.
Do not do it.

**Carrying the engine does not weaken that, and does not license it.**
Two different acts get confused here:

| | archive still reachable? |
|---|---|
| `git clone --branch bashified <this repo>` | **yes** — same repository; `git log origin/main` is one fetch away |
| copying this tree into a *new* repository | **no** — the history is severed, which is what the warning forbids |

A consumer clone is the first. It is the entire distribution design (see
realisateur `VERB-DISTRIBUTION.md`). The engine sitting here makes such a
clone *self-sufficient at runtime*; it does not make this tree a project,
and nothing here should ever be edited as if it were one.

## `vim_arcade/` here is derived. Do not edit it.

Two copies of the same 21 files exist in this repository. That is only
tolerable because one of them is derived and the derivation is checkable
by a command rather than by trust:

```
git rev-parse origin/main:vim_arcade  ==  git rev-parse HEAD:vim_arcade
```

A git tree object id is not a heuristic — one differing byte, one added or
removed file, and the ids differ. `ENGINE-PROVENANCE` records the id, so
half the check ("has this copy been hand-edited since it was carried?")
runs in a standalone clone that has never heard of `main`.

Fix bugs on `main`. Then `bin/sync-engine.sh` and commit. If you fix one
here instead, `--check` exits 5 and says so, because a fix living only in
a derived copy is a fix `main` will never ship.

## Verify

```
./test/contract-test.sh bin/entraine
./test/contract-test.sh bin/joue
./bin/sync-engine.sh --check
```

And the claim that actually matters — `joue` works with no dev clone —
proved from a clone of nothing but this branch:

```
git clone --depth 1 --branch bashified <repo> /tmp/joue-standalone
cd /tmp/joue-standalone && ./bin/joue --help
```

`--help` is the one invocation that must work with no terminal, no `gh`
and no engine, so it is the honest floor — and a floor is not a proof that
the engine is there. Two checks above it, in the same standalone clone:

```
./bin/joue ; echo $?          # 6 BLIND: names the missing TTY.
                              # It only reaches that probe after finding
                              # vim_arcade/gh_game.py, so 6 (not 5) is
                              # itself the witness that the engine is here.
PYTHONPATH=. python3 -c 'import vim_arcade.gh_game'   # imports, stdlib only
```
