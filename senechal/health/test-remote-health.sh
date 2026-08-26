#!/usr/bin/env bash
# Test harness for estate-health.sh's remote-host checks. Runs the real
# script against a throwaway config with PATH-stubbed `ssh` and `ping`,
# so no real device is ever contacted and every branch (healthy, full
# disk, hot, failed unit, auth failure, host down, undeclared os,
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"

# --- stub ssh: replays canned output/rc per host, records its argv/stdin
cat > "$T/bin/ssh" <<'STUB'
#!/usr/bin/env bash
host=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  a="${args[$i]}"
  case "$a" in
    -o) i=$((i + 2)); continue ;;
    -*) i=$((i + 1)); continue ;;
    *) host="$a"; break ;;
  esac
done
printf '%s\n' "$*" > "$STUB_DIR/ssh-argv-$host"
cat > "$STUB_DIR/ssh-stdin-$host" 2>/dev/null
[ -f "$STUB_DIR/ssh-out-$host" ] && cat "$STUB_DIR/ssh-out-$host"
rc=0
[ -f "$STUB_DIR/ssh-rc-$host" ] && rc="$(cat "$STUB_DIR/ssh-rc-$host")"
exit "$rc"
STUB

# --- stub ping: last arg is the address; rc from a per-address file
cat > "$T/bin/ping" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do addr="$a"; done
rc=0
[ -f "$STUB_DIR/ping-rc-$addr" ] && rc="$(cat "$STUB_DIR/ping-rc-$addr")"
exit "$rc"
STUB
chmod +x "$T/bin/ssh" "$T/bin/ping"

# --- throwaway registry: one device per branch under test ---------------
cat > "$T/senechal.json" <<'JSON'
{
  "estate": { "devices": [
    { "name": "pi-ok",      "kind": "pi", "addr": "10.0.0.1", "reach": "ssh", "ssh_host": "pi-ok",      "os": "linux",   "owner": "crt",  "expect": "intermittent" },
    { "name": "pi-sick",    "kind": "pi", "addr": "10.0.0.2", "reach": "ssh", "ssh_host": "pi-sick",    "os": "linux",   "owner": "crt",  "expect": "always-on" },
    { "name": "pi-noauth",  "kind": "pi", "addr": "10.0.0.3", "reach": "ssh", "ssh_host": "pi-noauth",  "os": "linux",   "owner": "crt",  "expect": "always-on" },
    { "name": "pi-off",     "kind": "pi", "addr": "10.0.0.4", "reach": "ssh", "ssh_host": "pi-off",     "os": "linux",   "owner": "crt",  "expect": "intermittent" },
    { "name": "pi-dark",    "kind": "pi", "addr": "10.0.0.5", "reach": "ssh", "ssh_host": "pi-dark",    "os": "linux",   "owner": "crt",  "expect": "always-on" },
    { "name": "pi-mystery",               "addr": "10.0.0.6", "reach": "ssh", "ssh_host": "pi-mystery",                                   "expect": "always-on" },
    { "name": "pi-garbage", "kind": "pi", "addr": "10.0.0.7", "reach": "ssh", "ssh_host": "pi-garbage", "os": "linux",   "owner": "crt",  "expect": "always-on" },
    { "name": "win-box",    "kind": "pc", "addr": "10.0.0.8", "reach": "ssh", "ssh_host": "win-box",    "os": "windows", "owner": "crt",  "expect": "always-on" },
    { "name": "pi-after",   "kind": "pi", "addr": "10.0.0.9", "reach": "ssh", "ssh_host": "pi-after",   "os": "linux",   "owner": "crt",  "expect": "always-on" }
  ]},
  "health": { "disk_warn_pct": 85, "disk_fail_pct": 95, "temp_warn_c": 85 }
}
JSON

