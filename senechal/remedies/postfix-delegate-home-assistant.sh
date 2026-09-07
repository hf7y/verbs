#!/usr/bin/env bash
# senechal: close ESTATE.md finding 2 (mail delivery dead) by DECIDING,
# not configuring mail.
#
#   ./postfix-delegate-home-assistant.sh enable    # mask postfix (asks for sudo)
#
# Data for the shared systemd-mask-unit toggle in lib/toggle-kinds.sh --
# #348 phase-4 probe; toggle-kinds.sh also carries a grub-kernel-param
# kind (formerly wrapped by remedies/i915-disable-psr.sh, retired
# hf7y/senechal#451 step 3) for the sibling shape.
#   [rest: vault:senechal/header-archaeology-20260818.md]
PRIVILEGED=yes
HOSTS=(mandark)
REACHES=()
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh
# shellcheck source=lib/toggle-kinds.sh
. lib/toggle-kinds.sh

UNIT="postfix@-.service"
# Overridable for tests only: exercise enable/verify against a fake
# systemctl and without a real sudo prompt.
SUDO_CMD="${SENECHAL_SUDO_CMD-sudo}"
SYSTEMCTL="${SENECHAL_SYSTEMCTL:-systemctl}"
TOGGLE_LIVE=1
[ "$SYSTEMCTL" = "systemctl" ] || TOGGLE_LIVE=0
INSTALLS=()

enable_() {
  toggle_systemd_mask_enable
  say ""
  say "Nothing left for you to do by hand. Mail on this host stays dead on"
  say "purpose: alerting is KDE Connect + notify-send and home-assistant."
  say "Check it worked with:"
  say "  ./postfix-delegate-home-assistant.sh verify"
}

verify_() {
  head_ "postfix-delegate-home-assistant: $UNIT masked, not failing"
  toggle_systemd_mask_verify
  finish_verify "OK -- $UNIT masked, mail delivery deliberately dead, alerting stays on KDE Connect + home-assistant."
}

case "${1:-}" in
  enable)  shift; parse_common_args "$@"; enable_ ;;
  disable) shift; parse_common_args "$@"; toggle_systemd_mask_disable ;;
  verify)  shift; parse_common_args "$@"; verify_ ;;
  *) die "usage: $0 enable|verify|disable [-q]" ;;
esac
