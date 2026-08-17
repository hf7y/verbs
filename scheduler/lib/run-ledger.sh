#!/usr/bin/env bash
# run-ledger.sh -- one append-only line per dispatch. Never consumed, never
# rewritten.
#
# WHY IT HAS TO EXIST BEFORE ANY BRAKE. bin/verdict.sh CONSUMES the verdict at
# dispatch (`verdict.sh clear`, usage-paced-runner.sh:604), so no verdict
# outlives its own run. That makes "the same blocker twice" not merely
# unimplemented but STRUCTURALLY UNOBSERVABLE -- you cannot detect repetition
# when each observation is deleted before the next arrives. hf7y/scheduler#54:
# "the missing piece is not another sensor. It is an append-only ledger."
#
# WHAT IT IS FOR. On 2026-08-06 DONE was recorded nine times across four
# accounts in one day and never once stopped a dispatch; bibliothecaire
# recorded DONE on six consecutive runs and was re-dispatched every time. Every
# project's brief tells the agent DONE means "the bar in my brief is met; stop
# dispatching". That was false, which is worse than not asking -- the agents
# spend turns producing a signal the system discards.
#
# APPEND-ONLY IS THE WHOLE CONTRACT. There is no update, no delete, no rotate.
# A single printf of one line under PIPE_BUF (4096 on Linux) is atomic, so
# concurrent dispatchers cannot interleave a row. Size is bounded by reality
# rather than by policy: at 60 dispatches/day a year is ~22k lines.
#
# Sourced, never executed. No top-level statement runs anything -- the same
# rule bin/lib/dose-common.sh learned the hard way when it exited its callers.
set -uo pipefail

# Follows the dispatcher: $HOME-scoped per account today, /var/lib under host
# mode, so the ledger lives wherever the decision is made rather than in a
# third place that has to be kept in sync.
# RESOLVED PER CALL, not at source time. It was a top-level assignment, so a
# caller that exported RUN_LEDGER_FILE *after* sourcing got the default
# silently -- and a witness doing exactly that wrote 23 fabricated rows into
# mandark's real ledger before anyone noticed. A test that believes it is
# hermetic and is not is worse than one that admits it needs the estate.
#
# Resolving per call also makes the host-mode switch work: STATE_DIR changes
# between account and host dispatch, and a value frozen at source time would
# keep pointing at whichever came first.
_ledger_file() {
  printf '%s' "${RUN_LEDGER_FILE:-${STATE_DIR:-$HOME/.local/share/scheduler-paced-runner}/ledger.tsv}"
}

# ledger_append <project> <tier> <rc> <outcome> <reason>
# Row: iso8601 <TAB> host <TAB> account <TAB> project <TAB> tier <TAB> rc <TAB> outcome <TAB> reason
ledger_append() {
  local proj="${1:-?}" tier="${2:-?}" rc="${3:-?}" outcome="${4:-}" reason="${5:-}"
  local f; f="$(_ledger_file)"
  local dir; dir="$(dirname "$f")"
  mkdir -p "$dir" 2>/dev/null || return 1
  # ONE ROW IS ONE LINE, always. A reason carrying a tab or newline would
  # silently split a row in two and every later reader would mis-parse the
  # file from that point on -- the kind of corruption that is invisible until
  # something counts wrong.
  outcome="$(printf '%s' "$outcome" | tr -d '\t\n' | cut -c1-32)"
  reason="$(printf '%s' "$reason" | tr '\t\n' '  ' | cut -c1-200)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Is)" "$(hostname -s 2>/dev/null || echo '?')" "$(id -un)" \
    "$proj" "$tier" "$rc" "${outcome:-NONE}" "$reason" >> "$f"
}

# ledger_streak <project> <outcome> -- how many of the MOST RECENT consecutive
# rows for <project> carry <outcome>. 0 if the last row is something else, or
# if the project has no rows at all.
#
# ABSENCE READS AS ZERO, DELIBERATELY. No history means no evidence of
# repetition, and the safe direction is to keep dispatching -- the same
# polarity as bin/verdict.sh, where absence of a verdict is never GAVE-UP.
ledger_streak() {
  local proj="${1:?}" want="${2:?}" n=0 line
  local f; f="$(_ledger_file)"
  [ -r "$f" ] || { printf '0'; return 0; }
  while IFS=$'\t' read -r _ts _host _acct p _tier _rc outcome _reason; do
    [ "$p" = "$proj" ] || continue
    if [ "$outcome" = "$want" ]; then n=$((n+1)); else n=0; fi
  done < "$f"
  printf '%s' "$n"
}

