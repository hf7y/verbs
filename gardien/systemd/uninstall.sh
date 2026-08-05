#!/bin/sh
# Undo install.sh: disable the timer and remove the installed unit files.
#
# Does not touch gardien.json, any RAID snapshots, or the repo itself --
# only the systemd --user units this script's counterpart installed.
set -eu

UNIT_DIR="${HOME}/.config/systemd/user"

for timer in gardien.timer gardien-check-stale.timer gardien-git-hygiene.timer; do
    systemctl --user disable --now "$timer" 2>/dev/null || true
done
rm -f "$UNIT_DIR/gardien.service" "$UNIT_DIR/gardien.timer" \
      "$UNIT_DIR/gardien-check-stale.service" "$UNIT_DIR/gardien-check-stale.timer" \
      "$UNIT_DIR/gardien-git-hygiene.service" "$UNIT_DIR/gardien-git-hygiene.timer"
systemctl --user daemon-reload

echo "gardien.timer + gardien-check-stale.timer + gardien-git-hygiene.timer disabled and unit files removed from $UNIT_DIR."
