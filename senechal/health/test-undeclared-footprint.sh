#!/usr/bin/env bash
# Test harness for undeclared-footprint.sh. Runs the real script against
# throwaway system/user unit directories and a throwaway footprint
# registry, with `ss` PATH-stubbed so listening-port output is
# deterministic and no real host state is ever touched.
#
# Exit: 0 all assertions pass / 1 any assertion failed.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/system-units" "$T/user-units" "$T/vendor"

# --- stub ss: replays a canned listener table
cat > "$T/bin/ss" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_DIR/ss-out" 2>/dev/null
exit 0
STUB
chmod +x "$T/bin/ss"

# --- unit fixtures ------------------------------------------------------
# undeclared, real file, system scope -> must be flagged
: > "$T/system-units/cd-autorip@.service"
# declared by exact target match -> must NOT be flagged
: > "$T/system-units/known-declared.service"
# declared only via a wildcard footprint entry covering several units
: > "$T/system-units/bibliothecaire-intake-a.service"
: > "$T/system-units/bibliothecaire-intake-b.timer"
# declared only via its .timer sibling's target -- stem-substring match
: > "$T/system-units/garde-nightly.service"
# real file but known package/subsystem noise -> excluded by name
: > "$T/system-units/snap.example.service"
# vendor-managed: a symlink into /usr/lib, even though it points at a
# real file -- `find -type f` does not match symlinks, so this must
# never be flagged
: > "$T/vendor/upstream.service"
ln -s "$T/vendor/upstream.service" "$T/system-units/upstream.service"
# a plain directory entry must not confuse the *.service/*.timer scan
mkdir -p "$T/system-units/not-a-unit.service"

# user scope: undeclared real file -> must be flagged, scope "user"
: > "$T/user-units/my-user-thing.service"
# user scope: declared -> must NOT be flagged
: > "$T/user-units/known-user.timer"

cat > "$T/senechal.json" <<JSON
{
  "estate": { "footprint": [
    { "id": "known", "host": "testhost", "owner": "o", "kind": "systemd-system-unit", "target": "known-declared.service", "status": "live" },
    { "id": "biblio", "host": "testhost", "owner": "o", "kind": "systemd-system-unit", "target": "bibliothecaire-intake*.{service,timer}", "status": "live" },
    { "id": "garde", "host": "testhost", "owner": "o", "kind": "systemd-system-unit", "target": "garde-nightly.timer", "status": "live" },
    { "id": "knownuser", "host": "testhost", "owner": "o", "kind": "systemd-user-unit", "target": "known-user.timer", "status": "live" },
    { "id": "myport", "host": "testhost", "owner": "o", "kind": "listening-port", "target": "8991", "status": "live" }
  ]}
}
JSON

printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\nLISTEN 0 128 0.0.0.0:8991 0.0.0.0:* users:(("python",pid=1,fd=3))\nLISTEN 0 128 0.0.0.0:9999 0.0.0.0:* users:(("nc",pid=2,fd=3))\n' \
  > "$T/ss-out"

run() {
  STUB_DIR="$T" PATH="$T/bin:$PATH" \
  SENECHAL_HOSTNAME=testhost \
  SENECHAL_CONFIG="$T/senechal.json" \
  SENECHAL_SYSTEM_UNIT_DIR="$T/system-units" \
  SENECHAL_USER_UNIT_DIR="$T/user-units" \
  bash ./undeclared-footprint.sh "$@"
}

out="$(run 2>&1)"
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
expect_text() {
  if grep -qF "$1" <<< "$out"; then
    printf 'ok:   text %s\n' "$1"
  else
    printf 'MISS: text %s\n' "$1"
    fails=$((fails + 1))
  fi
}
expect_no_text() {
  if grep -qF "$1" <<< "$out"; then
    printf 'MISS: unexpectedly present: %s\n' "$1"
    fails=$((fails + 1))
  else
    printf 'ok:   absent %s\n' "$1"
  fi
}

# --- undeclared units are flagged ---------------------------------------
expect_line WARN "system unit cd-autorip@.service is installed but not declared in estate.footprint"
expect_line WARN "user unit my-user-thing.service is installed but not declared in estate.footprint"

# --- declared / matched units are silent --------------------------------
expect_no_text "known-declared.service is installed but not declared"
expect_no_text "bibliothecaire-intake-a.service is installed but not declared"
expect_no_text "bibliothecaire-intake-b.timer is installed but not declared"
expect_no_text "garde-nightly.service is installed but not declared"
expect_no_text "known-user.timer is installed but not declared"

