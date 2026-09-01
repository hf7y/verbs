#!/usr/bin/env bash
# lib/cron-lock.sh -- one run at a time, for anything on a clock.
#
# A tick that finds the lock held says so and LEAVES (exit 0). Blocking would
# queue the runs this exists to prevent. Per-uid path: on monkey every self-dev
# account runs the same tick, and a shared /tmp path would deny all but one.
cron_lock() {
  local name="${1:?cron_lock: need a lock name}"
  local f="${CRON_LOCK_FILE:-${TMPDIR:-/tmp}/$name.$(id -u).lock}"
  exec 9>"$f" || { printf '%s: cannot open lock %s\n' "$name" "$f" >&2; exit 2; }
  flock -n 9 || { printf '%s: a run is already in flight -- leaving this tick to it\n' "$name" >&2; exit 0; }
}
