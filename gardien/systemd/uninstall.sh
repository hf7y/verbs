#!/bin/sh
# Undo install.sh: disable the timer and remove the installed unit files.
#
# Does not touch gardien.json, any RAID snapshots, or the repo itself --
# only the systemd --user units this script's counterpart installed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UNIT_DIR="${HOME}/.config/systemd/user"
. "$SCRIPT_DIR/units.sh"
SYSTEMCTL="${GARDE_SYSTEMCTL:-systemctl}"
# See install.sh's counterpart comment: GARDE_JSON is how bin/garde
# hands --json through its exec into this POSIX-sh script (gardien#164).
JSON="${GARDE_JSON:-0}"

for timer in $TIMERS; do
    "$SYSTEMCTL" --user disable --now "$timer" 2>/dev/null || true
done
for unit in $UNITS; do
    rm -f "$UNIT_DIR/$unit"
done
"$SYSTEMCTL" --user daemon-reload

if [ "$JSON" = 1 ]; then
    jq -n --arg timers "$TIMERS" --arg unit_dir "$UNIT_DIR" \
      '{ok: true, timers: ($timers | split(" ")), unit_dir: $unit_dir}'
else
    echo "$TIMERS disabled and unit files removed from $UNIT_DIR."
fi
