#!/usr/bin/env bash
# dose-project.sh -- dose <project>: converge THIS host to match schedule/ROSTER.
#
# hf7y/scheduler#80 (this command) + #81 (per-project rate). Frame: realisateur#134.
#
# Reads schedule/ROSTER from GITHUB via `gh api`, never a local clone: a clone
# on this host can be days stale (measured 2026-08-11: 5 days), converging to
# stale truth. `gh` unauthenticated, unreachable, or the file missing are all
# indistinguishable from here and BLIND (exit 6) -- never a silent "no rows
# found" (exit 4 is for a roster dose COULD read that has no row for this).
#
# THE JUDGEMENT THIS SCRIPT DOES NOT GET TO MAKE. Arming/parking is reserved
# for a human at a terminal -- an agent that edited the roster and converged
# would have self-armed. --check/--apply/--now never write schedule/ROSTER;
# --arm/--park (#291) do, but refuse a uid 3000-3099 self-dev caller outright.
#
# RUNNER: tests/dose-project-witness.sh
set -uo pipefail

CLI_NAME="dose-project.sh"
SCHED_REL="Documents/Projects/scheduler"

usage() {
  cat <<EOF
usage: $CLI_NAME <project> [--check|--apply|--arm|--park|--now]

Converge THIS host's crontab to match schedule/ROSTER's row for <project>,
read fresh from GitHub via 'gh api' every run.

  --check   report what would change; writes nothing (default)
  --apply   write it, then re-read and verify
  --arm     flip schedule/ROSTER's row to 'live' and the matching
            schedule/_paced.<host>.conf 'enabled' flag to 1, together, as
            one pull request with auto-merge armed. Human-only (#291):
            refuses a uid 3000-3099 self-dev account, and refuses a
            project whose unix account does not exist on the roster's host.
  --park    the same, to 'parked' / 0.
  --now     dispatch this project ONCE, right now, as its own account.
            Bypasses the usage gate and tempo -- scheduler-run consults
            neither. Hops to the roster's host over ssh if you are elsewhere.

exit: 0 kept  2 usage  4 gap  5 broken  6 blind  7 refused
EOF
}

MODE="--check"; PROJECT=""
for a in "$@"; do
  case "$a" in
    --check|--apply|--arm|--park|--now) MODE="$a" ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "$CLI_NAME: unknown flag $a" >&2; exit 2 ;;
    *) PROJECT="$a" ;;
  esac
done
[ -n "$PROJECT" ] || { echo "$CLI_NAME: name a project (see --help)" >&2; exit 2; }

# #291: refused on the CLI's OWN uid, before any network call.
if [ "$MODE" = "--arm" ] || [ "$MODE" = "--park" ]; then
  CALLER_UID="$(id -u)"
  if [ "$CALLER_UID" -ge 3000 ] && [ "$CALLER_UID" -le 3099 ]; then
    echo "REFUSED: uid $CALLER_UID is a self-dev account (3000-3099) -- $MODE is a human action at a terminal, not something a project may do to itself" >&2
    exit 7
  fi
fi

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

