#!/usr/bin/env bash

answer_contract_text() {
  cat <<'EOF'
How an answer binds (the ANSWER CONTRACT, rules A-D, 2026-07-29):

- **A. Direction, not instruction.** A reply states standing intent;
  whoever acts re-derives the concrete action from CURRENT state, not
  from the state the question described. So a reply never goes stale.
- **B. Re-probe the premise.** An instruction carries state claims;
  re-probe them. Premise false + action reversible -> act on the intent
  and flag the correction. Premise false + action irreversible -> stop
  and surface.
- **C. Extract standing direction silently.** A reply that generalizes
  past its question is folded into the tracker, quoted and dated,
  without asking first.
- **D. No clean-check reports.** A re-probe that confirms the human was
  right produces no output at all.
EOF
}
