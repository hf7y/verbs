#!/usr/bin/env bash
# lib/answered.sh -- the ONE-ISSUE feeder for bin/lib/answered.jq, where the
# predicate lives and only lives. jq, not bash: decision-rot reads every repo
# with ONE bulk call each and would otherwise spend one per issue.
ANSWERED_STAMP_ERA="${ANSWERED_STAMP_ERA:-2026-08-14}"
ANSWERED_OWNER="${ANSWERED_OWNER:-hf7y}"
ANSWERED_JQ_FILE="${ANSWERED_JQ_FILE:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/answered.jq}"

# Set by issue_answered() so a caller can SAY why -- throwing
# away the reason the predicate already computed would rebuild it.
ANSWERED_WHY=''
ANSWERED_AT=''

# issue_answered <owner/repo> <number>
#   0  answered      a human answered, or `answered` says one did elsewhere
#   1  unanswered    nothing here that could be a human's
#   2  uncounted     something could be, and cannot be counted -- NOT a silence
#   6  BLIND         could not look. Never folded into any of the above.
issue_answered() {
  local repo="$1" num="$2" json out
  ANSWERED_WHY=''; ANSWERED_AT=''
  [ -r "$ANSWERED_JQ_FILE" ] || {
    ANSWERED_WHY="BLIND -- the predicate is not readable at $ANSWERED_JQ_FILE"
    return 6
  }
  # `issue view`, not `api .../comments`: the REST comment list carries no
  # labels, and without labels the `answered` override cannot be seen here --
  # which is the half of the mechanism that closes hf7y/realisateur#568.
  json="$(gh issue view "$num" --repo "$repo" --json number,labels,comments 2>/dev/null)" || {
    ANSWERED_WHY="BLIND -- could not read $repo#$num"
    return 6
  }
  out="$(printf '[%s]' "$json" | jq -r --arg owner "$ANSWERED_OWNER" --arg era "$ANSWERED_STAMP_ERA" \
         "$(cat "$ANSWERED_JQ_FILE")"'.[] | verdict | "\(.verdict)\t\(.at // "")\t\(.why)"' 2>/dev/null)" || {
    ANSWERED_WHY='BLIND -- the predicate could not read that issue'
    return 6
  }
  ANSWERED_AT="$(printf '%s' "$out" | cut -f2)"
  ANSWERED_WHY="$(printf '%s' "$out" | cut -f3-)"
  case "$(printf '%s' "$out" | cut -f1)" in
    answered)   return 0 ;;
    unanswered) return 1 ;;
    uncounted)  return 2 ;;
    # A verdict this does not recognise is a misread, and a misread must never
    # clear a label.
    *) ANSWERED_WHY='BLIND -- the predicate returned no verdict'; return 6 ;;
  esac
}
