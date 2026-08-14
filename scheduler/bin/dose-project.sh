#!/usr/bin/env bash
# dose-project.sh -- dose <project>: converge THIS host to match schedule/ROSTER.
#
# hf7y/scheduler#80 (this command) + #81 (per-project rate). Frame: realisateur#134.
#
# Reads schedule/ROSTER from GITHUB via `gh api`, never a local clone: a clone
# on this very host can be days behind main (measured 2026-08-11: monkey's own
# scheduler checkout was 5 days stale), so a clone-reading dose would converge
# to stale truth on the host the command is typed on. `gh` unauthenticated,
# unreachable, or the file not existing yet are ALL indistinguishable from here
# and all mean the same thing: dose cannot see truth. That is BLIND (exit 6),
# never a silent "no rows found" (exit 4 is reserved for a roster dose COULD
# read that simply has no row for this project).
#
# THE JUDGEMENT THIS SCRIPT DOES NOT GET TO MAKE. schedule/FREEZE's header
# reserves arming for a human: "a row added to a rotation by an agent, a
# merge, or a copied file still dispatches NOTHING until a human adds a line
# here." The roster inherits that guard -- dose converges TO the roster, it
# never writes the roster, and only Zach edits schedule/ROSTER. An agent that
# edited the roster and then ran dose would have self-armed, which is exactly
# what FREEZE exists to prevent. This script has no code path that writes
# schedule/ROSTER, by design, not by omission.
#
# RUNNER: tests/dose-project-witness.sh
set -uo pipefail

CLI_NAME="dose-project.sh"
REPO_SLUG="${DOSE_REPO_SLUG:-hf7y/scheduler}"
ROSTER_REF="${DOSE_ROSTER_REF:-main}"
GH_BIN="${DOSE_GH_BIN:-gh}"
CRONTAB_BIN="${DOSE_CRONTAB_BIN:-crontab}"
HOST="${DOSE_HOST_OVERRIDE:-$(hostname -s 2>/dev/null || echo unknown)}"
LOCAL_ACCOUNT="$(id -un)"

SCHED_REL="Documents/Projects/scheduler"

usage() {
  cat <<EOF
usage: $CLI_NAME <project> [--check|--apply]

Converge THIS host's crontab to match schedule/ROSTER's row for <project>,
read fresh from GitHub via 'gh api' every run.

  --check   report what would change; writes nothing (default)
  --apply   write it, then re-read and verify

exit: 0 kept  2 usage  4 gap  5 broken  6 blind  7 refused
EOF
}

MODE="--check"; PROJECT=""
for a in "$@"; do
  case "$a" in
    --check|--apply) MODE="$a" ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "$CLI_NAME: unknown flag $a" >&2; exit 2 ;;
    *) PROJECT="$a" ;;
  esac
done
[ -n "$PROJECT" ] || { echo "$CLI_NAME: name a project (see --help)" >&2; exit 2; }

# --- the shared half, sourced so `dose host` cannot drift from it (#119) ---
# RESOLVABLE BY STATIC READING, deliberately. bashify/lib/closure.sh scores a
# script's transitive source closure to decide whether it may move onto the
# bashified branch, and it reports a source path it cannot resolve as
# UNRESOLVED -- which is "NEVER CLEAN, full stop". A `$(cd ... && pwd)`
# computed inside the source line is exactly that, and the first spelling of
# this line scored UNRESOLVED for that reason alone. The two-step keeps the
# same runtime behaviour (symlink-safe, works from the build or a checkout)
# while leaving a literal relative path on the `.` line for the tool to read.
DOSE_LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../lib/dose-common.sh
. "$DOSE_LIB_DIR/lib/dose-common.sh"

# The fetch lives HERE, not in the library: sourcing a library must not make a
# network call, and must not exit the process that sourced it (#120's defect,
# fixed 2026-08-11).
ROSTER_CONTENT="$(fetch_roster)" || exit $?

