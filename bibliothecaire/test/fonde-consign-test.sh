#!/usr/bin/env bash
# fonde-consign-test.sh -- consign must ASK basheur what a deposit costs,
# not decide for it.
#
# THE BUG THIS EXISTS FOR. `do_consign` printed "consign is contracted on the
# page and has no mechanism yet" and demanded --summon, from a branch that
# never consulted basheur at all. consign-prose had been MECHANIZED since
# 2026-08-01, so the sentence was false and a FREE operation was gated behind
# a cost flag. `fauche` refuses to clear a repo whose prose is unconsigned and
# names `fonde consign --summon` as the remedy, so on 2026-08-05 that made 76
# prose files across the estate look like 76 agent turns. They were zero.
#
# WHY basheur IS FAKED HERE. The real one would either cost money or need a
# contract store this suite has no business editing. What is under test is not
# basheur -- it is whether fonde ASKS. So the fake reports each state exactly
# as basheur's own documented contract does:
#
#   basheur run <name>            MECHANIZED -> exec impl;  AGENT -> print summon, exit 3
#   basheur run --summon <name>   ...and summon an agent IF, AND ONLY IF, one is needed
#
# The assertions are therefore about fonde's behaviour in each case, and the
# MECHANIZED row is the one that was wrong.

set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
VERB="${1:-$ROOT/bin/fonde}"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A vault fonde will accept: present, and under version control (it refuses a
# deposit into an unversioned tree, which is its own assertion below).
VAULT="$TMP/vault"; mkdir -p "$VAULT"
git -C "$VAULT" init -q 2>/dev/null
printf 'prose\n' > "$TMP/DOC.md"

# fake basheur. $TMP/state selects which contract state it reports, so a single
# fixture covers both rows without two copies of the harness.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/basheur" <<'FAKE'
#!/usr/bin/env bash
state="$(cat "$FAKE_STATE")"
# Argument order matters and is copied from basheur's own usage text:
#   basheur run --summon <name>
# The flag comes AFTER the subcommand. An earlier version of this fake read it
# before, which made the --summon row pass for the wrong reason.
sub="${1:-}"; shift || true
summon=0; [ "${1:-}" = "--summon" ] && { summon=1; shift; }
case "$sub" in
  run)
    if [ "$state" = MECHANIZED ]; then
      # The impl ran. Nothing was spent, and it says so on stdout.
      printf 'DEPOSITED %s\n' "fake"; exit 0
    fi
    # AGENT: `run` alone prints the summon and exits 3; only --summon spends.
    if [ "$summon" = 1 ]; then printf 'AGENT-RAN\n'; exit 0; fi
    printf 'would summon an agent for %s\n' "${1:-}"; exit 3 ;;
  summon) printf 'SUMMON-TEXT for %s\n' "${1:-}"; exit 0 ;;
esac
exit 4
FAKE
chmod +x "$TMP/bin/basheur"
export FAKE_STATE="$TMP/state"
export PATH="$TMP/bin:$PATH"
export BIBLIOTHECAIRE_VAULT="$VAULT"

run_consign() {  # run_consign <state> [extra-flags...] -> sets OUT / RC
  printf '%s\n' "$1" > "$FAKE_STATE"; shift
  OUT="$(cd "$TMP" && "$VERB" consign "$@" DOC.md 2>&1)"; RC=$?
}

echo "=== fonde consign: it must ask basheur, not assume"; echo

# --- the regression itself ---------------------------------------------
# A mechanized contract costs nothing, so no flag should be required and the
# deposit should simply happen.
run_consign MECHANIZED
check "MECHANIZED: consign succeeds with NO --summon" "$RC" "0"

case "$OUT" in
  *"has no mechanism yet"*)
    bad "MECHANIZED: must not claim there is no mechanism" "said: $OUT" ;;
  *) ok "MECHANIZED: does not claim there is no mechanism" ;;
esac

case "$OUT" in
  *"this needs a summon"*)
    bad "MECHANIZED: must not demand a summon for free work" "said: $OUT" ;;
  *) ok "MECHANIZED: does not demand a summon for free work" ;;
esac

case "$OUT" in
  *DEPOSITED*) ok "MECHANIZED: the impl's own output reaches the caller" ;;
  *) bad "MECHANIZED: impl output was swallowed" "got: $OUT" ;;
esac

# --- the other half, which must NOT be relaxed by the fix ---------------
# When an agent really IS required, the cost gate must still hold. A fix that
# made consign always run would pass every assertion above and quietly spend
# money, so this row is what keeps the change honest.
run_consign AGENT
check "AGENT, no --summon: still refuses, exit 3" "$RC" "3"

case "$OUT" in
  *"needs an agent"*) ok "AGENT: says an agent is needed" ;;
  *) bad "AGENT: did not say an agent is needed" "got: $OUT" ;;
esac

case "$OUT" in
  *"would summon an agent"*) ok "AGENT: shows the summon it would have made" ;;
  *) bad "AGENT: did not show the summon" "got: $OUT" ;;
esac

case "$OUT" in
  *AGENT-RAN*) bad "AGENT: spent a summon without --summon" "got: $OUT" ;;
  *) ok "AGENT: nothing was spent without --summon" ;;
esac

run_consign AGENT --summon
check "AGENT with --summon: performs the deposit" "$RC" "0"
case "$OUT" in
  *AGENT-RAN*) ok "AGENT with --summon: the summon actually ran" ;;
  *) bad "AGENT with --summon: no summon ran" "got: $OUT" ;;
esac

# --- refusals that predate this change and must survive it --------------
printf 'MECHANIZED\n' > "$FAKE_STATE"
OUT="$(cd "$TMP" && "$VERB" consign NOSUCH.md 2>&1)"; RC=$?
check "a missing path is refused before basheur is reached" "$RC" "2"

UNVERSIONED="$TMP/bare"; mkdir -p "$UNVERSIONED"
OUT="$(cd "$TMP" && BIBLIOTHECAIRE_VAULT="$UNVERSIONED" "$VERB" consign DOC.md 2>&1)"; RC=$?
check "a vault with no git history is REFUSED (7), not deposited into" "$RC" "7"

echo
printf -- '--- fonde consign: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
