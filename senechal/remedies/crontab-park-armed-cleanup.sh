#!/usr/bin/env bash
PRIVILEGED=yes
HOSTS=(monkey)
REACHES=()
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
. ../lib/common.sh

PARK_DIR="${SENECHAL_CRONTAB_PARK_DIR:-/root/crontab-park-2026-08-30}"
SUDO_CMD="${SENECHAL_SUDO_CMD-sudo}"

park_dir_is_redundant() {
  local d="$1" f u live extra
  for f in "$d"/*.cron; do
    [ -e "$f" ] || continue
    u="$(basename "$f" .cron)"
    live="$($SUDO_CMD crontab -l -u "$u" 2>/dev/null)" || live=""
    extra="$(diff <(printf '%s\n' "$live") "$f" 2>/dev/null | grep '^>' | grep -vc 'scheduler-managed')"
    [ "${extra:-0}" -eq 0 ] || return 1
  done
  return 0
}

do_enable() {
  if [ ! -d "$PARK_DIR" ]; then
    say "$PARK_DIR already gone -- nothing to do."
    exit 0
  fi
  if ! park_dir_is_redundant "$PARK_DIR"; then
    die "$PARK_DIR now holds lines no live crontab has -- #558's finding no longer holds, refusing to delete. Re-check by hand."
  fi
  say "removing $PARK_DIR ($(find "$PARK_DIR" -type f | wc -l) file(s), redundant with the live crontabs per #558)."
  $SUDO_CMD rm -rf "$PARK_DIR" || die "rm -rf $PARK_DIR failed"
  say "done."
}

do_verify() {
  if [ ! -d "$PARK_DIR" ]; then
    ok "$PARK_DIR does not exist"
    finish_verify "OK -- the armed park snapshot is gone."
    return
  fi
  if park_dir_is_redundant "$PARK_DIR"; then
    fail "$PARK_DIR still exists and is still redundant with the live crontabs -- run: ./crontab-park-armed-cleanup.sh enable"
  else
    fail "$PARK_DIR exists AND now differs from the live crontabs -- #558's finding no longer holds; this needs a human look, not enable"
  fi
  finish_verify "OK -- the armed park snapshot is gone."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
