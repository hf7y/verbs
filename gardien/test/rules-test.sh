#!/usr/bin/env bash
# rules-test.sh -- exercises `garde add`/`garde exclude`/`garde rules`
# (gardien#32) against a real temp garde.json, never this machine's real
# manifest.
#
# gardien#32's hazard: garde.json is hand-edited untracked JSON with no
# safety net. The invariant that matters is that a write VALIDATES before
# it ever replaces the live manifest -- so most of this suite proves the
# manifest is either updated correctly or left completely untouched,
# never partially written.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
GARDE="$ROOT/bin/garde"
pass=0; fail=0
ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (want $3, got $2)"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (output lacked: $3)" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 (output contained: $3)" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"; trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
MANIFEST="$TMP/garde.json"
cat > "$MANIFEST" <<JSON
{ "destinations": {}, "sets": [
  { "name": "Music", "path": "~/Music", "class": "bulk-immutable", "copies": [], "min_copies": 1, "verify": "md5" },
  { "name": "Downloads", "path": "~/Downloads", "class": "replaceable", "copies": [], "min_copies": 1, "verify": "md5",
    "exclude": ["work"] }
] }
JSON
export GARDE_MANIFEST="$MANIFEST"
export VERB_COST_FILE="$TMP/cost"

echo "=== garde add/exclude/rules: contract + behaviour"; echo

# --- rules on a manifest with nothing added yet -------------------------
out="$("$GARDE" rules 2>&1)"; rc=$?
check "rules on a clean manifest exits 0" "$rc" 0
has  "...and lists the pre-existing exclude" "$out" "work"
has  "...and reports no global excludes" "$out" "(none)"

# --- add: the golden path -----------------------------------------------
out="$("$GARDE" add '**/*.flac' --set Music 2>&1)"; rc=$?
check "add to an existing set exits 0" "$rc" 0
has  "...confirms what it added" "$out" "**/*.flac"
out="$("$GARDE" rules Music 2>&1)"
has  "rules now shows the include pattern" "$out" "**/*.flac"
has  "...and says it is not yet enforced (gardien#32 is honest about the gap)" "$out" "not yet enforced"

# --- add is idempotent, not append-forever -------------------------------
"$GARDE" add '**/*.flac' --set Music >/dev/null 2>&1
n="$(jq -r '.sets[] | select(.name=="Music") | (.include|length)' "$MANIFEST")"
check "adding the same pattern twice does not duplicate it" "$n" 1

# --- add refuses to invent a set -----------------------------------------
before="$(cat "$MANIFEST")"
"$GARDE" add 'x' --set NoSuchSet >/dev/null 2>&1
check "add to a nonexistent set is a usage error, exit 2" "$?" 2
after="$(cat "$MANIFEST")"
[ "$before" = "$after" ] && ok "...and the manifest was not touched" \
  || bad "...but the manifest changed anyway"

# --- add with no --set, or no pattern -------------------------------------
"$GARDE" add 'x' >/dev/null 2>&1
check "add with no --set is a usage error, exit 2" "$?" 2
"$GARDE" add --set Music >/dev/null 2>&1
check "add with no pattern is a usage error, exit 2" "$?" 2

# --- exclude --set: the golden path, and it is the SAME field media reads -
out="$("$GARDE" exclude '**/*.tmp' --set Downloads 2>&1)"; rc=$?
check "exclude --set on an existing set exits 0" "$rc" 0
n="$(jq -r '.sets[] | select(.name=="Downloads") | (.exclude|length)' "$MANIFEST")"
check "Downloads now carries 2 exclude patterns (work + the new one)" "$n" 2
hasnt "exclude's own confirmation does not claim 'not yet enforced' (it already is)" \
      "$out" "not yet enforced"

# --- exclude --global -----------------------------------------------------
out="$("$GARDE" exclude '**/node_modules' --global 2>&1)"; rc=$?
check "exclude --global exits 0" "$rc" 0
n="$(jq -r '(.global_exclude|length)' "$MANIFEST")"
check "global_exclude now has one entry" "$n" 1
out="$("$GARDE" rules 2>&1)"
has "rules prints the global exclude ahead of any set" "$out" "**/node_modules"

# --- exclude: mutually exclusive / missing target -------------------------
"$GARDE" exclude 'x' --set Music --global >/dev/null 2>&1
check "--set and --global together is a usage error, exit 2" "$?" 2
"$GARDE" exclude 'x' >/dev/null 2>&1
check "exclude with neither --set nor --global is a usage error, exit 2" "$?" 2
"$GARDE" exclude 'x' --set NoSuchSet >/dev/null 2>&1
check "exclude --set naming an absent set is a usage error, exit 2" "$?" 2

# --- rules on an unknown set name -----------------------------------------
"$GARDE" rules NoSuchSet >/dev/null 2>&1
check "rules <absent-set> is a usage error, not a silent empty report" "$?" 2

# --- the write is validated BEFORE it replaces the manifest --------------
# A directory with no write permission makes mktemp fail beside the
# manifest, which is exactly the failure mode a hand-edit has no
# equivalent guard against: this command must refuse loudly, exit 5
# (BROKEN, not a crash), and leave the real file exactly as it was.
RO="$TMP/readonly-dir"; mkdir -p "$RO"
cp "$MANIFEST" "$RO/garde.json"
chmod 555 "$RO"
before="$(cat "$RO/garde.json")"
GARDE_MANIFEST="$RO/garde.json" "$GARDE" add 'x' --set Music >/dev/null 2>&1
check "a write that cannot create its temp file is BROKEN, exit 5" "$?" 5
chmod 755 "$RO"
after="$(cat "$RO/garde.json")"
[ "$before" = "$after" ] && ok "...and the unwritable manifest itself was never touched" \
  || bad "...but the manifest changed anyway"

# --- every write took a backup somewhere -----------------------------------
bakcount="$(find "$TMP" -maxdepth 1 -name 'garde.json.bak.*' | wc -l)"
[ "$bakcount" -gt 0 ] && ok "at least one timestamped backup was written" \
  || bad "no backup was ever written"

# --- never spends: no --summon offered anywhere on these three -----------
out="$("$GARDE" add '**/*.flac' --set Music --summon 2>&1)"
check "add ignores --summon rather than needing it (bash-only, like media audit)" "$?" 0

echo
printf -- '--- rules: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
