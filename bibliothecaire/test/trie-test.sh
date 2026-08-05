#!/usr/bin/env bash
# trie-test.sh -- the man page, executed.
#
# Every row here is a row of the page test in realisateur's /bashify command.
# The point is that "the contract was kept" is a MEASUREMENT, not a claim, so
# each assertion names the page sentence it is checking.
#
# Exit 0 is only reachable over a filled inventory, and the inventory shipped
# in this tree is deliberately blank. So the fixture builds a whole miniature
# tree -- bin/, lib/, ACCOUNTS.md -- rather than adding an override flag the
# page would then have to document. No new surface exists for the test's sake.

set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
VERB="${1:-$ROOT/bin/trie}"
PAGE="$ROOT/man/trie.1"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }

fixture() {   # fixture <inventory-body>  -> prints the path to a runnable trie
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bin" "$d/lib"
  cp "$VERB" "$d/bin/trie"; cp "$ROOT/lib/verb.sh" "$d/lib/verb.sh"
  chmod +x "$d/bin/trie"
  { printf '| address | provider | purpose | volume | stakes | pain |\n|---|---|---|---|---|---|\n'
    printf '%s\n' "$1"; } > "$d/ACCOUNTS.md"
  printf '%s' "$d/bin/trie"
}

printf 'trie -- contract test\n\n'

# --- ROW 2: every SYNOPSIS form runs as written -------------------------------
printf 'SYNOPSIS forms run as written\n'
R="$(fixture '| a@x | gmail | work | 5 | high | pileup |')"
"$R" >/dev/null 2>&1;              check "trie"            "$?" "0"
"$R" --markdown >/dev/null 2>&1;   check "trie --markdown" "$?" "0"
"$R" --json >/dev/null 2>&1;       check "trie --json"     "$?" "0"
"$R" -q >/dev/null 2>&1;           check "trie -q"         "$?" "0"
"$R" --quiet >/dev/null 2>&1;      check "trie --quiet"    "$?" "0"
"$R" --help >/dev/null 2>&1;       check "trie --help"     "$?" "0"
"$R" --version >/dev/null 2>&1;    check "trie --version"  "$?" "0"

# --- ROW 3: the surface is bidirectional --------------------------------------
printf '\nsurface is bidirectional (page <-> program)\n'
# troff escapes every hyphen as \-, so the page is de-escaped before matching.
# The first draft of this test grepped the raw page and reported five documented
# flags as missing. A harness that damages its evidence reports the wrong thing
# broken -- check the harness before believing the finding.
page="$(sed 's/\\-/-/g' "$PAGE")"
for f in --markdown --json --quiet --version --help; do
  printf '%s' "$page" | grep -q -- "$f" && ok "page documents $f" || bad "page documents $f"
done
# and nothing the program accepts is missing from the page. --summon is excluded
# by declaration, not by hand: this verb sets VERB_CAN_SUMMON=0, so verb.sh
# REJECTS the flag, and a rejected flag is not surface the page owes a line to.
undoc=""
for f in --markdown $(grep -oE '^\s+(--[a-z]+\|)?(--[a-z]+|-[qhv])\)' "$ROOT/lib/verb.sh" \
                      | tr -d ' )' | tr '|' '\n' | sort -u | grep -v summon); do
  printf '%s' "$page" | grep -q -- "$f" || undoc="$undoc $f"
done
check "no undocumented flag" "${undoc:-none}" "none"

# --- ROW 4: every documented exit code is reachable ---------------------------
printf '\nEXIT STATUS is complete and reachable\n'
"$R" >/dev/null 2>&1;              check "0 order printed"  "$?" "0"
"$R" --nope >/dev/null 2>&1;       check "2 unknown flag"   "$?" "2"
"$R" extra >/dev/null 2>&1;        check "2 stray argument" "$?" "2"
B="$(fixture '| a@x | gmail | work | 5 |  |  |')"
"$B" >/dev/null 2>&1;              check "6 nothing ranked" "$?" "6"
M="$(fixture '| a@x | gmail | work | 5 | high |  |')"; rm -f "$(dirname "$(dirname "$M")")/ACCOUNTS.md"
"$M" >/dev/null 2>&1;              check "6 no inventory"   "$?" "6"
# and no code outside the page's list is reachable
for code in 3 4 5; do
  grep -qE "^\.B $code\$" "$PAGE" && bad "page lists unreachable $code" || ok "page does not claim $code"
