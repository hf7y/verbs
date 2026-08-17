#!/usr/bin/env bash
# check-witness.sh -- the runtime witness every check in bin/ leaves behind.
#
# Built 2026-07-28 (paced cycle), FOCUS.md Backlog step 1b. Answers a human
# question: "how do we make a built-but-unwired check fail noisily?"
#
# Static analysis CANNOT answer that. Grepping for a check's name proves it
# is MENTIONED; a call site inside a branch that never executes greps
# identically to a live one. The only thing that proves wiring is a RUNTIME
# WITNESS: the check itself recording that it ran. That is the same
# dead-man-switch shape this repo already trusts for jobs (EXPIRY_DAYS),
# applied to checks.
#
# It catches BOTH failure modes:
#   * never wired -- built, committed, never called by anything;
#   * silently unwired later -- a `sweep` pass deleted in a refactor. That
#     is exactly what happened to blockers-freshness-check.sh for two days
#     in July 2026, and nothing reported it.
#
# This file is the ONE source for the witness directory and the touch
# semantics -- bin/check-witness-lint.sh reads it too, rather than
# re-deriving the path (build discipline: config from one source, not
# retyped per file).

# Where witnesses live. State, not config -- safe to delete; the next sweep
# re-creates every witness for every check that is actually wired.
CHECK_WITNESS_DIR="${CHECK_WITNESS_DIR:-$HOME/.local/share/scheduler-checks}"

# check_witness [name] -- record that this check is running. Call it as the
# FIRST act of the script, before any early exit: a check that ran and came
# back BLIND still RAN, and that is what this witness is about.
#
# Deliberately never fatal. A check must not fail because its bookkeeping
# could not be written -- that would turn a missing directory into a broken
# check, which is the opposite of the point. An unwritable witness surfaces
# as a stale/missing finding in bin/check-witness-lint.sh instead, which is
# the loud channel that already exists.
check_witness() {
  local name="${1:-$(basename "${BASH_SOURCE[1]:-unknown}")}"
  mkdir -p "$CHECK_WITNESS_DIR" 2>/dev/null || return 0
  # The braces matter: `cmd >file 2>/dev/null` still lets BASH itself print
  # "Permission denied" for a failed redirection, which would make a check's
  # own bookkeeping noise up its output. Redirecting the group's stderr first
  # catches that message too.
  { printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
      > "$CHECK_WITNESS_DIR/$name.lastrun"; } 2>/dev/null || return 0
  return 0
}
