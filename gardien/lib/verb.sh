#!/usr/bin/env bash
# verb.sh -- the shared runtime every bashified utility sources.
#
# One copy of the argument grammar, the cost boundary, and the failure
# vocabulary, so nineteen utilities cannot drift into nineteen dialects.
# Config is read here and nowhere else.
#
# THE COST BOUNDARY (the reason this file exists at all):
#   Nothing in a bashified utility may spend money implicitly. A utility
#   that CAN spend declares VERB_CAN_SUMMON=1 and gains --summon; one that
#   cannot does not carry the flag at all, so `--help` alone answers the
#   question "can this cost me anything?".
#
#   Short form is deliberately ABSENT. `-s` collides with existing tools
#   and `-S` differs from it by one shift key, which is an unacceptable
#   property for the only flag that spends real money. Typing the whole
#   word IS the deliberateness.

set -uo pipefail

VERB_NAME="${VERB_NAME:?verb.sh: VERB_NAME must be set before sourcing}"
VERB_SUMMARY="${VERB_SUMMARY:-}"
VERB_CAN_SUMMON="${VERB_CAN_SUMMON:-0}"

# The cost is READ FROM A MEASUREMENT, never typed in. A summon flag that
# prints "cost: unmeasured" asks the human to authorise an unknown amount,
# which is weaker than the argument this file makes at length about why
# -s/-S are rejected. If no measurement exists yet, say so in exactly those
# words and mark the next run as the measuring one -- that is honest, and
# it closes the gap by construction rather than by intention.
VERB_COST_FILE="${VERB_COST_FILE:-$HOME/.local/share/$VERB_NAME/summon-cost}"
if [ -s "$VERB_COST_FILE" ]; then
  VERB_SUMMON_COST="$(head -1 "$VERB_COST_FILE")"
else
  VERB_SUMMON_COST="UNMEASURED -- the next summon is the measuring run"
fi

# Record what a summon actually cost, so the NEXT caller sees a number.
verb_record_cost() {
  mkdir -p "$(dirname "$VERB_COST_FILE")"
  printf '%s\n' "$1" > "$VERB_COST_FILE"
}

VERB_SUMMON=0        # did the caller authorise spending?
VERB_JSON=0
VERB_QUIET=0

# ---------------------------------------------------------------- failing
# Exit codes are part of the contract. An exit-0 no-op is the failure this
# ecosystem records more than any other, so every one of these is loud.
#   0  the promise was kept
#   2  usage error (the caller is wrong)
#   3  this needs a summon and did not get one -- A FINDING, NOT AN ERROR
#   4  GAP: SHOULD DO -- in scope, not built yet. Summon is legitimate here.
#   5  the promise was broken (ran, produced a wrong or partial answer)
#   6  BLIND: cannot read the domain, so cannot report on it
#   7  REFUSED: WON'T DO -- out of scope on principle. No summon exists.
#
# On 4 vs 7 (added 2026-07-30 in gardien; PROPOSED ecosystem-wide, see
# realisateur QUESTIONS -- until it is decided there, this file is the only
# copy carrying it, and that divergence is deliberate and recorded):
#
#   Exit 4 is a TEMPORAL claim -- "not yet". It invites escalation: summon
#   an agent or do it by hand, then mechanize it so the next call is free.
#   GAPS.md is its sink and those entries are meant to DRAIN.
#
#   Exit 7 is a claim about SCOPE -- "never". Filing it as a gap would put a
#   permanent decision on a to-do list, and GAPS.md would stop being a list
#   that can drain, which destroys it as a signal.
#
#   The rule that keeps the two honest: --summon is available on 4 and
#   FORBIDDEN on 7. A gap names its own escalation; a refusal offers none,
#   because having no escalation path is what refusing on principle MEANS.
#   Without this, --summon degrades into a general-purpose "do it anyway"
#   flag -- the failure mode a spending flag wired to an agent invites most.
verb_die()   { printf '%s: %s\n' "$VERB_NAME" "$*" >&2; exit 2; }
verb_gap()   { printf '%s: GAP: %s\n' "$VERB_NAME" "$*" >&2
               printf '%s: in scope, not built yet; see GAPS.md\n' "$VERB_NAME" >&2
               exit 4; }
