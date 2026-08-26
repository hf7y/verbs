#!/usr/bin/env bash
# Tests for notify-send-flap-guard.sh. Underscore-prefixed so
# verify-all.sh does not glob it up and run it as a remedy.
#
#   ./_test-notify-send-flap-guard.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="./notify-send-flap-guard.sh"
PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export HOME="$SCRATCH"
export SENECHAL_BACKUP_ROOT="$SCRATCH/.senechal-remedy-backups"
export XDG_STATE_HOME="$SCRATCH/.local/state"
mkdir -p "$SCRATCH/.config/senechal"
export SENECHAL_CONFIG="$SCRATCH/.config/senechal/senechal.json"
printf '{"estate":{"devices":[]},"health":{}}\n' > "$SENECHAL_CONFIG"

# A stub "real" notify-send: logs every invocation's args (one call per
# line) and hands back an incrementing id, like the real binary does.
STUB_DIR="$SCRATCH/stub-bin"
mkdir -p "$STUB_DIR"
STUB_LOG="$SCRATCH/stub-calls.log"
STUB_IDCOUNTER="$SCRATCH/stub-idcounter"
cat > "$STUB_DIR/notify-send" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB_LOG"
id=\$(( \$(cat "$STUB_IDCOUNTER" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\$id" > "$STUB_IDCOUNTER"
printf '%s\n' "\$id"
EOF
chmod +x "$STUB_DIR/notify-send"
export SENECHAL_NOTIFY_SEND_REAL="$STUB_DIR/notify-send"

echo "=== verify before enable: expect FAIL ==="
"$SCRIPT" verify >/tmp/out.$$ 2>&1
rc=$?
check "verify fails loud before enable" "$rc" "1"

echo "=== enable ==="
"$SCRIPT" enable >/tmp/out.$$ 2>&1
rc=$?
check "enable exits 0" "$rc" "0"
[ -x "$HOME/.local/bin/notify-send" ] && ok "wrapper installed and executable" || bad "wrapper missing or not executable"

echo "=== enable is idempotent ==="
before="$(cat "$HOME/.local/bin/notify-send")"
"$SCRIPT" enable >/tmp/out.$$ 2>&1
after="$(cat "$HOME/.local/bin/notify-send")"
check "second enable leaves wrapper byte-identical" "$after" "$before"

echo "=== verify after enable, PATH ordered correctly, but no evidence yet: expect INCOMPLETE ==="
export PATH="$HOME/.local/bin:$PATH"
"$SCRIPT" verify -q >/tmp/out.$$ 2>&1
rc=$?
check "verify is INCOMPLETE (not a silent pass) before any suppression evidence exists" "$rc" "2"

WRAPPER="$HOME/.local/bin/notify-send"

echo "=== identical (summary+body) fired twice: second is suppressed ==="
: > "$STUB_LOG"
"$WRAPPER" "flap test" "same body" >/dev/null
"$WRAPPER" "flap test" "same body" >/dev/null
calls="$(grep -c . "$STUB_LOG" 2>/dev/null || echo 0)"
check "only one call reached the real binary" "$calls" "1"

echo "=== a DIFFERENT body under the same summary is NOT suppressed, and replaces the tile ==="
"$WRAPPER" "flap test" "different body" >/dev/null
calls="$(grep -c . "$STUB_LOG" 2>/dev/null || echo 0)"
check "the differing call reached the real binary" "$calls" "2"
grep -q -- '-r 1 ' "$STUB_LOG" && ok "the second real call carried -r 1 (replaces the first tile)" || bad "second call did not carry -r 1 -- got: $(tail -1 "$STUB_LOG")"

echo "=== a caller-supplied -r is left alone, not overridden ==="
: > "$STUB_LOG"
"$WRAPPER" -r 99 "flap test" "caller controls replace-id" >/dev/null
grep -q -- '-r 99' "$STUB_LOG" && ok "caller's own -r 99 survived untouched" || bad "wrapper overrode the caller's -r -- got: $(cat "$STUB_LOG")"
grep -q -- ' -r 0' "$STUB_LOG" && bad "wrapper ALSO injected its own -r 0 alongside the caller's" || ok "wrapper did not inject a second -r"

echo "=== a call with no positional args (e.g. --help) passes straight through ==="
: > "$STUB_LOG"
"$WRAPPER" --help >/dev/null 2>&1 || true
calls="$(grep -c . "$STUB_LOG" 2>/dev/null || echo 0)"
check "a flag-only call still reaches the real binary" "$calls" "1"

echo "=== suppressed-count is tracked, and verify now PASSES on real evidence ==="
"$SCRIPT" verify -q >/tmp/out.$$ 2>&1
rc=$?
check "verify passes once it has real suppression evidence" "$rc" "0"
"$SCRIPT" verify >/tmp/out.$$ 2>&1
grep -q "suppressed" /tmp/out.$$ && ok "verify reports the suppression count" || bad "verify output missing suppression count: $(cat /tmp/out.$$)"

echo "=== disable removes the wrapper ==="
"$SCRIPT" disable >/tmp/out.$$ 2>&1
rc=$?
check "disable exits 0" "$rc" "0"
[ -f "$WRAPPER" ] && bad "wrapper still present after disable" || ok "wrapper removed"

rm -f /tmp/out.$$

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
