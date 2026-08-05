# GAPS -- what `juge` cannot yet do

Recorded 2026-07-30 during the bashify pass. These are to be closed
later; they are written down now so the utility never pretends.

## Deliberately not exposed (1)

That many files in the legacy tree are named after an external paid
service. Exposing them as subcommands would break this branch's stated
guarantee, so they are counted here and not carried over. Their paths
are on the default branch for anyone who needs them.

Closing this gap means writing a plain replacement, not re-exposing them.

## Standing gap: the cost baseline

No before-measurement exists for what the previous implementation cost
per call, so the saving from mechanising it is **unmeasured, not zero
and not assumed**. Closing this needs a real measurement, not an estimate.
