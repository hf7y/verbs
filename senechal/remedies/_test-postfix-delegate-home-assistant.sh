#!/usr/bin/env bash
# Tests for postfix-delegate-home-assistant.sh. Underscore-prefixed so
# verify-all.sh does not glob it up and run it as a remedy.
#
#   ./_test-postfix-delegate-home-assistant.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="./postfix-delegate-home-assistant.sh"
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

# A fake systemctl -- no real root/systemd involved. Tracks masked units
# and a failed-units list in scratch files so mask/is-enabled/list-units
# agree with each other across calls, the same way the real daemon would.
FAKE_SYSTEMCTL="$SCRATCH/fake-systemctl.sh"
MASKED_FILE="$SCRATCH/masked"
FAILED_FILE="$SCRATCH/failed"
: > "$MASKED_FILE"
printf 'postfix@-.service\n' > "$FAILED_FILE"   # starts "failed", like the real finding
cat > "$FAKE_SYSTEMCTL" <<EOF
#!/usr/bin/env bash
MASKED_FILE="$MASKED_FILE"
FAILED_FILE="$FAILED_FILE"
case "\$1" in
  mask) grep -qFx "\$2" "\$MASKED_FILE" 2>/dev/null || echo "\$2" >> "\$MASKED_FILE"; exit 0 ;;
  reset-failed) grep -vFx "\$2" "\$FAILED_FILE" > "\$FAILED_FILE.tmp" 2>/dev/null; mv "\$FAILED_FILE.tmp" "\$FAILED_FILE"; exit 0 ;;
  is-enabled) grep -qFx "\$2" "\$MASKED_FILE" 2>/dev/null && { echo masked; exit 0; }; echo enabled; exit 1 ;;
  list-units)
    while read -r u; do [ -n "\$u" ] && echo "\$u loaded failed failed unit"; done < "\$FAILED_FILE"
    exit 0 ;;
  *) echo "fake-systemctl: unsupported: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$FAKE_SYSTEMCTL"
export SENECHAL_SUDO_CMD=""
export SENECHAL_SYSTEMCTL="$FAKE_SYSTEMCTL"

echo "=== verify before enable: expect FAIL (not masked) ==="
"$SCRIPT" verify >/tmp/out.$$ 2>&1
rc=$?
check "verify fails loud when not masked" "$rc" "1"
grep -q "FAIL" /tmp/out.$$ && ok "verify output contains FAIL" || bad "verify output missing FAIL"

echo "=== enable ==="
"$SCRIPT" enable >/tmp/out.$$ 2>&1
rc=$?
check "enable exits 0" "$rc" "0"
grep -qFx "postfix@-.service" "$MASKED_FILE" && ok "unit recorded as masked" || bad "unit not recorded as masked"
grep -qFx "postfix@-.service" "$FAILED_FILE" && bad "unit still in failed-units list after enable" || ok "reset-failed cleared the failed-units entry"

echo "=== verify after enable: expect INCOMPLETE (masked, but fake systemctl can't answer the failed-units check) ==="
"$SCRIPT" verify >/tmp/out.$$ 2>&1
rc=$?
check "verify is incomplete, not a false pass, in test mode" "$rc" "2"
grep -q "postfix@-.service is masked" /tmp/out.$$ && ok "verify output confirms masked" || bad "verify output missing masked confirmation"

echo "=== enable again: idempotent ==="
before="$(cat "$MASKED_FILE")"
"$SCRIPT" enable >/tmp/out.$$ 2>&1
rc=$?
check "re-enable exits 0" "$rc" "0"
after="$(cat "$MASKED_FILE")"
check "re-enable does not double-mask" "$before" "$after"

rm -f /tmp/out.$$

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
