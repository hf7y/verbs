#!/usr/bin/env bash
# git-test.sh -- exercises `garde git <path>` against real temp git repos.
#
# gardien#33: "backed up" for a repository is a predicate over repository
# state (every commit on a remote, nothing uncommitted), not a file
# transfer -- so this never touches garde.json or the media engine, and it
# never touches a real remote. Every repo here is `git init`'d fresh under
# a mktemp dir with a local bare repo standing in for origin.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
GARDE="$ROOT/bin/garde"
pass=0; fail=0
ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (want $3, got $2)"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (output lacked: $3)" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 (output contained: $3)" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"

git init -q --bare "$TMP/origin.git"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@example
git -C "$REPO" config user.name t
printf 'hi\n' > "$REPO/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm init
git -C "$REPO" remote add origin "$TMP/origin.git"
git -C "$REPO" push -q origin main

echo "=== garde git: contract + behaviour"; echo

# --- usage ---------------------------------------------------------------
"$GARDE" git >/dev/null 2>&1
check "no path is a usage error, exit 2" "$?" 2

# --- blind, not broken -----------------------------------------------------
"$GARDE" git "$TMP/no-such-dir" >/dev/null 2>&1
check "a directory that does not exist is BLIND (6), not BROKEN (5)" "$?" 6

mkdir -p "$TMP/not-a-repo"
"$GARDE" git "$TMP/not-a-repo" >/dev/null 2>&1
check "a plain directory with no .git is BLIND (6)" "$?" 6

# --- the golden path -------------------------------------------------------
out="$("$GARDE" git "$REPO" 2>&1)"; rc=$?
check "a pushed, clean repo exits 0" "$rc" 0
has  "...and says so in words, not just the exit code" "$out" "backed up"

# --- --json (gardien#164) -------------------------------------------------
out="$("$GARDE" git "$REPO" --json 2>&1)"; rc=$?
check "--json on the golden path still exits 0" "$rc" 0
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
    && ok "git --json emits parseable JSON" || bad "git --json produced invalid JSON: $out"
  [ "$(printf '%s' "$out" | jq -r .backed_up)" = true ] \
    && ok "git --json reports backed_up:true on the golden path" \
    || bad "git --json backed_up wrong: $out"
  [ "$(printf '%s' "$out" | jq -r '.reasons | length')" = 0 ] \
    && ok "git --json has no reasons on the golden path" || bad "git --json reasons should be empty: $out"
fi

# --- a global flag ahead of the subcommand must still reach it (#155) ------
# `garde --quiet git <repo>` used to mistake `--quiet` itself for the
# subcommand, freeze cmd=list, and print the top-level menu at exit 0
# instead of running `git <repo>` -- a silent no-op on the actual request.
out="$("$GARDE" --quiet git "$REPO" 2>&1)"; rc=$?
check "--quiet before the subcommand: still exits 0 on the golden path" "$rc" 0
has   "...and still runs git, giving git's own verdict" "$out" "is fully pushed and clean"
hasnt "...not the top-level subcommand menu" "$out" "subcommands (discovered"

# --- uncommitted work --------------------------------------------------
printf 'more\n' >> "$REPO/a.txt"
out="$("$GARDE" git "$REPO" 2>&1)"; rc=$?
check "a modified tracked file is NOT backed up, exit 5" "$rc" 5
has  "...and names the working-tree issue" "$out" "uncommitted or untracked"
git -C "$REPO" checkout -q -- a.txt

# --- untracked, non-ignored file ----------------------------------------
printf 'x\n' > "$REPO/stray.txt"
"$GARDE" git "$REPO" >/dev/null 2>&1
check "an untracked file (no .gitignore) also fails, exit 5" "$?" 5
rm "$REPO/stray.txt"

# --- an ignored untracked file does NOT count against it -------------
printf '/ignored.txt\n' > "$REPO/.gitignore"
git -C "$REPO" add .gitignore
git -C "$REPO" commit -qm 'add gitignore'
git -C "$REPO" push -q origin main
printf 'debris\n' > "$REPO/ignored.txt"
"$GARDE" git "$REPO" >/dev/null 2>&1
check "a gitignored file is not counted as unbacked-up work" "$?" 0
rm "$REPO/ignored.txt"

# --- unpushed commit --------------------------------------------------
printf 'more\n' >> "$REPO/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm second
out="$("$GARDE" git "$REPO" 2>&1)"; rc=$?
check "a commit ahead of origin/main is NOT backed up, exit 5" "$rc" 5
has  "...and says it is ahead, by name" "$out" "ahead of origin/main"
git -C "$REPO" push -q origin main

# --- a branch that only exists on this host -----------------------------
git -C "$REPO" checkout -q -b feature
printf 'branchwork\n' >> "$REPO/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm 'on a branch with no origin ref'
out="$("$GARDE" git "$REPO" 2>&1)"; rc=$?
check "a branch with no origin/<branch> fails, even with main pushed" "$rc" 5
has  "...naming the branch that only exists on this host" "$out" "feature"
git -C "$REPO" checkout -q main
git -C "$REPO" branch -qD feature

# --- a stash is real work git status cannot see -------------------------
printf 'stashed-work\n' >> "$REPO/a.txt"
git -C "$REPO" stash -q
out="$("$GARDE" git "$REPO" 2>&1)"; rc=$?
check "a stash entry fails even though the tree is clean, exit 5" "$rc" 5
has  "...and calls out the stash by name" "$out" "stash"
git -C "$REPO" stash drop -q

# --- no origin remote at all --------------------------------------------
git -C "$REPO" remote remove origin
out="$("$GARDE" git "$REPO" 2>&1)"; rc=$?
check "no origin remote at all fails, exit 5" "$rc" 5
has  "...and says there is nowhere this is backed up to" "$out" "no 'origin' remote"

out="$("$GARDE" git "$REPO" --json 2>&1)"; rc=$?
check "--json on the not-backed-up path still exits 5" "$rc" 5
if command -v jq >/dev/null 2>&1; then
  [ "$(printf '%s' "$out" | jq -r .backed_up)" = false ] \
    && ok "git --json reports backed_up:false" || bad "git --json backed_up wrong: $out"
  printf '%s' "$out" | jq -e '.reasons | any(contains("no '"'"'origin'"'"' remote"))' >/dev/null 2>&1 \
    && ok "git --json names the missing origin remote in reasons" \
    || bad "git --json reasons must name the missing origin remote: $out"
fi

# --json bails BLIND before any reasons are computed, same as the text path
"$GARDE" git "$TMP/no-such-dir" --json >/dev/null 2>&1
check "--json on a missing directory is still BLIND (6), not a JSON object" "$?" 6

# --- --json is scoped: still a usage error on other garde subcommands ----
# `media list`/`media audit` and `git` implement --json (gardien#164); every
# other subcommand still refuses it loudly rather than silently handing
# back the human text -- this file's own header calls that "the worst
# failure available".
out="$("$GARDE" --json list 2>&1)"; rc=$?
check "--json is a usage error on an unimplemented subcommand, not a silently ignored flag" "$rc" 2
has  "...and says it is not yet implemented" "$out" "not yet implemented"

echo
printf -- '--- git: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
