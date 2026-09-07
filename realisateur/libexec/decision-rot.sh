#!/usr/bin/env bash
# decision-rot.sh -- how many of Zach's answers is nobody acting on?
#
# RUNNER: no -- a SURVEY: run in a triage pass, or ahead of /ideate.
# GUARD-TEST: bin/tests/decision-rot.test.sh, offline behind a fake `gh`
# GATE: none -- reads every roster repo's live issue tracker
# ROT: ANSWERED **AND** STILL OPEN **AND** SOMETHING IS ARMED TO ACT. Zach answers
# by COMMENTING and leaves it open; the nightly CLOSES what it handles. The
# predicate is bin/lib/answered.jq, shared with `etiquette`.
# TRAP: if a change here needs a convention INVENTED to work, THE AUDIT IS
#   WRONG -- report and stop. A draft keyed to "no commit references the
#   issue" worked, and would have gone stale SILENTLY.
#
set -uo pipefail

CLI_NAME='decision-rot.sh'
CLI_SUMMARY='is an answered issue still sitting open?'
CLI_USAGE='  decision-rot.sh --all              audit every ecosystem1 repo
  decision-rot.sh <owner>/<repo>    audit one repo
  decision-rot.sh --all --json      machine-readable NDJSON + summary line'
CLI_FLAGS='--all --json'
CLI_POSITIONAL=any
CLI_EXITS='  0  clean -- every answered issue in a repo that dispatches is closed
  1  rot found -- at least one answered issue is still open
  6  BLIND -- a repo or the arming roster could not be read; the count is NOT trustworthy'
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
cli_guard "$@"

# DECISION_ROT_OWNER: for the suite, whose fixture logins are not this estate's.
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/estate-set.sh"
OWNER="${DECISION_ROT_OWNER:-$GH_ESTATE_OWNER}"

# shellcheck source=bin/lib/roster-set.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/roster-set.sh"

# A MISSING SWEEP SET IS BLIND, NOT AN EMPTY ESTATE. `.` on an absent file does
# not abort under `set -uo pipefail`, so the walk iterates zero repos and exits
# 0 -- live 2026-08-22 over 48 rotting decisions. SWEEP_SET_LIB is the sentinel.
if [ "${SWEEP_SET_LIB:-}" != 1 ] || [ "${#SWEEP[@]}" -eq 0 ]; then
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
  for p in "${SWEEP[@]}"; do REPOS+=("$OWNER/$p"); done
fi

command -v gh >/dev/null || { echo "decision-rot.sh: gh not on PATH" >&2; exit 6; }
command -v jq >/dev/null || { echo "decision-rot.sh: jq not on PATH" >&2; exit 6; }

# THE PREDICATE IS NOT HERE: bin/lib/answered.jq, fed the bulk array below. A
# jq PROGRAM, so this stays ONE call per repo rather than one per issue.
#
# shellcheck source=bin/lib/answered.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/answered.sh"
[ -r "$ANSWERED_JQ_FILE" ] || {
  printf '%s: BLIND -- the predicate is not readable at %s. A count of zero here would be the absence of a reading, not the absence of rot.\n' \
    "$CLI_NAME" "$ANSWERED_JQ_FILE" >&2
  exit 6
}
DECISION_ROT_JQ="$(cat "$ANSWERED_JQ_FILE")"

# shellcheck source=bin/lib/arming.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/arming.sh"
if ! arming_load; then
  printf '%s: BLIND -- could not read %s:%s, so no repo can be told from a parked one. Classifying none of them.\n' \
    "$CLI_NAME" "$ARMING_ROSTER_REPO" "$ARMING_ROSTER_PATH" >&2
  exit 6
fi

# Warned, not counted: the exit code answers "is there rot in what I read".
if [ "$MODE" = all ]; then
  UNSWEPT="$(sweep_unswept "$ARMING_ROSTER")"
  [ -n "$UNSWEPT" ] && printf '%s: %s live in %s:%s and NOT in SWEEP, so this survey did not read %s: %s. Add to SWEEP_PROJECTS in lib/roster-set.sh.\n' \
    "$CLI_NAME" "$(printf '%s\n' "$UNSWEPT" | grep -c .)" \
    "$ARMING_ROSTER_REPO" "$ARMING_ROSTER_PATH" \
    "$([ "$(printf '%s\n' "$UNSWEPT" | grep -c .)" = 1 ] && echo it || echo them)" \
    "$(printf '%s\n' "$UNSWEPT" | paste -sd' ')" >&2
