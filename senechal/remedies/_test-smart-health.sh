#!/usr/bin/env bash
# Tests for smart-health.sh -- had no dedicated coverage before this file
# (#348 phase 4, fourth timer-kind: a SYSTEM unit + root-owned files,
# generalized from the --user-only shape auto-apply-remedies-timer.sh and
# estate-health-timer.sh already proved). Underscore-prefixed so
# verify-all.sh does not glob it up and run it as a remedy.
#
#   ./_test-smart-health.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="./smart-health.sh"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

DUMP_FILE="$SCRATCH/dump.txt"
mkdir -p "$SCRATCH/.config/senechal"
printf '{"estate":{"devices":[]},"health":{"smart_dump_file":"%s","smart_dump_max_age_hours":48}}\n' \
  "$DUMP_FILE" > "$SCRATCH/.config/senechal/senechal.json"

# A fake lsblk on PATH -- never the real machine's disks, so the "every
# disk present now is covered by the dump" check (verify_'s step 4) is
# testable without depending on how many drives this host happens to have.
STUB="$SCRATCH/stub"
mkdir -p "$STUB"
cat > "$STUB/lsblk" <<'EOF'
#!/usr/bin/env bash
echo "sda disk"
EOF
chmod +x "$STUB/lsblk"

run() {
  env HOME="$SCRATCH" XDG_CONFIG_HOME="$SCRATCH/.config" \
      SENECHAL_DEPLOYED_ROOT="$SCRATCH" \
      SENECHAL_CONFIG="$SCRATCH/.config/senechal/senechal.json" \
      SENECHAL_SMART_UNIT_DIR="$SCRATCH/units" \
      SENECHAL_SMART_HELPER="$SCRATCH/helper.sh" \
      SENECHAL_BACKUP_ROOT="$SCRATCH/backups" \
      PATH="$STUB:$PATH" \
      "$SCRIPT" "$@"
}

echo "=== verify before enable: expect FAIL (helper not installed) ==="
out="$(run verify)"; rc=$?
check "verify fails loud when not installed" "$rc" "1"
printf '%s\n' "$out" | grep -q "helper.sh missing" && ok "verify names the missing helper" || bad "verify did not name the missing helper"

echo "=== enable ==="
out="$(run enable)"; rc=$?
check "enable exits 0" "$rc" "0"
[ -f "$SCRATCH/helper.sh" ] && ok "helper written" || bad "helper missing"
[ -f "$SCRATCH/units/senechal-smart.service" ] && ok "service unit written" || bad "service unit missing"
[ -f "$SCRATCH/units/senechal-smart.timer" ] && ok "timer unit written" || bad "timer unit missing"
[ "$(stat -c %a "$SCRATCH/helper.sh")" = "755" ] && ok "helper mode 0755" || bad "helper mode wrong"
grep -q "OnCalendar=daily" "$SCRATCH/units/senechal-smart.timer" && ok "daily calendar timer (no INTERVAL_CFG_KEY needed)" || bad "OnCalendar=daily missing"
printf '%s\n' "$out" | grep -q "sudo/systemctl" && bad "leaked live-mode narration in test mode" || ok "no live-mode narration leaked"

echo "=== re-enable: idempotent ==="
out="$(run enable)"; rc=$?
check "re-enable exits 0" "$rc" "0"
printf '%s\n' "$out" | grep -q "already correct, untouched" && ok "re-enable recognizes unchanged files (helper included)" || bad "re-enable did not report files as untouched"

echo "=== verify after enable, before any dump exists: expect FAIL (dump missing) ==="
out="$(run verify)"; rc=$?
check "verify fails: dump never produced in test mode" "$rc" "1"
printf '%s\n' "$out" | grep -q "dump.txt missing" && ok "verify names the missing dump" || bad "verify did not name the missing dump"
printf '%s\n' "$out" | grep -q "senechal-smart.service matches" && ok "verify still drift-checked the unit before the dump check" || bad "verify skipped the unit drift check"

echo "=== drift: hand-edit the installed unit, verify catches it ==="
printf 'not the right content\n' > "$SCRATCH/units/senechal-smart.service"
out="$(run verify)"; rc=$?
check "verify fails on drift" "$rc" "1"
printf '%s\n' "$out" | grep -q "senechal-smart.service drifted" && ok "drift reported" || bad "drift not reported"
out="$(run enable)"  # repair before continuing
[ "$(cat "$SCRATCH/units/senechal-smart.service")" != "not the right content" ] && ok "re-enable repairs drift" || bad "re-enable did not repair drift"

echo "=== verify with a healthy dump present ==="
# Still INCOMPLETE (2), not a clean PASS -- test mode has no live systemd
# to confirm the timer is actually armed, same contract as the other two
# timer-kind callers' own tests (they never reach rc=0 in test mode either).
printf '# senechal-smart dump 2026-08-23 00:00:00+0000\nsda PASSED\n' > "$DUMP_FILE"
out="$(run verify)"; rc=$?
check "verify is incomplete (not a false pass) with a fresh, healthy dump in test mode" "$rc" "2"
printf '%s\n' "$out" | grep -q "/dev/sda SMART self-assessment PASSED" && ok "PASSED disk reported" || bad "PASSED disk not reported"

echo "=== verify with a failing drive ==="
printf '# senechal-smart dump 2026-08-23 00:00:00+0000\nsda FAILED\n' > "$DUMP_FILE"
out="$(run verify)"; rc=$?
check "verify fails loud on a failing drive" "$rc" "1"
printf '%s\n' "$out" | grep -q "sda SMART FAILING" && ok "FAILED disk reported" || bad "FAILED disk not reported"

echo "=== verify with a stale dump ==="
printf '# senechal-smart dump 2020-01-01 00:00:00+0000\nsda PASSED\n' > "$DUMP_FILE"
touch -d '10 days ago' "$DUMP_FILE"
out="$(run verify)"; rc=$?
check "verify fails loud on a stale dump" "$rc" "1"
printf '%s\n' "$out" | grep -q "the timer is not running" && ok "staleness reported" || bad "staleness not reported"

echo "=== disable ==="
printf '# senechal-smart dump 2026-08-23 00:00:00+0000\nsda PASSED\n' > "$DUMP_FILE"
touch "$DUMP_FILE"
out="$(run disable)"; rc=$?
check "disable exits 0" "$rc" "0"
[ -f "$SCRATCH/helper.sh" ] && bad "helper not removed by disable" || ok "disable removed the helper"
[ -f "$SCRATCH/units/senechal-smart.service" ] && bad "service unit not removed by disable" || ok "disable removed the service unit"
[ -f "$SCRATCH/units/senechal-smart.timer" ] && bad "timer unit not removed by disable" || ok "disable removed the timer unit"
[ -f "$DUMP_FILE" ] && ok "dump file left in place (historical record)" || bad "dump file should survive disable"

echo "=== verify after disable: expect FAIL (helper missing again) ==="
out="$(run verify)"; rc=$?
check "verify fails after disable" "$rc" "1"

echo
echo "smart-health test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
