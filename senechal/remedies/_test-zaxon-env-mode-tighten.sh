#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export SENECHAL_SKIP_CONFIG_CHECK=1
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"

cat > "$T/bin/ssh" <<'SH'
#!/usr/bin/env bash
[ "$(cat "$T_STATE/reachable" 2>/dev/null)" = "1" ] || exit 255
cmd="${@: -1}"
case "$cmd" in
  "exit 0") exit 0 ;;
  "stat -c %a "*) cat "$T_STATE/mode" 2>/dev/null; exit 0 ;;
  "stat -c %u "*) cat "$T_STATE/fuid" 2>/dev/null; exit 0 ;;
  "docker exec "*" id -u"*)
    c="$(awk '{print $3}' <<<"$cmd")"
    cat "$T_STATE/cuid_$c" 2>/dev/null; exit 0 ;;
  "chmod 600 "*)
    printf '600' > "$T_STATE/mode"; exit 0 ;;
  "docker inspect -f "*"State.Running"*)
    c="$(awk '{print $NF}' <<<"$cmd")"
    cat "$T_STATE/running_$c" 2>/dev/null; exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/ssh"
export PATH="$T/bin:$PATH" T_STATE="$T/state"

KEY="$T/key"
: > "$KEY"

run() {
  ZAXON_ENV_DEXTER_KEY="$KEY" \
  ZAXON_ENV_CONTAINERS="zaxon-gateway zaxon-relay" \
  ./zaxon-env-mode-tighten.sh "$@"
}

reset_state() {
  rm -rf "$T/state"; mkdir -p "$T/state"
  printf '1' > "$T/state/reachable"
  printf '777' > "$T/state/mode"
  printf '1000' > "$T/state/fuid"
  printf '1000' > "$T/state/cuid_zaxon-gateway"
  printf '1000' > "$T/state/cuid_zaxon-relay"
  printf 'true' > "$T/state/running_zaxon-gateway"
  printf 'true' > "$T/state/running_zaxon-relay"
}

echo "-- A. dexter unreachable"
reset_state
printf '0' > "$T/state/reachable"
out="$(run verify -q)"; rc=$?
check "A1 verify SKIPs (rc 2) when unreachable" "$rc" "2"
out="$(run enable 2>&1)"; rc=$?
check "A2 enable refuses (rc 1) when unreachable" "$rc" "1"

echo "-- B. no key present at all"
reset_state
rm -f "$KEY"
out="$(run verify -q)"; rc=$?
check "B1 verify SKIPs (rc 2) with no key" "$rc" "2"
out="$(run enable 2>&1)"; rc=$?
check "B2 enable refuses (rc 1) with no key" "$rc" "1"
: > "$KEY"

echo "-- C. every live container matches the file's uid -- enable proceeds"
reset_state
out="$(run enable 2>&1)"; rc=$?
check "C1 enable succeeds when every container's uid matches" "$rc" "0"
check "C2 the file is actually chmod'd to 600" "$(cat "$T/state/mode")" "600"
out="$(run verify -q)"; rc=$?
check "C3 verify passes afterward" "$rc" "0"

echo "-- D. a container reads a different uid -- refuses rather than guessing"
reset_state
printf '1001' > "$T/state/cuid_zaxon-relay"
out="$(run enable 2>&1)"; rc=$?
check "D1 enable REFUSES on a uid mismatch" "$rc" "1"
printf '%s' "$out" | grep -q "zaxon-relay reads the mount as uid 1001" \
  && ok "D2 names the mismatched container and uids" || bad "D2 did not name the mismatch ($out)"
check "D3 the file mode is untouched" "$(cat "$T/state/mode")" "777"

echo "-- E. already 600 -- enable is a no-op, does not even ask about containers"
reset_state
printf '600' > "$T/state/mode"
rm -f "$T/state/cuid_zaxon-gateway" "$T/state/cuid_zaxon-relay"
out="$(run enable 2>&1)"; rc=$?
check "E1 enable is a no-op when already 600" "$rc" "0"
printf '%s' "$out" | grep -q "already 600" && ok "E2 says so" || bad "E2 wrong message ($out)"

echo "-- F. no container in the list is running -- warns but does not refuse"
reset_state
rm -f "$T/state/cuid_zaxon-gateway" "$T/state/cuid_zaxon-relay"
out="$(run enable 2>&1)"; rc=$?
check "F1 enable proceeds when nothing is running to check against" "$rc" "0"
check "F2 the file is still chmod'd" "$(cat "$T/state/mode")" "600"

echo "zaxon-env-mode-tighten test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