done

# --- ROW 5: EXAMPLES are doctests ---------------------------------------------
printf '\nEXAMPLES are executed, not illustrated\n'
check "--version output" "$("$R" --version)" "trie (bashified)"
out="$("$B" 2>&1)"
check "BLIND line" \
  "$(printf '%s' "$out" | head -1)" \
  "trie: BLIND: no account in ACCOUNTS.md carries a stakes value (1 row with an address, 0 ranked)"
check "BLIND second line" \
  "$(printf '%s' "$out" | sed -n 2p)" \
  'trie: this is "I cannot see", NOT "nothing to report".'

# --- DESCRIPTION: the behaviour the page promises in prose --------------------
printf '\nDESCRIPTION holds\n'
O="$(fixture '| z@x | gmail | zed | 1 | low | spam |
| b@x | gmail | bee | 1 | high | missed replies |
| a@x | gmail | ay | 1 | high |  |
| n@x | gmail | none | 1 |  |  |')"
got="$("$O" | sed -n '2,5p' | sed 's/ .*//' | tr -d '\n')"
check "worst consequence first, ties on address" "$got" "1.2.3.?."
check "unranked row is printed, not dropped" "$("$O" | grep -c 'no stakes value')" "1"
check "unranked row names the address" "$("$O" | grep -c 'n@x')" "1"
check "same order twice over an unchanged inventory" "$("$O")" "$("$O")"
check "pain is carried onto the line" "$("$O" | grep -c 'watch for: missed replies')" "1"
check "--markdown heads the document" "$("$O" --markdown | head -1)" "# Morning triage order"
check "--quiet suppresses the heading" "$("$O" -q | head -1)" "1. a@x [high] — ay"
check "--quiet still prints unranked" "$("$O" -q | grep -c 'no stakes value')" "1"

# --- ROW 6: the cost boundary -------------------------------------------------
printf '\ncost is answerable from the page alone\n'
"$R" --summon >/dev/null 2>&1;     check "--summon rejected"  "$?" "2"
"$R" -s >/dev/null 2>&1;           check "-s rejected"        "$?" "2"
"$R" --help 2>&1 | grep -q 'cannot spend money' && ok "--help states it cannot spend" || bad "--help states it cannot spend"
grep -q 'does not spend money' "$PAGE" && ok "page states it cannot spend" || bad "page states it cannot spend"

# --- ROW 8: no vendor, no agent names -----------------------------------------
# SCOPED TO THIS VERB'S OWN FILES, and that is a narrowing made on purpose when
# the verb moved here from secretaire on 2026-08-02.
#
# On secretaire's branch this greppped $ROOT, which was the whole branch --
# one verb, so "this verb's files" and "the tree" were the same set. Here they
# are not: bibliothecaire's branch carries six other verbs and an 18-text
# corpus, and nine of its files fail this pattern today for reasons that have
# nothing to do with `trie`. Left branch-wide, this row would fail on arrival
# and report `trie` broken when `trie` is clean -- a test that names the wrong
# thing broken, which is worse than one that stays silent.
#
# The branch-wide claim is NOT abandoned; it is moved to where it belongs. The
# purge guard is the check that owns it, and it currently runs only inside
# `bashify emit`, which is why those nine files drifted in unnoticed. Promoting
# it to a standing check is Phase 0.4 of the verb-surface plan. When that lands,
# this row stays scoped and that guard covers the tree.
printf '\nno vendor or agent names in this verb'"'"'s own files\n'
own=("$ROOT/bin/trie" "$ROOT/man/trie.1" "$ROOT/ACCOUNTS.md")
hits="$(grep -niE 'claude|anthropic|openai|gpt|\bagent\b|llm' "${own[@]}" 2>/dev/null | wc -l)"
check "grep over bin/trie, man/trie.1, ACCOUNTS.md" "$hits" "0"

# --- JSON is honoured, not merely parsed --------------------------------------
printf '\n--json is wired, not decorative\n'
check "json is an array of objects" "$("$O" --json | head -1)" "["
check "json carries every row" "$("$O" --json | grep -c '"address"')" "4"
check "json marks the unranked row null" "$("$O" --json | grep -c '"order": null')" "1"
if command -v python3 >/dev/null; then
  "$O" --json | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
    && ok "json parses" || bad "json parses"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
