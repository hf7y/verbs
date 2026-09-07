#!/usr/bin/env bash
# deadman-switch.sh -- THE dead-man switch. One implementation, sourced.
#
# RETIRES: the hand-pasted copy in svc-vaporwave's
# aedile-nightly-batch-loop.sh, and the inline block that used to live in
# lib/sweep-loop-common.sh.
#
# WHY THIS IS A SEPARATE FILE, NOT A COPY AND NOT A MERGE INTO
# sweep-loop-common.sh. A hand-pasted copy in svc-vaporwave's wrapper
# diverged from the original within a day: no notify-send, placed above the
# wrapper's own `LOG=` assignment (so notices went to cron mail instead of
# run.log), no "=== <ts> ===" delimiter, and missing the renewal warning
# below -- because copying is what copies do. The fix is not a better copy,
# it is one copy. But aedile's wrapper is deliberately bespoke (a shared org
# repo, its own clone/branch/PR flow) and does not source
# lib/sweep-loop-common.sh's clone/push engine, so this stays a small
# standalone file: a shared FUNCTION, not a shared ENGINE.
#
# CONTRACT -- caller sets these before calling, and MUST have created
# STATE_DIR already:
#   JOB_NAME     required, used in the notification and the log record
#   STATE_DIR    required, must exist; holds the expires_at stamp
#   LOG          required, the run log `scheduler status` reads
#   EXPIRY_DAYS  optional, default 7
#
# On trip: writes a complete ===-delimited run record to $LOG, fires
# notify-send, and returns 3. On renewal/first run: stamps now+EXPIRY_DAYS
# and returns 0. The CALLER decides what to do with 3 -- this file never
# calls exit, so sourcing it can never terminate a caller by surprise.

deadman_check() {
  local expires_at_file expires_at now_is msg
  : "${EXPIRY_DAYS:=7}"

  # Fail loud on a broken contract rather than silently skipping the switch.
  # A switch that quietly does nothing is worse than no switch: it reads as
  # protection that is not there.
  if [ -z "${JOB_NAME:-}" ] || [ -z "${STATE_DIR:-}" ] || [ -z "${LOG:-}" ]; then
    echo "deadman_check: BROKEN CONTRACT -- JOB_NAME, STATE_DIR and LOG must all be set" >&2
    return 2
  fi
  if [ ! -d "$STATE_DIR" ]; then
    echo "deadman_check: BROKEN CONTRACT -- STATE_DIR ($STATE_DIR) does not exist; create it before calling" >&2
    return 2
  fi

  expires_at_file="$STATE_DIR/expires_at"
  if [ ! -f "$expires_at_file" ]; then
    date -d "+${EXPIRY_DAYS} days" -Is > "$expires_at_file" || {
      echo "deadman_check: could not write $expires_at_file" >&2
      return 2
    }
  fi
  expires_at="$(cat "$expires_at_file")"
  now_is="$(date -Is)"

  [[ "$now_is" > "$expires_at" ]] || return 0

  msg="Auto-disabled: dead-man switch tripped ($expires_at). Renew: rm $expires_at_file -- next run re-stamps now+${EXPIRY_DAYS}d. Bumping EXPIRY_DAYS alone does NOT renew (the stamp is only written when the file is missing)."
  # `|| true` guards against FAILING. It does not guard against NEVER
  # RETURNING, and those are different: the dbus socket at
  # $XDG_RUNTIME_DIR/bus can exist with nothing listening, which makes
  # notify-send block forever. A service account has no desktop session to
  # notify; the notification is best-effort garnish and must never be able
  # to wedge the job it is decorating.
  timeout 5 notify-send "$JOB_NAME" "$msg" 2>/dev/null || true
  {
    echo "=== $now_is ==="
    echo "expired -- dead-man switch tripped; no work attempted (no clone, no claude). $msg"
    echo "note: bin/sync-crontab.sh prunes this job's crontab line on its next --apply run; this script never touches crontab itself"
    echo "=== skipped (expired $expires_at) $now_is (0s) ==="
  } >> "$LOG"
  return 3
}

# ---------------------------------------------------------------------------
# deadman_renew -- record that this job is ALIVE, pushing the stamp forward.
#
# THE POLARITY BUG THIS EXISTS TO FIX. Before it, `expires_at` was written
# exactly once -- on the first run, because deadman_check only stamps when the
# file is MISSING -- and never again. So the switch did not measure silence.
# It measured the calendar: every job died EXPIRY_DAYS after its first run,
# healthy or not, and the only cure was a human noticing and running `rm`
# (found live 2026-08-11: three healthy, working accounts all within 19
# hours of self-destructing on that timer, one already dead). The switch is
# also what `sync-crontab.sh --apply` reads to PRUNE a job's crontab line, so
# an unnoticed trip escalates from "stops running" to "stops being scheduled
# at all".
#
# WHAT COUNTS AS ALIVE, and why it is not "succeeded". A job that runs and
# FAILS every night is not silent -- it is shouting, and the FAILED notify plus
# a non-zero exit are the channel for that. A job whose cron stopped firing,
# whose host is off, or whose wrapper dies before reaching the end is silent,
# and that is the only thing a dead-man switch can honestly detect. So the
# renewal is on REACHING THE END OF A RUN, whatever the run concluded.
#
# THE DELIBERATE BRAKE IS UNAFFECTED, and this is the load-bearing interaction:
# bin/usage-paced-runner.sh brakes a GAVE-UP participant by stamping expires_at
# IN THE PAST. That happens after the run, in the runner, not here -- so a
# renewal earlier in the same run cannot undo it. An agent that declares
# IMPOSSIBLE still stops. What can no longer happen is a job stopping because
# a week went by.
deadman_renew() {
  local expires_at_file
  : "${EXPIRY_DAYS:=7}"

  if [ -z "${STATE_DIR:-}" ]; then
    echo "deadman_renew: BROKEN CONTRACT -- STATE_DIR must be set" >&2
    return 2
  fi
  if [ ! -d "$STATE_DIR" ]; then
    echo "deadman_renew: BROKEN CONTRACT -- STATE_DIR ($STATE_DIR) does not exist" >&2
    return 2
  fi

  expires_at_file="$STATE_DIR/expires_at"
  # Unconditional overwrite. deadman_check writes only when the file is
  # missing, which is correct for BOOTSTRAPPING a stamp and is exactly what
  # made the stamp permanent; renewal is the opposite operation and has to say
  # so by clobbering.
  date -d "+${EXPIRY_DAYS} days" -Is > "$expires_at_file" || {
    echo "deadman_renew: could not write $expires_at_file" >&2
    return 2
  }
  return 0
}
