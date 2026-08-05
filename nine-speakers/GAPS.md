# GAPS -- what `chante` cannot yet do

Recorded 2026-07-30 during the bashify pass. These are to be closed
later; they are written down now so the utility never pretends.

## No shell tooling existed at all

This tree had **zero** shell scripts. So `chante` is currently a contract
and a front door with nothing behind it: every subcommand is a gap.

**This is the most important finding available here.** It is the honest
measure of how much of this work was ever mechanised, and the answer is
none of it.

## Python that was never given a shell contract (20 files)

These do real work but are not reachable through the verb, because they
have no stated argv/output promise to wrap:

- `nine_speakers/__init__.py`
- `nine_speakers/acoustics.py`
- `nine_speakers/audio.py`
- `nine_speakers/bus.py`
- `nine_speakers/ca_model.py`
- `nine_speakers/node.py`
- `nine_speakers/selfmodel.py`
- `nine_speakers/sim.py`
- `nine_speakers/viz.py`
- `nine_speakers/world.py`
- `tests/__init__.py`
- `tests/test_acoustics.py`
- `tests/test_audio.py`
- `tests/test_bus.py`
- `tests/test_ca_model.py`
- `tests/test_layering.py`
- `tests/test_node.py`
- `tests/test_selfmodel.py`
- `tests/test_viz.py`
- `tests/test_world.py`

## Standing gap: the cost baseline

No before-measurement exists for what the previous implementation cost
per call, so the saving from mechanising it is **unmeasured, not zero
and not assumed**. Closing this needs a real measurement, not an estimate.
