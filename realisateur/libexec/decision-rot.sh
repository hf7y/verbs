#!/usr/bin/env bash
# decision-rot.sh -- how many of Zach's answers is nobody acting on?
#
# RUNNER: no -- a SURVEY, not a guard: run in a triage pass, or ahead of an /ideate or /nightly-batch
# GUARD-TEST: bin/tests/decision-rot.test.sh -- 36 cases, offline behind a fake `gh`
# GATE: none -- reads live issue trackers across 18 repos
#
# THE PREDICATE: ANSWERED **AND** STILL OPEN -- direction handed over and never
# taken up. Zach answers by COMMENTING and leaves the issue open; the nightly
# CLOSES what it handles. ANSWERED lives in bin/lib/answered.sh (`etiquette`
# reads it too).
#
# TRAP: if a change here needs a convention INVENTED to work, THE AUDIT IS
#   WRONG -- report that and stop. An earlier draft keyed rot to "no commit
#   references the issue"; it worked, and would have gone stale SILENTLY the
#   day commit messages changed shape. The predicate above fails LOUDLY.
#
# TRAP: ANSWERED is hf7y/chezz's predicate, reused as a CONVENTION and NOT
#   imported -- that dependency would run the wrong direction across repos.
#   It is NOT the `answered` label; nothing applies it.
#
# KNOWN GAP: an unstamped agent comment is indistinguishable from Zach's; that
#   fix belongs in bin/gh-sign.sh. The stamp's second cost -- a stamped RELAY
#   of a spoken answer reading as not-an-answer -- is fixed by `relayed` below.
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
# not abort under `set -uo pipefail`: it prints to stderr and execution
# continues with ROSTER unset, so the walk below iterates zero repositories and
# this script prints `TOTAL 0 0` and exits 0 -- which `ausculte` renders as
# "rot OK -- no answered-and-abandoned issues". Found live on monkey
# 2026-08-22: /usr/local/libexec/selfdev/ lacked lib/roster-set.sh and the
# health verb had been reporting a clean estate over 48 rotting decisions.
# roster-set.sh sets ROSTER_SET_LIB as a load sentinel; nothing read it.
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

# THE PREDICATE, in one jq program, so bin/tests/decision-rot.test.sh can pin
# it against fixtures with no network. stdin is a `gh issue list --json
# number,title,state,labels,comments` array.
DECISION_ROT_JQ='
  # stamped: TRUE iff the body`s LAST NON-BLANK LINE opens with `<!-- agent:`.
  def stamped:
    (. // "") | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))
    | if length == 0 then false else (.[-1] | test("^<!--\\s*agent:")) end;
  # relayed: `<!-- decision-by: zach ... -->`; spoken calls die otherwise.
  def relayed: (. // "") | test("<!--\\s*decision-by:");
  # The LATEST owner comment unstamped or relaying. An older answer that was
  # taken up does not excuse a newer one that was not.
  def answer:
    [ .comments[]? | select((.author.login // "") == $o)
      | select(((.body | stamped) | not) or (.body | relayed)) ]
    | if length == 0 then null else (sort_by(.createdAt) | .[-1]) end;
  # The `answered` label is an override, never the trigger; it needs a clock.
  def labelled_answer:
    if ((.labels // []) | any(.name == "answered"))
    then ([ .comments[]? | select((.author.login // "") == $o) ]
          | if length == 0 then null else (sort_by(.createdAt) | .[-1]) end)
    else null end;
  def answered: (answer // labelled_answer);
'

rot_scan() {
  jq -r --arg o "$1" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DECISION_ROT_JQ"'
    .[]
    | . as $i
    | answered as $a
    | select($a != null)
    | select($i.state == "OPEN")            # <-- ROT: answered, and still open
    | [ $i.number,
        ($a.createdAt | split("T")[0]),
        ((($now | fromdateiso8601) - ($a.createdAt | fromdateiso8601)) / 86400 | floor),
        ($i.title | gsub("\\s+"; " "))
      ] | @tsv'
}

answered_count() {
  jq -r --arg o "$1" "$DECISION_ROT_JQ"'
    [ .[] | select(answered != null) ] | length'
}

ERRORS=0
TOTAL_ANSWERED=0
TOTAL_ROT=0
ROWS=''   # repo<TAB>answered<TAB>rot<TAB>oldest_days
ROT=''    # repo<TAB>number<TAB>answered_at<TAB>age_days<TAB>title

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

  n_answered=$(printf '%s' "$issues" | answered_count "$OWNER")
  rows=$(printf '%s' "$issues" | rot_scan "$OWNER")
  n_rot=$(printf '%s\n' "$rows" | grep -c .)
  oldest=$(printf '%s\n' "$rows" | grep . | cut -f3 | sort -rn | head -n1)

  TOTAL_ANSWERED=$((TOTAL_ANSWERED + n_answered))
  TOTAL_ROT=$((TOTAL_ROT + n_rot))
  ROWS+="${repo#*/}"$'\t'"$n_answered"$'\t'"$n_rot"$'\t'"${oldest:-0}"$'\n'
  while IFS= read -r line; do
    [ -n "$line" ] && ROT+="$repo"$'\t'"$line"$'\n'
  done <<< "$rows"
done

if [ "$JSON" = 1 ]; then
  printf '%s' "$ROT" | while IFS=$'\t' read -r r n a g t; do
    [ -n "$r" ] || continue
    jq -cn --arg repo "$r" --argjson number "$n" --arg answered_at "$a" \
           --argjson age_days "$g" --arg title "$t" \
           '{kind:"rotting",repo:$repo,number:$number,answered_at:$answered_at,age_days:$age_days,title:$title}'
  done
  jq -cn --argjson repos "${#REPOS[@]}" --argjson answered "$TOTAL_ANSWERED" \
         --argjson rotting "$TOTAL_ROT" --argjson errors "$ERRORS" \
         '{kind:"summary",repos:$repos,answered:$answered,rotting:$rotting,errors:$errors}'
else
  printf '%-18s %9s %8s %12s\n' REPO ANSWERED ROTTING OLDEST_DAYS
  printf '%s' "$ROWS" | while IFS=$'\t' read -r r a n o; do
    [ -n "$r" ] || continue
    printf '%-18s %9s %8s %12s\n' "$r" "$a" "$n" "$o"
  done
  printf '%-18s %9s %8s\n' TOTAL "$TOTAL_ANSWERED" "$TOTAL_ROT"
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
