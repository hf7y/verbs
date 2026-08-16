# vim-arcade, bashified

*`entraine` — train the hands: vim motions as a game mechanic (off the user path since 2026-08-05, see GAPS §0)*
*`vim-arcade` — play your live GitHub issue/PR queue as a vim-arcade level*

This is the **bashified** branch of `vim-arcade`. It carries two shell
utilities, and — since 2026-08-04 — the Python engine one of them fronts.

```
bin/entraine          train the hands (a front door; the teaching logic is on main)
bin/vim-arcade              triage your live GitHub queue (self-contained; see below)
man/entraine.1        the promise entraine is judged against
man/vim-arcade.1            the promise vim-arcade is judged against
dist/vim-arcade.pyz         the engine vim-arcade runs -- built from main, carried by CI
ENGINE-PROVENANCE     which main commit built the carried archive
CONTRACT.md           the promises, and the reasoning for carrying an engine
GAPS.md               what these cannot do yet
test/                 the contract test, runnable against any implementation
```

## "a plain shell utility and nothing else" — no longer true, and why

This file said exactly that until 2026-08-04. It is written down rather
than quietly edited out, because a README that silently stops being true
is the defect this ecosystem cares most about.

`vim-arcade` is bash over a stdlib-only Python engine. If the engine stayed on
`main` only, then `vim-arcade` would work exactly where a vim-arcade development
clone happened to exist and nowhere else — which is the shape it was
brought here to escape. Its predecessor was `~/.local/bin/joue` pointing at
`~/Documents/Projects/vim-arcade/joue`: a hand-installed symlink into a dev
clone, owned by no installer, invisible to `install-verbs.sh`, and dead the
moment that clone was removed.

So the engine travels with the verb — since 2026-08-15 (issue #131) as a
**built artifact**, `dist/vim-arcade.pyz`, not a source copy. **A standalone
shallow clone of this branch, on a machine with no vim-arcade checkout
anywhere, is a complete and working `vim-arcade`.** That is not a claim; see
Verify.

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

## `dist/vim-arcade.pyz` here is built. Do not edit it.

Until 2026-08-15 this branch carried `vim_arcade/` as a byte-verbatim
source copy, policed by a git-tree-id check (`bin/sync-engine.sh`) because
source duplicated as source looks editable. Issue #131 retired both: the
payload is now a built artifact, `dist/vim-arcade.pyz`, produced by
`bin/build-zipapp.sh` on `main` and committed here by
`.github/workflows/carry-zipapp.yml` on every push. An artifact does not
invite hand-editing the way a second copy of 28 `.py` files did, so there
is nothing left to police — `ENGINE-PROVENANCE` now just names which main
commit built it.

Fix bugs on `main`. The next push carries the rebuilt archive here
automatically; nothing needs running by hand.

## Verify

```
./test/contract-test.sh bin/entraine
./test/contract-test.sh bin/vim-arcade
```

And the claim that actually matters — `vim-arcade` works with no dev clone —
proved from a clone of nothing but this branch:

```
git clone --depth 1 --branch bashified <repo> /tmp/vim-arcade-standalone
cd /tmp/vim-arcade-standalone && ./bin/vim-arcade --help
```

`--help` is the one invocation that must work with no terminal, no `gh`
and no engine, so it is the honest floor — and a floor is not a proof that
the engine is there. Two checks above it, in the same standalone clone:

```
./bin/vim-arcade ; echo $?          # 6 BLIND: names the missing TTY.
                              # It only reaches that probe after finding
                              # dist/vim-arcade.pyz, so 6 (not 5) is
                              # itself the witness that the engine is here.
python3 -c 'import sys; sys.path.insert(0, "dist/vim-arcade.pyz"); import vim_arcade.gh_game'   # imports, stdlib only
```
