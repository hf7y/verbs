#!/usr/bin/env bash
# check-project-busy.sh <project> -- offline-first concurrency guard.
#
# KIND: verb
#
# Answers one narrow question: is a scheduler-dispatched job (nightly-batch,
# bug-sweep, or a project's own oddly-named batch job) actively running
# push-race/concurrency finding (see FOCUS.md) -- scheduler owns making the
# dedicated-clone-vs-working-checkout sync itself robust; this script is
# realisateur's job: don't cross-write into a project's own FOCUS.md/
# QUESTIONS.md while that project's own automation is mid-run against the
# same files, in the same spirit as vault:realisateur/STABILITY-MILESTONES.md's "a dirty tree
# is a stop" rule for crt.
#
# Mechanism: every scheduler job dir at ~/.local/share/<job-name>/ holds a
# sweep.lock (or run.lock) taken via `flock` for the run's duration (see
# scheduler's lib/sweep-loop-common.sh). A non-blocking flock probe on that
# same file tells us, with zero AI cost and zero race window, whether a job
# currently holds it -- no PID files, no guessing from mtimes.
#
# Usage: bin/check-project-busy.sh <project>
# Exit 0 + "free" if no matching job dir's lock is currently held.
# Exit 1 + "BUSY: <job-name>" (one line per busy job) if any is held.
set -uo pipefail

CLI_NAME='check-project-busy.sh'
CLI_SUMMARY='is a scheduler-dispatched job running against <project> right now?'
CLI_USAGE='  check-project-busy.sh <project>   probe that project'"'"'s locks; print BUSY or free'
CLI_FLAGS=''
CLI_POSITIONAL=any
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/cli-guard.sh"
cli_guard "$@"

project="${1:?usage: check-project-busy.sh <project>}"
[ "$#" -eq 1 ] || { echo "check-project-busy.sh: takes exactly one project, got $#" >&2; exit 2; }

# A MISSPELLED PROJECT MUST NOT READ AS "free". This script's whole job is to
# gate cross-writes, and its safe-looking answer is the permissive one -- so an
# unregistered name silently returning "free" is the exact shape of a guard
# that fails open: `check-project-busy.sh --not-a-real-flag`
# exited 0 and reported free.
# Same host-portability fix as bin/notify-senechal.sh: this was an absolute
# path under /home/zach, so on any other host EVERY project read as
# unregistered. That direction is at least safe -- it refuses rather than
# answering "free" -- but a guard that refuses everything is no guard.
PROJECTS_ROOT="${INSTALLE_PROJECTS:-$HOME/Documents/Projects}"
SCHED_ROOT="${SCHED_ROOT:-$PROJECTS_ROOT/scheduler}"
if [ ! -f "$SCHED_ROOT/schedule/$project.conf" ]; then
  echo "check-project-busy.sh: '$project' is not a scheduler-registered project" >&2
  echo "  (no $SCHED_ROOT/schedule/$project.conf -- refusing to answer 'free' for a name I cannot check)" >&2
  exit 2
fi
share_dir="$HOME/.local/share"

# Shared scheduler INFRASTRUCTURE job dirs, not any one project's own
# automation -- these happen to share the "scheduler-*" prefix with
# scheduler's own real jobs (scheduler-nightly-batch, scheduler-paced-dev)
# purely by naming coincidence, but being "busy" here means "the shared
declare -A INFRA_EXCLUDE=( [scheduler-paced-runner]=1 [scheduler-registry]=1 [scheduler-glance]=1 )

busy=0
shopt -s nullglob

# -- 1. THE CANONICAL PER-PROJECT LOCK ---------------------------------------
# scheduler's lib/sweep-loop-common.sh already keys a lock by PROJECT_KEY
# rather than job name -- its own comment: that is "what makes every tier/job
registry_dir="$share_dir/scheduler-registry"
reg_lock="$registry_dir/$project.lock"
if [ -f "$reg_lock" ] && ! flock -n "$reg_lock" -c true 2>/dev/null; then
  holder="$(cat "$registry_dir/$project.active" 2>/dev/null || echo 'unknown job')"
  echo "BUSY: $holder"
  busy=1
fi

# -- 2. A LIVE INTERACTIVE SESSION -------------------------------------------
# The other half of the same question: a job lock says
# "automation is writing here"; this says "a human is". Written by
# bin/session-marker.sh from a Claude SessionStart hook.
marker="$registry_dir/$project.interactive"
if [ -f "$marker" ]; then
  mpid="$(awk -F= '$1=="pid"{print $2}' "$marker" 2>/dev/null)"
  if [ -n "$mpid" ] && kill -0 "$mpid" 2>/dev/null; then
    echo "BUSY: interactive session (pid $mpid, since $(awk -F= '$1=="started_at"{print $2}' "$marker" 2>/dev/null))"
    busy=1
  fi
fi

# -- 3. per-job-dir fallback (pre-registry jobs) ------------------------------
# Skipped when the registry already answered: both sources describe the same
# job, and reporting it twice makes one busy job read like two.
reg_answered="$busy"
for dir in "$share_dir/$project"-*/; do
  [ "$reg_answered" -eq 1 ] && break
  job="$(basename "$dir")"
  [ -n "${INFRA_EXCLUDE[$job]:-}" ] && continue
  lock="$dir/sweep.lock"
  [ -f "$lock" ] || lock="$dir/run.lock"
  [ -f "$lock" ] || continue
  if ! flock -n "$lock" -c true 2>/dev/null; then
    echo "BUSY: $job"
    busy=1
  fi
done

if [ "$busy" -eq 0 ]; then
  echo "free"
  exit 0
fi
exit 1
