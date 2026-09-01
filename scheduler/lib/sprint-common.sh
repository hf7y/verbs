#!/usr/bin/env bash
# sprint-common.sh -- state for `dose <project> --sprint` (#292): an ABSOLUTE
# deadline until which usage-paced-runner.sh's tempo check is bypassed.
# NEVER the usage gate/USAGE_CEILING -- that split is enforced by the runner,
# this file only stores and reads the deadline.
#
# State lives under a project's own dispatcher STATE_DIR
# ($HOME/.local/share/scheduler-paced-runner), so the runner needs no new
# wiring to see a sprint land.
#
# Sourced, never executed (no network call, no top-level side effect --
# same rule tests/dose-common-purity-witness.sh checks for dose-common.sh).
# Timestamps are UTC, second precision, Z suffix, so lexical string
# comparison is chronological comparison.
#
# RUNNER: tests/sprint-common-witness.sh
set -uo pipefail

SPRINT_JOB_NAME="scheduler-paced-runner"

sprint_dir() { printf '%s/sprints' "${1:?sprint_dir needs a state root}"; }

# "<N>h" / "<N>m" -> seconds; 1 on anything else.
sprint_parse_duration() {
  local spec="${1:-}"
  if [[ "$spec" =~ ^([0-9]+)h$ ]]; then
    printf '%d' "$(( 10#${BASH_REMATCH[1]} * 3600 ))"; return 0
  fi
  if [[ "$spec" =~ ^([0-9]+)m$ ]]; then
    printf '%d' "$(( 10#${BASH_REMATCH[1]} * 60 ))"; return 0
  fi
  return 1
}

# now-epoch is a parameter, not always `date -u +%s`, so a witness can pass a
# fixed epoch and get a deterministic expected output.
sprint_expires_at() {
  local secs="${1:?sprint_expires_at needs a seconds count}" now="${2:-$(date -u +%s)}"
  date -u -d "@$(( now + secs ))" +%Y-%m-%dT%H:%M:%SZ
}

sprint_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Write-then-rename so a reader never sees a half-written file. Caller must
# already be the right uid (dose-project.sh sudo's to the row's account).
sprint_set() {
  local root="${1:?sprint_set needs a state root}" proj="${2:?sprint_set needs a project}" \
        exp="${3:?sprint_set needs an expires-at}" dir
  dir="$(sprint_dir "$root")"
  mkdir -p "$dir" || return 1
  printf '%s\n' "$exp" > "$dir/$proj.expiry.tmp" || return 1
  mv -f "$dir/$proj.expiry.tmp" "$dir/$proj.expiry"
}

sprint_clear() { rm -f "$(sprint_dir "${1:?sprint_clear needs a state root}")/${2:?sprint_clear needs a project}.expiry"; }

# The recorded expiry, whether or not it has passed. Empty + return 1 if
# there is no sprint on record.
sprint_expiry() {
  local f; f="$(sprint_dir "${1:?sprint_expiry needs a state root}")/${2:?sprint_expiry needs a project}.expiry"
  [ -r "$f" ] || return 1
  cat "$f"
}

# 0 if a sprint is on record and not yet past its deadline, 1 otherwise.
# SELF-CLEANING: an expired record is deleted on the read that finds it, so
# "expired" and "never sprinted" converge on their own -- no reaper, and no
# window where a status check reports a phantom active sprint. This is also
# the hard stop #292 asks for: the tick after the deadline finds no sprint
# at all, not a decaying one.
sprint_active() {
  local root="${1:?sprint_active needs a state root}" proj="${2:?sprint_active needs a project}" \
        now="${3:-$(sprint_now)}" exp
  exp="$(sprint_expiry "$root" "$proj" 2>/dev/null)" || return 1
  if [[ "$now" < "$exp" ]]; then
    return 0
  fi
  sprint_clear "$root" "$proj"
  return 1
}
