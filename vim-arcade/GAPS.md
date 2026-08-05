# GAPS -- what `entraine` cannot yet do

Recorded 2026-07-30 during the bashify pass. These are to be closed
later; they are written down now so the utility never pretends.

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
