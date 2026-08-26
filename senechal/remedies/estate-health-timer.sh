#!/usr/bin/env bash
# senechal: run the estate health check on a schedule.
#
#   ./estate-health-timer.sh enable    # install + arm the --user timer
#   ./estate-health-timer.sh verify    # non-AI, cron-safe: is it armed?
#   [rest: vault:senechal/header-archaeology-20260818.md]
#
# Rewired onto remedies/lib/timer-kind.sh's shared engine (#348 phase 4):
# this file only defines the unit content, the post-enable epilogue, and
# the health-history witness check verify_() adds after the shared checks.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh
# shellcheck source=lib/timer-kind.sh
. lib/timer-kind.sh

# --- target values, defined once, read by both verbs --------------------
INTERVAL="$(cfg health.check_interval 1h)"
INTERVAL_CFG_KEY="health.check_interval"
SERVICE_NAME="senechal-health.service"
TIMER_NAME="senechal-health.timer"
CHECK="$(senechal_entrypoint health/estate-health.sh)"
# Overridable for tests only: lets `enable` run against a throwaway
# HOME with no live systemd.
UNIT_DIR="${SENECHAL_HEALTH_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
LIVE=1
[ -z "${SENECHAL_HEALTH_UNIT_DIR:-}" ] || LIVE=0

service_content() {
  cat <<EOF
[Unit]
Description=senechal: estate health check

[Service]
Type=oneshot
ExecStart=$CHECK --quiet
# The health check's exit codes are its report, not a crash: 1 fail,
# 2 could-not-check, 3 warn (lib/common.sh's contract). Without this,
# every unhealthy run would leave a failed user unit -- which
# estate-health.sh's own check_units would then report as a failure on
# the next run, a self-referential alert loop. Anything outside the
# contract (a real crash, an unreadable script) still fails loudly.
SuccessExitStatus=1 2 3
EOF
}

timer_content() {
  cat <<EOF
[Unit]
Description=senechal: run the estate health check every $INTERVAL

[Timer]
OnStartupSec=5m
OnUnitActiveSec=$INTERVAL
# Catch up on one missed run after a laptop suspend/resume rather than
# staying silent until the next whole interval.
Persistent=true
RandomizedDelaySec=2m

[Install]
WantedBy=timers.target
EOF
}

timer_enable_post() {
  say "  running one check now so verify has a result to read..."
  systemctl --user start "$SERVICE_NAME" \
    || say "  (that run exited nonzero -- that is the health report, not a failure; see below)"
  say ""
  say "Done. Check it worked with:"
  say "  ./estate-health-timer.sh verify"
  say "  systemctl --user list-timers $TIMER_NAME"
}

# --- enable -------------------------------------------------------------
enable_() {
  say "estate-health-timer enable: run $CHECK every $INTERVAL (systemd --user)"
  [ -x "$CHECK" ] || die "$CHECK missing or not executable -- wrong repo checkout?"
  toggle_timer_enable
}

# --- disable ------------------------------------------------------------
# The undo, so enabling this is not a one-way door.
disable_() {
  say "estate-health-timer disable: removing the --user timer"
  toggle_timer_disable
  say "Done. health/estate-health.sh itself is untouched and still runnable by hand."
}

# --- verify -------------------------------------------------------------
verify_() {
  head_ "estate-health-timer: scheduled health check ($INTERVAL, systemd --user)"
  toggle_timer_verify

  # Witness that it has actually produced a result, not just that it is
  # armed. estate-health.sh appends one line per run here.
  local hist="${XDG_STATE_HOME:-$HOME/.local/state}/senechal/health-history.tsv"
  if [ -r "$hist" ]; then
    local last age_h ts
    last="$(tail -n 1 "$hist" 2>/dev/null)"
    ts="$(date -d "$(printf '%s' "$last" | cut -f1)" +%s 2>/dev/null || echo 0)"
    if [ "$ts" -eq 0 ]; then
      skip "could not parse the last run timestamp out of $hist"
    else
      # STALENESS IS RELATIVE TO THE INTERVAL, not to a constant. This was
      # `age_h -le 24` while the timer runs hourly, so a result 24x older
      # than the cadence read as a PASS. On 2026-08-23 it did exactly that:
      # both units had been 203/EXEC for 22 hours and this row said
      # "PASS last health run 22h ago". A guard reporting OK on the harm it
      # exists to detect is worse than no guard, because it is believed.
      local age_s tol_s
      age_s=$(( $(date +%s) - ts ))
      age_h=$(( age_s / 3600 ))
      tol_s=$(( $(interval_seconds "$INTERVAL") * 3 ))
      if [ "$age_s" -le "$tol_s" ]; then
        ok "last health run ${age_h}h ago: $(printf '%s' "$last" | cut -f2)"
      else
        warn_ "last health run was ${age_h}h ago, but the timer's interval is $INTERVAL -- armed and not firing. Check: systemctl --user status $SERVICE_NAME"
      fi
    fi
  else
    skip "$hist absent -- the check has not completed a run yet"
  fi

  finish_verify "OK -- estate health runs every $INTERVAL."
}

case "${1:-}" in
  enable)  enable_ ;;
  disable) disable_ ;;
  verify)  verify_ ;;
  *) die "usage: $(basename "$0") enable|disable|verify" ;;
esac