# --- canned probe replies ----------------------------------------------
cat > "$T/ssh-out-pi-ok" <<'EOF'
SENECHAL-RHC-1
disk / 40 8.2G
temp 50000
EOF
cat > "$T/ssh-out-pi-sick" <<'EOF'
SENECHAL-RHC-1
disk / 96 1.1G
disk /boot 88 30M
temp 91000
failedunit foo.service
EOF
printf '255\n' > "$T/ssh-rc-pi-noauth"
printf 'Permission denied (publickey).\n' > "$T/ssh-out-pi-noauth"
printf '1\n' > "$T/ping-rc-10.0.0.4"   # pi-off: down, intermittent
printf '1\n' > "$T/ping-rc-10.0.0.5"   # pi-dark: down, always-on
printf 'Last login: whenever\nnot a probe\n' > "$T/ssh-out-pi-garbage"
cat > "$T/ssh-out-win-box" <<'EOF'
SENECHAL-RHC-1
disk C: 55 120.5G
EOF
cat > "$T/ssh-out-pi-after" <<'EOF'
SENECHAL-RHC-1
disk / 10 90G
temp 40000
EOF

# --- run the real script ------------------------------------------------
out="$(STUB_DIR="$T" PATH="$T/bin:$PATH" \
       SENECHAL_CONFIG="$T/senechal.json" \
       XDG_STATE_HOME="$T/state" \
       bash ./estate-health.sh 2>&1)"
rc=$?

fails=0
expect_line() { # expect_line <marker> <substring...>
  local marker="$1"; shift
  if grep -qF "  $marker  $*" <<< "$out"; then
    printf 'ok:   %s  %s\n' "$marker" "$*"
  else
    printf 'MISS: %s  %s\n' "$marker" "$*"
    fails=$((fails + 1))
  fi
}

# healthy linux host
expect_line PASS "pi-ok: / at 40%, 8.2G free"
expect_line PASS "pi-ok: hottest zone at 50C"
expect_line PASS "pi-ok: no failed systemd units"
# degraded/broken linux host, same thresholds as local checks
expect_line FAIL "pi-sick: / at 96% (>= 95% fail threshold), 1.1G free. Owner: crt"
expect_line WARN "pi-sick: /boot at 88% (>= 85% warn threshold), 30M free"
expect_line WARN "pi-sick: hottest zone at 91C (>= 85C) -- likely throttling"
expect_line FAIL "pi-sick: systemd unit failed: foo.service"
# up but ssh refused: could-not-check, never a pass
expect_line SKIP "pi-noauth is up but the ssh probe failed (rc=255)"
# down + intermittent: off is normal, no incomplete
expect_line PASS "pi-off is off (declared intermittent)"
# down + always-on: reachability owns the FAIL, remote check skips
expect_line SKIP "pi-dark is not answering at 10.0.0.5"
# no os declared: the gap itself is visible
expect_line SKIP "pi-mystery -- no \"os\" declared in its estate entry"
# sentinel missing (motd/wrong shell): never parsed as health data
expect_line SKIP "pi-garbage is up but the ssh probe failed (rc=0)"
# windows: disk parsed, honesty note about narrower coverage
expect_line PASS "win-box: C: at 55%, 120.5G free"
if grep -qF "win-box: probe returned no disk data" <<< "$out"; then
  printf 'MISS: win-box disk line was not parsed\n'; fails=$((fails + 1))
fi
if ! grep -qF "temp/service checks not implemented for windows" <<< "$out"; then
  printf 'MISS: windows coverage note absent\n'; fails=$((fails + 1))
fi
# the device AFTER the windows host still ran (guards the stdin-eating bug)
expect_line PASS "pi-after: / at 10%, 90G free"

# transport assertions: BatchMode everywhere, right dialect per os
if ! grep -q 'BatchMode=yes' "$T/ssh-argv-pi-ok"; then
  printf 'MISS: linux ssh not in BatchMode\n'; fails=$((fails + 1))
fi
if ! grep -q 'SENECHAL-RHC-1' "$T/ssh-stdin-pi-ok"; then
  printf 'MISS: linux probe script not sent on stdin\n'; fails=$((fails + 1))
fi
if ! grep -q 'powershell .*-EncodedCommand' "$T/ssh-argv-win-box"; then
  printf 'MISS: windows probe not sent via powershell -EncodedCommand\n'; fails=$((fails + 1))
fi

printf '\nestate-health exit: %s (informational -- includes this host'\''s own checks)\n' "$rc"
if [ "$fails" -eq 0 ]; then
  printf 'ALL REMOTE-HEALTH ASSERTIONS PASSED\n'
  exit 0
fi
printf '%s ASSERTION(S) FAILED\n' "$fails"
exit 1
