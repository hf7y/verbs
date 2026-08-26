#!/usr/bin/env bash
# Tests for remote-health-keys.sh. Underscore-prefixed so verify-all.sh
# does not glob it up and run it as a remedy.
#
#   ./_test-remote-health-keys.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="./remote-health-keys.sh"
PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export HOME="$SCRATCH"
mkdir -p "$SCRATCH/.config/senechal"
export SENECHAL_CONFIG="$SCRATCH/.config/senechal/senechal.json"

# name, kind, addr, reach, owner, expect, ssh_host, os -- cfg_devices'
# field order (lib/common.sh). "zeta" is reach=local, so it must never
# show up in ssh_devices() at all.
cat > "$SENECHAL_CONFIG" <<'JSON'
{
  "estate": {
    "devices": [
      { "name": "alpha",   "kind": "host", "addr": "10.0.0.1", "reach": "ssh",   "ssh_host": "alpha-host" },
      { "name": "beta",    "kind": "host", "addr": "10.0.0.2", "reach": "ssh",   "ssh_host": "beta-host" },
      { "name": "gamma",   "kind": "host", "addr": "10.0.0.3", "reach": "ssh",   "ssh_host": "gamma-host" },
      { "name": "delta",   "kind": "host", "addr": "10.0.0.4", "reach": "ssh",   "ssh_host": "delta-host" },
      { "name": "epsilon", "kind": "host", "addr": "10.0.0.5", "reach": "ssh",   "ssh_host": "epsilon-host" },
      { "name": "zeta",    "kind": "host", "addr": "10.0.0.6", "reach": "local", "ssh_host": "zeta-host" }
    ]
  },
  "health": {}
}
JSON

# Fake ssh/ssh-copy-id/ping -- no real network involved. Real ssh-keygen
# still resolves from the rest of PATH (untouched, offline, writes only
# under $HOME).
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
TRUSTED_FILE="$SCRATCH/trusted"       # hosts BatchMode ssh currently trusts
DOWN_FILE="$SCRATCH/down"             # addrs that don't answer ping
COPYID_FAIL_FILE="$SCRATCH/copyid-fail"     # hosts where ssh-copy-id itself fails
COPYID_SILENT_FILE="$SCRATCH/copyid-silent" # hosts where ssh-copy-id "succeeds" but grants no real trust
: > "$TRUSTED_FILE"; : > "$DOWN_FILE"; : > "$COPYID_FAIL_FILE"; : > "$COPYID_SILENT_FILE"
printf 'alpha-host\n' > "$TRUSTED_FILE"           # already trusts the key
printf '10.0.0.2\n' > "$DOWN_FILE"                # beta: off right now
printf 'epsilon-host\n' > "$COPYID_FAIL_FILE"     # epsilon: ssh-copy-id fails outright
printf 'delta-host\n' > "$COPYID_SILENT_FILE"     # delta: copy "succeeds", key still refused after

cat > "$FAKEBIN/ssh" <<EOF
#!/usr/bin/env bash
host="\${@: -2:1}"
grep -qFx "\$host" "$TRUSTED_FILE" 2>/dev/null && exit 0
exit 255
EOF

cat > "$FAKEBIN/ssh-copy-id" <<EOF
#!/usr/bin/env bash
host="\${@: -1}"
grep -qFx "\$host" "$COPYID_FAIL_FILE" 2>/dev/null && exit 1
grep -qFx "\$host" "$COPYID_SILENT_FILE" 2>/dev/null && exit 0
echo "\$host" >> "$TRUSTED_FILE"
exit 0
EOF

cat > "$FAKEBIN/ping" <<EOF
#!/usr/bin/env bash
addr="\${@: -1}"
grep -qFx "\$addr" "$DOWN_FILE" 2>/dev/null && exit 1
exit 0
EOF
chmod +x "$FAKEBIN"/ssh "$FAKEBIN"/ssh-copy-id "$FAKEBIN"/ping
export PATH="$FAKEBIN:$PATH"

echo "=== verify before enable: expect FAIL (no dedicated key yet) ==="
"$SCRIPT" verify >/tmp/out.$$ 2>&1
rc=$?
check "verify fails loud with no dedicated key" "$rc" "1"
grep -q "does not exist" /tmp/out.$$ && ok "verify names the missing key" || bad "verify output missing the missing-key line"

echo "=== enable ==="
"$SCRIPT" enable >/tmp/out.$$ 2>&1
rc=$?
check "enable exits 0" "$rc" "0"
[ -f "$SCRATCH/.ssh/senechal-estate-ed25519" ] && ok "dedicated key was generated" || bad "dedicated key missing after enable"
grep -q "alpha: already trusts this key" /tmp/out.$$ && ok "already-trusted device reported untouched" || bad "missing already-trusted line for alpha"
grep -q "beta: not answering" /tmp/out.$$ && ok "unreachable device reported as skipped, not failed" || bad "missing not-answering line for beta"
grep -q "gamma: BatchMode ssh now works" /tmp/out.$$ && ok "gamma's key push confirmed working" || bad "missing confirmation line for gamma"
grep -q "delta: key pushed but BatchMode ssh still fails" /tmp/out.$$ && ok "delta's silent-refusal case reported correctly" || bad "missing silent-refusal line for delta"
grep -q "epsilon: ssh-copy-id failed" /tmp/out.$$ && ok "epsilon's outright copy failure reported correctly" || bad "missing copy-failure line for epsilon"
grep -q "zeta" /tmp/out.$$ && bad "reach=local device zeta should never appear in ssh device output" || ok "reach=local device zeta correctly excluded"

echo "=== verify after enable ==="
"$SCRIPT" verify >/tmp/out.$$ 2>&1
rc=$?
check "verify still fails overall (delta/epsilon remain untrusted)" "$rc" "1"
grep -q "alpha: BatchMode ssh works" /tmp/out.$$ && ok "alpha verified trusted" || bad "alpha not reported trusted"
grep -q "gamma: BatchMode ssh works" /tmp/out.$$ && ok "gamma verified trusted" || bad "gamma not reported trusted"
grep -q "beta is not answering" /tmp/out.$$ && ok "beta still reported as SKIP, not a failure, while off" || bad "beta not reported as unreachable"
grep -q "delta: up, but BatchMode ssh" /tmp/out.$$ && ok "delta still reported as refused" || bad "delta not reported as still refused"
grep -q "epsilon: up, but BatchMode ssh" /tmp/out.$$ && ok "epsilon still reported as refused" || bad "epsilon not reported as still refused"

echo "=== enable again: idempotent (existing key left alone, alpha untouched) ==="
before_key="$(cat "$SCRATCH/.ssh/senechal-estate-ed25519")"
"$SCRIPT" enable >/tmp/out.$$ 2>&1
rc=$?
after_key="$(cat "$SCRATCH/.ssh/senechal-estate-ed25519")"
check "re-enable does not regenerate the key" "$before_key" "$after_key"
grep -q "key already exists" /tmp/out.$$ && ok "re-enable reports the existing key, does not overwrite" || bad "re-enable did not report the existing key"

rm -f /tmp/out.$$

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
