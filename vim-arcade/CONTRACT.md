# CONTRACT — `vim-arcade` bashified

This branch declares **two** verbs. `entraine` came first and the bulk of
this document is its contract, unchanged below. `vim-arcade` was added
2026-08-04 and required answering a question about the branch itself
before it could be added at all, so that answer comes first.

---

# The question `vim-arcade` forced: does `bashified` carry an engine?

**Answered: yes, and the declaration rule does not grow a second shape.**

The rule (realisateur `bin/lib/verb-set.sh`) is:

> a project declares a verb ⟺ its `bashified` branch carries an executable
> `bin/<name>` **and** a matching `man/<name>.1`

`vim-arcade` is bash over a stdlib-only Python engine (`vim_arcade/`, 21 files,
284K) that lived only on `main`. The two candidate answers were:

**(a) the rule grows a second shape** — some declaration form meaning
"this verb's implementation is elsewhere, fetch that too."

**(b) `bashified` carries the engine** — the branch stops being shell-only
and ships what its verbs need in order to run.

**(b), for three reasons, in the order that decided it.**

**1. (a) does not satisfy the rule; it repeals it.** The rule's own header
says declarations are read with `git ls-tree` "so that a project needs no
checkout of `bashified` for its verbs to count… that is what lets a bare
host recover the surface." A second shape pointing at `main` makes the
declared verb a promissory note: the consumer clones one ref, gets an
executable `bin/vim-arcade`, and it does not run. `VERB-DISTRIBUTION.md` §6(3)
records that exact failure, found by hand — a build where every verb was
`-f && -x` and every verb was broken — and the fix adopted there was to
make the check *run each verb's `--help`*. Under (a), `vim-arcade` would pass
even that check and still be useless, because introducing itself is the
one thing a front door can do without its engine.

**2. The seam this branch is cut along is not shell-versus-Python.** Zach,
2026-08-04: *"the seam is between end products and dev environment
utilities. the latter should be bashify shaped."* `entraine` is a game you
play; `vim-arcade` is how you work. A rule change motivated by "but it is
Python" would enforce a seam nobody chose. The precedent is already in the
ecosystem: bibliothecaire's `bashified` carries `bin/page92.py` —
executable Python, no man page, correctly not a verb and correctly there.

**3. A rule change is ecosystem-wide; a branch change is not.** (a) edits
the one derivation that two callers and a CI build depend on, in order to
solve one project's problem, and every other project would then have to
decide whether it is a case of the new shape. (b) is contained in this
repository and costs one directory.

## What (b) costs, and the mechanism that pays for it

It costs **two copies of the same 21 files in one repository** — which is
BUILD-DISCIPLINE's *"config read from one source, not retyped per file"*
straightforwardly violated, that clause being about derivations and not
only about hostnames.

Two copies are tolerable only if one is **derived** and the derivation is
**checkable by a command**. Both halves are mechanized, in
`bin/sync-engine.sh`:

| property | how |
|---|---|
| derived | `git checkout <ref> -- vim_arcade/`. Byte-verbatim; the copy is never edited on this branch. |
| checkable | `git rev-parse <ref>:vim_arcade` vs `git rev-parse HEAD:vim_arcade`. A git **tree object id**: one differing byte, or one file added or removed, and they differ. Recorded in `ENGINE-PROVENANCE`. |
| checkable **without** `main` | recorded tree id vs `HEAD:vim_arcade` runs in a standalone clone that has never heard of `main`. This half catches the failure that would actually destroy the design: a bug fixed in the derived copy, which `main` will never see. |
| honest when it cannot look | `--check` exits **6 BLIND** when the source ref is unreachable — never 0. "I could not compare" is not "up to date"; that is `garde`'s failure in `MONKEY.md` §5. |
| honest when it is behind | exits **4 GAP** when the source ref has moved on. Behind-but-named is not broken, it is temporal, and 4 drains. |

### Rejected alternatives, each with what it breaks

