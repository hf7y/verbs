#!/usr/bin/env bash
# senechal: run every remedy's verify on a schedule.
#
#   ./verify-all-timer.sh enable    # install + arm the --user timer
#   ./verify-all-timer.sh verify    # non-AI, cron-safe: is it armed?
#   ./verify-all-timer.sh disable   # undo
#
# WHY THIS EXISTS. this repo's prose told you for months to cron verify-all.sh
# since the directory was created, and printed the crontab line to paste.
# Nobody pasted it -- and mandark's crontab was deliberately emptied on
# 2026-07-29 for THE PLAY, so even a pasted line would have gone. Measured
# 2026-08-23: 30 remedies, aggregate exit 1, 13 FAIL / 4 INCOMPLETE /
# 1 WARN / 12 PASS, and no clock had asked any of them in weeks. The
# remedies were not stale; nothing was reading them.
#
# A README that tells a person to install the clock is not a clock. This
# is the same finding as .github/workflows/tests.yml one layer over: the
# work existed, the runner did not.
#
# DAILY, not hourly. estate-health.sh already runs every hour and is the
# right place for anything that must be caught fast. Remedy drift is slow
# -- a package upgrade, a config rewrite, a hand edit -- and verify-all
# ssh's to every reach=ssh device on the way through, which is real cost
# to repeat 24 times a day for an answer that changes weekly. This is also
# exactly the cadence README.md's own crontab line used (0 9 * * *).
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh
# shellcheck source=lib/timer-kind.sh
. lib/timer-kind.sh

# --- target values, defined once, read by both verbs --------------------
SERVICE_NAME="senechal-verify-all.service"
TIMER_NAME="senechal-verify-all.timer"
# INTERVAL_CFG_KEY deliberately EMPTY: this timer is OnCalendar-driven, not
# interval-driven, and timer-kind.sh skips the time-span format check and
# the "interval X" verify wording for exactly this shape (see its header).
INTERVAL_CFG_KEY=""
INTERVAL="daily"
CHECK="$(senechal_entrypoint remedies/verify-all.sh)"
UNIT_DIR="${SENECHAL_VERIFYALL_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
LIVE=1
[ -z "${SENECHAL_VERIFYALL_UNIT_DIR:-}" ] || LIVE=0

service_content() {
  cat <<EOF
[Unit]
Description=senechal: verify every remedy still holds

[Service]
Type=oneshot
ExecStart=$CHECK -q
# verify-all aggregates the lib/common.sh exit contract with rc_severity:
# 1 a remedy no longer holds, 2 could-not-check, 3 degrading. Those are
# its REPORT, not a crash. Without this every unhealthy run leaves a
# failed user unit, which estate-health.sh's own check_units then reports
# as a failure -- the self-referential alert loop estate-health-timer.sh
# already guards against for the same reason.
SuccessExitStatus=1 2 3
EOF
}

timer_content() {
  cat <<EOF
[Unit]
Description=senechal: verify every remedy still holds, daily

[Timer]
OnCalendar=daily
# Catch up on a missed run after a laptop suspend rather than staying
# silent until tomorrow.
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF
}

timer_enable_post() {
  say ""
  say "Done. Check it worked with:"
  say "  ./verify-all-timer.sh verify"
  say "  systemctl --user list-timers $TIMER_NAME"
  say "  journalctl --user -u $SERVICE_NAME"
}

enable_() {
  say "verify-all-timer enable: run $CHECK daily (systemd --user)"
  [ -x "$CHECK" ] || die "$CHECK missing or not executable -- wrong repo checkout?"
  toggle_timer_enable
}

disable_() {
  say "verify-all-timer disable: removing the --user timer"
  toggle_timer_disable
  say "Done. remedies/verify-all.sh itself is untouched and still runnable by hand."
}

verify_() {
  head_ "verify-all-timer: every remedy's verify, daily (systemd --user)"
  toggle_timer_verify
  finish_verify "OK -- every remedy's verify runs daily."
}

case "${1:-}" in
  enable)  enable_ ;;
  disable) disable_ ;;
  verify)  verify_ ;;
  *) die "usage: $(basename "$0") enable|disable|verify" ;;
esac
