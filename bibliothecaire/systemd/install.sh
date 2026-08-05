#!/usr/bin/env bash
# Install the bibliothecaire intake timer on mandark.
#
#   sudo systemd/install.sh             install + enable + start
#   sudo systemd/install.sh --verify    check, change nothing
#   sudo systemd/install.sh --uninstall
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="/etc/systemd/system"
UNITS=(bibliothecaire-intake.service bibliothecaire-intake.timer
       bibliothecaire-intake-health.service bibliothecaire-intake-health.timer
       bibliothecaire-intake-ocr.service bibliothecaire-intake-ocr.timer)
TIMERS=(bibliothecaire-intake.timer bibliothecaire-intake-health.timer
        bibliothecaire-intake-ocr.timer)

die() { echo "[FAIL] $*" >&2; exit 1; }
ok()  { echo "[ok] $*"; }
OWNER="${SUDO_USER:-zach}"

# sudo resets PATH to secure_path, which excludes ~/.local/bin -- where
# realisateur installs the ecosystem guards. Looking for notify-senechal
# on root's PATH finds nothing and silently skips the notification, which
# is a guard that fails quietly: the worst kind. Resolve it through the
# owner's own login shell instead, and treat "still not found" as a
# finding rather than a shrug.
find_notify() {
  local p
  p="$(sudo -u "$OWNER" bash -lc 'command -v notify-senechal' 2>/dev/null || true)"
  [[ -n "$p" && -x "$p" ]] && { echo "$p"; return 0; }
  for p in "/home/$OWNER/.local/bin/notify-senechal" /usr/local/bin/notify-senechal; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

pay_senechal() {
  local note="$1" bin
  if bin="$(find_notify)"; then
    # `sudo -u` does not load a login shell, so the callee inherits root's
    # secure_path and cannot find ITS own guards -- notify-senechal went
    # looking for focus-commit, missed it, and fell back to a bare git
    # sequence it exists to replace. Hand the owner's bin dir down
    # explicitly rather than hoping.
    if sudo -u "$OWNER" env "PATH=/home/$OWNER/.local/bin:/usr/local/bin:/usr/bin:/bin" \
         "$bin" "$note"; then
      ok "senechal told (via $bin)"
    else
      echo "[WARN] notify-senechal FAILED -- senechal does NOT know this machine config exists." >&2
      echo "[WARN] Re-run by hand: notify-senechal '<what changed, where, who owns it>'" >&2
    fi
  else
    echo "[FAIL] notify-senechal not found for user $OWNER -- a missing guard is a finding," >&2
    echo "[FAIL] not an inconvenience. senechal has NOT been told about this config." >&2
  fi
}


MODE="install"
[[ "${1:-}" == "--verify" ]] && MODE="verify"
[[ "${1:-}" == "--uninstall" ]] && MODE="uninstall"
[[ $EUID -eq 0 ]] || die "must run as root"

if [[ "$MODE" == "verify" ]]; then
  rc=0
  for u in "${UNITS[@]}"; do
    [[ -f "$UNIT_DIR/$u" ]] || { echo "[FAIL] $UNIT_DIR/$u absent" >&2; rc=1; continue; }
    # Deploy drift fails loud: an installed unit that no longer matches
    # the repo is a unit nobody can reason about from the repo.
    diff -q "$REPO/systemd/$u" "$UNIT_DIR/$u" >/dev/null \
      || { echo "[FAIL] $u installed copy has DRIFTED from $REPO/systemd/$u" >&2; rc=1; }
  done
  for t in "${TIMERS[@]}"; do
    systemctl is-enabled --quiet "$t" \
      || { echo "[FAIL] $t not enabled -- built but not wired" >&2; rc=1; }
    systemctl is-active --quiet "$t" \
      || { echo "[FAIL] $t not active" >&2; rc=1; }
  done
  [[ $rc -eq 0 ]] && ok "intake timers installed, enabled, active, and matching the repo"
  exit $rc
fi

if [[ "$MODE" == "uninstall" ]]; then
  for t in "${TIMERS[@]}"; do systemctl disable --now "$t" 2>/dev/null || true; done
  for u in "${UNITS[@]}"; do rm -f "$UNIT_DIR/$u"; done
  systemctl daemon-reload
  ok "intake timer removed (the samba share is separate: smb/install-intake-share.sh --uninstall)"
  exit 0
fi

for u in "${UNITS[@]}"; do
  install -m 0644 "$REPO/systemd/$u" "$UNIT_DIR/$u"
  ok "installed $UNIT_DIR/$u"
done
systemctl daemon-reload
for t in "${TIMERS[@]}"; do
  systemctl enable --now "$t"
  ok "$t enabled and started"
done
systemctl list-timers "${TIMERS[@]}" --no-pager || true

# Wired, not just built: prove it end to end right now rather than
# waiting for 10:00 tomorrow to find out the unit does not run.
echo
echo "--- first healthcheck (this is the witness, not the install log) ---"
systemctl start bibliothecaire-intake-health.service || true
sudo -u "$OWNER" "$REPO/bin/intake.py" --healthcheck --no-freshness || \
  echo "[WARN] healthcheck is red -- the timers are installed, but the pipeline is NOT yet working end to end. The output above says which part." >&2

pay_senechal "mandark: systemd units bibliothecaire-intake.service/.timer (15-min drain of the scanner SMB drop box; deletes originals only after proving gardien on dexter has them) and bibliothecaire-intake-health.service/.timer (daily 10:00 healthcheck that re-probes the live system and notifies senechal + desktop when degraded) installed in /etc/systemd/system. Owned by the bibliothecaire project (~/Documents/Projects/bibliothecaire, systemd/install.sh --verify/--uninstall)."
