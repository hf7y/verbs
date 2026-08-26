#!/usr/bin/env bash
# Tests for estate-health-timer.sh -- had no dedicated coverage before
# this file (#348 phase 4 timer-kind collapse). Underscore-prefixed so
# verify-all.sh does not glob it up and run it as a remedy.
#
#   ./_test-estate-health-timer.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="./estate-health-timer.sh"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/.config/senechal"
printf '{"estate":{"devices":[]},"health":{}}\n' > "$SCRATCH/.config/senechal/senechal.json"

# A unit's ExecStart is refused unless it names the declared build root
# (lib/common.sh refuse_undeployable_path). A hermetic test declares its
# own: without this the suite can only ever exercise the REFUSING path,
# which says nothing about whether enable works.
mkdir -p "$SCRATCH/build/health"
cp ../health/estate-health.sh "$SCRATCH/build/health/"
chmod +x "$SCRATCH/build/health/estate-health.sh"

run() {
  env HOME="$SCRATCH" XDG_CONFIG_HOME="$SCRATCH/.config" \
      SENECHAL_CONFIG="$SCRATCH/.config/senechal/senechal.json" \
      SENECHAL_HEALTH_UNIT_DIR="$SCRATCH/.config/systemd/user" \
      SENECHAL_BACKUP_ROOT="$SCRATCH/backups" \
      SENECHAL_DEPLOYED_ROOT="$SCRATCH/build" \
      "$SCRIPT" "$@"
}

out="$(run enable)"; rc=$?
check "enable exits 0" "$rc" "0"
[ -f "$SCRATCH/.config/systemd/user/senechal-health.service" ] && ok "service unit written" || bad "service unit missing"
[ -f "$SCRATCH/.config/systemd/user/senechal-health.timer" ] && ok "timer unit written" || bad "timer unit missing"
grep -q "OnUnitActiveSec=1h" "$SCRATCH/.config/systemd/user/senechal-health.timer" && ok "default interval 1h in timer unit" || bad "interval missing/wrong"
grep -q "SuccessExitStatus=1 2 3" "$SCRATCH/.config/systemd/user/senechal-health.service" && ok "service tolerates the health-check exit contract" || bad "SuccessExitStatus missing/wrong"

out="$(run enable)"; rc=$?
check "re-enable exits 0 (idempotent)" "$rc" "0"
printf '%s\n' "$out" | grep -q "already correct, untouched" && ok "re-enable recognizes unchanged units" || bad "re-enable did not report units as untouched"

out="$(run verify)"; rc=$?
check "verify exits 2 (test mode: units present but no live systemd to ask)" "$rc" "2"

out="$(run disable)"
[ -f "$SCRATCH/.config/systemd/user/senechal-health.timer" ] && bad "timer unit not removed by disable" || ok "disable removed the timer unit"
[ -f "$SCRATCH/.config/systemd/user/senechal-health.service" ] && bad "service unit not removed by disable" || ok "disable removed the service unit"

out="$(run verify)"; rc=$?
check "verify after disable exits 1 (missing)" "$rc" "1"

# --- the path that gets written down (2026-08-22, #403 one layer up) ----
#
# On 2026-08-22 21:23 an agent ran enable from a `mktemp -d` checkout. The
# unit captured /tmp/tmp.UUh80RFo5e, the directory was cleaned, and both
# --user timers went 203/EXEC every run for 22 hours with the timer still
# reporting enabled+active. Nothing in the unit content or the timer state
# shows this; only the path does. Assert the refusal, and assert that
# NOTHING was written -- a refusal that still leaves half a unit behind is
# not a refusal.
UNITS="$SCRATCH/.config/systemd/user"

refuses() { # refuses <label> <expected-substring> [env assignments...]
  local label="$1" want="$2"; shift 2
  rm -rf "$UNITS"; mkdir -p "$UNITS"
  local out rc
  out="$(env HOME="$SCRATCH" XDG_CONFIG_HOME="$SCRATCH/.config" \
             SENECHAL_CONFIG="$SCRATCH/.config/senechal/senechal.json" \
             SENECHAL_HEALTH_UNIT_DIR="$UNITS" \
             SENECHAL_BACKUP_ROOT="$SCRATCH/backups" \
             "$@" "$SCRIPT" enable 2>&1)"; rc=$?
  check "$label: exits 2 (RC_INCOMPLETE)" "$rc" "2"
  printf '%s' "$out" | grep -q "REFUSING" \
    && ok "$label: says REFUSING" || bad "$label: no REFUSING in output"
  printf '%s' "$out" | grep -qi -- "$want" \
    && ok "$label: names the reason ($want)" || bad "$label: reason '$want' not in output"
  check "$label: wrote no unit at all" "$(ls "$UNITS" | wc -l)" "0"
}

EPHEMERAL="$(mktemp -d)"
mkdir -p "$EPHEMERAL/health"
cp ../health/estate-health.sh "$EPHEMERAL/health/"
chmod +x "$EPHEMERAL/health/estate-health.sh"
refuses "enable from a temp checkout" "temporary directory" \
  SENECHAL_DEPLOYED_ROOT=/nonexistent SENECHAL_ROOT="$EPHEMERAL"
rm -rf "$EPHEMERAL"

# And the rule Zach set on 2026-08-23: no shims. A working clone is not a
# deploy target either, however permanent it looks.
refuses "enable from a working clone" "working clone" \
  SENECHAL_DEPLOYED_ROOT=/nonexistent

echo "estate-health-timer test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
