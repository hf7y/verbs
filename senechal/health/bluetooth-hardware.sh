#!/usr/bin/env bash
# senechal: bluetooth hardware visibility check. Non-AI, cron-safe,
# READ-ONLY.
#
#   ./bluetooth-hardware.sh          # full report
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

# --- probes ---------------------------------------------------------
# Each probe echoes "<verdict> <detail>". Verdicts: present, absent,
# suspect, unknown (never a pass; see the exit contract in common.sh).

# Overridable so the test harness can point this at a throwaway
# directory instead of the real /sys.
BT_SYSFS_DIR="${BT_SYSFS_DIR:-/sys/class/bluetooth}"

probe_sysfs() {
  if [ -d "$BT_SYSFS_DIR" ] && [ -n "$(ls -A "$BT_SYSFS_DIR" 2>/dev/null)" ]; then
    echo "present $(ls "$BT_SYSFS_DIR" 2>/dev/null | tr '\n' ' ')"
  else
    echo "absent $BT_SYSFS_DIR is missing or empty"
  fi
}

probe_service() {
  command -v systemctl >/dev/null 2>&1 || { echo "unknown systemctl not available"; return; }
  local cond active
  cond="$(systemctl show -p ConditionResult --value bluetooth.service 2>/dev/null)"
  active="$(systemctl is-active bluetooth.service 2>/dev/null)"
  if [ -z "$cond" ]; then
    echo "unknown could not query bluetooth.service"
    return
  fi
  if [ "$active" = active ]; then
    echo "present bluetooth.service is active"
  elif [ "$cond" = no ]; then
    echo "absent bluetooth.service skipped this boot -- ConditionPathIsDirectory unmet, the kernel never created /sys/class/bluetooth"
  else
    echo "suspect bluetooth.service is $active (start condition met, but not running)"
  fi
}

# Repeated USB enumeration failure is the fingerprint of "hardware
# present but the port/chip is stuck" -- a device that tries an address,
# fails (error -71, "Device not responding to setup address"), and the
# kernel retries every few minutes, forever, without ever succeeding.
probe_usb_enum() {
  command -v journalctl >/dev/null 2>&1 || { echo "unknown journalctl not available"; return; }
  local out n ports
  out="$(journalctl -k -b 0 --no-pager 2>/dev/null)" || true
  if [ -z "$out" ]; then
    echo "unknown journalctl -k returned nothing -- no permission, or an empty kernel ring this boot"
    return
  fi
  n="$(printf '%s\n' "$out" | grep -c 'unable to enumerate USB device' || true)"
  if [ "$n" -gt 0 ]; then
    ports="$(printf '%s\n' "$out" \
      | grep -oE 'usb usb[0-9]+-port[0-9]+: unable to enumerate' \
      | awk '{print $2}' | tr -d ':' | sort -u | tr '\n' ' ')"
    echo "suspect $n enumeration failure(s) this boot on port(s): ${ports:-unknown}"
  else
    echo "absent no USB enumeration failures logged this boot"
  fi
}

# --- cross-boot fault memory (2026-08-09) ------------------------------
# The power-drain remedy is worth prescribing exactly once. When the SAME
# full-speed enumeration fault survives onto the NEXT boot -- which is
# what actually happened on mandark, three boots running, drains included
#   [rest: vault:senechal/header-archaeology-20260818.md]
BT_BOOT_ID_FILE="${BT_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"

bt_boot_id() {
  [ -n "${BT_BOOT_ID:-}" ] && { printf '%s\n' "$BT_BOOT_ID"; return 0; }
  cat "$BT_BOOT_ID_FILE" 2>/dev/null   # empty + rc 1 if unreadable; caller checks -n
}