| | why not |
|---|---|
| **git submodule** | a consumer clones ONE ref; a submodule makes that two fetches and a second credential — exactly the sprawl `VERB-DISTRIBUTION.md` §5 collapsed. |
| **subtree merge** | merges `main`'s history into `bashified`. This branch's whole justification (README) is that the purged material is one `git log main` away; merging `main` back in dissolves the purge it defends. |
| **a build step** | then "executable `bin/<name>`" no longer suffices for the verb to *run*, and a build tag ships a tree that must be built before use. Carrying the output is what makes a checkout usable as checked out. |
| **vendor only what `vim-arcade` imports** | measured: `gh_game`'s import closure is 12 of the 21 modules. A subset means a new `import` on `main` breaks `bashified` at a distance, and nothing on `main` could know. The saving is ~120K; the cost is a tripwire. |

## What this does NOT decide

It does not decide the rule for anyone else. If a second project needs the
same thing, *that* is when "does the rule need a second shape" becomes a
real ecosystem question rather than this branch's local one — and the
evidence will then be two independent projects, which is the threshold
`lib/verb.sh`'s own de-fork note uses ("three copies of a thing is the
evidence that it belongs in one").

It also does not fix `entraine`, which still reaches outside its own tree
through `ENTRAINE_LEGACY_ROOT`. See `GAPS.md`.

---

# CONTRACT — `vim-arcade`

**play your live GitHub issue/PR queue as a vim-arcade level: an item you
clear with a motion is triaged for real.**

Coined 2026-08-04. Unlike `entraine`, whose page was written before its
tool, `vim-arcade`'s tooling existed first — as `~/.local/bin/joue`, a
hand-installed symlink into a dev clone, owned by no installer and
invisible to `install-verbs.sh`. So this contract is **derived from a
working thing**, and its obligations are correspondingly `bash` rather
than `summon`. What did not exist was the contract, and that is the
finding.

## The obligations

