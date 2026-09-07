#!/usr/bin/env bash
# backup-test.sh -- exercises `garde backup`'s wrap of gardien.py
# (gardien#26 / GAPS.md design question 2).
#
# gardien.py itself lives on `main`, not this branch, so this never runs
# the real script -- it stands a fake gardien.py in for it under
# GARDIEN_REPO/GARDIEN_CONFIG and asserts the argv/exit-code contract
# `garde backup` promises: --config is passed through, a 0 exit passes
# through as 0, a real nonzero exit is reported BROKEN (5) not silently
# swallowed, and a missing script is GAP (4) rather than a crash.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
GARDE="$ROOT/bin/garde"
pass=0; fail=0
ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (want $3, got $2)"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (output lacked: $3)" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/gardien-repo"
CONFIG="$TMP/gardien.json"
mkdir -p "$REPO"
: > "$CONFIG"

echo "=== garde backup: contract + behaviour"; echo

# --- GAP when gardien.py is not where GARDIEN_REPO says -------------------
out="$(GARDIEN_REPO="$REPO" GARDIEN_CONFIG="$CONFIG" "$GARDE" backup 2>&1)"; rc=$?
check "gardien.py missing at GARDIEN_REPO is GAP, exit 4" "$rc" 4
has  "...and names the env var to set" "$out" "GARDIEN_REPO"

# --- a fake gardien.py that succeeds --------------------------------------
cat > "$REPO/gardien.py" <<'PY'
import sys
assert sys.argv[1] == "--config"
open(sys.argv[2]).read()  # prove the config path was passed through
print("ran with " + " ".join(sys.argv[1:]))
sys.exit(0)
PY

out="$(GARDIEN_REPO="$REPO" GARDIEN_CONFIG="$CONFIG" "$GARDE" backup 2>&1)"; rc=$?
check "a gardien.py that exits 0 passes through as exit 0" "$rc" 0
has  "...and --config was passed through with the right path" "$out" "--config $CONFIG"

# --- gardien.py's own flags pass through after -- -------------------------
# verb_parse rejects any unrecognized leading-dash flag before a subcommand
# ever sees it (lib/verb.sh: "unknown flag: $1"), so gardien.py-specific
# flags like --only aren't reachable bare -- they go after the verb
# framework's own `--` ("rest is verbatim"), same as any other verb.
out="$(GARDIEN_REPO="$REPO" GARDIEN_CONFIG="$CONFIG" "$GARDE" backup -- --only mandark 2>&1)"; rc=$?
check "gardien.py flags after -- pass through, exit 0" "$rc" 0
has  "...and --only mandark reached gardien.py" "$out" "--only mandark"

# --- --json on the golden path (gardien#164) -------------------------------
# gardien.py's own [OK]/[FAIL] commentary is redirected to stderr under
# --json so stdout carries nothing but the JSON object; only stdout is
# captured here, the same as every other subcommand's --json assertions.
out="$(GARDIEN_REPO="$REPO" GARDIEN_CONFIG="$CONFIG" "$GARDE" --json backup 2>/dev/null)"; rc=$?
check "--json on the golden path still exits 0" "$rc" 0
echo "$out" | jq -e . >/dev/null 2>&1 && ok "backup --json emits parseable JSON" \
  || bad "backup --json emits parseable JSON (got: $out)"
[ "$(echo "$out" | jq -r .ok)" = "true" ] && ok "backup --json reports ok:true on the golden path" \
  || bad "backup --json reports ok:true on the golden path (got: $out)"
[ "$(echo "$out" | jq -r .exit_code)" = "0" ] && ok "backup --json reports exit_code:0 on the golden path" \
  || bad "backup --json reports exit_code:0 on the golden path (got: $out)"
errout="$(GARDIEN_REPO="$REPO" GARDIEN_CONFIG="$CONFIG" "$GARDE" --json backup 2>&1 1>/dev/null)"
has  "...and gardien.py's own commentary still reaches stderr, not swallowed" "$errout" "ran with --config"

# --- a fake gardien.py that fails -----------------------------------------
cat > "$REPO/gardien.py" <<'PY'
import sys
print("[FAIL] the raid isn't mounted", file=sys.stderr)
sys.exit(1)
PY

out="$(GARDIEN_REPO="$REPO" GARDIEN_CONFIG="$CONFIG" "$GARDE" backup 2>&1)"; rc=$?
check "a gardien.py that exits 1 is reported BROKEN, exit 5" "$rc" 5
has  "...quoting gardien.py's own [FAIL] rather than swallowing it" "$out" "raid isn't mounted"

# --- --json on the BROKEN path ----------------------------------------------
out="$(GARDIEN_REPO="$REPO" GARDIEN_CONFIG="$CONFIG" "$GARDE" --json backup 2>/dev/null)"; rc=$?
check "--json on the BROKEN path still exits 5" "$rc" 5
[ "$(echo "$out" | jq -r .ok)" = "false" ] && ok "backup --json reports ok:false on the BROKEN path" \
  || bad "backup --json reports ok:false on the BROKEN path (got: $out)"
[ "$(echo "$out" | jq -r .exit_code)" = "1" ] && ok "backup --json reports gardien.py's own exit_code, not the wrapper's 5" \
  || bad "backup --json reports gardien.py's own exit_code (got: $out)"

# --- GAP stays plain text even under --json ---------------------------------
EMPTYREPO="$TMP/no-gardien-here"; mkdir -p "$EMPTYREPO"
out="$(GARDIEN_REPO="$EMPTYREPO" GARDIEN_CONFIG="$CONFIG" "$GARDE" --json backup 2>&1)"; rc=$?
check "--json on a missing gardien.py is still GAP (4), not a JSON object" "$rc" 4
has  "...and the GAP message is unchanged plain text" "$out" "GARDIEN_REPO"

echo
printf -- '--- backup: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
