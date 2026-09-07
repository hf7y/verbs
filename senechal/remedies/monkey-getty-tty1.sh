#!/usr/bin/env bash
PRIVILEGED=yes
HOSTS=(monkey)
REACHES=()
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
. ../lib/common.sh
. lib/toggle-kinds.sh

UNIT="getty@tty1.service"
SUDO_CMD="${SENECHAL_SUDO_CMD-sudo}"
SYSTEMCTL="${SENECHAL_SYSTEMCTL:-systemctl}"
TOGGLE_LIVE=1
[ "$SYSTEMCTL" = "systemctl" ] || TOGGLE_LIVE=0
INSTALLS=()

enable_() {
  toggle_systemd_mask_enable
  say ""
  say "WSL2 has no real tty1 -- masked rather than chasing a console"
  say "that will never come up. Check with: ./monkey-getty-tty1.sh verify"
}

verify_() {
  head_ "monkey-getty-tty1: $UNIT masked, not failing"
  toggle_systemd_mask_verify
  finish_verify "OK -- $UNIT masked, WSL2's phantom console stays quiet."
}

case "${1:-}" in
  enable)  shift; parse_common_args "$@"; enable_ ;;
  disable) shift; parse_common_args "$@"; toggle_systemd_mask_disable ;;
  verify)  shift; parse_common_args "$@"; verify_ ;;
  *) die "usage: $0 enable|verify|disable [-q]" ;;
esac
