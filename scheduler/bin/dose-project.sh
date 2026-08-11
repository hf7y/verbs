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

# The one job this converges -- SAME name/command/env sync-crontab.sh already
# writes today (schedule/_runner.conf), so dose and sync-crontab never fight
# over the shape of the line, only over who last wrote it. Only the CRON
# field is roster-derived; that is the whole point of #81 (retiring the
# global RUNNER_CRON in favor of a per-project rate).
RUNNER_JOB="scheduler-paced-runner"
RUNNER_CMD_REL="bin/usage-paced-runner.sh"
RUNNER_ENV="PACED_MAX_PER_TICK=1"
SCHED_REL="Documents/Projects/scheduler"
TAG="# scheduler:${RUNNER_JOB}:RUNNER (usage-paced dispatch)"

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

# --- stagger: IDENTICAL formula to cron_spec_for() in realisateur's
# bin/wire-release-channel.sh (cksum % 60 of the name). Not sourced -- that
# script is a CLI entry point that consumes $@ on load, not a library -- but
# the transform is copied verbatim so dose and the release-channel tick can
# never disagree about which minute a given name lands on.
stagger_minute() {
  printf '%d' "$(( $(cksum <<<"$1" | cut -d' ' -f1) % 60 ))"
}

# Roster rate ("6h" / "1h" / "30m", per hf7y/scheduler#81) -> 5-field cron,
# minute(s) staggered by project name. Echoes the fields; returns 1 on a rate
# this dose does not understand (a broken roster row, not a usage error).
cron_fields_for_rate() {
  local rate="$1" name="$2" m n v i count vals
  m="$(stagger_minute "$name")"
  if [[ "$rate" =~ ^([0-9]+)h$ ]]; then
    n="${BASH_REMATCH[1]}"
    if [ "$n" -eq 1 ]; then printf '%s * * * *' "$m"; else printf '%s */%s * * *' "$m" "$n"; fi
    return 0
  fi
  if [[ "$rate" =~ ^([0-9]+)m$ ]]; then
    n="${BASH_REMATCH[1]}"
    { [ "$n" -ge 1 ] && [ "$n" -lt 60 ] && [ $((60 % n)) -eq 0 ]; } || return 1
    count=$((60 / n)); v=$m; vals="$m"
    for ((i = 1; i < count; i++)); do v=$(( (v + n) % 60 )); vals="$vals,$v"; done
    vals="$(printf '%s\n' "${vals//,/$'\n'}" | sort -n | paste -sd, -)"
    printf '%s * * * *' "$vals"
    return 0
  fi
  return 1
}

validate_cron() { [ "$(awk '{print NF}' <<<"$1")" -eq 5 ]; }

# --- crontab access, one account's at a time. Foreign-account read mirrors
# bin/sync-crontab.sh's read_crontab_for(): "no crontab for" is a successful
# read of nothing (crontab -l's own exit 1 for that case), anything else
# nonzero is a real failure and must not be swallowed into "empty".
crontab_read() {
  local acct="$1" out rc
  if [ "$acct" = "$LOCAL_ACCOUNT" ]; then
    "$CRONTAB_BIN" -l 2>/dev/null || true
    return 0
  fi
  out="$(sudo -n -u "$acct" "$CRONTAB_BIN" -l 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"no crontab for"*) printf ''; return 0 ;;
      *) printf '%s' "$out" >&2; return 1 ;;
    esac
  fi
  printf '%s' "$out"
}
crontab_write() {
  local acct="$1" content="$2"
  if [ "$acct" = "$LOCAL_ACCOUNT" ]; then
    printf '%s\n' "$content" | "$CRONTAB_BIN" -
  else
    printf '%s\n' "$content" | sudo -n -u "$acct" "$CRONTAB_BIN" -
  fi
}

# --- 1. bootstrap: read schedule/ROSTER from GitHub, not a local clone -----
fetch_roster() {
  if ! command -v "$GH_BIN" >/dev/null 2>&1; then
    echo "BLIND: '$GH_BIN' not on PATH -- cannot read schedule/ROSTER" >&2
    return 6
  fi
  local out rc
  out="$("$GH_BIN" api "repos/$REPO_SLUG/contents/schedule/ROSTER?ref=$ROSTER_REF" --jq '.content' 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    # "THE FILE IS NOT THERE" AND "I COULD NOT LOOK" ARE DIFFERENT ANSWERS, and
    # collapsing them is this estate's signature failure -- selfdev-release-tick
    # makes the same distinction in the other direction ("Deliberately NOT 3.
    # BLIND means we could not look at the channel; this means we looked at
    # ourselves and the bootstrap is not here").
    #
    # They ARE distinguishable, contrary to a first draft of this function: a
    # 404 from the contents endpoint, when `repos/<slug>` itself reads fine, is
    # a POSITIVE statement that the ref carries no such file. Only if the repo
    # probe fails too is dose actually blind. Without this, a mistyped path
    # would report "cannot see truth" forever instead of "that file is absent",
    # and the operator would go looking at credentials.
    if printf '%s' "$out" | grep -q 'HTTP 404' \
       && "$GH_BIN" api "repos/$REPO_SLUG" --jq '.name' >/dev/null 2>&1; then
      echo "GAP: $REPO_SLUG is reachable and $ROSTER_REF carries no schedule/ROSTER." >&2
      echo "     The roster has not landed on that ref yet (hf7y/scheduler#79), or the path is wrong." >&2
      echo "     This is not a credential problem: repos/$REPO_SLUG read fine on the same token." >&2
      return 4
    fi
    echo "BLIND: gh could not read schedule/ROSTER from $REPO_SLUG@$ROSTER_REF -- unauthenticated or unreachable. Nothing was verified: $out" >&2
    return 6
  fi
  printf '%s' "$out" | tr -d '\n' | base64 -d 2>/dev/null
}

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
