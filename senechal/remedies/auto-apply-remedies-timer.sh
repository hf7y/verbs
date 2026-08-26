#!/usr/bin/env bash
# senechal: run tools/auto-apply-remedies.sh on a schedule (systemd
# --user), so a merge to origin/main is the last human step for
# non-privileged remedies -- see tools/auto-apply-remedies.sh's own
# header for the policy and its scope.
#
#   ./auto-apply-remedies-timer.sh enable    # install + arm the --user timer
#   ./auto-apply-remedies-timer.sh verify    # non-AI, cron-safe: is it armed?
#   ./auto-apply-remedies-timer.sh disable   # undo
#
# BOOTSTRAPPING NOTE: this remedy itself still needs Zach to run
# `enable` by hand, once -- there is no auto-apply before auto-apply
# exists to apply itself. After this lands, every FUTURE non-privileged
# remedy PR gets picked up automatically once merged.
#
# No DISPLAY / session-bus dependency the way estate-health-timer.sh
# has (that one delivers desktop notifications; this one just runs git
# and shell scripts), so unlike that timer this could in principle be a
# system-level unit. Kept --user anyway, on purpose: it writes into
# Zach's own $HOME (backups, plasmoid edits, etc.) and a --user unit
# only ever runs as him, with his real HOME/XDG paths, no separate
# permission model to reason about.
#
# Rewired onto remedies/lib/timer-kind.sh's shared engine (#348 phase 4):
# this file only defines the unit content and the post-enable epilogue.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh
# shellcheck source=lib/timer-kind.sh
. lib/timer-kind.sh

INTERVAL="$(cfg health.auto_apply_interval 15m)"
INTERVAL_CFG_KEY="health.auto_apply_interval"
SERVICE_NAME="senechal-auto-apply-remedies.service"
TIMER_NAME="senechal-auto-apply-remedies.timer"
DRIVER="$(senechal_entrypoint tools/auto-apply-remedies.sh)"
# The tree the driver was resolved into -- deployed build or this
# checkout. Never $SENECHAL_ROOT: the two differ exactly when it matters.
DRIVER_ROOT="$(cd "$(dirname "$DRIVER")/.." && pwd)"
UNIT_DIR="${SENECHAL_AUTOAPPLY_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
LIVE=1
[ -z "${SENECHAL_AUTOAPPLY_UNIT_DIR:-}" ] || LIVE=0

service_content() {
  cat <<EOF
[Unit]
Description=senechal: apply newly-merged non-privileged remedies

[Service]
Type=oneshot
WorkingDirectory=$DRIVER_ROOT
ExecStart=$DRIVER
# 1 means a remedy still fails verify after enable -- a real finding to
# surface (journalctl --user -u $SERVICE_NAME), not a crash.
SuccessExitStatus=1
EOF
}

timer_content() {
  cat <<EOF
[Unit]
Description=senechal: check for newly-merged remedies every $INTERVAL

[Timer]
OnStartupSec=5m
OnUnitActiveSec=$INTERVAL
Persistent=true
RandomizedDelaySec=1m

[Install]
WantedBy=timers.target
EOF
}

timer_enable_post() {
  say ""
  say "First tick will establish a baseline SHA and apply nothing (by design --"
  say "see tools/auto-apply-remedies.sh's header). Every merge after that is live."
  say "Check it worked with:"
  say "  ./auto-apply-remedies-timer.sh verify"
}

enable_() {
  say "auto-apply-remedies-timer enable: run $DRIVER every $INTERVAL (systemd --user)"
  [ -x "$DRIVER" ] || die "$DRIVER missing or not executable -- wrong repo checkout?"
  toggle_timer_enable
}

disable_() {
  say "auto-apply-remedies-timer disable: removing the --user timer"
  toggle_timer_disable
  say "Done. Merged remedy PRs go back to needing a by-hand enable."
}

verify_() {
  head_ "auto-apply-remedies-timer: scheduled auto-apply ($INTERVAL, systemd --user)"
  toggle_timer_verify
  finish_verify "OK -- auto-apply-remedies runs every $INTERVAL."
}

case "${1:-}" in
  enable)  enable_ ;;
  disable) disable_ ;;
  verify)  shift; parse_common_args "$@"; verify_ ;;
  *) die "usage: $0 enable|disable|verify [-q]" ;;
esac
