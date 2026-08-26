#!/usr/bin/env bash
# decision-rot.sh -- how many of Zach's answers is nobody acting on?
#
# RUNNER: no -- a SURVEY: run in a triage pass, or ahead of /ideate.
# GUARD-TEST: bin/tests/decision-rot.test.sh, offline behind a fake `gh`
# GATE: none -- reads every roster repo's live issue tracker
# ROT: ANSWERED **AND** STILL OPEN -- handed over, never taken up. Zach answers
# by COMMENTING and leaves it open; the nightly CLOSES what it handles. The
# predicate is bin/lib/answered.jq, shared with `etiquette`.
# TRAP: if a change here needs a convention INVENTED to work, THE AUDIT IS
#   WRONG -- report and stop. A draft keyed to "no commit references the issue"
#   worked, and would have gone stale SILENTLY when commit shape changed.
#
set -uo pipefail

CLI_NAME='decision-rot.sh'
CLI_SUMMARY='is an answered issue still sitting open?'
CLI_USAGE='  decision-rot.sh --all              audit every ecosystem1 repo
  decision-rot.sh <owner>/<repo>    audit one repo
  decision-rot.sh --all --json      machine-readable NDJSON + summary line'
CLI_FLAGS='--all --json'
CLI_POSITIONAL=any
CLI_EXITS='  0  clean -- every answered issue has been closed
  1  rot found -- at least one answered issue is still open
  6  BLIND -- a repo could not be read; the count is NOT trustworthy'
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
cli_guard "$@"

# DECISION_ROT_OWNER exists for bin/tests/decision-rot.test.sh, which pins the
# predicate against fixture JSON whose author login is not this estate's.
OWNER="${DECISION_ROT_OWNER:-hf7y}"

# shellcheck source=bin/lib/roster-set.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/roster-set.sh"

# A MISSING ROSTER IS BLIND, NOT AN EMPTY ESTATE. `.` on an absent file does
# not abort under `set -uo pipefail`, so the walk iterates zero repos, exits 0,
# and `ausculte` renders that "rot OK" -- live 2026-08-22 over 48 rotting
# decisions. ROSTER_SET_LIB is the load sentinel.
if [ "${ROSTER_SET_LIB:-}" != 1 ] || [ "${#ROSTER[@]}" -eq 0 ]; then
  printf '%s: BLIND -- lib/roster-set.sh did not load, so this audited NO repositories. A count of zero here is the absence of a reading, not the absence of rot.\n' \
    "$CLI_NAME" >&2
  exit 6
fi

MODE=''
REPOS=()
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all) MODE=all; shift ;;
    --json) JSON=1; shift ;;
    */*) MODE=one; REPOS+=("$1"); shift ;;
    *) echo "decision-rot.sh: not an <owner>/<repo>: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$MODE" ]; then
  echo "decision-rot.sh: pass --all or an <owner>/<repo>" >&2
  exit 2
fi
if [ "$MODE" = all ]; then
  for p in "${ROSTER[@]}"; do REPOS+=("$OWNER/$p"); done
fi

command -v gh >/dev/null || { echo "decision-rot.sh: gh not on PATH" >&2; exit 6; }
command -v jq >/dev/null || { echo "decision-rot.sh: jq not on PATH" >&2; exit 6; }

# THE PREDICATE IS NOT HERE: bin/lib/answered.jq, fed the bulk array below.
# It is a jq PROGRAM, not a bash function, so this stays ONE call per repo --
# issue_answered() would cost one per issue, hundreds across 26 repos.
#
# shellcheck source=bin/lib/answered.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/answered.sh"
[ -r "$ANSWERED_JQ_FILE" ] || {
  printf '%s: BLIND -- the predicate is not readable at %s. A count of zero here would be the absence of a reading, not the absence of rot.\n' \
    "$CLI_NAME" "$ANSWERED_JQ_FILE" >&2
  exit 6
}
DECISION_ROT_JQ="$(cat "$ANSWERED_JQ_FILE")"

# Verdicts: `number<TAB>verdict<TAB>at<TAB>state<TAB>title`. DETAIL is OPEN ONLY
# (318 listed, 3 real); COUNT stays all-states, matching `answered` (B2).
verdicts() {
  jq -r --arg owner "$1" --arg era "$ANSWERED_STAMP_ERA" "$DECISION_ROT_JQ"'
    .[]
    | . as $i
    | ($i | verdict)
    | [.number, .verdict, (.at // ""), $i.state, ($i.title | gsub("\\s+"; " "))] | @tsv'
}

rot_scan() {
  jq -r --arg owner "$1" --arg era "$ANSWERED_STAMP_ERA" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DECISION_ROT_JQ"'
    .[]
    | . as $i
    | ($i | verdict) as $v
    | select($v.verdict == "answered")
    | select($i.state == "OPEN")            # <-- ROT: answered, and still open
    | [ $i.number,
        ($v.at | split("T")[0]),
        ((($now | fromdateiso8601) - ($v.at | fromdateiso8601)) / 86400 | floor),
        ($i.title | gsub("\\s+"; " "))
      ] | @tsv'
}

ERRORS=0
TOTAL_ANSWERED=0
TOTAL_ROT=0
TOTAL_UNCOUNTED=0
TOTAL_UNC_OPEN=0
ROWS=''   # repo<TAB>answered<TAB>rot<TAB>oldest_days<TAB>uncounted
ROT=''    # repo<TAB>number<TAB>answered_at<TAB>age_days<TAB>title
UNC=''    # repo<TAB>number<TAB>comment_date<TAB>title

for repo in "${REPOS[@]}"; do
  if ! issues=$(gh issue list --repo "$repo" --state all --limit 500 \
                  --json number,title,state,labels,comments 2>&1); then
    case "$issues" in
      *"issues are disabled"*|*"Issues are disabled"*)
        printf '%-16s (issues disabled)\n' "${repo#*/}" >&2 ;;
      *)
        printf 'decision-rot.sh: ERROR reading %s: %s\n' "$repo" "$issues" >&2
        ERRORS=$((ERRORS+1)) ;;
    esac
    continue
  fi
  if ! printf '%s' "$issues" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf 'decision-rot.sh: ERROR %s returned a non-array (rate limit? token scope?)\n' "$repo" >&2
    ERRORS=$((ERRORS+1)); continue
  fi

  verd=$(printf '%s' "$issues" | verdicts "$OWNER")
  n_answered=$(printf '%s\n' "$verd" | cut -f2 | grep -c '^answered$')
  n_uncounted=$(printf '%s\n' "$verd" | cut -f2 | grep -c '^uncounted$')
  unc=$(printf '%s\n' "$verd" | awk -F'\t' '$2 == "uncounted" && $4 == "OPEN" { print $1 "\t" substr($3,1,10) "\t" $5 }')
  n_unc_open=$(printf '%s\n' "$unc" | grep -c .)
  rows=$(printf '%s' "$issues" | rot_scan "$OWNER")
  n_rot=$(printf '%s\n' "$rows" | grep -c .)
  oldest=$(printf '%s\n' "$rows" | grep . | cut -f3 | sort -rn | head -n1)

  TOTAL_ANSWERED=$((TOTAL_ANSWERED + n_answered))
  TOTAL_ROT=$((TOTAL_ROT + n_rot))
  TOTAL_UNCOUNTED=$((TOTAL_UNCOUNTED + n_uncounted))
  TOTAL_UNC_OPEN=$((TOTAL_UNC_OPEN + n_unc_open))
  ROWS+="${repo#*/}"$'\t'"$n_answered"$'\t'"$n_rot"$'\t'"${oldest:-0}"$'\t'"$n_unc_open"$'\n'
  while IFS= read -r line; do
    [ -n "$line" ] && ROT+="$repo"$'\t'"$line"$'\n'
  done <<< "$rows"
  while IFS= read -r line; do
    [ -n "$line" ] && UNC+="$repo"$'\t'"$line"$'\n'
  done <<< "$unc"
