# GAPS -- what this branch's verbs cannot yet do

Recorded 2026-07-30 during the bashify pass. These are to be closed
later; they are written down now so the utility never pretends.

**Scope note, 2026-08-04.** Everything from "No shell tooling existed at
all" onward is about **`entraine`** and is unrevised. `joue`'s gaps are
the section immediately below, and they are a different kind: `joue`
works, so its gaps are about what is *unproven* and *unwatched* rather
than what is unbuilt.

---

# GAPS -- `joue` (2026-08-04)

## 1. The engine drift check is detectable but not DETECTED

`bin/sync-engine.sh --check` exists and is correct. **Nothing runs it.**
There is no CI on this branch, no scheduler job, and no hook: the check
fires when a human or an agent thinks to type it, which is the same
reliability as a comment asking people to be careful.

This is the load-bearing gap of the whole design in `CONTRACT.md`. Two
copies of `vim_arcade/` are justified by "the derivation is checkable by a
command"; an unrun command narrows the failure but does not close it. The
concrete bad outcome: `main` fixes a merge-guard bug, `bashified` is never
re-synced, and every consumer of the verb build keeps running the buggy
engine while `main`'s test suite is green.

Closing it needs one of: a workflow on this branch, a scheduler entry, or
`cut-verb-build.sh` learning to run each project's own `--check` before
assembling. The third is the right home and is not this repository's to
change.

## 2. The carried engine is not TESTED here

`tests/` is not carried and should not be — a test suite is not something
a consumer needs at runtime. But it means this branch verifies the engine
only through `bin/joue`'s own probes: that it is present, and that it
imports. **The assertion "this engine works" is made on `main` and
believed here.**

That is sound only as long as gap 1 is closed, because the tree id is what
transfers `main`'s green suite to this copy. Today the transfer is by
hand.

## 3. Exit codes 5, 6 and 7 were provoked by hand, not by a committed test

`test/contract-test.sh` is universal: seven assertions every bashified
verb must keep, and `joue` passes all seven. It does not reach `joue`'s
own exit vocabulary. The 5/6/7 paths were each provoked at a terminal on
2026-08-04 (missing engine, piped stdout, `--force`) and the transcript is
in a PR description, which is not a test.

`entraine`'s GAPS §4 records the same shortfall in its own words
(`test/provoke-entraine.txt` does not exist). One provoke file covering
both verbs is the obvious shape and neither has it.

## 4. The old symlink still shadows the declared verb

`~/.local/bin/joue -> ~/Documents/Projects/vim-arcade/joue` was still in
place on 2026-08-04. Nothing on this branch can remove it: `~/.local/bin`
is `installe`'s, and repointing it is a human's act (`VERB-DISTRIBUTION.md`
§7 flags the `installe`-learns-builds change as a separate sitting).

So until that happens, **declaring `joue` here changes what the ecosystem
knows and not what this host runs.** The root `joue` and `joue-panes`
scripts on `main` are also untouched and still work; they are the dev
tree's own launchers.

## 5. `--json` and `--quiet` are accepted and do nothing

The shared runtime parses both for every verb. `joue` is a curses front
end with no non-interactive output to shape, so both are inert. The man
page says so rather than implying a behaviour, but "documented as inert"
is weaker than "rejected", and rejecting them would mean diverging from
the shared runtime for one verb.

## 6. The carried engine cries "wrong branch" at every launch

