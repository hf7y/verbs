#!/usr/bin/env bash
# ausculte-test.sh -- regression tests for two exit-code bugs found
# 2026-08-01 in the arity guard `bin/ausculte` grew alongside `--json`,
# `--quiet` and `--version` support:
#
#   1. `dead-config` (and every other run_health subcommand) must exit 6
#      -- BLIND -- when its backing check cannot read its domain, never 0.
#      This file provokes it with a deterministic fixture rather than
#      trusting the real estate to have something unreadable in it.
#   2. A leading flag this verb does not recognise (`--nonsense`, and
#      `--summon`, which VERB_CAN_SUMMON=0 never grants) must exit 2, not
#      fall through to the subcommand listing and exit 0.
#
# test/contract-test.sh already covers the universal form of bug 2
# (`--definitely-not-a-real-flag`, `-s`, `-S`). This file adds the BLIND
# case contract-test.sh has no vocabulary for, and the one negative case
# specific to this verb's own declared position (VERB_CAN_SUMMON=0). Each
# assertion pairs a NEGATIVE (must fail loudly) with the fully-passing
# control it would be trivial to fake by asserting success alone.

set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CMD="${1:-$ROOT/bin/ausculte}"

pass=0; fail=0
ok() { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }

printf '=== ausculte: exit-code regression tests\n    command: %s\n\n' "$CMD"

# --- fixture: a legacy health check under our own control, never the real
# estate. dead-config.sh's own contract (health/dead-config.sh) is 0 all
# declared / 1 found something / 2 could-not-check; run_health in bin/ausculte
# translates that legacy 2 into this ecosystem's BLIND (exit 6).
SANDBOX=""
fixture() {  # fixture <exit-code-for-dead-config.sh>
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/health"
  cat > "$SANDBOX/health/dead-config.sh" <<EOF
#!/usr/bin/env bash
printf 'fixture dead-config check\n'
exit $1
EOF
  chmod +x "$SANDBOX/health/dead-config.sh"
}
trap '[ -n "$SANDBOX" ] && rm -rf "$SANDBOX"' EXIT

# --- bug 1: BLIND must exit 6, not 0 (or anything else) ---------------------
fixture 2   # legacy could-not-check
blind_out="$(AUSCULTE_LEGACY_ROOT="$SANDBOX" "$CMD" dead-config 2>&1)"
blind_rc=$?
check "BLIND: dead-config (legacy exit 2) exits 6"  "$blind_rc"  6
case "$blind_out" in
  *"BLIND"*"dead-config"*"could not read part of its domain"*) ok "BLIND: message names the domain, not a bare exit" ;;
  *) no "BLIND: message missing or malformed: $blind_out" ;;
esac
case "$blind_out" in
  *'this is "I cannot see", NOT "nothing to report".'*) ok "BLIND: message distinguishes could-not-look from nothing-to-report" ;;
  *) no "BLIND: message does not state the could-not-look/nothing-to-report distinction" ;;
esac

# The control: the SAME wiring, a check that actually ran clean, must still
# exit 0. A fix that makes everything exit 6 is as broken as one that makes
# everything exit 0 -- this is the assertion that would catch that.
fixture 0   # legacy all-clear
check "control: dead-config (legacy exit 0) still exits 0" \
  "$(AUSCULTE_LEGACY_ROOT="$SANDBOX" "$CMD" dead-config >/dev/null 2>&1; printf '%s' "$?")" 0

# A legacy exit this verb's own contract does not define must land on
# BROKEN (5), not BLIND and not a pass -- the other arm of the same
# translation, checked so a future edit cannot collapse both into one.
fixture 9
check "control: dead-config (legacy exit 9, undefined) exits 5 (BROKEN)" \
  "$(AUSCULTE_LEGACY_ROOT="$SANDBOX" "$CMD" dead-config >/dev/null 2>&1; printf '%s' "$?")" 5

rm -rf "$SANDBOX"; SANDBOX=""

# --- bug 2: an unrecognised leading flag must exit 2, not fall into `list` --
rc() { "$CMD" "$@" >/tmp/ausculte-test.$$ 2>&1; local r=$?; cat /tmp/ausculte-test.$$; rm -f /tmp/ausculte-test.$$; return $r; }

nonsense_out="$(rc --nonsense)"; nonsense_rc=$?
check "unknown flag: --nonsense exits 2" "$nonsense_rc" 2
case "$nonsense_out" in
  *dead-config*) no "unknown flag: --nonsense fell through to the subcommand list" ;;
  *) ok "unknown flag: --nonsense did not print the subcommand list" ;;
esac

# VERB_CAN_SUMMON=0 here: --summon must be REFUSED, not silently accepted
# into the listing path as just another dash-prefixed argument.
summon_out="$(rc --summon)"; summon_rc=$?
check "--summon (never granted, VERB_CAN_SUMMON=0) exits 2" "$summon_rc" 2
case "$summon_out" in
  *dead-config*) no "--summon fell through to the subcommand list" ;;
  *) ok "--summon did not print the subcommand list" ;;
esac

# The control: a flag this verb DOES claim (per its own --help / man page)
# must keep working -- this is the assertion a fix that rejects everything
# starting with '-' would fail.
check "control: --json (a real, documented flag) still exits 0" \
  "$(rc --json >/dev/null 2>&1; printf '%s' "$?")" 0
check "control: --help (a real, documented flag) still exits 0" \
  "$(rc --help >/dev/null 2>&1; printf '%s' "$?")" 0

# --- control: a subcommand's OWN trailing flag is not this verb's
# vocabulary and must still reach the backing check unmangled. `silence
# --strict` is documented on man/ausculte.1; `--strict` is not one of
# verb_parse's flags, so if the fix ever grows to consume every argument
# through verb_parse (not just the leading one), this is what it would
# break. A fixture stands in for the real ecosim silence-audit.sh so this
# does not depend on that repository existing on the machine running the
# test.
STRICT_SANDBOX="$(mktemp -d)"
cat > "$STRICT_SANDBOX/silence-audit-fixture.sh" <<'EOF'
#!/usr/bin/env bash
printf 'GOT ARGS: %s\n' "$*"
exit 0
EOF
chmod +x "$STRICT_SANDBOX/silence-audit-fixture.sh"
strict_out="$(AUSCULTE_SILENCE_AUDIT="$STRICT_SANDBOX/silence-audit-fixture.sh" "$CMD" silence --strict 2>&1)"
strict_rc=$?
check "control: 'silence --strict' reaches the backing check, not rejected" "$strict_rc" 0
case "$strict_out" in
  *"GOT ARGS: --strict"*) ok "control: '--strict' arrived at the backing check unmangled" ;;
  *) no "control: '--strict' did not reach the backing check: $strict_out" ;;
esac
rm -rf "$STRICT_SANDBOX"

printf '\n--- ausculte exit-code regressions: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