done

if [ "$JSON" = 1 ]; then
  printf '%s' "$ROT" | while IFS=$'\t' read -r r n a g t; do
    [ -n "$r" ] || continue
    jq -cn --arg repo "$r" --argjson number "$n" --arg answered_at "$a" \
           --argjson age_days "$g" --arg title "$t" \
           '{kind:"rotting",repo:$repo,number:$number,answered_at:$answered_at,age_days:$age_days,title:$title}'
  done
  printf '%s' "$UNC" | while IFS=$'\t' read -r r n a t; do
    [ -n "$r" ] || continue
    jq -cn --arg repo "$r" --argjson number "$n" --arg comment_at "$a" --arg title "$t" \
           '{kind:"uncounted",repo:$repo,number:$number,comment_at:$comment_at,title:$title}'
  done
  jq -cn --argjson repos "${#REPOS[@]}" --argjson answered "$TOTAL_ANSWERED" \
         --argjson rotting "$TOTAL_ROT" --argjson uncounted "$TOTAL_UNCOUNTED" \
         --argjson uncounted_open "$TOTAL_UNC_OPEN" --argjson errors "$ERRORS" \
         '{kind:"summary",repos:$repos,answered:$answered,rotting:$rotting,uncounted:$uncounted,uncounted_open:$uncounted_open,errors:$errors}'
else
  printf '%-18s %9s %8s %12s %10s\n' REPO ANSWERED ROTTING OLDEST_DAYS UNC_OPEN
  printf '%s' "$ROWS" | while IFS=$'\t' read -r r a n o u; do
    [ -n "$r" ] || continue
    printf '%-18s %9s %8s %12s %10s\n' "$r" "$a" "$n" "$o" "$u"
  done
  printf '%-18s %9s %8s %12s %10s\n' TOTAL "$TOTAL_ANSWERED" "$TOTAL_ROT" '' "$TOTAL_UNC_OPEN"
  if [ "$TOTAL_UNC_OPEN" -gt 0 ]; then
    echo
    # UNCOUNTED FIRST, ROTTING LAST: ausculte reads `tail -1` as the DOWN reason.
    echo "UNCOUNTED and still OPEN -- a pre-$ANSWERED_STAMP_ERA comment that cannot be"
    echo 'told from an agent'"'"'s. Read it; if a human answered, label it `answered`.'
    printf '%s' "$UNC" | sort -t$'\t' -k3,3 | while IFS=$'\t' read -r r n a t; do
      [ -n "$r" ] || continue
      printf '  %-16s #%-5s comment %s  %s\n' "${r#*/}" "$n" "$a" "$t"
    done
  fi
  if [ "$TOTAL_ROT" -gt 0 ]; then
    echo
    echo 'ROTTING -- answered, still open:'
    printf '%s' "$ROT" | sort -t$'\t' -k4,4rn | while IFS=$'\t' read -r r n a g t; do
      [ -n "$r" ] || continue
      printf '  %-16s #%-5s answered %s  %4sd  %s\n' "${r#*/}" "$n" "$a" "$g" "$t"
    done
  fi
fi

if [ "$ERRORS" -gt 0 ]; then
  echo "decision-rot.sh: $ERRORS repo(s) unreadable -- the count above is NOT trustworthy" >&2
  exit 6
fi
[ "$TOTAL_ROT" -gt 0 ] && exit 1
exit 0
