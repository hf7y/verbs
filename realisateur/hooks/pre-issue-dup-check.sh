#!/usr/bin/env bash
set -uo pipefail  # pre-issue-dup-check.sh -- PreToolUse guard on `gh issue create`: search before you file. GUARD-TEST: bin/tests/selfdev-hooks-provision.test.sh. GATE: advisory -- it denies once and can be overridden. TWO SIGNALS, because one was not enough: title words catch the obvious case, shared citations catch what words cannot -- #792 duplicated #790 with NO title word in common, but both cited #754. A TOLL BOOTH, NOT A WALL: it denies once with the candidates listed; re-run the identical command with `# dup-checked` appended and it proceeds. FAILS OPEN, ALWAYS: no jq, no gh, no network, or a search that errors or times out -> exit 0, because a guard that blocks filing because it could not check is worse than the duplicate it was preventing. WHY it exists is in the commit that added it.

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
cmd="$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)"
[ -n "$cmd" ] || exit 0

case "$cmd" in *"gh issue create"*) ;; *) exit 0 ;; esac
case "$cmd" in *"# dup-checked"*) exit 0 ;; esac        # the documented override

title="$(sed -n 's/.*--title[= ]\{1,\}\("\([^"]*\)"\|'"'"'\([^'"'"']*\)'"'"'\).*/\2\3/p' <<<"$cmd" | head -1)"
[ -n "$title" ] || exit 0

repo=""
case "$cmd" in *"--repo "*) repo="$(sed -n 's/.*--repo[= ]\{1,\}\([^ ]*\).*/\1/p' <<<"$cmd" | head -1)" ;; esac
[ -n "$repo" ] && repo="--repo $repo"

terms="$(tr -cs '[:alnum:]' ' ' <<<"$title" | tr 'A-Z' 'a-z' | tr ' ' '\n' \
        | awk 'length($0)>4' | sort -u | head -6 | tr '\n' ' ')"  # punctuation stripped; the 6 longest words carry the signal, and GitHub search ORs them
[ -n "${terms// }" ] || exit 0

hits="$(timeout 12 gh issue list $repo --state all --limit 6 --search "$terms" \
        --json number,state,title --jq '.[]|"  #\(.number) \(.state)  \(.title[0:72])"' 2>/dev/null)" || exit 0

bf="$(sed -n 's/.*--body-file[= ]\{1,\}\([^ ]*\).*/\1/p' <<<"$cmd" | head -1)"  # SHARED CITATIONS, not just shared words: an OPEN issue citing what you are about to cite is the strongest duplicate signal there is
cites=""
if [ -n "$bf" ] && [ -r "$bf" ]; then
  for n in $(grep -oE '#[0-9]{2,5}' "$bf" 2>/dev/null | tr -d '#' | sort -u | head -4); do
    m="$(timeout 8 gh issue list $repo --state open --limit 3 --search "$n in:body" \
         --json number,title --jq ".[]|\"  #\(.number) also cites #$n: \(.title[0:60])\"" 2>/dev/null \
         | grep -v "^  #$n " )"
    [ -n "$m" ] && cites="$cites$m
"
  done
fi
[ -n "$hits$cites" ] || exit 0
[ -n "$cites" ] && hits="$hits
$cites"

jq -n --arg h "$hits" --arg t "$terms" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("SEARCH BEFORE YOU FILE. Existing issues matching this title:\n\n" + $h +
      "\n\nsearched: " + $t +
      "\n\nIf one of these is the same finding, comment on it instead -- moving your unique content there and NOT filing a second issue. If yours is genuinely new, or adds a decision the existing one lacks, re-run the identical command with `# dup-checked` appended and it will proceed.")
  }
}'