# --- 2. project not in roster -> exit 4, not 0 ------------------------------
find_row() {
  local proj="$1" f1 f2 f3 f4
  while IFS='|' read -r f1 f2 f3 f4 _; do
    f1="$(xargs <<<"$f1")"
    [ "$f1" = "$proj" ] || continue
    f2="$(xargs <<<"$f2")"; f3="$(xargs <<<"$f3")"; f4="$(xargs <<<"$f4")"
    printf '%s\n%s\n%s\n%s\n' "$f1" "$f2" "$f3" "$f4"
    return 0
  done < <(grep -vE '^[[:space:]]*(#|$)' <<<"$ROSTER_CONTENT")
  return 1
}
mapfile -t ROW < <(find_row "$PROJECT")
if [ "${#ROW[@]}" -lt 4 ]; then
  echo "GAP: '$PROJECT' is not in schedule/ROSTER -- nothing to converge" >&2
  exit 4
fi
ROW_ACCT_HOST="${ROW[1]}"; ROW_RATE="${ROW[2]}"; ROW_STATE="${ROW[3]}"
ROW_ACCT="${ROW_ACCT_HOST%@*}"; ROW_HOST="${ROW_ACCT_HOST##*@}"

# --- 3. wrong host: say so, stop. Never half-act. ---------------------------
if [ "$ROW_HOST" != "$HOST" ]; then
  echo "REFUSED: roster says '$PROJECT' runs on '$ROW_HOST', this host is '$HOST' -- stopping, nothing touched" >&2
  exit 7
fi

# --- 3b. the job this converges -- SAME source sync-crontab.sh already reads
# (schedule/_runner.conf, host-overridable), fetched over the same GitHub path
# as the roster rather than hardcoded here a second time (scheduler#112: two
# writers for one fact drift silently, exactly hf7y/scheduler#119's shape).
# Only RUNNER_CRON is deliberately NOT read from here -- that field is
# roster-derived, the whole point of #81 retiring the global RUNNER_CRON.
runner_field_present() { grep -qE "^${2}=" <<<"$1"; }
runner_field_value() {
  grep -E "^${2}=" <<<"$1" | tail -1 | sed -E "s/^${2}=\"?([^\"]*)\"?.*/\1/"
}
RUNNER_CONF="$(fetch_repo_file schedule/_runner.conf)" || exit $?
RUNNER_JOB="$(runner_field_value "$RUNNER_CONF" RUNNER_JOB)"
RUNNER_CMD_REL="$(runner_field_value "$RUNNER_CONF" RUNNER_CMD)"
RUNNER_ENV="$(runner_field_value "$RUNNER_CONF" RUNNER_ENV)"
HOST_RUNNER_CONF="$(fetch_repo_file "schedule/_runner.${HOST}.conf")"; rc=$?
case "$rc" in
  0)
    runner_field_present "$HOST_RUNNER_CONF" RUNNER_JOB && RUNNER_JOB="$(runner_field_value "$HOST_RUNNER_CONF" RUNNER_JOB)"
    runner_field_present "$HOST_RUNNER_CONF" RUNNER_CMD && RUNNER_CMD_REL="$(runner_field_value "$HOST_RUNNER_CONF" RUNNER_CMD)"
    runner_field_present "$HOST_RUNNER_CONF" RUNNER_ENV && RUNNER_ENV="$(runner_field_value "$HOST_RUNNER_CONF" RUNNER_ENV)"
    ;;
  4) : ;; # no host override on file -- shared value stands, not an error
  *) exit "$rc" ;;
esac
if [ -z "$RUNNER_JOB" ] || [ -z "$RUNNER_CMD_REL" ]; then
  echo "BROKEN: schedule/_runner.conf does not set both RUNNER_JOB and RUNNER_CMD -- nothing to converge to" >&2
  exit 5
fi
TAG="# scheduler:${RUNNER_JOB}:RUNNER (usage-paced dispatch)"

