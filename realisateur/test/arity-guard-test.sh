#!/usr/bin/env bash
# arity-guard-test.sh -- regression test for the 2026-08-01 arity-guard bug.
#
# `bin/arpente` and `bin/epluche` grew a `-*) cmd=list` arm (4a9dc85) that
# routed ANY leading flag straight to the listing path without ever calling
# `verb_parse`. Effect: `--nonsense` (and every other unrecognised flag)
# printed the subcommand list and exited 0 -- a usage error reported as
# success. It also meant `--help`/`--version` "worked" only by accident:
# they too fell into `cmd=list`, printed the wrong thing, and happened to
# exit 0 -- not by being parsed, but by never being looked at.
#
# The fix restores the `verb_parse "$@"` call (the pattern already used by
# `bin/juge`) so a leading flag is actually parsed instead of rubber-stamped
# as "list". This test asserts the NEGATIVE path (unknown flag -> 2), the
# POSITIVE path (a real invocation still -> 0), and -- because this
# ecosystem's recorded worst failure is "failing toward OK" -- that an
# unreachable request still fails loud rather than defaulting to 0.
#
# BLIND (exit 6) is deliberately NOT asserted here: `bin/arpente` and
# `bin/epluche` contain no domain-reading logic of their own (verified by
# reading both files whole -- every subcommand branch either execs out to
# a legacy script, named via *_LEGACY_ROOT, that lives entirely outside
# this branch, or hits the deterministic `-x` gap check below). `lib/verb.sh`
# defines `verb_blind` but neither verb ever calls it, so there is no
# reachable blind-and-exits-0 path inside this branch to regress-test.
# If the exec'd legacy scripts have that defect, it is theirs to fix, not
# this dispatcher's.
#
#   ./test/arity-guard-test.sh <command-under-test> [label]
#
# It never hangs: every invocation is wrapped in `timeout`.

set -uo pipefail
CUT="${1:?usage: arity-guard-test.sh <command-under-test> [label]}"
LABEL="${2:-$CUT}"
TIMEOUT="${CONTRACT_TIMEOUT:-20}"

PASS=0; FAIL=0
declare -a FAILED=()

# run <expected-exit> <description> -- args...
_run() {
  local want="$1" desc="$2"; shift 2
  local out rc
  out="$(timeout "$TIMEOUT" "$CUT" "$@" 2>&1)"; rc=$?
  if [ "$rc" = 124 ]; then
    FAIL=$((FAIL+1)); FAILED+=("$desc -- TIMED OUT after ${TIMEOUT}s")
    printf 'FAIL  %s\n        timed out after %ss\n' "$desc" "$TIMEOUT"; return 1
  fi
  LAST_OUT="$out"; LAST_RC="$rc"
  if [ "$rc" != "$want" ]; then
    FAIL=$((FAIL+1)); FAILED+=("$desc -- exit $rc, wanted $want")
    printf 'FAIL  %s\n        exit %s (wanted %s): %s\n' "$desc" "$rc" "$want" "$(printf '%s' "$out" | head -2)"; return 1
  fi
  PASS=$((PASS+1)); printf 'PASS  %s\n' "$desc"; return 0
}

_out_matches() {
  local re="$1" desc="$2"
  if printf '%s' "${LAST_OUT:-}" | grep -qE "$re"; then
    PASS=$((PASS+1)); printf 'PASS  %s\n' "$desc"
  else
    FAIL=$((FAIL+1)); FAILED+=("$desc")
    printf 'FAIL  %s\n        output did not match /%s/\n' "$desc" "$re"
  fi
}

printf '=== arity-guard regression: %s\n' "$LABEL"
printf '    under test: %s\n\n' "$CUT"

# NEGATIVE PATH -- the actual bug. An unrecognised flag used to fall
# through the `-*) cmd=list` arm straight to the listing path and exit 0.
_run 2 'unknown flag exits 2, not 0 (the arity-guard bug)'  --this-flag-does-not-exist

# NEGATIVE PATH, second flag shape -- a near-miss short flag must not be
# silently absorbed into "list" either.
_run 2 'unknown short flag exits 2, not 0'  -z

# POSITIVE PATH -- the fix must not break the plain listing the arity
# guard exists to protect.
_run 0 'bare invocation (no args) still lists and exits 0'
_out_matches 'subcommands' 'bare invocation still prints the subcommand list'

_run 0 'explicit `list` subcommand still exits 0'  list

# POSITIVE PATH -- `--help` must now be genuinely parsed (not just
# accidentally routed through `cmd=list`), so it must print real usage
# text, not the plain listing.
_run 0 '--help exits 0'  --help
_out_matches 'usage' '--help prints usage (not the plain listing)'
_out_matches 'exit' '--help documents the exit-code contract'

# REGRESSION GUARD, pre-existing behaviour, re-checked after the fix --
# this is the "fails toward OK" concern from the other half of this task.
# An unrecognised (but non-flag) subcommand name must still fail loud (4),
# never default to 0, exactly as `bin/arpente` and `bin/epluche`'s own
# header comments promise ("a subcommand with nothing behind it reports
# GAP, never an exit-0 no-op").
_run 4 'unrecognised subcommand still reports GAP (4), never 0'  not-a-real-subcommand-xyz

printf '\n--- %s: %d passed, %d failed\n' "$LABEL" "$PASS" "$FAIL"
if [ "${#FAILED[@]}" -gt 0 ]; then
  printf 'failures:\n'; printf '  - %s\n' "${FAILED[@]}"
fi
[ "$FAIL" = 0 ]
