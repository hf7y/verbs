#!/bin/sh
# Install and enable the gardien nightly-backup systemd --user timer.
#
# Safe to run before gardien.json exists or the RAID is mounted: the
# timer will fire on schedule regardless, and gardien.py's own guard
# rails (missing config, unmounted RAID) make a misfire a loud, harmless
# no-op rather than a write to the wrong disk. Re-running this script is
# idempotent (systemctl enable is a no-op if already enabled).
set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="${HOME}/.config/systemd/user"

mkdir -p "$UNIT_DIR"
for unit in gardien.service gardien.timer \
            gardien-check-stale.service gardien-check-stale.timer \
            gardien-git-hygiene.service gardien-git-hygiene.timer; do
    cp "$REPO_DIR/systemd/$unit" "$UNIT_DIR/$unit"
done

systemctl --user daemon-reload
systemctl --user enable --now gardien.timer
# The freshness check (09:00 daily) is what notices when the 03:00 backup
# stops firing at all -- a failure mode gardien.timer itself cannot
# report, since a timer that never fires logs nothing. Installed together
# so a backup schedule can't exist without something watching it.
systemctl --user enable --now gardien-check-stale.timer
# The git hygiene report (09:05 daily) is read-only sensing across every
# host gardien already sweeps -- installed alongside the other two so it
# doesn't stay a manual-only, easy-to-forget flag.
systemctl --user enable --now gardien-git-hygiene.timer

echo "gardien.timer + gardien-check-stale.timer + gardien-git-hygiene.timer installed and enabled. Check with:"
echo "  systemctl --user list-timers 'gardien*'"
echo "  systemctl --user status gardien.service gardien-check-stale.service gardien-git-hygiene.service"
echo "  journalctl --user -u gardien.service -u gardien-check-stale.service -u gardien-git-hygiene.service"
