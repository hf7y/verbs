#!/usr/bin/env bash
# registry-lock.sh -- "is anything else writing to this project right now?"
#
# ONE implementation of the two-half lockout, sourced by every caller:
#   half 1, job vs job    -- flock on $REGISTRY_DIR/<key>.lock + a .active marker
#   half 2, job vs HUMAN  -- $REGISTRY_DIR/<key>.interactive, pid-probed
#
# WHAT THIS RETIRES: the inline copy of both halves that lived only in
# lib/sweep-loop-common.sh. That placement is why the lockout covered every
# PROJECT's jobs but not the scheduler's own self-development cycle --
# bin/scheduler-dev-cycle.sh does not source sweep-loop-common.sh (it has no
# clone, no secrets, no `claude -p` wrapper to inherit), so it had NO registry
# participation at all and substituted `git status --porcelain` as a proxy for
# "is a person here". That proxy is what stranded 14 commits on 2026-07-25/26:
# a dirty tree is not a human, it has no starvation cap, and nothing retried.
#
# Callers RETURN on these, they do not exit -- each has its own exit-code
# vocabulary (sweep-loop-common uses 4 for deferred; the dev cycle just skips
# the merge and lets the cycle continue), so the policy lives here and the
# consequence stays with the caller.
#
# LIVENESS IS ALWAYS A PID PROBE, never a file's existence: neither the
# session hook nor a job can guarantee a clean release (SessionEnd is not
# guaranteed on crash), so trusting the file would wedge a project silently.
# See realisateur/bin/session-marker.sh, whose recorded pid was itself wrong
# until 2026-07-27 (c49c70d) -- it stored a PPID that died with the hook, so
# this probe read "nobody home" while a human was actively editing.

: "${REGISTRY_DIR:=$HOME/.local/share/scheduler-registry}"

# registry_claim <project_key> <job_name> <tier>
#   0 = claimed (caller must arrange release; sets REGISTRY_MARKER)
#   1 = another job already holds this project
# The flock is taken on fd 201 with `exec`, so it persists for the life of the
# calling process -- a function-local fd would close on return and release the
# lock while the job kept running.
registry_claim() {
  local key="$1" job="$2" tier="${3:-unspecified}"
  mkdir -p "$REGISTRY_DIR" || return 1
  REGISTRY_LOCK="$REGISTRY_DIR/${key}.lock"
  REGISTRY_MARKER="$REGISTRY_DIR/${key}.active"
  exec 201>"$REGISTRY_LOCK"
  if ! flock -n 201; then
    REGISTRY_HOLDER="$(cat "$REGISTRY_MARKER" 2>/dev/null || echo 'unknown job')"
    return 1
  fi
  printf '{"job":"%s","tier":"%s","started_at":"%s","pid":%s}\n' \
    "$job" "$tier" "$(date -Is)" "$$" > "$REGISTRY_MARKER"
  return 0
}

registry_release() { [ -n "${REGISTRY_MARKER:-}" ] && rm -f "$REGISTRY_MARKER"; return 0; }

# registry_human_pid <project_key>
# Echoes the pid of a LIVE interactive session, or nothing. A marker whose pid
# is gone is not a human -- it is litter from a crashed session.
registry_human_pid() {
  local marker="$REGISTRY_DIR/${1}.interactive" pid
  pid="$(awk -F= '$1=="pid"{print $2}' "$marker" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && printf '%s\n' "$pid"
  return 0
}

registry_human_since() {
  awk -F= '$1=="started_at"{print $2}' "$REGISTRY_DIR/${1}.interactive" 2>/dev/null || true
}

# registry_marker_cwd <project_key> -- where the human actually is.
# The job's own $REPO is a dedicated clone; a person never edits that. The
# directory to watch for activity is the one the session hook recorded.
registry_marker_cwd() {
  awk -F= '$1=="cwd"{print $2}' "$REGISTRY_DIR/${1}.interactive" 2>/dev/null || true
}

# registry_repo_active <dir> <seconds>
#   0 = something in <dir> changed within the window
# `-newermt` + `-quit` stops at the FIRST hit, so this is cheap even on a big
# checkout -- it does not stat the whole tree. .git is pruned: git's own
# housekeeping (index refreshes, gc, fetch writing FETCH_HEAD) touches files
# there constantly and would read as "a human is typing" forever. A commit
# inside the window counts too, because checkout/rebase can leave file mtimes
# older than the work they represent.
registry_repo_active() {
  local dir="$1" secs="$2" last now
  [ -d "$dir" ] || return 1
  if [ -n "$(find "$dir" -name .git -prune -o -type f -newermt "-${secs} seconds" -print -quit 2>/dev/null)" ]; then
    return 0
  fi
  last="$(git -C "$dir" log -1 --format=%ct 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  now="$(date +%s)"
  [ "$last" -gt "$(( now - secs ))" ]
}

