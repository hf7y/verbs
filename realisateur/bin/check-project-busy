#!/usr/bin/env bash
# check-project-busy.sh <project> -- offline-first concurrency guard.
#
# KIND: verb
# Tested by bin/tests/check-project-busy.test.sh; deliberately not declared
# a guard -- this is a front door, and that census is for guards.
#
# One narrow question: is a scheduler-dispatched job running against <project>
# right now? It gates a DIRECT write into that project's tree while its own
# automation is mid-run -- the same spirit as the "a dirty tree is a stop"
# rule -- the gate is about the tree.
#
# Mechanism: a scheduler job dir holds a sweep.lock (or run.lock) taken via
# `flock` for the run's duration. A non-blocking flock probe on that file
# answers with no AI cost and no race window -- no PID files, no mtimes.
#
# usage and exit codes: `--help`. One source.
set -uo pipefail

CLI_NAME='check-project-busy.sh'
CLI_SUMMARY='is a scheduler-dispatched job running against <project> right now?'
CLI_USAGE='  check-project-busy.sh <project>   probe that project'"'"'s locks; print BUSY or free'
CLI_FLAGS=''
CLI_EXITS='  0  free -- no job holds a lock for that project
  1  BUSY -- a job does, and the row names it
  2  usage error, or a name the scheduler does not register
  6  BLIND -- the project has an account whose job state this caller cannot
     read. Never 0: could-not-look is not not-busy.'
CLI_POSITIONAL=any
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/cli-guard.sh"
cli_guard "$@"

project="${1:?usage: check-project-busy.sh <project>}"
[ "$#" -eq 1 ] || { echo "check-project-busy.sh: takes exactly one project, got $#" >&2; exit 2; }

# A MISSPELLED PROJECT MUST NOT READ AS "free": the safe-looking answer here
# is the permissive one, so an unregistered name returning "free" is a guard
# failing open -- `check-project-busy.sh --not-a-real-flag` once did.
# Host-portability, as in notify-senechal.sh: an absolute /home/zach path made
# EVERY project read on another host as
# unregistered. That direction is at least safe -- it refuses rather than
# answering "free" -- but a guard that refuses everything is no guard.
PROJECTS_ROOT="${INSTALLE_PROJECTS:-$HOME/Documents/Projects}"
SCHED_ROOT="${SCHED_ROOT:-$PROJECTS_ROOT/scheduler}"
if [ ! -f "$SCHED_ROOT/schedule/$project.conf" ]; then
  echo "check-project-busy.sh: '$project' is not a scheduler-registered project" >&2
  echo "  (no $SCHED_ROOT/schedule/$project.conf -- refusing to answer 'free' for a name I cannot check)" >&2
  exit 2
fi
# THE LOCK LIVES IN THE PROJECT'S OWN ACCOUNT, NOT THE CALLER'S. Each account
# holds its own scheduler-registry, so probing $HOME asked "is a job running
# under MY account?" -- always no for anyone else's. On 2026-08-21 this
# reported senechal free while unable to read senechal's lock at all.
BUSY_HOME_ROOT="${BUSY_HOME_ROOT:-/home}"
# Right for the caller's own project; explicit so a test can redirect it.
share_dir="${BUSY_SHARE_DIR:-$HOME/.local/share}"
if [ "$project" != "$(id -un)" ] && [ -d "$BUSY_HOME_ROOT/$project" ]; then
  owner_share="$BUSY_HOME_ROOT/$project/.local/share"
  if [ -r "$owner_share" ] && [ -x "$owner_share" ]; then
    share_dir="$owner_share"
  else
    # COULD-NOT-LOOK IS NOT NOT-BUSY: the account exists and its state is
    # sealed to this caller, so there is no answer to give. 6, not 0.
    echo "check-project-busy.sh: BLIND -- $project's job state is in $owner_share," >&2
    echo "  which this account ($(id -un)) cannot read. Refusing to answer 'free'." >&2
    exit 6
  fi
fi

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
# a session marker written from a Claude SessionStart hook.
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