# --- 3a. --arm/--park (#291): write the roster, never converge. Runs before
# the wrong-host check -- a GitHub write has no "wrong host" to be wrong about.
roster_with_state() {  # <content> <project> <new-state>
  awk -v proj="$2" -v newstate="$3" '
    $0 ~ /^[[:space:]]*(#|$)/ { print; next }
    {
      n = split($0, f, "|")
      if (n < 4) { print; next }
      p = f[1]; gsub(/^[ \t]+|[ \t]+$/, "", p)
      if (p != proj) { print; next }
      lead = f[n]; sub(/[^ \t].*$/, "", lead)
      out = f[1]
      for (i = 2; i < n; i++) out = out "|" f[i]
      print out "|" lead newstate
    }
  ' <<<"$1"
}
paced_with_enabled() {  # <content> <project> <new-enabled 0|1>
  awk -v proj="$2" -v val="$3" 'BEGIN{FS=OFS="|"} $1 == proj { $2 = val } { print }' <<<"$1"
}
if [ "$MODE" = "--arm" ] || [ "$MODE" = "--park" ]; then
  NEW_STATE="live"; NEW_ENABLED=1
  [ "$MODE" = "--park" ] && { NEW_STATE="parked"; NEW_ENABLED=0; }

  if [ "$ROW_STATE" = "$NEW_STATE" ]; then
    echo "kept: '$PROJECT' is already $NEW_STATE in schedule/ROSTER"
    exit 0
  fi

  # do_live exits 5 BROKEN if the account is missing -- catch it here first.
  if [ "$NEW_STATE" = "live" ]; then
    ACCT_OK=1
    if [ "$ROW_HOST" = "$HOST" ]; then
      getent passwd "$ROW_ACCT" >/dev/null 2>&1 || ACCT_OK=0
    else
      ssh -o BatchMode=yes -o ConnectTimeout=5 "$ROW_HOST" "getent passwd '$ROW_ACCT'" >/dev/null 2>&1 || ACCT_OK=0
    fi
    if [ "$ACCT_OK" -ne 1 ]; then
      echo "BROKEN: '$ROW_ACCT' has no unix account on '$ROW_HOST' yet -- arming now would converge to a break. Provision the account first, then --arm." >&2
      exit 5
    fi
  fi

  PACED_REL="schedule/_paced.${ROW_HOST}.conf"
  PACED_CONTENT="$(fetch_repo_file "$PACED_REL")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "BROKEN: no $PACED_REL to converge alongside schedule/ROSTER -- #291 writes both together or neither" >&2
    exit 5
  fi
  if ! grep -qE "^${PROJECT}\|" <<<"$PACED_CONTENT"; then
    echo "BROKEN: '$PROJECT' has a schedule/ROSTER row but no line in $PACED_REL -- the two files already disagree, dose will not paper over that by hand" >&2
    exit 5
  fi

  NEW_ROSTER="$(roster_with_state "$ROSTER_CONTENT" "$PROJECT" "$NEW_STATE")"
  NEW_PACED="$(paced_with_enabled "$PACED_CONTENT" "$PROJECT" "$NEW_ENABLED")"

  BRANCH="dose-${MODE#--}-${PROJECT}-$(date +%s)"
  TITLE="dose $PROJECT $MODE -> $NEW_STATE"
  BODY="Opened by \`dose $PROJECT $MODE\` (hf7y/scheduler#291) -- schedule/ROSTER's state and $PACED_REL's enabled flag, together, so the two cannot disagree. Auto-merge is armed; this merges itself once 'suites' is green."

  create_repo_branch "$BRANCH" "$ROSTER_REF" \
    || { echo "BLIND: could not branch from '$ROSTER_REF' -- nothing written" >&2; exit 6; }
  write_repo_file schedule/ROSTER "$NEW_ROSTER" "$BRANCH" "ROSTER: $PROJECT -> $NEW_STATE" \
    || { echo "BROKEN: branched '$BRANCH' but could not write schedule/ROSTER on it -- delete the stray branch by hand: https://github.com/$REPO_SLUG/tree/$BRANCH" >&2; exit 5; }
  write_repo_file "$PACED_REL" "$NEW_PACED" "$BRANCH" "$PACED_REL: $PROJECT enabled=$NEW_ENABLED" \
    || { echo "BROKEN: wrote schedule/ROSTER on '$BRANCH' but not $PACED_REL -- the branch is half-written, fix it by hand or delete it: https://github.com/$REPO_SLUG/tree/$BRANCH" >&2; exit 5; }

  read -r PR_NUM PR_URL < <(open_repo_pr "$BRANCH" "$ROSTER_REF" "$TITLE" "$BODY")
  if [ -z "$PR_NUM" ]; then
    echo "BROKEN: both files are committed on '$BRANCH' but opening the pull request failed -- open it by hand: https://github.com/$REPO_SLUG/compare/$ROSTER_REF...$BRANCH" >&2
    exit 5
  fi
  if enable_pr_auto_merge "$PR_NUM"; then
    echo "armed: PR #$PR_NUM will merge itself once 'suites' is green -- $PR_URL"
  else
    echo "opened: PR #$PR_NUM -- $PR_URL (auto-merge could not be armed; merge it by hand once green)"
  fi
  echo "next: once merged, run 'dose $PROJECT --apply' on $ROW_HOST to converge its crontab"
  exit 0
fi

# --- 3. wrong host: say so, stop. Never half-act. ---------------------------
if [ "$ROW_HOST" != "$HOST" ]; then
  # --now is the one mode that may travel. Converging a crontab is a WRITE and
  # stays refused off-host; dispatching is a request the roster already says
  # belongs to $ROW_HOST, so carrying it there is obedience, not a bypass.
  if [ "$MODE" = --now ]; then
    echo "hop: '$PROJECT' runs on '$ROW_HOST'; re-running there over ssh"
    exec ssh -o BatchMode=yes "$ROW_HOST" "sudo -n dose '$PROJECT' --now"
  fi
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

# --- 4b. --now: dispatch once, bypassing the regulator ----------------------
# WHY THIS EXISTS. `dose --apply` installs a cron line and that is ALL it does.
# usage-gate.sh is an EVEN-BURN regulator -- it dispatches only when a project
# is BEHIND pace -- so a freshly armed account reports HOLD ... (on-pace) and
# runs nothing. Until #292 lands a real sprint, the only override is
# scheduler-run, which consults neither the gate nor tempo. That was reachable
# only by hand-typing setsid/nohup/sudo -u over ssh, and getting any part of it
# wrong fails in a different way each time.
do_now() {
  local home clone log
  home="$(getent passwd "$ROW_ACCT" 2>/dev/null | cut -d: -f6)"
  [ -n "$home" ] || { echo "BROKEN: '$PROJECT' names account '$ROW_ACCT' but no such account exists on $HOST" >&2; exit 5; }
  clone="$home/$SCHED_REL"
  [ -d "$clone/.git" ] || { echo "BROKEN: $ROW_ACCT has no scheduler clone at $clone" >&2; exit 5; }

  [ "$ROW_STATE" = live ] || echo "note: '$PROJECT' is $ROW_STATE in the roster -- dispatching anyway, because you asked for one run, not for arming"

  # ALREADY RUNNING IS NOT A DISPATCH. The witness below is a pgrep, and a
  # pgrep cannot tell a run we just started from one that started an hour ago
  # -- so without this check a launch that died on its first line would report
  # success on the strength of the previous run. scheduler-run has its own
  # mutex and would refuse anyway; this makes the refusal legible.
  if pgrep -u "$ROW_ACCT" -f 'claude -p' >/dev/null 2>&1; then
    echo "kept: '$PROJECT' is ALREADY running as $ROW_ACCT -- not starting a second one"
    return 0
  fi

  # PULL FIRST, ALWAYS. The paced runner pulls on its tick; a hand-run never
  # did, so a clone one commit behind died with `no such conf: <project>.conf`
  # on a project registered that same hour. Measured 2026-08-25, apms.
  if ! sudo -n -u "$ROW_ACCT" git -C "$clone" pull -q --ff-only 2>/dev/null; then
    echo "BROKEN: could not fast-forward $ROW_ACCT's scheduler clone -- refusing to dispatch against a stale base" >&2
    exit 5
  fi
  [ -f "$clone/schedule/$PROJECT.conf" ] || { echo "BROKEN: no schedule/$PROJECT.conf in $clone even after pulling -- is '$PROJECT' registered?" >&2; exit 5; }

  log="$home/dose-now.log"
  echo "dispatching '$PROJECT' as $ROW_ACCT on $HOST -- gate and tempo bypassed"
  # setsid+nohup because the caller is usually a soon-to-close ssh session, and
  # bash -lc because a non-interactive shell has no PATH and `claude` is not
  # found without it.
  sudo -n -u "$ROW_ACCT" -H bash -lc \
    "cd '$clone' && setsid nohup ./bin/scheduler-run '$PROJECT' batch > '$log' 2>&1 < /dev/null &" \
    >/dev/null 2>&1

  # WITNESS BY LOOKING, not by trusting the launch. A backgrounded process that
  # died on its first line exits 0 from here.
  local i=0
  while [ "$i" -lt 40 ]; do
    if pgrep -u "$ROW_ACCT" -f 'claude -p' >/dev/null 2>&1; then
      echo "dispatched: '$PROJECT' is running as $ROW_ACCT (log: $log)"
      return 0
    fi
    sleep 3; i=$((i + 1))
  done
  echo "BROKEN: launched '$PROJECT' but no claude process appeared within 120s. Last lines of $log:" >&2
  sudo -n -u "$ROW_ACCT" tail -5 "$log" >&2 2>/dev/null
  exit 5
}

if [ "$MODE" = --now ]; then do_now; exit $?; fi

case "$ROW_STATE" in
  parked) do_parked ;;
  live)   do_live ;;
  *) echo "BROKEN: schedule/ROSTER row for '$PROJECT' has state='$ROW_STATE' (want live or parked)" >&2; exit 5 ;;
esac