# --- 4. parked -> ensure dark, arm NOTHING. Ever. ---------------------------
do_parked() {
  local cur tagged
  cur="$(crontab_read "$ROW_ACCT")" || { echo "BROKEN: could not read $ROW_ACCT's crontab" >&2; exit 5; }
  tagged="$(grep -F "$TAG" <<<"$cur" || true)"
  if [ -z "$tagged" ]; then
    echo "kept: '$PROJECT' is parked and $ROW_ACCT's crontab is already dark"
    exit 0
  fi
  echo "note: '$PROJECT' is parked but $ROW_ACCT's crontab still carries: $tagged"
  if [ "$MODE" = "--check" ]; then
    echo "would   remove that line -- a parked project arms nothing"
    exit 0
  fi
  local newcron
  newcron="$(grep -vF "$TAG" <<<"$cur")"
  crontab_write "$ROW_ACCT" "$newcron" || { echo "BROKEN: could not write $ROW_ACCT's crontab while darkening" >&2; exit 5; }
  if grep -qF "$TAG" <<<"$(crontab_read "$ROW_ACCT")"; then
    echo "BROKEN: removed the line but it is STILL present on re-read -- verify failed" >&2
    exit 5
  fi
  echo "darkened: removed the stray line from $ROW_ACCT's crontab"
  exit 0
}

# --- 5. live -> converge; 6. verify by re-reading, never trust the write ---
do_live() {
  local home
  if [ "$ROW_ACCT" = "$LOCAL_ACCOUNT" ]; then
    home="$HOME"
  else
    home="$(getent passwd "$ROW_ACCT" 2>/dev/null | cut -d: -f6)"
    [ -n "$home" ] || { echo "BROKEN: live project '$PROJECT' names account '$ROW_ACCT' but no such account exists on $HOST" >&2; exit 5; }
  fi

  local rate_fields
  rate_fields="$(cron_fields_for_rate "$ROW_RATE" "$PROJECT")" \
    || { echo "BROKEN: roster rate '$ROW_RATE' for '$PROJECT' is not a form dose understands (want <N>h or <N>m)" >&2; exit 5; }
  validate_cron "$rate_fields" || { echo "BROKEN: derived cron '$rate_fields' is not 5 fields" >&2; exit 5; }

  local abs_cmd desired cur curline
  abs_cmd="$home/$SCHED_REL/$RUNNER_CMD_REL"
  desired="$rate_fields ${RUNNER_ENV:+$RUNNER_ENV }$abs_cmd $TAG"

  cur="$(crontab_read "$ROW_ACCT")" || { echo "BROKEN: could not read $ROW_ACCT's crontab" >&2; exit 5; }
  curline="$(grep -F "$TAG" <<<"$cur" || true)"

  if [ "$curline" = "$desired" ]; then
    echo "kept: $ROW_ACCT's crontab already matches the roster for '$PROJECT'"
    echo "  $desired"
    exit 0
  fi

  echo "drift: current  = ${curline:-<none>}"
  echo "       desired  = $desired"
  if [ "$MODE" = "--check" ]; then
    echo "would   converge $ROW_ACCT's crontab to the line above"
    exit 0
  fi

  local newcron
  newcron="$(grep -vF "$TAG" <<<"$cur")"
  newcron="$(printf '%s\n%s\n' "$newcron" "$desired")"
  crontab_write "$ROW_ACCT" "$newcron" || { echo "BROKEN: crontab write failed for $ROW_ACCT" >&2; exit 5; }

  # VERIFY -- re-read, don't trust the write's exit code ("crontab - exited
  # 0" is not evidence a line is scheduled).
  local afterline
  afterline="$(grep -F "$TAG" <<<"$(crontab_read "$ROW_ACCT")" || true)"
  if [ "$afterline" != "$desired" ]; then
    echo "BROKEN: verify failed -- crontab - exited 0 but the re-read line does not match what was written" >&2
    echo "  wrote    = $desired" >&2
    echo "  re-read  = ${afterline:-<none>}" >&2
    exit 5
  fi
  echo "converged: $ROW_ACCT's crontab now matches the roster for '$PROJECT'"
  exit 0
}

case "$ROW_STATE" in
  parked) do_parked ;;
  live)   do_live ;;
  *) echo "BROKEN: schedule/ROSTER row for '$PROJECT' has state='$ROW_STATE' (want live or parked)" >&2; exit 5 ;;
esac
