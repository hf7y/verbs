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
. "$REPO_DIR/systemd/units.sh"
# Overridable so a test can stub it instead of touching this host's real
# systemd --user state, same idea as fauche's FAUCHE_SYSTEMCTL.
SYSTEMCTL="${GARDE_SYSTEMCTL:-systemctl}"
# `bin/garde` execs straight into this script (gardien#164), so --json
# cannot be parsed here the normal verb.sh way -- there is no verb.sh in
# a POSIX /bin/sh script. GARDE_JSON is the same env-var handoff gardien.py
# already uses (GARDIEN_REPO/GARDIEN_CONFIG) for a wrapped script that
# doesn't share the bash runtime.
JSON="${GARDE_JSON:-0}"

mkdir -p "$UNIT_DIR"
for unit in $UNITS; do
    cp "$REPO_DIR/systemd/$unit" "$UNIT_DIR/$unit"
done

"$SYSTEMCTL" --user daemon-reload
# All three timers install together on purpose: a backup schedule
# shouldn't exist without something watching whether it actually fires
# (check-stale, 09:00 daily -- the failure mode gardien.timer itself
# cannot report, since a timer that never fires logs nothing) or without
# its cross-host git hygiene sensing (git-hygiene, 09:05 daily,
# read-only) running alongside it.
for timer in $TIMERS; do
    "$SYSTEMCTL" --user enable --now "$timer"
done

if [ "$JSON" = 1 ]; then
    jq -n --arg units "$UNITS" --arg timers "$TIMERS" \
      '{ok: true, units: ($units | split(" ")), timers: ($timers | split(" "))}'
else
    echo "$TIMERS installed and enabled. Check with:"
    echo "  systemctl --user list-timers 'gardien*'"
    echo "  systemctl --user status gardien.service gardien-check-stale.service gardien-git-hygiene.service"
    echo "  journalctl --user -u gardien.service -u gardien-check-stale.service -u gardien-git-hygiene.service"
fi