| obligation | HOW | backed by |
|---|---|---|
| Open the queue of the repository the CALLER stands in, not the one `vim-arcade` was installed from | bash | `gh_triage.get_repo_slug()` resolves from cwd; `bin/vim-arcade` passes no repo. This is what makes it correct from any directory on the machine |
| Run from a checkout with no vim-arcade dev clone anywhere on the machine | bash | the engine is carried on this branch; `bin/vim-arcade`'s `VIM_ARCADE_ENGINE_ROOT` defaults to its own tree root; `README.md` "Verify" gives the standalone-clone commands |
| Change nothing unless the caller spelled out `--live` | bash | `gh_game.main()`: `live = "--live" in argv`; otherwise every action logs the `gh` command it would have run |
| Refuse a merge locally, before building a `gh pr merge`, on a conflict, a draft, a blocked gate, or superseded content | bash | `vim_arcade/merge_safety.py` (issue #31). Superseded content is detected by overlap rather than by GitHub's conflict flag, because a superseded PR that still applies *cleanly* would otherwise merge silently |
| Dispatch every action key from exactly one event loop | bash | `gh_game.run()`; issue #39 deleted `gh_multipane.py` after the two loops drifted the same day both were touched |
| Say "I cannot see" distinctly from "nothing to report" | bash | `bin/vim-arcade` exits 6 for: no TTY, no `gh`, `gh` unauthenticated. The last is the sharp one — an unauthenticated `gh` still lists *public* repositories, so the queue comes back **short**, not empty, and a short queue reads as a quiet morning |
| Say "this checkout is incomplete" distinctly from "I cannot see" | bash | exit 5 when `vim_arcade/gh_game.py` is absent or `python3` is missing. One nonzero would have flattened two different world-states |
| Introduce itself with no terminal, no `gh`, and no engine | bash | `--help` is answered before any probe. It is the one doctest in `man/vim-arcade.1` EXAMPLES |
| Never spend money | bash | `VERB_CAN_SUMMON=0`; no code path reaches a metered service |
| Advertise only the exit codes it can return | bash | `VERB_EXITS="0 2 5 6 7"`. No summon and no contracted-but-unbuilt action, so 3 and 4 are unreachable and are not offered |
| Keep the carried engine identical to the source ref's | bash | `bin/sync-engine.sh --check`, by git tree object id |

## What `vim-arcade` WILL NOT do

| obligation | HOW | backed by |
|---|---|---|
| Let `--force` override a refused merge | refused | the merge guard exists to prevent a merge nobody looked at. A refusal a flag can lift is a warning in a refusal's clothes. The only second look offered is a second `m` press, in the detail panel, for the title/diff-mismatch case alone |
| Dispatch item actions at map zoom | refused | a tile carries a name and a count, not a body — `gh_map.py`. You cannot safely press `x` on something you cannot read |
| Run a second event loop for a second front end | refused | issue #39. `joue-panes` was exactly that, and it drifted from `vim-arcade` the same day both were touched |
| Write when `--dry-run` and `--live` are both given | refused | not a merge of intents: a caller who said both does not know which they meant, and guessing "write" is the expensive guess |

## `joue-panes`: a flag, not a second verb

It is already a thin alias for `vim-arcade --map` — issue #39 collapsed the two
engines and left the script as a compatibility shim. It is **not**
declared here, and the reason is the declaration rule itself: a verb owes
a man page, and `man/joue-panes.1` would be `man/vim-arcade.1` with one sentence
changed. That is a second definition of one thing — the drift #39 removed,
reintroduced in slower motion and this time in prose.

Two supporting facts, both probed rather than assumed: nothing ever
installed it (on 2026-08-04 `~/.local/bin` held `vim-arcade` and no
`joue-panes`), and it is a starting *position* rather than a mode — `M`
reaches the map from the single-repo view anyway, so a second verb would
add no capability the one verb lacks.

---

# CONTRACT — `entraine`

**train the hands: teach vim, tmux and git as competence that survives a
fresh machine, by making the keystroke the game mechanic.**

Derived 2026-07-30 from `vim-arcade` as it actually is. This **revises**
the contract on `origin/bashified`, which recorded a single row —
*"no shell tooling existed in this project"* — and is not wrong so much
as one-eyed: it looked for shell scripts and therefore saw nothing. The
teaching logic is mechanized, tested, and curses-free. What does not
exist is the **verb**. That split is the finding this document exists to
state.

This document says what `entraine` is obliged to do because of its role.
Where document and code disagree, the document is right and the code is
behind.

## How to read the HOW column

| HOW | meaning | exit when unmet | cost |
|---|---|---|---|
| **bash** | mechanized. Runs free, unattended, no model in the loop. | 5 if it ran and broke | free |
| **summon** | SHOULD DO — in scope, not yet mechanized. | 4 (GAP), naming its own escalation | metered, printed before spending |
| **refused** | WON'T DO — out of scope on principle. | 7 (REFUSED) | n/a, no summon exists |

## The obligations

### Teaching the motions

| obligation | HOW | backed by |
|---|---|---|
| Parse a real vim key sequence — count, operator, motion, find target, register letter — and say when a buffer is partial rather than invalid | bash | `vim_arcade/motions.py`; `test_parse_count_incomplete`, `test_parse_operator_alone_is_partial_not_invalid`, `test_parse_invalid_buffer_is_not_partial` |
| Apply a motion with the same semantics real vim has, including yank never mutating what delete would | bash | `motions.apply_operator`; `test_apply_operator_yank_never_clears_walls`, `test_apply_operator_yfX_never_clears_walls` |
| Gate every motion to the level that taught it, and *say so* when a locked key is pressed rather than silently failing or working anyway | bash | `vim_arcade/session.py`; `test_locked_motion_returns_locked_event`, `test_operator_locked_target_motion_not_unlocked` |
| Every level is winnable with exactly the vocabulary unlocked at that point | bash | `test_every_level_has_a_goal` plus a per-level solvability test for levels 6–14 (`test_level_nine_is_operator_plus_find_and_solvable_with_dfX`, `test_level_fourteen_solvable_using_marks`, …) |
| Explain the new vocabulary before the learner needs it, in text written fresh | bash | `vim_arcade/tips.py` `LEVEL_TIPS`; `test_level_tips_key_motion_introduced_at_that_level` |
| Survive hostile input without hanging — huge counts, nested macro replay, multi-row visual selections | bash | `test_huge_replay_count_via_repeated_at_does_not_hang`, `test_visual_huge_count_does_not_hang`, `test_visual_mode_multi_row_selection_is_a_safe_no_op` |
| Prove all of the above without a terminal | bash | `pytest -q` — declared *outside* the repo, in `scheduler/schedule/vim-arcade.conf` `BATCH_TEST_CMD`; every module but `game.py` is curses-free by construction |

### Remembering where the learner got to

| obligation | HOW | backed by |
|---|---|---|
| Resume on the level last reached instead of restarting | bash | `vim_arcade/progress.py`; `test_save_then_load_round_trips` |
| Treat a corrupt, truncated or out-of-range save as "start over", never as a crash | bash | `test_load_progress_recovers_from_corrupt_file`, `test_load_progress_recovers_from_missing_key`, `test_load_progress_rejects_out_of_range_index` |
| Persist only the level index, rederiving everything else, so the save file cannot desync from the level table | bash | `progress.cumulative_unlocked`; `test_cumulative_unlocked_matches_playing_through_by_hand` |
| Finishing the game leaves the next play fresh | bash | `test_clear_progress_removes_the_file`, `test_clear_progress_is_a_no_op_when_file_absent` |

### The stability milestone — paste between an assistant chat and a file, on a fresh machine

The the project's own FOCUS file bar set 2026-07-28 by Zach. It is **not one
obligation**; its four checkboxes have four different HOW values, and
flattening them to one would hide three gaps.

| obligation | HOW | backed by |
|---|---|---|
| Teach pasting multi-line text INTO vim without autoindent staircasing it, naming all three safe routes (`:set paste`, `"+p`, `:r <file>`) | bash | `tips.INTRO_TIPS`; `test_intro_tips_cover_the_three_safe_paste_options` |
| Teach copying OUT of vim into the system clipboard, so it can go back to that chat | summon | **not built.** `tips.py` covers the inbound direction only; nothing in `LEVELS` or `INTRO_TIPS` mentions the outbound one |
| Use realistic material — a code block and a Markdown blockquote of the shape Zach actually moves between an assistant chat and a FOCUS file | summon | undetermined — the paste lesson is an advice *screen*, not a level whose grid content **is** the material. Settled by a decision on which of the two it should be; nothing in the repo says |
| Zach does a real chat→vim→chat round trip on a machine without his config and names what he used | summon | undetermined — `(waiting: Zach)` in the project's own FOCUS file. Only a person can supply this witness; no code closes it |
| Enforce that everything taught works on stock vim with no `~/.vimrc` and no plugins | summon | **unenforced.** The constraint is stated three times in `FOCUS.md` and nothing checks it; no test asserts a taught keystroke is stock |

### Being a verb at all

| obligation | HOW | backed by |
|---|---|---|
| Be invocable as `entraine` | summon | **nothing exists.** No `bin/`, no `setup.py`/`pyproject.toml` console entry point, no `__main__.py`; `command -v entraine` is empty. The only entry point is `python3 -m vim_arcade.game`, which is a Python invocation, not a verb |
| Have a stated argv contract — which subcommands exist and what each promises | summon | undetermined — the bashify report records **0 subcommands**, and no file proposes any. Settled by deciding what a nightly caller would ask `entraine` for, which nothing yet does |
| Speak the exit vocabulary: 4 GAP, 5 BROKEN, 6 BLIND, 7 REFUSED | summon | **not implemented anywhere.** `game.main()` enters `curses.wrapper` directly, so "no TTY" (which is BLIND, 6) and any other failure are indistinguishable to a caller |
| Report "I cannot see" distinctly from "nothing to report" when there is no terminal | summon | **not implemented.** Documented in `README.md` as a caveat to a human ("needs a real terminal"), not as a machine-readable exit |

### The arcs that are named but not reachable

| obligation | HOW | backed by |
|---|---|---|
| Teach tmux pane splitting and focus movement to an actual learner | summon | `vim_arcade/panes.py` exists and passes 17 assertions (`test_leader_percent_splits_and_moves_focus_to_new_pane`, …) — but its own docstring says it is *"standalone from Session/LEVELS on purpose"*, so no learner can reach it. Built and unreachable is still a gap |
| Teach git hygiene and etiquette — why a commit message, small commits, fetch before you start, resolving a real conflict | summon | designed, not built. The 2026-07-27 `FOCUS.md` entry decides the *shape* (assistant-native tutor over a disposable sandbox repo, model-driven) and explicitly leaves the delivery undetermined: slash command vs a commands-directory template vs realisateur scaffolding |
| Teach `c` (change) alongside `d`/`y` | summon | undetermined — `README.md` "What's genuinely open": no grid-world analog without insert-mode text entry. Settled by a design call on whether this world has text entry at all |

### What `entraine` WILL NOT do

At least one refusal is expected, and these are quoted from the repo
rather than reasoned out here.

| obligation | HOW | backed by |
|---|---|---|
| Teach anything that needs a `~/.vimrc`, a plugin, or an installed dotfile | refused | the project's own FOCUS file milestone: *"Stock vim only. No `~/.vimrc`, no plugins — the whole point is competence that survives a fresh machine, and a paste trick that needs a dotfile is not the skill."* |
| Simulate command output for the learner | refused | the project's own FOCUS file 2026-07-27: *"make the user run the actual command and report real output back, never simulate output."* A tutor that prints what the command *would* say teaches trust in the tutor, not the tool |
| Teach git as an ASCII-grid game | refused | the project's own FOCUS file 2026-07-27, argued in full: vim moves a cursor over static text, git operates on live stateful history, and the honest teaching moment does not survive the metaphor "without faking the state underneath it" |
| Quote `vimtutor`'s own text | refused | enforced in bash, uniquely among these rows: `test_level_tips_do_not_quote_vimtutor_verbatim`. Vim-licensed text; the tips are written fresh |
| Drive a real tmux subprocess | refused | `vim_arcade/panes.py` docstring: a grid-world metaphor, *"not a real tmux subprocess"* — deliberately, to keep the mechanic curses-free and unit-testable, at the stated cost of teaching keybinding muscle memory only |

## Universal clauses

Every subcommand of `entraine`, without exception:

- exits **0 only if the promise was kept**. Never an exit-0 no-op.
- exits **4 (GAP)** when the obligation is in scope but not yet
  mechanized, and names its own escalation.
- exits **5 (BROKEN)** when it ran and broke.
- exits **6 (BLIND)** when it cannot read its domain — here, when there
  is no TTY to render into, or the progress file is unreadable rather
  than merely absent. "I cannot see" is never reported as "nothing to
  report".
- exits **7 (REFUSED)** for anything in the WILL NOT table above.
- **cannot spend** money unless it declares `--summon`, which has no
  short form and is never implied.

**`--summon` is available on 4 and forbidden on 7.** A gap names its
escalation; a refusal offers none, because having no escalation path is
what refusing on principle means. Asking `entraine --summon` to teach git
as a grid game must exit 7, not spend.

## The finding

Seven `bash` rows and thirteen `summon` rows describe the same tree. The
teaching logic — parsing, gating, level design, progress, tips — is real,
tested by name, and free to run. **None of it is reachable as a verb.**
`entraine` does not exist on this machine: there is no front door, no
argv contract, and no exit vocabulary, so nothing in the ecosystem can
call vim-arcade or tell why it failed. The cheapest honest next step is
not another motion level; it is a `bin/entraine` that can exit 6 when
there is no terminal.
