#!/usr/bin/env bash
# senechal: silence the phantom getty@tty1 on dexter (WSL2).
#
#   ./dexter-getty-tty1.sh enable    # mask it on dexter (over ssh)
#   ./dexter-getty-tty1.sh verify    # non-AI, cron-safe: is it still failing?
#
# Data for the shared systemd-mask-unit toggle in lib/toggle-kinds.sh --
# #348 phase-4 probe, second instance of the kind (see i915-disable-psr.sh
# and postfix-delegate-home-assistant.sh for the other two). The kind's
# _mask_run/_mask_query indirection exists BECAUSE of this file: the unit
# lives on a different host, so "run systemctl" has to mean "ssh there and
# run systemctl", not a direct local call. SSH_CMD is overridable so the
# test suite can point it at a fake ssh with no real network involved,
# matching the pattern SENECHAL_SYSTEMCTL already uses for the local kind.
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh
# shellcheck source=lib/toggle-kinds.sh
. lib/toggle-kinds.sh

UNIT="getty@tty1.service"
SSH_HOST="$(cfg health.dexter_ssh_host dexter)"
SSH_TIMEOUT="$(cfg health.remote_ssh_timeout 6)"
SSH_CMD="${SENECHAL_SSH_CMD:-ssh}"
# Overridable for tests only: exercise enable/verify against a fake ssh,
# no real network or remote sudo prompt involved.
SUDO_CMD="${SENECHAL_SUDO_CMD-sudo}"
SYSTEMCTL="systemctl"
TOGGLE_LIVE=1
[ "$SSH_CMD" = "ssh" ] || TOGGLE_LIVE=0

on_dexter() {
  "$SSH_CMD" -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes "$SSH_HOST" "$@" 2>/dev/null
}

# Route the kind's transport over ssh instead of running systemctl
# locally. Redefining after sourcing lib/toggle-kinds.sh wins: both
# functions are only ever called at runtime, never at source time.
_mask_run() { on_dexter "${SUDO_CMD:+$SUDO_CMD }$SYSTEMCTL $*"; }
_mask_query() { on_dexter "$SYSTEMCTL $*"; }

# Reachability is a separate fact from the unit's state, and conflating
# them is how a check turns "I could not look" into a reassuring pass.
require_dexter() {
  on_dexter true || {
    skip "cannot reach $SSH_HOST over ssh -- getty state unknown from here"
    note "this is could-not-check, not a pass: the unit may still be failing"
    finish_verify
  }
}

do_enable() {
  say "senechal remedy: mask $UNIT on $SSH_HOST (WSL2 has no login console)"
  say "Undo is one command: ./dexter-getty-tty1.sh disable"
  say ""
  on_dexter true || die "cannot reach $SSH_HOST over ssh -- nothing was changed"
  say "masking (needs sudo on $SSH_HOST -- you may be prompted)..."
  toggle_systemd_mask_enable
  say ""
  say "run: ./dexter-getty-tty1.sh verify"
}

do_disable() {
  say "senechal remedy: UNMASK $UNIT on $SSH_HOST (undo)"
  on_dexter true || die "cannot reach $SSH_HOST over ssh -- nothing was changed"
  toggle_systemd_mask_disable
  say "On WSL2 this will very likely go straight back to failed -- that is"
  say "the point of the mask."
}

do_verify() {
  require_dexter
  head_ "dexter-getty-tty1: $UNIT masked and quiet on $SSH_HOST"
  toggle_systemd_mask_verify
  finish_verify "OK -- the phantom getty on $SSH_HOST is masked and quiet."
}

case "${1:-}" in
  enable)  shift; parse_common_args "$@"; do_enable ;;
  disable) shift; parse_common_args "$@"; do_disable ;;
  verify)  shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify|disable [-q]" ;;
esac
