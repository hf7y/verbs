#!/usr/bin/env bash
# tools/test-vault.sh -- the suite for tools/vault.sh. Exit 0 = all pass.
#
# Every case runs against a throwaway BARE repo in a temp dir, never against
# hf7y/ecosystem1-vault. The estate's real record is not a test fixture.
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
VAULT_SH="$PWD/vault.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1"; echo "       $2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want '$2', got '$3'"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3'" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpected '$3'" ;; *) ok "$1" ;; esac; }

newvault() {                       # -> $T/origin.git, one committed file
  rm -rf "$T/origin.git" "$T/seed"
  git init -q --bare "$T/origin.git"
  git init -q "$T/seed"; git -C "$T/seed" config user.email t@t; git -C "$T/seed" config user.name t
  mkdir -p "$T/seed/senechal"; echo existing > "$T/seed/senechal/OLD.md"
  git -C "$T/seed" add -A; git -C "$T/seed" commit -qm seed
  git -C "$T/seed" branch -M main; git -C "$T/seed" push -q "$T/origin.git" main
}
run() { OUT="$(bash "$VAULT_SH" --repo "$T/origin.git" run "$@" 2>&1)"; RC=$?; }
origin_has() { git --git-dir="$T/origin.git" cat-file -e "main:$1" 2>/dev/null; }

echo "-- A. the deposit must reach origin, or say it did not"
newvault
run bash -c 'echo new > "$BIBLIOTHECAIRE_VAULT/senechal/NEW.md"'
is  "A1 a writing command exits 0"                 0 "$RC"
origin_has senechal/NEW.md && ok "A2 the write is ON ORIGIN, not just in the temp clone" \
                           || bad "A2 the write is ON ORIGIN" "senechal/NEW.md absent from origin"
has "A3 it names the pushed commit"                "$OUT" "vault: pushed"

newvault
run bash -c 'ls "$BIBLIOTHECAIRE_VAULT" >/dev/null'
is  "A4 a read-only command exits 0"               0 "$RC"
hasnt "A4 and pushes nothing"                      "$OUT" "vault: pushed"

echo "-- A5. a push that cannot land is a FAILURE, and keeps the work"
newvault
chmod -R a-w "$T/origin.git"
run bash -c 'echo doomed > "$BIBLIOTHECAIRE_VAULT/senechal/DOOMED.md"'
chmod -R u+w "$T/origin.git"
is  "A5 an unpushable write exits 1, not 0"        1 "$RC"
has "A5 it says the push failed"                   "$OUT" "COULD NOT PUSH"
has "A5 it names where the only copy is"           "$OUT" "kept deliberately"
has "A5 it warns the safe-to-remove line is false" "$OUT" "safe to remove"
kept="$(sed -n 's/.*work is \([^ ]*\) .*/\1/p' <<<"$OUT" | head -1)"
[ -n "$kept" ] && [ -f "$kept/senechal/DOOMED.md" ] \
  && ok "A5 and the work really is still there" \
  || bad "A5 the work really is still there" "nothing at '${kept:-<unparsed>}'"
[ -n "$kept" ] && rm -rf "$kept"

echo "-- B. no persistent checkout survives a run"
newvault
run bash -c 'echo x > "$BIBLIOTHECAIRE_VAULT/senechal/B.md"; echo "$BIBLIOTHECAIRE_VAULT" > '"$T/where"
used="$(cat "$T/where")"
[ -d "$used" ] && bad "B1 the temp checkout is deleted after a successful run" "$used still exists" \
               || ok "B1 the temp checkout is deleted after a successful run"

echo "-- C. the command's own exit code and flags survive the wrapper"
newvault
run bash -c 'exit 7'
is  "C1 a failing command's exit code is propagated" 7 "$RC"
newvault
run bash -c 'echo "flags:$*"' _ --vault /somewhere --depth=1
has "C2 flags after \`run\` belong to the command"   "$OUT" "flags:--vault /somewhere --depth=1"

echo "-- D. could-not-look is never a pass"
OUT="$(bash "$VAULT_SH" --repo "$T/nonexistent.git" run true 2>&1)"; RC=$?
is  "D1 an unclonable vault exits 2, not 0 or 1"   2 "$RC"
OUT="$(bash "$VAULT_SH" run 2>&1)"; RC=$?
is  "D2 no command exits 2"                        2 "$RC"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
