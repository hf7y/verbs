#!/usr/bin/env bash
# lib/answered.sh -- the feeder for bin/lib/answered.jq, where the predicate
# lives and only lives. Two entry points, one gh call each: a bulk-fed
# issue_answered_json() for a caller already holding many issues (#573), and
# issue_answered() for a caller with just one number.
ANSWERED_STAMP_ERA="${ANSWERED_STAMP_ERA:-2026-08-14}"
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/estate-set.sh"
ANSWERED_OWNER="${ANSWERED_OWNER:-$GH_ESTATE_OWNER}"
ANSWERED_JQ_FILE="${ANSWERED_JQ_FILE:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/answered.jq}"

# Set by issue_answered()/issue_answered_json() so a caller can SAY why --
# throwing away the reason the predicate already computed would rebuild it.
ANSWERED_WHY=''
ANSWERED_AT=''
ANSWERED_BY=''   # the ANSWERED-BY target this issue's body names, or empty

# issue_answered_json <one issue's {number,labels,comments[,body]}> -- no gh call.
#   0  answered      a human answered, or `answered` says one did elsewhere
#   1  unanswered    nothing here that could be a human's
#   2  uncounted     something could be, and cannot be counted -- NOT a silence
#   6  BLIND         could not look. Never folded into any of the above.
issue_answered_json() {
  local issue_json="$1" out
  ANSWERED_WHY=''; ANSWERED_AT=''; ANSWERED_BY=''
  [ -r "$ANSWERED_JQ_FILE" ] || {
    ANSWERED_WHY="BLIND -- the predicate is not readable at $ANSWERED_JQ_FILE"
    return 6
  }
  out="$(printf '[%s]' "$issue_json" | jq -r --arg owner "$ANSWERED_OWNER" --arg era "$ANSWERED_STAMP_ERA" \
         "$(cat "$ANSWERED_JQ_FILE")"'.[] | verdict | "\(.verdict)\t\(.at // "")\t\(.answered_by // "")\t\(.why)"' 2>/dev/null)" || {
    ANSWERED_WHY='BLIND -- the predicate could not read that issue'
    return 6
  }
  ANSWERED_AT="$(printf '%s' "$out" | cut -f2)"
  ANSWERED_BY="$(printf '%s' "$out" | cut -f3)"
  ANSWERED_WHY="$(printf '%s' "$out" | cut -f4-)"
  case "$(printf '%s' "$out" | cut -f1)" in
    answered)   return 0 ;;
    unanswered) return 1 ;;
    uncounted)  return 2 ;;
    # A verdict this does not recognise is a misread, and a misread must never
    # clear a label.
    *) ANSWERED_WHY='BLIND -- the predicate returned no verdict'; return 6 ;;
  esac
}

# issue_answered <owner/repo> <number> -- fetches (`issue view`, labels the
# REST comment list lacks), then follows ANSWERED-BY (#568) ONE HOP via
# issue_answered_json -- never issue_answered, so A->B->A cannot hang it.
issue_answered() {
  local repo="$1" num="$2" json rc target t_repo t_num t_json t_rc t_why
  ANSWERED_WHY=''; ANSWERED_AT=''; ANSWERED_BY=''
  [ -r "$ANSWERED_JQ_FILE" ] || {
    ANSWERED_WHY="BLIND -- the predicate is not readable at $ANSWERED_JQ_FILE"
    return 6
  }
  json="$(gh issue view "$num" --repo "$repo" --json number,labels,comments,body 2>/dev/null)" || {
    ANSWERED_WHY="BLIND -- could not read $repo#$num"
    return 6
  }
  issue_answered_json "$json"; rc=$?
  target="$ANSWERED_BY"

  if [ "$rc" -ne 0 ] && [ -n "$target" ]; then
    t_repo="${target%#*}"
    t_num="${target##*#}"
    if t_json="$(gh issue view "$t_num" --repo "$t_repo" --json number,labels,comments,body 2>/dev/null)"; then
      issue_answered_json "$t_json"; t_rc=$?
      if [ "$t_rc" -eq 0 ]; then
        t_why="$ANSWERED_WHY"
        ANSWERED_WHY="ANSWERED-BY $target, itself answered -- $t_why"
        ANSWERED_BY="$target"
        return 0
      fi
    fi
    issue_answered_json "$json"; rc=$?  # unconfirmed hop: restore this issue's own verdict
  fi
  return "$rc"
}
