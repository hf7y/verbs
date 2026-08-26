#!/usr/bin/env bash
# senechal: SMART drive health, readable without root.
#
#   ./smart-health.sh enable    # install the root timer (asks for sudo)
#   ./smart-health.sh disable   # undo
#   ./smart-health.sh verify    # non-AI, cron-safe: is the dump fresh + healthy?
#   [rest: vault:senechal/header-archaeology-20260818.md]
#
# Rewired onto remedies/lib/timer-kind.sh's shared engine (#348 phase 4,
# fourth kind): a SYSTEM (not --user) timer, root-owned files written via
# `sudo install -D`, plus one extra root-owned file (the helper script)
# the other two callers don't have. Redefines _timer_ctl/_timer_ctl_reachable/
# _timer_write_file/_timer_remove_file after sourcing the engine -- same
# function-redefinition-after-sourcing indirection toggle-kinds.sh's
# _mask_run/_mask_query use for a remote unit. No INTERVAL_CFG_KEY: this
# timer is OnCalendar=daily, not interval-driven, and the engine treats an
# unset INTERVAL_CFG_KEY as "this kind has no interval to validate/report".
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh
# shellcheck source=lib/timer-kind.sh
. lib/timer-kind.sh

# --- target values, defined once, read by both verbs --------------------
# Dump path/age come from senechal.json (single config source); defaults
# match senechal.json.example.
DUMP_FILE="$(cfg health.smart_dump_file /var/lib/senechal/smart-health.txt)"
DUMP_MAX_AGE_H="$(cfg health.smart_dump_max_age_hours 48)"
SERVICE_NAME="senechal-smart.service"
TIMER_NAME="senechal-smart.timer"
# Overridable for tests only: lets `enable` be exercised against a
# throwaway directory tree with no sudo and no live systemd.
UNIT_DIR="${SENECHAL_SMART_UNIT_DIR:-/etc/systemd/system}"
HELPER="${SENECHAL_SMART_HELPER:-/usr/local/lib/senechal/smart-dump.sh}"
LIVE=1
[ "$UNIT_DIR" = "/etc/systemd/system" ] || LIVE=0

# --- transport indirection: SYSTEM unit, root-owned files ----------------
_timer_ctl() { sudo systemctl "$@"; }
_timer_ctl_reachable() { :; }  # system-unit state needs no session bus, even under cron
_timer_write_file() { # $1 dest, $2 mode, content on stdin
  local dest="$1" mode="$2" content
  content="$(cat)"
  if [ "$LIVE" -eq 1 ]; then
    printf '%s\n' "$content" | sudo install -D -m "$mode" /dev/stdin "$dest" \
      || die "could not write $dest"
  else
    mkdir -p "$(dirname "$dest")"
    printf '%s\n' "$content" > "$dest"
    chmod "$mode" "$dest"
  fi
}
_timer_remove_file() { [ "$LIVE" -eq 1 ] && sudo rm -f "$1" || rm -f "$1"; }

# The root-side dump script. Normalizes smartctl's per-drive phrasing
# (ATA "PASSED", SCSI "OK") to one token per line -- "<dev> PASSED" /
# "<dev> FAILED" / "<dev> UNKNOWN" -- so the user-side readers stay dumb.
helper_content() {
  cat <<EOF
#!/bin/sh
# Installed by senechal remedies/smart-health.sh -- run as root by
# $SERVICE_NAME. Dumps SMART self-assessment per physical disk to a
# user-readable file so unattended health checks need no root.
set -u
out="$DUMP_FILE"
tmp="\$out.tmp"
mkdir -p "\$(dirname "\$out")"
chmod 0755 "\$(dirname "\$out")"
{
  echo "# senechal-smart dump \$(date '+%Y-%m-%d %H:%M:%S%z')"
  lsblk -dn -o NAME,TYPE | awk '\$2=="disk"{print \$1}' | while read -r dev; do
    [ -n "\$dev" ] || continue
    res="\$(smartctl -H "/dev/\$dev" 2>&1)"
    # Match smartctl's verdict phrases exactly (ATA/NVMe "test result:",
    # SCSI "Health Status:"), not bare PASSED/FAILED -- an open error
    # like "failed: Permission denied" must read UNKNOWN, never FAILED.
    if printf '%s' "\$res" | grep -qiE 'test result: *PASSED|Health Status: *OK'; then
      echo "\$dev PASSED"
    elif printf '%s' "\$res" | grep -qiE 'test result: *FAILED|Health Status: *FAILING'; then
      echo "\$dev FAILED"
    else
      echo "\$dev UNKNOWN"
    fi
  done
} > "\$tmp"
chmod 0644 "\$tmp"
mv "\$tmp" "\$out"
EOF
}

