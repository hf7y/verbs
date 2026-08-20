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

echo
printf -- '--- git: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
