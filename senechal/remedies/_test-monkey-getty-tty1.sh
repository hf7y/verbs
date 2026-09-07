#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="./monkey-getty-tty1.sh"
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
OUT="$SCRATCH/out"

FAKE_SYSTEMCTL="$SCRATCH/fake-systemctl.sh"
MASKED_FILE="$SCRATCH/masked"
FAILED_FILE="$SCRATCH/failed"
: > "$MASKED_FILE"
printf 'getty@tty1.service\n' > "$FAILED_FILE"
cat > "$FAKE_SYSTEMCTL" <<EOF
#!/usr/bin/env bash
MASKED_FILE="$MASKED_FILE"
FAILED_FILE="$FAILED_FILE"
case "\$1" in
  mask) grep -qFx "\$2" "\$MASKED_FILE" 2>/dev/null || echo "\$2" >> "\$MASKED_FILE"; exit 0 ;;
  unmask) grep -vFx "\$2" "\$MASKED_FILE" > "\$MASKED_FILE.tmp" 2>/dev/null; mv "\$MASKED_FILE.tmp" "\$MASKED_FILE"; exit 0 ;;
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
"$SCRIPT" verify >"$OUT" 2>&1
rc=$?
check "verify fails loud when not masked" "$rc" "5"
grep -q "FAIL" "$OUT" && ok "verify output contains FAIL" || bad "verify output missing FAIL"

echo "=== enable ==="
"$SCRIPT" enable >"$OUT" 2>&1
rc=$?
check "enable exits 0" "$rc" "0"
grep -qFx "getty@tty1.service" "$MASKED_FILE" && ok "unit recorded as masked" || bad "unit not recorded as masked"
grep -qFx "getty@tty1.service" "$FAILED_FILE" && bad "unit still in failed-units list after enable" || ok "reset-failed cleared the failed-units entry"

echo "=== verify after enable: expect INCOMPLETE (masked, but fake systemctl can't answer the failed-units check) ==="
"$SCRIPT" verify >"$OUT" 2>&1
rc=$?
check "verify is incomplete, not a false pass, in test mode" "$rc" "2"
grep -q "getty@tty1.service is masked" "$OUT" && ok "verify output confirms masked" || bad "verify output missing masked confirmation"

echo "=== enable again: idempotent ==="
before="$(cat "$MASKED_FILE")"
"$SCRIPT" enable >"$OUT" 2>&1
rc=$?
check "re-enable exits 0" "$rc" "0"
after="$(cat "$MASKED_FILE")"
check "re-enable does not double-mask" "$before" "$after"

echo "=== disable: undo ==="
"$SCRIPT" disable >"$OUT" 2>&1
rc=$?
check "disable exits 0" "$rc" "0"
grep -qFx "getty@tty1.service" "$MASKED_FILE" && bad "unit still recorded as masked after disable" || ok "unit unmasked"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
