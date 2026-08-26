#!/usr/bin/env bash
# Test harness for unabsorbed-notices.sh. Runs the real script with a
# PATH-stubbed `gh` that echoes fixed JSON, so no real issue is ever
# touched and the age arithmetic is exercised against a fixed clock.
#
# Exit: 0 all assertions pass / 1 any assertion failed.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# createdAt timestamps computed relative to "now" so the fixture never
# goes stale itself: one notice a day old (young), one 5 days old
# (stale past the 2-day default threshold), one exactly at the
# threshold boundary.
young_ts="$(date -u -d '1 day ago' '+%Y-%m-%dT%H:%M:%SZ')"
stale_ts="$(date -u -d '5 days ago' '+%Y-%m-%dT%H:%M:%SZ')"
boundary_ts="$(date -u -d '2 days ago' '+%Y-%m-%dT%H:%M:%SZ')"

# --- stub gh: answers `issue list --repo ... --json ...` from a canned
# JSON file in $STUB_DIR/gh-issues.json. Any other invocation, or a
# missing/empty fixture file, is treated as "gh unreachable" (nonzero
# exit + stderr), matching a real auth/network failure.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    if [ "${GH_FAIL:-0}" = 1 ]; then
      echo "gh: authentication failed" >&2
      exit 4
    fi
    if [ -f "$STUB_DIR/gh-issues.json" ]; then
      cat "$STUB_DIR/gh-issues.json"
      exit 0
    fi
    echo "gh: no fixture" >&2
    exit 1
    ;;
  *)
    echo "gh: unsupported stub invocation: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$T/bin/gh"

fails=0
run() { # run <fixture-json-or-empty> <gh_fail 0/1>
  local fixture="$1" ghfail="$2"
  [ -n "$fixture" ] && printf '%s' "$fixture" > "$T/gh-issues.json"
  [ -z "$fixture" ] && rm -f "$T/gh-issues.json"
  STUB_DIR="$T" GH_FAIL="$ghfail" PATH="$T/bin:$PATH" \
    SENECHAL_CONFIG="$T/senechal.json" \
    bash ./unabsorbed-notices.sh 2>&1
}

expect_text() { # expect_text <output> <substring>
  if grep -qF "$2" <<< "$1"; then
    printf 'ok:   text %s\n' "$2"
  else
    printf 'MISS: text %s\n' "$2"
    fails=$((fails + 1))
  fi
}
expect_rc() { # expect_rc <label> <got> <want>
  if [ "$2" -eq "$3" ]; then
    printf 'ok:   %s rc=%s\n' "$1" "$2"
  else
    printf 'MISS: %s expected rc=%s, got %s\n' "$1" "$3" "$2"
    fails=$((fails + 1))
  fi
}

# --- throwaway config: default 2-day threshold ---------------------------
cat > "$T/senechal.json" <<JSON
{ "health": { "notice_stale_days": 2 } }
JSON

# (a) no stale notices -> pass -------------------------------------------
fixture_none_stale=$(cat <<JSON
[
  {"number": 101, "title": "young notice, well under threshold", "createdAt": "$young_ts"}
]
JSON
)
out="$(run "$fixture_none_stale" 0)"; rc=$?
expect_rc "no stale notices" "$rc" 0
expect_text "$out" "under the 2d threshold"

# (b) a notice past the threshold -> flags it, real content assertion ----
fixture_stale=$(cat <<JSON
[
  {"number": 202, "title": "monkey has four live project accounts", "createdAt": "$stale_ts"}
]
JSON
)
out="$(run "$fixture_stale" 0)"; rc=$?
expect_rc "stale notice" "$rc" 3
expect_text "$out" "WARN  #202"
expect_text "$out" "monkey has four live project accounts"
expect_text "$out" "still open and unabsorbed"

# boundary: exactly at the threshold counts as stale (>=), not under it.
fixture_boundary=$(cat <<JSON
[
  {"number": 303, "title": "boundary notice", "createdAt": "$boundary_ts"}
]
JSON
)
out="$(run "$fixture_boundary" 0)"; rc=$?
expect_rc "boundary notice (age == threshold)" "$rc" 3
expect_text "$out" "WARN  #303"

# mixed: one stale, one fresh -> still flags only the stale one and rc=3
fixture_mixed=$(cat <<JSON
[
  {"number": 202, "title": "stale one", "createdAt": "$stale_ts"},
  {"number": 101, "title": "fresh one", "createdAt": "$young_ts"}
]
JSON
)
out="$(run "$fixture_mixed" 0)"; rc=$?
expect_rc "mixed notices" "$rc" 3
expect_text "$out" "WARN  #202"
expect_text "$out" "PASS  #101"

# empty list -> pass, no notices at all
out="$(run '[]' 0)"; rc=$?
expect_rc "empty notice queue" "$rc" 0
expect_text "$out" "no open"

# (c) gh unavailable / auth or network failure -> exit 2, never a pass ---
out="$(run "$fixture_none_stale" 1)"; rc=$?
expect_rc "gh auth/network failure" "$rc" 2
expect_text "$out" "gh issue list failed"

# gh entirely missing from PATH -> exit 2 as well
out="$(STUB_DIR="$T" PATH="/usr/bin:/bin" SENECHAL_CONFIG="$T/senechal.json" \
       bash ./unabsorbed-notices.sh 2>&1)"; rc=$?
if command -v gh >/dev/null 2>&1; then
  printf 'skip: real gh is on the system PATH -- cannot exercise "gh missing" here\n'
else
  expect_rc "gh missing from PATH" "$rc" 2
  expect_text "$out" "not on PATH"
fi

# -q must stay silent on a clean pass but still report on a real finding
printf '%s' "$fixture_none_stale" > "$T/gh-issues.json"
out_q_pass="$(STUB_DIR="$T" GH_FAIL=0 PATH="$T/bin:$PATH" \
              SENECHAL_CONFIG="$T/senechal.json" \
              bash ./unabsorbed-notices.sh -q 2>&1)"
if [ -z "$out_q_pass" ]; then
  printf 'ok:   -q silent on clean pass\n'
else
  printf 'MISS: -q should be silent on a clean pass, got: %s\n' "$out_q_pass"
  fails=$((fails + 1))
fi
printf '%s' "$fixture_stale" > "$T/gh-issues.json"
out_q_warn="$(STUB_DIR="$T" GH_FAIL=0 PATH="$T/bin:$PATH" \
              SENECHAL_CONFIG="$T/senechal.json" \
              bash ./unabsorbed-notices.sh -q 2>&1)"
expect_text "$out_q_warn" "WARN  #202"

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'all assertions passed\n'; exit 0
fi
printf '%d assertion(s) failed\n' "$fails"
exit 1