# registry_should_defer <project_key> <state_file> [fallback_dir]
#   0 = defer to the human (caller stands down and comes back)
#   1 = proceed
# Sets REGISTRY_DEFER_PID / _SINCE / _REASON / _STREAK_MIN, and
# REGISTRY_DEFER_CAPPED=1 ONLY when proceeding over a genuinely active repo.
#
# WHAT THIS RETIRES: INTERACTIVE_DEFER_MAX, the "after N consecutive deferrals,
# run anyway" cap. It counted DISPATCH ATTEMPTS, which is not a measure of
# anything a human does. Two ways it was wrong, both observed:
#   * Four attempts inside ten seconds exhausted the whole budget (2026-07-27),
#     so the "you have been editing across three of this project's turns"
#     reading of the counter was simply false -- it can be three turns or ten
#     seconds depending only on how often the runner fires.
#   * It could not tell an actively-edited repo from an editor left open in
#     the background overnight. The overwhelmingly common case -- a session
#     sitting idle in a terminal -- looked identical to someone mid-refactor,
#     so the job either barged into real work or stood down for nothing.
#
# The question is not "how many times have I asked?" but "is this repo being
# worked in right now?". So: defer while the repo has been TOUCHED recently,
# proceed quietly once it has gone quiet, and keep an absolute time backstop
# for the genuinely pathological case (someone edits every few minutes for a
# day straight) rather than a per-attempt one.
#
# Proceeding over an IDLE repo is the normal, expected path -- a file left
# open is not a person. It is not a warning and must not notify; only the
# backstop is loud.
registry_should_defer() {
  local key="$1" state_file="$2" fallback="${3:-}" dir grace_min max_h streak_start now
  grace_min="${REGISTRY_ACTIVE_GRACE_MIN:-60}"
  max_h="${REGISTRY_MAX_DEFER_HOURS:-24}"
  REGISTRY_DEFER_CAPPED=0
  REGISTRY_DEFER_REASON=""
  REGISTRY_DEFER_GRACE_MIN="$grace_min"
  REGISTRY_DEFER_MAX_HOURS="$max_h"
  REGISTRY_DEFER_PID="$(registry_human_pid "$key")"

  if [ -z "$REGISTRY_DEFER_PID" ]; then
    rm -f "$state_file"
    REGISTRY_DEFER_REASON="nobody home"
    return 1
  fi
  REGISTRY_DEFER_SINCE="$(registry_human_since "$key")"

  dir="$(registry_marker_cwd "$key")"
  [ -n "$dir" ] && [ -d "$dir" ] || dir="$fallback"
  REGISTRY_DEFER_DIR="$dir"

  # No directory to probe: the session is real but we cannot see what it is
  # doing. Defer -- the backstop below still bounds it -- rather than assume
  # idle, because assuming idle is the failing-open direction.
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    REGISTRY_DEFER_REASON="live session, repo activity UNKNOWN (no readable cwd) -- deferring conservatively"
  elif registry_repo_active "$dir" "$(( grace_min * 60 ))"; then
    REGISTRY_DEFER_REASON="repo edited within the last ${grace_min}m"
  else
    # Human present, repo quiet: an editor left open, not work in progress.
    rm -f "$state_file"
    REGISTRY_DEFER_REASON="live session but repo untouched for >${grace_min}m -- treating as a background editor, not active work"
    return 1
  fi

  now="$(date +%s)"
  streak_start="$(cat "$state_file" 2>/dev/null || echo '')"
  case "$streak_start" in ''|*[!0-9]*) streak_start="$now"; echo "$now" > "$state_file" ;; esac
  REGISTRY_DEFER_STREAK_MIN=$(( (now - streak_start) / 60 ))

  # Absolute backstop, time-based not attempt-based: continuous deferral for
  # longer than max_h means this job has been starved for a real day, not
  # nagged three times in a minute.
  if [ "$(( now - streak_start ))" -ge "$(( max_h * 3600 ))" ]; then
    REGISTRY_DEFER_CAPPED=1
    REGISTRY_DEFER_REASON="deferred continuously for ${REGISTRY_DEFER_STREAK_MIN}m (>= ${max_h}h backstop)"
    rm -f "$state_file"
    return 1
  fi
  return 0
}
