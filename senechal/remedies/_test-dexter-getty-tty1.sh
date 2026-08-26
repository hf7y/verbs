#!/usr/bin/env bash
# Tests for dexter-getty-tty1.sh. Underscore-prefixed so verify-all.sh
# does not glob it up and run it as a remedy.
#
#   ./_test-dexter-getty-tty1.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="./dexter-getty-tty1.sh"
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
printf '{"estate":{"devices":[]},"health":{"dexter_ssh_host":"dexter-fake"}}\n' > "$SENECHAL_CONFIG"

# A fake ssh -- no real network, no real dexter involved. Takes the LAST
# argument as "the remote command" (real ssh joins every trailing arg
# into one string on the wire; on_dexter always hands it exactly one),
# and answers systemctl mask/unmask/is-enabled/reset-failed/list-units
# the same way the real unit's systemd would, tracked in scratch files so
# mask/is-enabled/list-units agree with each other across calls.
FAKE_SSH="$SCRATCH/fake-ssh.sh"
MASKED_FILE="$SCRATCH/masked"
FAILED_FILE="$SCRATCH/failed"
: > "$MASKED_FILE"
printf 'getty@tty1.service\n' > "$FAILED_FILE"   # starts "failed", like the real finding
cat > "$FAKE_SSH" <<EOF
#!/usr/bin/env bash
MASKED_FILE="$MASKED_FILE"
FAILED_FILE="$FAILED_FILE"
cmd="\${!#}"
cmd="\${cmd#sudo }"
case "\$cmd" in
  true) exit 0 ;;
  "systemctl is-enabled "*)
    unit="\${cmd#systemctl is-enabled }"
    grep -qFx "\$unit" "\$MASKED_FILE" 2>/dev/null && { echo masked; exit 0; }
    echo enabled; exit 1 ;;
  "systemctl mask "*)
    unit="\${cmd#systemctl mask }"
    grep -qFx "\$unit" "\$MASKED_FILE" 2>/dev/null || echo "\$unit" >> "\$MASKED_FILE"
    exit 0 ;;
  "systemctl unmask "*)
    unit="\${cmd#systemctl unmask }"
    grep -vFx "\$unit" "\$MASKED_FILE" > "\$MASKED_FILE.tmp" 2>/dev/null
    mv "\$MASKED_FILE.tmp" "\$MASKED_FILE"
    exit 0 ;;
  "systemctl reset-failed "*)
    unit="\${cmd#systemctl reset-failed }"
    grep -vFx "\$unit" "\$FAILED_FILE" > "\$FAILED_FILE.tmp" 2>/dev/null
    mv "\$FAILED_FILE.tmp" "\$FAILED_FILE"
    exit 0 ;;
  "systemctl list-units "*)
    while read -r u; do [ -n "\$u" ] && echo "\$u loaded failed failed unit"; done < "\$FAILED_FILE"
    exit 0 ;;
  *) echo "fake-ssh: unsupported: \$cmd" >&2; exit 1 ;;
esac
EOF
chmod +x "$FAKE_SSH"
export SENECHAL_SUDO_CMD=""
export SENECHAL_SSH_CMD="$FAKE_SSH"

echo "=== unreachable: fake ssh missing entirely -> INCOMPLETE, not a pass ==="
SENECHAL_SSH_CMD="$SCRATCH/no-such-ssh" "$SCRIPT" verify >/tmp/out.$$ 2>&1
rc=$?
check "verify is incomplete when dexter is unreachable" "$rc" "2"
grep -q "cannot reach" /tmp/out.$$ && ok "verify says could-not-check, not broken" || bad "verify missing the could-not-check line"

echo "=== verify before enable: expect FAIL (not masked) ==="
"$SCRIPT" verify >/tmp/out.$$ 2>&1
rc=$?
check "verify fails loud when not masked" "$rc" "1"
grep -q "FAIL" /tmp/out.$$ && ok "verify output contains FAIL" || bad "verify output missing FAIL"

echo "=== enable ==="
"$SCRIPT" enable >/tmp/out.$$ 2>&1
rc=$?
check "enable exits 0" "$rc" "0"
grep -qFx "getty@tty1.service" "$MASKED_FILE" && ok "unit recorded as masked" || bad "unit not recorded as masked"
grep -qFx "getty@tty1.service" "$FAILED_FILE" && bad "unit still in failed-units list after enable" || ok "reset-failed cleared the failed-units entry"

echo "=== verify after enable: expect INCOMPLETE (masked, but fake ssh mode can't answer the failed-units check) ==="
"$SCRIPT" verify >/tmp/out.$$ 2>&1
rc=$?
check "verify is incomplete, not a false pass, in test mode" "$rc" "2"
grep -q "getty@tty1.service is masked" /tmp/out.$$ && ok "verify output confirms masked" || bad "verify output missing masked confirmation"

echo "=== enable again: idempotent ==="
before="$(cat "$MASKED_FILE")"
"$SCRIPT" enable >/tmp/out.$$ 2>&1
rc=$?
check "re-enable exits 0" "$rc" "0"
after="$(cat "$MASKED_FILE")"
check "re-enable does not double-mask" "$before" "$after"

echo "=== disable: unmask ==="
"$SCRIPT" disable >/tmp/out.$$ 2>&1
rc=$?
check "disable exits 0" "$rc" "0"
grep -qFx "getty@tty1.service" "$MASKED_FILE" && bad "unit still recorded as masked after disable" || ok "unit unmasked"

echo "=== verify after disable: expect FAIL again ==="
"$SCRIPT" verify >/tmp/out.$$ 2>&1
rc=$?
check "verify fails after disable" "$rc" "1"

rm -f /tmp/out.$$

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
