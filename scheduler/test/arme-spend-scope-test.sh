#!/usr/bin/env bash
# arme-spend-scope-test.sh -- the INVOCATION decides, not the binary.
#
# Zach, 2026-08-01: judge the invocation, "c but throw a warning".
#
# The property under test is a boundary, so every case here has a matching
# NEGATIVE: for each thing that must be allowed there is a neighbouring thing
# that must still be refused. A version of this file that only checked "garde
# can now be armed" would pass against an arme that armed everything.
#
# usage: ./test/arme-spend-scope-test.sh [path-to-arme]
set -uo pipefail

ARME="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/arme}"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"

# A leaf: no model runner, no handoff. Must read FREE.
# NOTE the shebang is /bin/bash, not /usr/bin/env bash: the leaf detector
# treats any /usr/bin/ path as a handoff, so an env-shebang script can never
# read FREE. That is pre-existing and arguably over-strict, but it is not what
# this change is about -- recorded here so the fixture's oddity is not read as
# a mistake.
printf '#!/bin/bash\necho leaf\n' > "$BIN/leaf"

# A MIXED tool: documents a --summon cost (so its source matches /claude/)
# but its default path cannot spend. This is `garde`'s exact shape.
cat > "$BIN/mixed" <<'EOS'
#!/usr/bin/env bash
# --summon  AUTHORISE SPENDING REAL MONEY (cost: ~56s of one claude -p call)
case "${1:-}" in
  --summon) echo "would spend" ;;
  *) echo "free path" ;;
esac
EOS
chmod +x "$BIN/leaf" "$BIN/mixed"

mkdir -p "$WORK/schedule"
run_check() {  # $1 = conf body
  printf '%s\n' "$1" > "$WORK/schedule/_monitor.conf"
  ARME_LEGACY_ROOT="$WORK" bash "$ARME" check 2>&1
}
ATT='this invocation cannot spend: it passes no --summon and the free path reaches no model'

# --- 1. MIXED binary, safe invocation, attested -> ARMED, and WARNED ---
out="$(run_check "mixed-safe|1|30 3 * * *|$BIN/mixed run|$ATT")"; rc=$?
case "$out" in
  *WARN*)  ok "1a mixed binary + safe invocation + attestation is ARMED with a WARN" ;;
  *)       bad "1a mixed binary + safe invocation + attestation is ARMED with a WARN"; printf '%s\n' "$out" | head -4 ;;
esac
case "$out" in
  *"CAN spend"*) ok "1b the warning says the binary can spend" ;;
  *)             bad "1b the warning says the binary can spend" ;;
esac
case "$out" in
  *REFUSED*) bad "1c an attested MIXED entry is not refused" ;;
  *)         ok "1c an attested MIXED entry is not refused" ;;
esac

# --- 2. NEGATIVE: same binary, but the invocation asks to spend -> REFUSED ---
out="$(run_check "mixed-summon|1|30 3 * * *|$BIN/mixed --summon|$ATT")"
case "$out" in
  *SPENDS*) ok "2a --summon in the invocation is SPENDS even with an attestation" ;;
  *)        bad "2a --summon in the invocation is SPENDS even with an attestation"; printf '%s\n' "$out" | head -4 ;;
esac
case "$out" in
  *REFUSED*) ok "2b and the run is REFUSED" ;;
  *)         bad "2b and the run is REFUSED" ;;
esac

# --- 3. NEGATIVE: MIXED without an attestation -> REFUSED ---
out="$(run_check "mixed-bare|1|30 3 * * *|$BIN/mixed run|")"
case "$out" in
  *REFUSED*) ok "3a MIXED without an attestation is REFUSED (not waved through)" ;;
  *)         bad "3a MIXED without an attestation is REFUSED (not waved through)"; printf '%s\n' "$out" | head -4 ;;
esac

# --- 4. NEGATIVE: an invocation naming the model runner directly -> REFUSED ---
out="$(run_check "names-model|1|30 3 * * *|$BIN/leaf claude -p hi|$ATT")"
case "$out" in
  *SPENDS*) ok "4a naming the model runner in the invocation is SPENDS" ;;
  *)        bad "4a naming the model runner in the invocation is SPENDS"; printf '%s\n' "$out" | head -4 ;;
esac

# --- 5. A genuine leaf still reads FREE and needs no attestation ---
out="$(run_check "leafy|1|30 3 * * *|$BIN/leaf|")"
case "$out" in
  *FREE*) ok "5a a real leaf is still FREE with no attestation" ;;
  *)      bad "5a a real leaf is still FREE with no attestation"; printf '%s\n' "$out" | head -4 ;;
esac
case "$out" in
  *WARN*) bad "5b a leaf does not warn" ;;
  *)      ok "5b a leaf does not warn" ;;
esac

printf '\n--- arme spend-scope: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
