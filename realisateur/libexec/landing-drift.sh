#!/usr/bin/env bash
# landing-drift.sh -- is there a repo whose green work has nowhere to land?
# RUNNER: bin/ausculte.sh -- the `landing` probe
# GUARD-TEST: bin/tests/landing-drift.test.sh -- offline, behind a fake `gh`
# GATE: default --all
# A PILE IS THE FINDING; flagging the route would red every repo forever.
set -uo pipefail

CLI_NAME='landing-drift.sh'
CLI_SUMMARY='green pull requests with no route to land'
CLI_USAGE='  landing-drift.sh --all             every repo this estate sweeps
  landing-drift.sh <owner>/<repo>   just one
  landing-drift.sh --all --json     one JSON object per repo'
CLI_FLAGS='--all --json'
CLI_POSITIONAL=any
CLI_EXITS='  0  no pile anywhere, and every default branch is named main
  1  drift found -- a pile, or a default branch that is not main
  6  BLIND -- a repo could not be read; a count of zero is not a reading'
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
cli_guard "$@"

. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/estate-set.sh"
OWNER="${LANDING_DRIFT_OWNER:-$GH_ESTATE_OWNER}"

. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/roster-set.sh"
if [ "${SWEEP_SET_LIB:-}" != 1 ] || [ "${#SWEEP[@]}" -eq 0 ]; then
  printf '%s: BLIND -- lib/roster-set.sh did not load, so this read NO repositories.\n' "$CLI_NAME" >&2
  exit 6
fi

STALE_H="${LANDING_DRIFT_STALE_H:-24}"   # a pile is old, not merely open
MODE=''
REPOS=()
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all) MODE=all; shift ;;
    --json) JSON=1; shift ;;
    */*) MODE=one; REPOS+=("$1"); shift ;;
    *) echo "$CLI_NAME: not an <owner>/<repo>: $1" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { echo "$CLI_NAME: pass --all or an <owner>/<repo>" >&2; exit 2; }
[ "$MODE" = all ] && for p in "${SWEEP[@]}"; do REPOS+=("$OWNER/$p"); done

command -v gh >/dev/null || { echo "$CLI_NAME: BLIND -- gh not on PATH" >&2; exit 6; }
command -v jq >/dev/null || { echo "$CLI_NAME: BLIND -- jq not on PATH" >&2; exit 6; }

NOW="$(date -u +%s)"
ERRORS=0
FINDINGS=0
ROWS=''

for r in "${REPOS[@]}"; do
  settings="$(gh api "repos/$r" --jq '[.default_branch, (.allow_auto_merge|tostring), (.private|tostring)] | @tsv' 2>/dev/null)" || settings=''
  if [ -z "$settings" ]; then
    printf '%s: BLIND -- could not read repos/%s\n' "$CLI_NAME" "$r" >&2
    ERRORS=$((ERRORS + 1)); continue
  fi
  IFS=$'\t' read -r branch automerge private <<<"$settings"

  prs="$(gh pr list --repo "$r" --state open --limit 200 \
           --json isDraft,mergeStateStatus,createdAt 2>/dev/null)" || prs=''
  if [ -z "$prs" ]; then
    printf '%s: BLIND -- could not list pull requests for %s\n' "$CLI_NAME" "$r" >&2
    ERRORS=$((ERRORS + 1)); continue
  fi
  # UNKNOWN IS NOT CLEAN: recomputed lazily, it read 16 stuck PRs as none.
  read -r stranded oldest unknown <<<"$(printf '%s' "$prs" | jq -r --argjson now "$NOW" --argjson h "$STALE_H" '
    [.[] | select(.isDraft == false)] as $open
    | [$open[] | select(.mergeStateStatus == "CLEAN") | (($now - (.createdAt | fromdateiso8601)) / 3600) | select(. >= $h)] as $old
    | [($old | length), (($old | max // 0) / 24 | floor),
       ([$open[] | select(.mergeStateStatus == "UNKNOWN")] | length)] | @tsv')"
  if [ "${unknown:-0}" -gt 0 ]; then
    printf '%s: BLIND -- %s open pull request(s) in %s report mergeStateStatus UNKNOWN; a pile there would not be visible.\n' \
      "$CLI_NAME" "$unknown" "$r" >&2
    ERRORS=$((ERRORS + 1))
  fi

  route=agent
  gh api "repos/$r/contents/.github/workflows/automerge.yml" --jq .sha >/dev/null 2>&1 && route=workflow

  flags=''
  [ "$stranded" -gt 0 ] && flags="stranded"
  [ "$branch" != main ] && flags="${flags:+$flags,}branch"
  [ -n "$flags" ] && FINDINGS=$((FINDINGS + 1))
  ROWS="$ROWS$r	$stranded	$oldest	$route	$automerge	$private	$branch	${flags:--}
"
done

if [ "$JSON" = 1 ]; then
  printf '%s' "$ROWS" | while IFS=$'\t' read -r repo stranded oldest route automerge private branch flags; do
    [ -n "$repo" ] || continue
    jq -nc --arg repo "$repo" --argjson stranded "$stranded" --argjson oldest_days "$oldest" \
       --arg route "$route" --argjson allow_auto_merge "$automerge" --argjson private "$private" \
       --arg default_branch "$branch" --arg flags "$flags" \
       '{repo:$repo, stranded:$stranded, oldest_days:$oldest_days, route:$route,
         allow_auto_merge:$allow_auto_merge, private:$private, default_branch:$default_branch,
         flags:(if $flags == "-" then [] else ($flags | split(",")) end)}'
  done
else
  printf 'landing-drift -- %s, pull requests open past %sh\n\n' "$OWNER" "$STALE_H"
  printf '%-28s %8s %7s %-9s %s\n' REPO STRANDED OLDEST ROUTE FLAGS
  printf '%s' "$ROWS" | while IFS=$'\t' read -r repo stranded oldest route automerge private branch flags; do
    [ -n "$repo" ] || continue
    printf '%-28s %8s %6sd %-9s %s\n' "${repo#*/}" "$stranded" "$oldest" "$route" "$flags"
  done
  printf '\n%s finding(s) across %s repo(s)\n' "$FINDINGS" "${#REPOS[@]}"
fi

if [ "$ERRORS" -gt 0 ]; then
  printf '%s: BLIND -- %s repo(s) could not be read, so this count is not a reading.\n' "$CLI_NAME" "$ERRORS" >&2
  exit 6
fi
[ "$FINDINGS" -gt 0 ] && exit 1
exit 0