# ledger_age_min <project> [skip-outcome ...] -- WALL-CLOCK minutes since the
# most recent row for <project> whose outcome is none of the skips. 999999 when
# there is no such row.
#
# EVERY OTHER READER HERE COUNTS ROWS; THIS ONE COUNTS MINUTES, and the two are
# not interchangeable. A row-counting brake (ledger_since) measures dispatch
# OPPORTUNITIES, so it only advances when the dispatcher ticks and it must
# record its own skips to elapse at all. A pace regulator has to elapse on the
# wall clock instead: its whole job is to decide how many of those ticks become
# dispatches, so a clock that only moves when it says yes would never say yes
# a second time.
#
# THE SKIP LIST IS WHY THIS IS NOT ONE LINE OF awk AT THE CALL SITE. Holds
# write rows (COOLDOWN, BLOCKED-HOLD), so "the last row" is routinely a hold
# rather than a dispatch, and a regulator reading it would see a project held
# by a NEIGHBOURING brake as freshly dispatched -- permanently, since each hold
# refreshes the timestamp it is reading.
#
# ABSENCE IS 999999, matching ledger_since: no history is no evidence to hold
# back on, and the safe direction is to let the caller run.
ledger_age_min() {
  local proj="${1:?}"; shift
  local skips=" $* "
  local f; f="$(_ledger_file)"
  [ -r "$f" ] || { printf '999999'; return 0; }
  local ts="" line_ts line_p line_o
  while IFS=$'\t' read -r line_ts _h _a line_p _t _rc line_o _r; do
    [ "$line_p" = "$proj" ] || continue
    [ -n "$line_o" ] && [ "$skips" != "  " ] && case "$skips" in *" $line_o "*) continue ;; esac
    ts="$line_ts"
  done < "$f"
  [ -n "$ts" ] || { printf '999999'; return 0; }
  local epoch now
  epoch="$(date -d "$ts" +%s 2>/dev/null)" || { printf '999999'; return 0; }
  [ -n "$epoch" ] || { printf '999999'; return 0; }
  now="$(date +%s)"
  # A row stamped in the future is a clock that moved, not a dispatch that has
  # not happened yet. Clamp at 0 so it reads as "just ran" -- the cautious
  # direction for a regulator that would otherwise wave everything through.
  if [ "$epoch" -gt "$now" ]; then printf '0'; else printf '%s' $(( (now - epoch) / 60 )); fi
}

# ledger_last <project> -- the most recent outcome for <project>, or empty.
ledger_last() {
  local proj="${1:?}"
  local f; f="$(_ledger_file)"
  [ -r "$f" ] || return 0
  awk -F'\t' -v p="$proj" '$4==p {o=$7} END{if(o!="") print o}' "$f"
}

# ledger_since <project> <outcome> -- how many rows for <project> have been
# appended SINCE its most recent <outcome> row. Empty/absent history prints a
# number large enough to mean "no reason to hold back" rather than 0, because
# 0 here would read as "the outcome just happened".
#
# THIS IS WHAT MAKES A COOLDOWN ELAPSE. A streak count cannot: skipping a
# dispatch appends nothing, so a streak-based hold would never see its own
# condition change and would stop the project permanently. Counting rows since
# the event only works if the SKIP is itself recorded -- which is why the
# cooldown writes a COOLDOWN row every time it holds.
ledger_since() {
  local proj="${1:?}" want="${2:?}"
  local f; f="$(_ledger_file)"
  [ -r "$f" ] || { printf '999999'; return 0; }
  awk -F'\t' -v p="$proj" -v w="$want" '
    $4==p { if ($7==w) n=0; else if (n!="") n++ }
    END { if (n=="") print 999999; else print n }' "$f"
}

# ledger_run <project> <outcome> [skip-outcome] -- consecutive <outcome> rows at
# the end for <project>, IGNORING rows whose outcome matches <skip-outcome>.
#
# WHY THE SKIP ARGUMENT EXISTS. A hold writes its own row (it must, or the
# cooldown never elapses -- see ledger_since). Those rows sit between the real
# verdicts, so a plain consecutive count sees BLOCKED, HOLD, BLOCKED as a run
# of one. Backoff needs to know it is the THIRD blockage, not the first.
ledger_run() {
  local proj="${1:?}" want="${2:?}" skip="${3:-}" n=0 o
  local f; f="$(_ledger_file)"
  [ -r "$f" ] || { printf '0'; return 0; }
  while IFS=$'\t' read -r _ts _h _a p _t _rc o _r; do
    [ "$p" = "$proj" ] || continue
    [ -n "$skip" ] && [ "$o" = "$skip" ] && continue
    if [ "$o" = "$want" ]; then n=$((n+1)); else n=0; fi
  done < "$f"
  printf '%s' "$n"
}

# ledger_reason <project> <outcome> [nth-from-last] -- the reason recorded with
# the most recent (or nth-most-recent) row of that outcome. This is what makes
# "the same blocker twice" observable: compare this run's reason against the
# last one. Before the ledger existed the previous reason had already been
# deleted by `verdict.sh clear` at dispatch.
ledger_reason() {
  local proj="${1:?}" want="${2:?}" nth="${3:-1}"
  local f; f="$(_ledger_file)"
  [ -r "$f" ] || return 0
  awk -F'\t' -v p="$proj" -v w="$want" -v n="$nth" '
    $4==p && $7==w { buf[++c]=$8 }
    END { if (c>=n) print buf[c-n+1] }' "$f"
}