Found by running `joue` under a real pty from a standalone clone, which is
the only way it was ever going to show up. The engine's own startup
staleness check (issue #18) compares the engine checkout's branch against
trunk, and a consumer's `bashified` clone is permanently and correctly not
on trunk, so every launch opens with:

```
vim-arcade startup check
engine: vim-arcade is on 'bashified', but the trunk is 'main'. git pull
would not have caught this.
[u] update engine & restart
[Enter] continue on this copy
```

The claim is false and the offered action is worse — `u` fast-forwards the
engine directory, which is not how a carried engine is ever updated.

**Fixed on `main`, not here** (`staleness.is_carried_engine()`, keyed on
`ENGINE-PROVENANCE`), which is the derived-copy rule working as intended:
the fix belongs on the source ref. It reaches this branch on the next
`bin/sync-engine.sh`, and until then `ENGINE-PROVENANCE` honestly names a
sha that predates it.

**So this branch ships a verb with a known false prompt on launch.** That
is written here rather than smoothed over, and it is the concrete
demonstration of gap 1: the sync is a manual step, and a manual step is
where a fix goes to sit.

## 7. No before-measurement of what `joue` replaces

Same standing gap `entraine` records: nothing measured what triaging this
queue by hand cost, so the saving is **unmeasured, not zero and not
assumed**.

---

## No shell tooling existed at all

This tree had **zero** shell scripts. So `entraine` is currently a contract
and a front door with nothing behind it: every subcommand is a gap.

**This is the most important finding available here.** It is the honest
measure of how much of this work was ever mechanised, and the answer is
none of it.

## Python that was never given a shell contract (15 files)

These do real work but are not reachable through the verb, because they
have no stated argv/output promise to wrap:

- `tests/__init__.py`
- `tests/test_motions.py`
- `tests/test_panes.py`
- `tests/test_progress.py`
- `tests/test_session.py`
- `tests/test_tips.py`
- `vim_arcade/__init__.py`
- `vim_arcade/game.py`
- `vim_arcade/grid.py`
- `vim_arcade/levels.py`
- `vim_arcade/motions.py`
- `vim_arcade/panes.py`
- `vim_arcade/progress.py`
- `vim_arcade/session.py`
- `vim_arcade/tips.py`

## Standing gap: the cost baseline

No before-measurement exists for what the previous implementation cost
per call, so the saving from mechanising it is **unmeasured, not zero
and not assumed**. Closing this needs a real measurement, not an estimate.

---

## What the page now promises and the tool does not do (2026-08-01)

`man/entraine.1` was rewritten **before** any implementation, deliberately:
the page is the promise the tool will be judged against. Everything here is
therefore owed, and is written down so the tool never pretends otherwise.

Scored by `test/page-test.sh entraine`, which is machine-run, not eyeballed:
**4 rows pass, 2 fail, 2 unchecked.** The two failures are the honest state
of a page-first pass and are expected to stay red until the verb exists.

### 1. Eight documented subcommands are not dispatched

`play`, `levels`, `tips`, `progress`, `reset`, `panes`, `git`, `simulate`.
Row 3 (bidirectional surface) fails on all eight.

### 2. They answer 2, and they owe 4 — this is the first thing to fix

`bin/entraine` has no arm for any of them, so they fall through to "unknown
subcommand" and **exit 2**. That is wrong in a specific way: 2 says *the
caller is wrong*, when in fact the caller read the page correctly and the
TOOL is behind. The correct answer is **4 (GAP)** naming its own escalation
— except `simulate`, which is a refusal and owes **7**.

The cheapest honest next step is not a level or a mechanic. It is a
`bin/entraine` that dispatches all eight names and answers 4, 7, or 6 —
including exiting **6 (BLIND) when there is no TTY**, which the contract
already identifies as the thing nothing in this project can currently say.

### 3. No example is a doctest yet

Row 5 fails: all three EXAMPLES exit 2. The page shows the invocations
without inventing output, because an example whose output was never
executed is a lie with a shell prompt in front of it. They become doctests
when the subcommands answer.

### 4. Exit-code reachability is unproven

Row 4 is UNCHECKED: there is no `test/provoke-entraine.txt`, so no
documented code has been shown reachable. It cannot be written honestly
until the subcommands exist.

### 5. Row 9 is not mechanized

Present-tense-only is reported UNCHECKED by the harness and is still
verified by reading.
