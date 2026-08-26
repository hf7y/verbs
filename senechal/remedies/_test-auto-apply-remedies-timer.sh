#!/usr/bin/env bash
# Tests for auto-apply-remedies-timer.sh. Underscore-prefixed so
# verify-all.sh does not glob it up and run it as a remedy.
#
#   ./_test-auto-apply-remedies-timer.sh
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="./auto-apply-remedies-timer.sh"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

SCRATCH="$(mktemp -d)"
# See _test-estate-health-timer.sh: a hermetic test declares its own build
# root, or enable can only ever be observed refusing.
mkdir -p "$SCRATCH/build/tools"
cp ../tools/auto-apply-remedies.sh "$SCRATCH/build/tools/" 2>/dev/null
chmod +x "$SCRATCH/build/tools/auto-apply-remedies.sh" 2>/dev/null
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/.config/senechal"
printf '{"estate":{"devices":[]},"health":{}}\n' > "$SCRATCH/.config/senechal/senechal.json"

run() {
  env HOME="$SCRATCH" XDG_CONFIG_HOME="$SCRATCH/.config" \
      SENECHAL_DEPLOYED_ROOT="$SCRATCH/build" \
      SENECHAL_CONFIG="$SCRATCH/.config/senechal/senechal.json" \
      SENECHAL_AUTOAPPLY_UNIT_DIR="$SCRATCH/.config/systemd/user" \
      SENECHAL_BACKUP_ROOT="$SCRATCH/backups" \
      "$SCRIPT" "$@"
}

out="$(run enable)"; rc=$?
check "enable exits 0" "$rc" "0"
[ -f "$SCRATCH/.config/systemd/user/senechal-auto-apply-remedies.service" ] && ok "service unit written" || bad "service unit missing"
[ -f "$SCRATCH/.config/systemd/user/senechal-auto-apply-remedies.timer" ] && ok "timer unit written" || bad "timer unit missing"
grep -q "OnUnitActiveSec=15m" "$SCRATCH/.config/systemd/user/senechal-auto-apply-remedies.timer" && ok "default interval 15m in timer unit" || bad "interval missing/wrong"

out="$(run verify -q)"; rc=$?
check "verify exits 2 (test mode: units present but no live systemd to ask)" "$rc" "2"

out="$(run disable)"
[ -f "$SCRATCH/.config/systemd/user/senechal-auto-apply-remedies.timer" ] && bad "timer unit not removed by disable" || ok "disable removed the timer unit"

out="$(run verify -q)"; rc=$?
check "verify after disable exits 1 (missing)" "$rc" "1"

echo "auto-apply-remedies-timer test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
