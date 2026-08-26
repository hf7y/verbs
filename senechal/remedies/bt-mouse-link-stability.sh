#!/usr/bin/env bash
# senechal: keep the Bluetooth mouse's link alive across idle.
#
#   ./bt-mouse-link-stability.sh enable    # apply the fix (asks for sudo)
#   ./bt-mouse-link-stability.sh verify    # non-AI, cron-safe: is it holding?
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

# --- target values, defined once, read by both verbs --------------------
MOUSE_MAC="$(cfg health.bt_mouse_mac FB:0E:09:77:DE:C7)"
VID="$(cfg health.bt_adapter_usb_vid 8087)"
PID="$(cfg health.bt_adapter_usb_pid 0029)"
REATTACH_WARN="$(cfg health.bt_reattach_warn_per_day 4)"
WIFI_CONN="$(cfg health.wifi_conn SETUP-B061)"
WIFI_BAND="$(cfg health.wifi_band a)"

# Overridable for tests only: lets `enable` run against a throwaway tree
# with no sudo and no live udev.
MODPROBE_DIR="${SENECHAL_BT_MODPROBE_DIR:-/etc/modprobe.d}"
UDEV_DIR="${SENECHAL_BT_UDEV_DIR:-/etc/udev/rules.d}"
MODPROBE_CONF="$MODPROBE_DIR/senechal-btusb-nosuspend.conf"
UDEV_RULE="$UDEV_DIR/71-senechal-bt-nosuspend.rules"
LIVE=1
[ "$MODPROBE_DIR" = "/etc/modprobe.d" ] || LIVE=0