service_content() {
  cat <<EOF
[Unit]
Description=senechal: dump SMART health to a user-readable file

[Service]
Type=oneshot
ExecStart=$HELPER
EOF
}

timer_content() {
  cat <<EOF
[Unit]
Description=senechal: daily SMART health dump

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
EOF
}

# --- enable/disable ------------------------------------------------------
timer_enable_post() {
  say "  running the first dump now so verify has something to read..."
  _timer_ctl start "$SERVICE_NAME" || die "first dump run failed -- journalctl -u $SERVICE_NAME"
  say ""
  say "Done. Nothing left for you to do by hand; check it worked with:"
  say "  ./smart-health.sh verify"
}

enable_() {
  say "smart-health enable: root timer dumping SMART to $DUMP_FILE"
  if [ "$LIVE" -eq 1 ] && ! command -v smartctl >/dev/null 2>&1; then
    die "smartctl not installed -- run: sudo apt install smartmontools"
  fi
  helper_content | _timer_install_file "$HELPER" 0755
  toggle_timer_enable
}

disable_() {
  say "smart-health disable: removing the root timer and helper"
  [ -f "$HELPER" ] && _timer_remove_file "$HELPER" && say "  removed $HELPER"
  toggle_timer_disable
  say "Done. $DUMP_FILE is left in place (historical record); nothing reads it once the timer is gone."
}

# --- verify -------------------------------------------------------------
verify_() {
  head_ "smart-health: root SMART dump ($DUMP_FILE)"

  # 1. the helper is an extra root file the shared engine doesn't know
  #    about (it only tracks the service/timer units) -- installed at all,
  #    and if so, drift-checked, same as the engine does for the units.
  if [ ! -f "$HELPER" ]; then
    fail "$HELPER missing -- remedy not installed (run: ./smart-health.sh enable)"
  else
    [ "$(cat "$HELPER")" = "$(helper_content)" ] \
      && ok "$HELPER matches this script's content" \
      || fail "$HELPER drifted from this script -- re-run enable (or diff by hand first)"
  fi

  # 2. the units themselves: installed, drift-free, armed (LIVE only).
  toggle_timer_verify

  # 3. the dump itself: present, fresh, and healthy.
  if [ ! -r "$DUMP_FILE" ]; then
    fail "$DUMP_FILE missing -- the service has never produced a dump (journalctl -u $SERVICE_NAME)"
    finish_verify
  fi
  local ts now age_h
  ts="$(stat -c %Y "$DUMP_FILE" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  age_h=$(( (now - ts) / 3600 ))
  if [ "$ts" -eq 0 ]; then
    skip "could not stat $DUMP_FILE"
  elif [ "$age_h" -gt "$DUMP_MAX_AGE_H" ]; then
    fail "dump is ${age_h}h old (> ${DUMP_MAX_AGE_H}h) -- the timer is not running"
  else
    ok "dump is ${age_h}h old (<= ${DUMP_MAX_AGE_H}h)"
  fi

  local dev verdict any=0
  while read -r dev verdict; do
    case "$dev" in ''|\#*) continue ;; esac
    any=1
    case "$verdict" in
      PASSED) ok "/dev/$dev SMART self-assessment PASSED" ;;
      FAILED) fail "/dev/$dev SMART FAILING -- back up now and replace the drive" ;;
      *)      skip "/dev/$dev -- dump could not interpret smartctl output" ;;
    esac
  done < "$DUMP_FILE"
  [ "$any" -eq 1 ] || fail "dump contains no disks at all -- something is wrong with the helper"

  # 4. every disk present NOW is covered by the dump (a drive added
  #    after the last elapse isn't checked yet -- say so).
  while read -r dev; do
    [ -n "$dev" ] || continue
    grep -q "^$dev " "$DUMP_FILE" \
      || skip "/dev/$dev present but not in the dump yet -- covered after the next timer run"
  done <<< "$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')"

  finish_verify "OK -- SMART dump fresh and every drive passing."
}

case "${1:-}" in
  enable)  shift; parse_common_args "$@"; enable_ ;;
  disable) disable_ ;;
  verify)  shift; parse_common_args "$@"; verify_ ;;
  *) die "usage: $0 enable|disable|verify [-q]" ;;
esac
