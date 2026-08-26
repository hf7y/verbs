#!/usr/bin/env bash
# Tests for verify-all-timer.sh. Underscore-prefixed so verify-all.sh does
# not glob it up and run it as a remedy.
#
# The rows that matter are the OnCalendar shape (this is the first
# non-interval caller of lib/timer-kind.sh, whose format check and verify
# wording both branch on an empty INTERVAL_CFG_KEY) and the same
# undeployable-path refusal every timer caller now owes.
#
#   ./_test-verify-all-timer.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="./verify-all-timer.sh"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/.config/senechal"
printf '{"estate":{"devices":[]},"health":{}}\n' > "$SCRATCH/.config/senechal/senechal.json"

# A hermetic test declares its own build root, or enable can only ever be
# observed refusing -- see lib/common.sh refuse_undeployable_path.
mkdir -p "$SCRATCH/build/remedies"
cp ./verify-all.sh "$SCRATCH/build/remedies/"
chmod +x "$SCRATCH/build/remedies/verify-all.sh"

UNITS="$SCRATCH/.config/systemd/user"
run() {
  env HOME="$SCRATCH" XDG_CONFIG_HOME="$SCRATCH/.config" \
      SENECHAL_CONFIG="$SCRATCH/.config/senechal/senechal.json" \
      SENECHAL_VERIFYALL_UNIT_DIR="$UNITS" \
      SENECHAL_BACKUP_ROOT="$SCRATCH/backups" \
      SENECHAL_DEPLOYED_ROOT="$SCRATCH/build" \
      "$SCRIPT" "$@"
}

out="$(run enable)"; rc=$?
check "enable exits 0" "$rc" "0"
[ -f "$UNITS/$(basename senechal-verify-all.service)" ] && ok "service unit written" || bad "service unit missing"
[ -f "$UNITS/senechal-verify-all.timer" ] && ok "timer unit written" || bad "timer unit missing"

# OnCalendar, not OnUnitActiveSec: this caller leaves INTERVAL_CFG_KEY empty
# so timer-kind.sh skips the time-span format check entirely.
grep -q "^OnCalendar=daily" "$UNITS/senechal-verify-all.timer" \
  && ok "timer is OnCalendar=daily" || bad "OnCalendar=daily missing"
grep -q "OnUnitActiveSec" "$UNITS/senechal-verify-all.timer" \
  && bad "timer still carries an interval knob" || ok "timer carries no interval knob"
grep -q "^Persistent=true" "$UNITS/senechal-verify-all.timer" \
  && ok "catches up on a run missed to suspend" || bad "Persistent=true missing"

# The aggregate's own exit contract is a report, not a crash. Without this
# every failing remedy leaves a failed user unit, which estate-health.sh's
# check_units then reports as a failure -- a self-referential alert loop.
grep -q "^SuccessExitStatus=1 2 3" "$UNITS/senechal-verify-all.service" \
  && ok "service tolerates the verify exit contract" || bad "SuccessExitStatus missing/wrong"
grep -q "ExecStart=$SCRATCH/build/remedies/verify-all.sh -q" "$UNITS/senechal-verify-all.service" \
  && ok "ExecStart names the deployed verify-all, with -q" || bad "ExecStart wrong"

out="$(run enable)"; rc=$?
check "re-enable exits 0 (idempotent)" "$rc" "0"
printf '%s\n' "$out" | grep -q "already correct, untouched" \
  && ok "re-enable recognizes unchanged units" || bad "re-enable did not report units as untouched"

out="$(run verify)"; rc=$?
check "verify exits 2 (test mode: units present, no live systemd to ask)" "$rc" "2"

run disable >/dev/null
[ -f "$UNITS/senechal-verify-all.timer" ] && bad "timer unit not removed by disable" || ok "disable removed the timer unit"
[ -f "$UNITS/senechal-verify-all.service" ] && bad "service unit not removed by disable" || ok "disable removed the service unit"

out="$(run verify)"; rc=$?
check "verify after disable exits 1 (missing)" "$rc" "1"

# Same refusal every timer caller owes (#403 one layer up, 2026-08-22).
rm -rf "$UNITS"; mkdir -p "$UNITS"
out="$(env HOME="$SCRATCH" XDG_CONFIG_HOME="$SCRATCH/.config" \
           SENECHAL_CONFIG="$SCRATCH/.config/senechal/senechal.json" \
           SENECHAL_VERIFYALL_UNIT_DIR="$UNITS" \
           SENECHAL_BACKUP_ROOT="$SCRATCH/backups" \
           SENECHAL_DEPLOYED_ROOT=/nonexistent \
           "$SCRIPT" enable 2>&1)"; rc=$?
check "enable from a working clone exits 2" "$rc" "2"
printf '%s' "$out" | grep -q "REFUSING" && ok "refusal says REFUSING" || bad "no REFUSING in output"
check "refusal wrote no unit at all" "$(ls "$UNITS" | wc -l)" "0"

echo "verify-all-timer test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