# Locate the adapter's USB device directory by vid/pid rather than
# hardcoding a bus path -- 1-7 today is not 1-7 after a dock or a reboot
# with a different enumeration order.
adapter_usb_dir() {
  local d
  for d in /sys/bus/usb/devices/*/; do
    [ -f "$d/idVendor" ] && [ -f "$d/idProduct" ] || continue
    [ "$(cat "$d/idVendor" 2>/dev/null)" = "$VID" ] || continue
    [ "$(cat "$d/idProduct" 2>/dev/null)" = "$PID" ] || continue
    printf '%s\n' "${d%/}"
    return 0
  done
  return 1
}

modprobe_content() {
  cat <<EOF
# Installed by senechal remedies/bt-mouse-link-stability.sh
# A USB-autosuspended Bluetooth controller does no background scanning,
# so a BLE peripheral (the mouse) can never reconnect on its own -- and
# this controller cannot be armed as a wake source ("Bad flag given
# (0x1) vs supported (0x0)"). Keep the radio listening.
options btusb enable_autosuspend=0
EOF
}

udev_content() {
  cat <<EOF
# Installed by senechal remedies/bt-mouse-link-stability.sh
# Belt and braces with senechal-btusb-nosuspend.conf: pin runtime PM off
# for this adapter at hotplug time, so the fix applies without waiting
# for a module reload, and applies only to the Bluetooth controller
# rather than disabling USB autosuspend machine-wide.
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="$VID", ATTR{idProduct}=="$PID", TEST=="power/control", ATTR{power/control}="on"
EOF
}

# --- enable -------------------------------------------------------------
do_enable() {
  local usbdir backup manual=()

  say "senechal: Bluetooth mouse link stability"
  say ""

  usbdir="$(adapter_usb_dir)" || {
    warn "no USB device $VID:$PID found -- is the adapter present?"
    warn "installing the config anyway; it will apply when it appears."
    usbdir=""
  }
  [ -n "$usbdir" ] && say "adapter: $usbdir"

  # 1. module option
  say ""
  say "1/3  btusb enable_autosuspend=0 -> $MODPROBE_CONF"
  backup="$(backup_file "$MODPROBE_CONF")"
  [ -n "$backup" ] && say "     backed up existing file to $backup"
  if [ "$LIVE" -eq 1 ]; then
    modprobe_content | sudo tee "$MODPROBE_CONF" >/dev/null || die "could not write $MODPROBE_CONF"
  else
    mkdir -p "$MODPROBE_DIR" || die "could not create $MODPROBE_DIR"
    modprobe_content > "$MODPROBE_CONF" || die "could not write $MODPROBE_CONF"
  fi
  # Confirm rather than announce: a write that silently failed must not
  # print "written." and exit 0. (It did, on 2026-07-28, until this check.)
  [ -s "$MODPROBE_CONF" ] || die "$MODPROBE_CONF is missing or empty after write"
  say "     written."

  # 2. udev rule
  say ""
  say "2/3  udev rule pinning power/control=on -> $UDEV_RULE"
  backup="$(backup_file "$UDEV_RULE")"
  [ -n "$backup" ] && say "     backed up existing file to $backup"
  if [ "$LIVE" -eq 1 ]; then
    udev_content | sudo tee "$UDEV_RULE" >/dev/null || die "could not write $UDEV_RULE"
    sudo udevadm control --reload-rules >/dev/null 2>&1 && say "     udev rules reloaded."
  else
    mkdir -p "$UDEV_DIR" || die "could not create $UDEV_DIR"
    udev_content > "$UDEV_RULE" || die "could not write $UDEV_RULE"
  fi
  [ -s "$UDEV_RULE" ] || die "$UDEV_RULE is missing or empty after write"
  say "     written."

  # Apply immediately so Zach does not have to reboot to get his mouse
  # back. Writing 'on' to a live sysfs node is runtime-only and resets
  # itself on reboot -- the two files above are what make it durable.
  if [ "$LIVE" -eq 1 ] && [ -n "$usbdir" ] && [ -w /dev/null ]; then
    if echo on | sudo tee "$usbdir/power/control" >/dev/null 2>&1; then
      say "     applied live: $(cat "$usbdir/power/control") (was 'auto')"
    else
      manual+=("write 'on' to $usbdir/power/control (needs root)")
    fi
  fi

  # 3. Wi-Fi band
  say ""
  say "3/3  pin Wi-Fi '$WIFI_CONN' to the ${WIFI_BAND}-band (5 GHz)"
  if [ "$LIVE" -eq 1 ] && command -v nmcli >/dev/null 2>&1; then
    if nmcli -g connection.id con show "$WIFI_CONN" >/dev/null 2>&1; then
      if nmcli con mod "$WIFI_CONN" 802-11-wireless.band "$WIFI_BAND" 2>/dev/null; then
        say "     set. Reconnect to apply:  nmcli con up '$WIFI_CONN'"
        manual+=("run: nmcli con up '$WIFI_CONN'   (drops the link briefly)")
      else
        manual+=("run: nmcli con mod '$WIFI_CONN' 802-11-wireless.band $WIFI_BAND")
      fi
    else
      warn "no NetworkManager connection named '$WIFI_CONN' -- skipping."
      manual+=("set health.wifi_conn in senechal.json to the right connection name")
    fi
  else
    say "     (skipped: not a live run, or nmcli absent)"
  fi

  say ""
  say "The module option only takes effect on the next boot or on a"
  say "btusb reload. The live write above covers you until then."
  say ""
  if [ "${#manual[@]}" -gt 0 ]; then
    say "STEPS SENECHAL COULD NOT DO FOR YOU:"
    for m in "${manual[@]}"; do say "  - $m"; done
    say ""
  fi
  say "Then leave the mouse idle for an hour and run:"
  say "  ./bt-mouse-link-stability.sh verify"
  say ""
  say "The real witness is not this script's exit code: it is that you"
  say "stop reaching for the Bluetooth toggle. verify counts re-attaches"
  say "in the journal so that stops depending on your memory."
}

# --- verify -------------------------------------------------------------
do_verify() {
  local usbdir v reattach band freq

  head_ "Bluetooth adapter power management"
  usbdir="$(adapter_usb_dir)"
  if [ -z "$usbdir" ]; then
    skip "USB adapter $VID:$PID not present -- cannot check runtime PM"
  else
    v="$(cat "$usbdir/power/control" 2>/dev/null)"
    case "$v" in
      on)   ok "$usbdir/power/control = on (radio stays listening)" ;;
      auto) fail "$usbdir/power/control = auto -- adapter will suspend and go deaf"
            note "run: ./bt-mouse-link-stability.sh enable" ;;
      *)    skip "could not read $usbdir/power/control" ;;
    esac
  fi

  v="$(cat /sys/module/btusb/parameters/enable_autosuspend 2>/dev/null)"
  case "$v" in
    N) ok "btusb enable_autosuspend = N" ;;
    Y) fail "btusb enable_autosuspend = Y -- reverts on next boot/module reload"
       note "expected $MODPROBE_CONF to set it; is the file present, and has the machine rebooted since?" ;;
    *) skip "btusb module parameter unreadable (module not loaded?)" ;;
  esac

  [ -f "$MODPROBE_CONF" ] && ok "$MODPROBE_CONF present" \
    || fail "$MODPROBE_CONF missing -- fix is not durable across reboot"
  [ -f "$UDEV_RULE" ] && ok "$UDEV_RULE present" \
    || fail "$UDEV_RULE missing -- fix is not durable across hotplug"

  head_ "Wi-Fi / Bluetooth coexistence"
  if ! command -v nmcli >/dev/null 2>&1; then
    skip "nmcli absent -- cannot check the Wi-Fi band"
  else
    band="$(nmcli -g 802-11-wireless.band con show "$WIFI_CONN" 2>/dev/null)"
    if [ -z "$band" ] || [ "$band" = "--" ]; then
      warn_ "'$WIFI_CONN' has no band pinned -- may associate on 2.4 GHz, sharing the AX200 radio with the mouse"
    elif [ "$band" = "$WIFI_BAND" ]; then
      ok "'$WIFI_CONN' pinned to band '$band'"
    else
      warn_ "'$WIFI_CONN' pinned to band '$band', expected '$WIFI_BAND'"
    fi
    # What it is *actually* associated on matters more than the setting.
    freq="$(nmcli -t -f ACTIVE,FREQ dev wifi list 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}' | tr -dc '0-9')"
    if [ -z "$freq" ]; then
      skip "no active Wi-Fi association -- cannot check the live band"
    elif [ "$freq" -ge 5000 ] 2>/dev/null; then
      ok "associated at ${freq} MHz (5 GHz -- out of the mouse's band)"
    else
      warn_ "associated at ${freq} MHz (2.4 GHz -- same band as the mouse)"
    fi
  fi

  # The human-sense witness. A passing config that still drops the mouse
  # is not a pass, so count the actual re-link events rather than trust
  # the settings above.
  head_ "Link stability witness (last 24h)"
  if ! command -v journalctl >/dev/null 2>&1; then
    skip "journalctl absent -- cannot count re-attaches"
  else
    reattach="$(journalctl --since "-24h" --no-pager 2>/dev/null \
                | grep -c "BLUETOOTH HID .* Mouse")"
    if [ -z "$reattach" ]; then
      skip "could not read the journal -- not a pass"
    elif [ "$reattach" -le "$REATTACH_WARN" ]; then
      ok "$reattach mouse re-attach event(s) in 24h (threshold $REATTACH_WARN)"
    else
      fail "$reattach mouse re-attach events in 24h -- above threshold $REATTACH_WARN"
      note "the link is still dropping; power management is not the whole cause."
      note "next suspects: mouse battery, or BLE connection supervision timeout."
    fi
  fi

  # The Phomemo is the control, not a fault. Report it so a future
  # reader does not rediscover it as a bug -- see the header.
  head_ "Control device (expected to differ)"
  note "Phomemo M02 reconnects via CUPS dialling out (phomemo://), not via"
  note "an inbound BLE reconnect. Its working is expected and is evidence"
  note "for this diagnosis, not a contradiction of it. Do not 'fix' it."

  finish_verify "OK -- the adapter stays listening and the mouse is holding its link."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) say "usage: $(basename "$0") {enable|verify [-q]}"; exit 2 ;;
esac
