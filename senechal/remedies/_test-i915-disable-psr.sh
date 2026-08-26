#!/usr/bin/env bash
# Tests for i915-disable-psr.sh. Underscore-prefixed so verify-all.sh
# does not glob it up and run it as a remedy.
#
#   ./_test-i915-disable-psr.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="./i915-disable-psr.sh"
PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export HOME="$SCRATCH"
export SENECHAL_BACKUP_ROOT="$SCRATCH/.senechal-remedy-backups"
mkdir -p "$SCRATCH/.config/senechal"
export SENECHAL_CONFIG="$SCRATCH/.config/senechal/senechal.json"
printf '{"estate":{"devices":[]},"health":{}}\n' > "$SENECHAL_CONFIG"

# No real root/sudo/update-grub -- run against a scratch file the test
# user owns, with sudo and update-grub stubbed to no-ops.
export SENECHAL_GRUB_FILE="$SCRATCH/grub"
export SENECHAL_SUDO_CMD=""
export SENECHAL_UPDATE_GRUB_CMD="true"

cat > "$SENECHAL_GRUB_FILE" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX_DEFAULT="fsck.mode=skip quiet splash"
GRUB_CMDLINE_LINUX=""
EOF

echo "=== verify on a file with no param: expect FAIL ==="
"$SCRIPT" verify >/tmp/out.$$ 2>&1
rc=$?
check "verify fails loud when param absent" "$rc" "1"
grep -q "FAIL" /tmp/out.$$ && ok "verify output contains FAIL" || bad "verify output missing FAIL"

echo "=== enable ==="
"$SCRIPT" enable >/tmp/out.$$ 2>&1
rc=$?
check "enable exits 0" "$rc" "0"

cmdline="$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$SENECHAL_GRUB_FILE")"
case " $cmdline " in
  *" i915.enable_psr=0 "*) ok "param present after enable" ;;
  *) bad "param present after enable (cmdline: '$cmdline')" ;;
esac
case "$cmdline" in
  *"fsck.mode=skip quiet splash"*) ok "unrelated flags survive enable" ;;
  *) bad "unrelated flags survive enable (cmdline: '$cmdline')" ;;
esac

other="$(awk -F= '/^GRUB_TIMEOUT=/{print $2}' "$SENECHAL_GRUB_FILE")"
check "unrelated GRUB_TIMEOUT= survives the edit" "$other" "5"

echo "=== enable again: idempotent ==="
before="$(cat "$SENECHAL_GRUB_FILE")"
"$SCRIPT" enable >/tmp/out.$$ 2>&1
rc=$?
check "re-enable exits 0" "$rc" "0"
after="$(cat "$SENECHAL_GRUB_FILE")"
check "re-enable changes nothing" "$before" "$after"

# The real host's /proc/cmdline is untouched by this scratch grub file (no
# reboot happened), so verify correctly WARNs (rc=3) that the change is
# not yet live rather than claiming a false PASS.
echo "=== verify after enable, before reboot: expect WARN (in grub, not yet live) ==="
"$SCRIPT" verify >/tmp/out.$$ 2>&1
rc=$?
check "verify warns after enable pending reboot" "$rc" "3"
grep -q "WARN" /tmp/out.$$ && ok "verify output contains WARN" || bad "verify output missing WARN"

echo "=== disable ==="
"$SCRIPT" disable >/tmp/out.$$ 2>&1
rc=$?
check "disable exits 0" "$rc" "0"

cmdline="$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$SENECHAL_GRUB_FILE")"
case " $cmdline " in
  *" i915.enable_psr=0 "*) bad "param removed after disable (cmdline: '$cmdline')" ;;
  *) ok "param removed after disable" ;;
esac
case "$cmdline" in
  fsck.mode=skip\ quiet\ splash) ok "cmdline restored to original after disable" ;;
  *) bad "cmdline restored to original after disable (got '$cmdline')" ;;
esac

echo "=== disable again: idempotent (already gone) ==="
before="$(cat "$SENECHAL_GRUB_FILE")"
"$SCRIPT" disable >/tmp/out.$$ 2>&1
rc=$?
check "re-disable exits 0" "$rc" "0"
after="$(cat "$SENECHAL_GRUB_FILE")"
check "re-disable changes nothing" "$before" "$after"

echo "=== verify after disable: expect FAIL again ==="
"$SCRIPT" verify >/tmp/out.$$ 2>&1
rc=$?
check "verify fails after disable" "$rc" "1"

rm -f /tmp/out.$$

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