# Record one more boot on which the storm fingerprint fired; echoes the
# new consecutive-boot count (0 if it cannot know, 1 for the first).
# Without a boot signal the state is left untouched and 0 is echoed, so a
# fieldless boot can never fabricate a streak out of repeated runs.
bt_fault_tally() {
  local state="${BT_FAULT_STATE:-$(senechal_state_dir)/bluetooth-hardware-fault.state}"
  local id="" prev_id="" n=0
  id="$(bt_boot_id)"
  [ -f "$state" ] && read -r prev_id n < "$state" 2>/dev/null || true
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ -n "$id" ] && [ "$id" != "$prev_id" ]; then
    n=$((n + 1))
  elif [ -n "$id" ] && [ "$n" -lt 1 ]; then
    n=1
  fi
  if [ -n "$id" ]; then
    mkdir -p "$(dirname "$state")" 2>/dev/null || true
    printf '%s %s\n' "$id" "$n" > "$state" 2>/dev/null || true
  fi
  printf '%s\n' "$n"
}

# Commit that this run is not a storm boot: the consecutive streak
# restarts from scratch.
bt_fault_clear() {
  local state="${BT_FAULT_STATE:-$(senechal_state_dir)/bluetooth-hardware-fault.state}"
  rm -f "$state" 2>/dev/null || true
}

check_bluetooth_hardware() {
  head_ "Bluetooth hardware visibility"
  local sysfs_r svc_r usb_r sysfs_v sysfs_d svc_v svc_d usb_v usb_d boots

  sysfs_r="$(probe_sysfs)";  sysfs_v="${sysfs_r%% *}"; sysfs_d="${sysfs_r#* }"
  svc_r="$(probe_service)";  svc_v="${svc_r%% *}";     svc_d="${svc_r#* }"
  usb_r="$(probe_usb_enum)"; usb_v="${usb_r%% *}";     usb_d="${usb_r#* }"

  if [ "$sysfs_v" = present ]; then
    bt_fault_clear
    ok "adapter visible to the kernel: $sysfs_d"
    return
  fi

  case "$usb_v" in
    suspect)
      boots="$(bt_fault_tally)"
      fail "hardware not visible ($svc_d), but IS attempting to attach: $usb_d"
      if [ "${boots:-0}" -gt 1 ]; then
        note "this is the ${boots}th consecutive boot with the same full-speed enumeration fault (error -71)."
        note "the power-drain remedy encoded here did not clear it -- a stuck xHCI controller is no longer the explanation, this is a hardware fault in the adapter's USB attachment (on mandark: the AX200's Bluetooth half, 8087:0029)."
        note "fix: reseat the Wi-Fi/Bluetooth M.2 card (antenna cables too). If it still recurs, replace the card, or use a USB Bluetooth adapter."
      else
        note "this is a USB enumeration fault, not a disabled service -- a warm reboot will not clear it."
        note "fix: fully power off (drain AC + battery, 10s+) to reset the xHCI controller. If the SAME fault is present on the next boot, this check escalates to reseat-replace-the-card."
      fi
      ;;
    absent)
      bt_fault_clear
      fail "hardware not visible, and no USB enumeration attempts seen this boot ($svc_d)"
      note "check BIOS for a disabled Bluetooth/wireless radio toggle, or that the internal module/cable is seated."
      ;;
    *)
      bt_fault_clear
      skip "hardware not visible; could not determine USB enumeration state: $usb_d"
      note "service: $svc_d"
      ;;
  esac
}

main() {
  parse_common_args "$@"
  _emit "senechal bluetooth-hardware check -- $(date '+%Y-%m-%d %H:%M') on $(hostname)"
  check_bluetooth_hardware

  local logdir; logdir="$(senechal_state_dir)"
  if mkdir -p "$logdir" 2>/dev/null; then
    printf '%s' "$_out" > "$logdir/bluetooth-hardware-latest.txt" 2>/dev/null || true
    note "findings saved to $logdir/bluetooth-hardware-latest.txt"
  fi
  alert_if_changed "$logdir/bluetooth-hardware-latest.txt"

  finish_verify "OK -- bluetooth adapter visible to the kernel."
}
main "$@"