fi

# `number<TAB>verdict<TAB>at<TAB>state<TAB>title`. DETAIL is OPEN ONLY; COUNT
# stays all-states, matching `answered` (B2).
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
TOTAL_NOT_MINE=0
ROWS=''   # repo<TAB>answered<TAB>rot<TAB>not_mine<TAB>oldest_days<TAB>uncounted
ROT=''    # repo<TAB>number<TAB>answered_at<TAB>age_days<TAB>title
NOTMINE='' # repo<TAB>count<TAB>arming
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

  # THE SPLIT: only "is anything armed here?" separates a finding from a fact
  # about somebody else's repo. ROTTING stays field 3; ausculte parses it so.
  arming="$(arming_state "${repo#*/}")"
  n_not_mine=0
  case "$arming" in
    live) ;;
    *) n_not_mine=$n_rot; n_rot=0; rows=''; oldest=''
       [ "$n_not_mine" -gt 0 ] && \
         NOTMINE+="${repo#*/}"$'\t'"$n_not_mine"$'\t'"$arming"$'\n' ;;
  esac

  TOTAL_ANSWERED=$((TOTAL_ANSWERED + n_answered))
  TOTAL_ROT=$((TOTAL_ROT + n_rot))
  TOTAL_NOT_MINE=$((TOTAL_NOT_MINE + n_not_mine))
  TOTAL_UNCOUNTED=$((TOTAL_UNCOUNTED + n_uncounted))
  TOTAL_UNC_OPEN=$((TOTAL_UNC_OPEN + n_unc_open))
  ROWS+="${repo#*/}"$'\t'"$n_answered"$'\t'"$n_rot"$'\t'"$n_not_mine"$'\t'"${oldest:-0}"$'\t'"$n_unc_open"$'\n'
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
  printf '%s' "$NOTMINE" | while IFS=$'\t' read -r r c a; do
    [ -n "$r" ] || continue
    jq -cn --arg repo "$r" --argjson count "$c" --arg arming "$a" \
           '{kind:"not-mine",repo:$repo,count:$count,arming:$arming}'
  done
  jq -cn --argjson repos "${#REPOS[@]}" --argjson answered "$TOTAL_ANSWERED" \
         --argjson rotting "$TOTAL_ROT" --argjson not_mine "$TOTAL_NOT_MINE" \
         --argjson uncounted "$TOTAL_UNCOUNTED" \
         --argjson uncounted_open "$TOTAL_UNC_OPEN" --argjson errors "$ERRORS" \
         '{kind:"summary",repos:$repos,answered:$answered,rotting:$rotting,not_mine:$not_mine,uncounted:$uncounted,uncounted_open:$uncounted_open,errors:$errors}'
else
  printf '%-18s %9s %8s %9s %12s %10s\n' REPO ANSWERED ROTTING NOT_MINE OLDEST_DAYS UNC_OPEN
  printf '%s' "$ROWS" | while IFS=$'\t' read -r r a n m o u; do
    [ -n "$r" ] || continue
    printf '%-18s %9s %8s %9s %12s %10s\n' "$r" "$a" "$n" "$m" "$o" "$u"
  done
  printf '%-18s %9s %8s %9s %12s %10s\n' TOTAL "$TOTAL_ANSWERED" "$TOTAL_ROT" "$TOTAL_NOT_MINE" '' "$TOTAL_UNC_OPEN"
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
  if [ "$TOTAL_NOT_MINE" -gt 0 ]; then
    echo
    echo "NOT-MINE -- $TOTAL_NOT_MINE answered-and-open in repos nothing dispatches to."
    echo 'Not rot: no account is armed to act, so no run could ever close them.'
    printf '%s' "$NOTMINE" | sort -t$'\t' -k2,2rn | while IFS=$'\t' read -r r c a; do
      [ -n "$r" ] || continue
      printf '  %-16s %3s  (%s)\n' "$r" "$c" "$a"
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
