#!/usr/bin/env bash
# Tests for secret-plaintext-egress.sh. Underscore-prefixed so
# verify-all.sh does not glob it up and run it as a remedy.
#
#   ./_test-secret-plaintext-egress.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="./secret-plaintext-egress.sh"
PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export HOME="$SCRATCH"
mkdir -p "$SCRATCH/.config/senechal"
export SENECHAL_CONFIG="$SCRATCH/.config/senechal/senechal.json"

write_config() {
  # id, host, owner, path, purpose, mode, recovery, reprovision_cost,
  # offhost, status, verify, reprovision, notes -- cfg_secrets' field
  # order (lib/common.sh).
  cat > "$SENECHAL_CONFIG" <<'JSON'
{
  "estate": {
    "devices": [],
    "secrets": [
      {
        "id": "test-cred-live",
        "host": "mandark",
        "owner": "testapp",
        "path": "~/.config/testapp/secret.token",
        "purpose": "test",
        "mode": "600",
        "offhost": "forbid",
        "status": "live"
      },
      {
        "id": "test-cred-retired",
        "host": "mandark",
        "owner": "testapp",
        "path": "~/.config/testapp/old.token",
        "purpose": "test",
        "mode": "600",
        "offhost": "forbid",
        "status": "retired"
      },
      {
        "id": "test-cred-allowed",
        "host": "mandark",
        "owner": "testapp",
        "path": "~/.config/testapp/public.token",
        "purpose": "test",
        "mode": "600",
        "offhost": "allow",
        "status": "live"
      },
      {
        "id": "test-cred-outside",
        "host": "mandark",
        "owner": "testapp",
        "path": "~/.ssh/outside_key",
        "purpose": "test",
        "mode": "600",
        "offhost": "forbid",
        "status": "live"
      }
    ]
  },
  "health": {}
}
JSON
}

write_garde() {
  mkdir -p "$SCRATCH/.config/gardien"
  cat > "$SCRATCH/.config/gardien/garde.json" <<'JSON'
{
  "sets": [
    { "name": ".config", "exclude": [] }
  ]
}
JSON
}

echo "=== no gardien config: enable is incomplete, not a false pass ==="
write_config
rm -f "$SCRATCH/.config/gardien/garde.json"
"$SCRIPT" enable >/tmp/out.$$ 2>&1
rc=$?
check "enable with no gardien config exits INCOMPLETE" "$rc" "2"

echo "=== no gardien config: verify skips, never a pass ==="
"$SCRIPT" verify >/tmp/out.$$ 2>&1
rc=$?
check "verify with no gardien config exits INCOMPLETE" "$rc" "2"
grep -q "SKIP" /tmp/out.$$ && ok "verify output contains SKIP" || bad "verify output missing SKIP"

echo "=== gardien config present, no offhost=forbid secrets under .config ==="
write_garde
printf '{"estate":{"devices":[],"secrets":[]},"health":{}}\n' > "$SENECHAL_CONFIG"
"$SCRIPT" verify >/tmp/out.$$ 2>&1
rc=$?
check "verify with nothing to exclude passes" "$rc" "0"
"$SCRIPT" enable >/tmp/out.$$ 2>&1
rc=$?
check "enable with nothing to exclude passes" "$rc" "0"

echo "=== verify before enable: expect FAIL (registered credential not excluded) ==="
write_config
write_garde
"$SCRIPT" verify >/tmp/out.$$ 2>&1
rc=$?
check "verify fails loud when the credential isn't excluded" "$rc" "1"
grep -q "testapp/secret.token is NOT excluded" /tmp/out.$$ && ok "verify names the missing credential" || bad "verify output missing the credential name"

echo "=== enable ==="
"$SCRIPT" enable >/tmp/out.$$ 2>&1
rc=$?
check "enable exits 0" "$rc" "0"
have="$(python3 -c "import json; print(json.load(open('$SCRATCH/.config/gardien/garde.json'))['sets'][0]['exclude'])")"
case "$have" in
  *testapp/secret.token*) ok "live, offhost=forbid credential under .config was excluded" ;;
  *) bad "live credential missing from excludes: $have" ;;
esac
case "$have" in
  *testapp/old.token*) bad "retired credential should NOT have been excluded: $have" ;;
  *) ok "retired credential correctly left out of excludes" ;;
esac
case "$have" in
  *testapp/public.token*) bad "offhost=allow credential should NOT have been excluded: $have" ;;
  *) ok "offhost=allow credential correctly left out of excludes" ;;
esac
case "$have" in
  *outside_key*) bad "credential outside ~/.config should NOT have been excluded: $have" ;;
  *) ok "credential outside ~/.config correctly left out of excludes" ;;
esac

echo "=== backup was written before the edit ==="
bcount="$(find "$SCRATCH/.config/gardien" -maxdepth 1 -name 'garde.json.senechal-backup.*' | wc -l)"
[ "$bcount" -ge 1 ] && ok "a timestamped backup of garde.json exists" || bad "no backup of garde.json found"

echo "=== verify after enable: expect PASS ==="
"$SCRIPT" verify >/tmp/out.$$ 2>&1
rc=$?
check "verify passes once the credential is excluded" "$rc" "0"
grep -q "copies already on" /tmp/out.$$ || grep -qi "must be removed by hand" /tmp/out.$$ \
  && ok "verify still flags the dexter-side copy as unfinished" \
  || bad "verify dropped the dexter-side leftover-copy note"

echo "=== enable again: idempotent, does not duplicate the exclude ==="
"$SCRIPT" enable >/tmp/out.$$ 2>&1
rc=$?
check "re-enable exits 0" "$rc" "0"
count="$(python3 -c "
import json
d = json.load(open('$SCRATCH/.config/gardien/garde.json'))
print(d['sets'][0]['exclude'].count('testapp/secret.token'))
")"
check "re-enable does not double-add the exclude" "$count" "1"

rm -f /tmp/out.$$

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
