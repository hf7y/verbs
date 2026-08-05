# GAPS -- what `capte` cannot yet do

Recorded 2026-07-30 during the bashify pass. These are to be closed
later; they are written down now so the utility never pretends.

## No shell tooling existed at all

This tree had **zero** shell scripts. So `capte` is currently a contract
and a front door with nothing behind it: every subcommand is a gap.

**This is the most important finding available here.** It is the honest
measure of how much of this work was ever mechanised, and the answer is
none of it.

## Tooling in other languages, not reachable through the verb (2 files)

This tree does real work in javascript/typescript. The verb wraps shell
only, so none of it is exposed yet. This is the largest single gap here:

- `public/app.js`
- `server/waitlist-server.js`

## Standing gap: the cost baseline

No before-measurement exists for what the previous implementation cost
per call, so the saving from mechanising it is **unmeasured, not zero
and not assumed**. Closing this needs a real measurement, not an estimate.
