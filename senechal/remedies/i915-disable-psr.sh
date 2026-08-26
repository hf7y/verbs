#!/usr/bin/env bash
# senechal: reversible install/uninstall for the i915.enable_psr=0 kernel
# parameter -- a well-known workaround for Intel Panel Self Refresh (PSR)
# display corruption/flicker on Intel iGPUs.
#
# Data for the shared grub-kernel-param toggle in lib/toggle-kinds.sh --
# #348 phase-4 probe; see postfix-delegate-home-assistant.sh for the
# sibling systemd-mask-unit wrapper.
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh
# shellcheck source=lib/toggle-kinds.sh
. lib/toggle-kinds.sh

# GRUB_FILE/SUDO_CMD/UPDATE_GRUB_CMD are overridable so the test suite can
# run this against a scratch file with no real root/update-grub involved.
GRUB_FILE="${SENECHAL_GRUB_FILE:-/etc/default/grub}"
SUDO_CMD="${SENECHAL_SUDO_CMD-sudo}"
UPDATE_GRUB_CMD="${SENECHAL_UPDATE_GRUB_CMD:-update-grub}"
PARAM="i915.enable_psr=0"

do_enable() {
  toggle_grub_param_enable
  say ""
  say "run: ./i915-disable-psr.sh verify"
}

do_disable() {
  toggle_grub_param_disable
  say ""
  say "run: ./i915-disable-psr.sh verify"
}

do_verify() {
  toggle_grub_param_verify
  finish_verify "OK -- $PARAM is in effect."
}

case "${1:-}" in
  enable) do_enable ;;
  disable) do_disable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|disable|verify [-q]" ;;
esac