# verb_gap_or_summon <what-is-missing> <agent-prompt>
#
# THE LOOP THIS EXISTS FOR (Zach, 2026-07-30): "What it can do in bash, it
# does. What it can't? We invoke agents, do the task by hand, and mechanize
# it for next time." So an in-scope gap is not a dead end -- it is an
# escalation with a receipt. Without --summon it reports GAP (exit 4) and
# names its own escalation. With --summon an agent does the task by hand,
# and the request is appended to a mechanization queue so the NEXT build
# has a concrete list of what to wire up in bash.
#
# Exit 7 refusals never route here, deliberately. That is the whole
# difference between "not yet" and "never".
VERB_MECHANIZE="${VERB_MECHANIZE:-$HOME/.local/share/$VERB_NAME/mechanize.md}"
verb_gap_or_summon() {
  local what="$1" prompt="$2" started rc
  if [ "$VERB_CAN_SUMMON" = 1 ] && [ "$VERB_SUMMON" = 1 ]; then
    command -v claude >/dev/null 2>&1 \
      || verb_gap "$what (and --summon was given, but the 'claude' CLI is not on PATH)"
    mkdir -p "$(dirname "$VERB_MECHANIZE")"
    printf -- '- [ ] %s -- summoned %s\n' "$what" "$(date -Is)" >> "$VERB_MECHANIZE"
    started=$(date +%s)
    claude -p "$prompt"
    rc=$?
    verb_record_cost "~$(( $(date +%s) - started ))s of one claude -p call, measured $(date +%Y-%m-%d)"
    printf '%s: queued for mechanization in %s\n' "$VERB_NAME" "$VERB_MECHANIZE" >&2
    return "$rc"
  fi
  printf '%s: GAP: %s\n' "$VERB_NAME" "$what" >&2
  printf '%s: in scope, not built yet; see GAPS.md\n' "$VERB_NAME" >&2
  if [ "$VERB_CAN_SUMMON" = 1 ]; then
    printf '%s: an agent can do this by hand now: re-run with --summon\n' "$VERB_NAME" >&2
    printf '%s: cost: %s\n' "$VERB_NAME" "$VERB_SUMMON_COST" >&2
    printf '%s: it will also be queued for mechanization at the next build.\n' "$VERB_NAME" >&2
  fi
  exit 4
}

verb_refuse(){ printf '%s: REFUSED: %s\n' "$VERB_NAME" "$*" >&2
               printf '%s: out of scope by design, not unbuilt. No --summon exists\n' "$VERB_NAME" >&2
               printf '%s: for this; see the "will not" section of CONTRACT.md.\n' "$VERB_NAME" >&2
               exit 7; }
verb_broke() { printf '%s: BROKEN: %s\n' "$VERB_NAME" "$*" >&2; exit 5; }
verb_blind() { printf '%s: BLIND: %s\n' "$VERB_NAME" "$*" >&2
               printf '%s: this is "I cannot see", NOT "nothing to report".\n' "$VERB_NAME" >&2
               exit 6; }

# ------------------------------------------------------------ the summon
# Refuse rather than spend. Callers that want the money spent must say so.
verb_need_summon() {
  local what="$1"
  [ "$VERB_CAN_SUMMON" = 1 ] || verb_die "internal: verb_need_summon in a utility that declares no summon"
  if [ "$VERB_SUMMON" = 1 ]; then
    return 0
  fi
  printf '%s: this needs a summon: %s\n' "$VERB_NAME" "$what" >&2
  printf '%s: cost: %s\n' "$VERB_NAME" "$VERB_SUMMON_COST" >&2
  printf '%s: re-run with --summon to authorise spending real money.\n' "$VERB_NAME" >&2
  exit 3
}

# ------------------------------------------------------------ arg parsing
# Hand-rolled rather than getopts: getopts cannot express "--summon has no
# short form on purpose", and silently accepting a bundled cost flag is
# exactly the misparse that would spend money the caller never authorised.
verb_parse() {
  VERB_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --summon)
        [ "$VERB_CAN_SUMMON" = 1 ] || verb_die "--summon: this utility never spends; the flag does not exist here"
        VERB_SUMMON=1 ;;
      --summon=*) verb_die "--summon takes no value" ;;
      -s|-S|-\$|--sum|--summ|--summo)
        # Named explicitly so a near-miss FAILS rather than being ignored.
        verb_die "no short or abbreviated form of --summon exists. Spell it out; that is the point." ;;
      --json)    VERB_JSON=1 ;;
      --quiet|-q) VERB_QUIET=1 ;;
      -h|--help) verb_usage; exit 0 ;;
      --version) printf '%s (bashified)\n' "$VERB_NAME"; exit 0 ;;
      --) shift; VERB_ARGS+=("$@"); break ;;
      -*) verb_die "unknown flag: $1  (try --help)" ;;
      *)  VERB_ARGS+=("$1") ;;
    esac
    shift
  done
}

verb_usage() {
  printf '%s -- %s\n\n' "$VERB_NAME" "$VERB_SUMMARY"
  printf 'usage: %s\n\n' "${VERB_USAGE:-$VERB_NAME [flags]}"
  printf 'flags:\n'
  printf '  --json        machine-readable output\n'
  printf '  --quiet, -q   suppress commentary; results only\n'
  printf '  -h, --help    this text\n'
  printf '  --version     print version\n'
  if [ "$VERB_CAN_SUMMON" = 1 ]; then
    printf '  --summon      AUTHORISE SPENDING REAL MONEY (cost: %s)\n' "$VERB_SUMMON_COST"
    printf '                No short form exists, deliberately.\n'
  else
    printf '\nThis utility cannot spend money. It has no --summon flag.\n'
  fi
  printf '\nexit: 0 kept  2 usage  3 needs-summon  4 gap(should-do)  5 broken\n'
  printf '      6 blind  7 refused(wont-do)\n'
  printf 'see: man %s\n' "$VERB_NAME"
}
