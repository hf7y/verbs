# GAPS — what these verbs cannot yet do

## The BLIND code is not one number

`claim-drift` and `closeout-lint` exit **6** on could-not-look; `silence-audit`
exits **3**. Both are "I could not see", and a caller checking one number gets
the other wrong. Twenty-one scripts share the confusion. hf7y/realisateur#334.

## The cost baseline is still unmeasured

No before-measurement exists for what the previous implementation cost per
call, so the saving from mechanising it is **unmeasured — not zero, and not
assumed**. Closing this needs a real measurement, not an estimate.