# --- known noise and non-real-file cases are never flagged --------------
expect_no_text "snap.example.service"
expect_no_text "upstream.service is installed but not declared"

# --- ports are informational only, never affect the verdict -------------
expect_text "0.0.0.0:8991"
expect_text "declared (listening-port: 8991)"
expect_text "0.0.0.0:9999"
expect_text "not in estate.footprint"

# --- exit contract: undeclared units found -> WARN severity (rc=3) ------
if [ "$rc" -ne 3 ]; then
  printf 'MISS: expected rc=3 with undeclared units present, got %s\n' "$rc"; fails=$((fails + 1))
else
  printf 'ok:   rc=3 with undeclared units present\n'
fi

# --- a clean host (nothing undeclared) reports PASS and rc=0 ------------
T2="$(mktemp -d)"
mkdir -p "$T2/system-units" "$T2/user-units"
: > "$T2/system-units/known-declared.service"
cat > "$T2/senechal.json" <<JSON
{ "estate": { "footprint": [
  { "id": "known", "host": "testhost", "owner": "o", "kind": "systemd-system-unit", "target": "known-declared.service", "status": "live" }
]}}
JSON
printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\n' > "$T2/ss-out"
out2="$(STUB_DIR="$T2" PATH="$T/bin:$PATH" SENECHAL_HOSTNAME=testhost \
        SENECHAL_CONFIG="$T2/senechal.json" \
        SENECHAL_SYSTEM_UNIT_DIR="$T2/system-units" \
        SENECHAL_USER_UNIT_DIR="$T2/user-units" \
        bash ./undeclared-footprint.sh 2>&1)"
rc2=$?
if [ "$rc2" -eq 0 ] && grep -qF "no undeclared custom systemd units found" <<< "$out2"; then
  printf 'ok:   clean host is a PASS (rc=0)\n'
else
  printf 'MISS: clean host gave rc=%s, out=%s\n' "$rc2" "$out2"; fails=$((fails + 1))
fi
rm -rf "$T2"

# --- neither unit dir exists: no crash, reads as clean, not INCOMPLETE --
T3="$(mktemp -d)"
cat > "$T3/senechal.json" <<'JSON'
{ "estate": { "footprint": [] } }
JSON
printf '' > "$T3/ss-out"
out3="$(STUB_DIR="$T3" PATH="$T/bin:$PATH" SENECHAL_HOSTNAME=testhost \
        SENECHAL_CONFIG="$T3/senechal.json" \
        SENECHAL_SYSTEM_UNIT_DIR="$T3/no-such-dir" \
        SENECHAL_USER_UNIT_DIR="$T3/also-missing" \
        bash ./undeclared-footprint.sh 2>&1)"
rc3=$?
if [ "$rc3" -eq 0 ] && grep -qF "no undeclared custom systemd units found" <<< "$out3"; then
  printf 'ok:   missing unit dirs read as clean, not a crash (rc=0)\n'
else
  printf 'MISS: missing unit dirs gave rc=%s, out=%s\n' "$rc3" "$out3"; fails=$((fails + 1))
fi
rm -rf "$T3"

# --- quiet flag: clean pass prints nothing -------------------------------
T4="$(mktemp -d)"
cat > "$T4/senechal.json" <<'JSON'
{ "estate": { "footprint": [] } }
JSON
printf '' > "$T4/ss-out"
out4="$(STUB_DIR="$T4" PATH="$T/bin:$PATH" SENECHAL_HOSTNAME=testhost \
        SENECHAL_CONFIG="$T4/senechal.json" \
        SENECHAL_SYSTEM_UNIT_DIR="$T4/no-such-dir" \
        SENECHAL_USER_UNIT_DIR="$T4/also-missing" \
        bash ./undeclared-footprint.sh -q 2>&1)"
rc4=$?
if [ "$rc4" -eq 0 ] && [ -z "$out4" ]; then
  printf 'ok:   -q on a clean pass prints nothing\n'
else
  printf 'MISS: -q clean pass gave rc=%s, out=%q\n' "$rc4" "$out4"; fails=$((fails + 1))
fi
rm -rf "$T4"

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'all assertions passed\n'; exit 0
fi
printf '%d assertion(s) failed\n' "$fails"
exit 1
