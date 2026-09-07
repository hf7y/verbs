#!/usr/bin/env bash
cron_lock() {  # one run at a time. A held lock LEAVES (exit 0) rather than queuing; per-uid path since monkey runs one tick per self-dev account.
  local name="${1:?cron_lock: need a lock name}"
  local f="${CRON_LOCK_FILE:-${TMPDIR:-/tmp}/$name.$(id -u).lock}"
  exec 9>"$f" || { printf '%s: cannot open lock %s\n' "$name" "$f" >&2; exit 2; }
  flock -n 9 || { printf '%s: a run is already in flight -- leaving this tick to it\n' "$name" >&2; exit 0; }
}
