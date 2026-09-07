#!/usr/bin/env bash
# schedule-clean-check.sh -- the committed-config gate: is schedule/ deployed
# from a commit, or from a working tree nobody has saved?
#
# Extracted from bin/sync-crontab.sh's --check-clean (hf7y/scheduler#471,
# retiring that script -- it stopped owning any crontab, see #454). This is
# the ONLY half that had a live caller outside sync-crontab.sh itself:
# bin/usage-paced-runner.sh's dispatch-critical gate. Kept as its own tiny
# subprocess rather than folded into a sourced lib, on purpose -- see
# bin/sync-crontab.sh's old header (git log) on why usage-paced-runner.sh
# must never source a lib for something on its hot path: a syntax error in a
# sourced file fails ALL dispatch, a subprocess failure fails one call.
#
# CLAUDE.md build discipline: "deploy verified against a git ref; drift fails
# loud." Dirty = any tracked modification/staged change under schedule/, or
# any UNTRACKED schedule/*.conf (a conf that has never been committed at all
# is the worst case, not an exempt one).
#
# Writes nothing, reads no crontab -- safe to call from a sweep or a dispatch
# tick. Exit 0 = schedule/ matches HEAD. Exit 2 = dirty, or unverifiable
# (not inside a git repo, or `git status` itself failed).
set -uo pipefail

SCHED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULE_DIR="$SCHED_DIR/schedule"

case "${1:-}" in
  -h|--help)
    echo "Usage: $0"
    echo "  runs the committed-config gate and exits:"
    echo "  0 = schedule/ matches HEAD, 2 = dirty/unverifiable"
    echo "  Writes nothing, reads no crontab -- safe to call from a sweep."
    exit 0
    ;;
esac

schedule_dirty_report() {
  # Prints one line per problem to stdout; returns 0 if clean, 1 if dirty,
  # 2 if the tree can't be verified against a git ref at all.
  git -C "$SCHED_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "schedule/ is not inside a git repository -- nothing to verify it against"
    return 2
  }
  local out
  out="$(git -C "$SCHED_DIR" status --porcelain -- schedule 2>&1)" || {
    echo "git status failed for schedule/: $out"
    return 2
  }
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
  return 1
}

if [ ! -d "$SCHEDULE_DIR" ]; then
  echo "no $SCHEDULE_DIR yet -- nothing to verify" >&2
  exit 0
fi

DIRTY_REPORT="$(schedule_dirty_report)"; DIRTY_RC=$?

if [ "$DIRTY_RC" -eq 0 ]; then
  echo "schedule/ is clean at $(git -C "$SCHED_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
  exit 0
fi

if [ "$DIRTY_RC" -eq 2 ]; then
  echo "UNVERIFIABLE: schedule/ cannot be checked against a git ref:" >&2
else
  echo "DIRTY: schedule/ does not match HEAD -- these would be deployed from an uncommitted state:" >&2
fi
printf '%s\n' "$DIRTY_REPORT" | sed 's/^/    /' >&2
exit 2
