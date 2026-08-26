#!/usr/bin/env bash
# senechal: stop unattended-upgrades from silently reinstalling snapd.
#
#   ./unattended-upgrades-firefox-snap.sh enable    # needs sudo, asks once
#   ./unattended-upgrades-firefox-snap.sh verify    # non-AI, cron-safe
#
# Root cause, confirmed from /var/log/apt/history.log: Zach ran
# `apt purge snapd` on 2026-08-16. On 2026-08-19 06:29:42,
# /usr/bin/unattended-upgrade ran (Allowed-Origins includes the plain
# "${distro_id}:${distro_codename}" pocket, not just -security) and
# upgraded firefox:amd64 from the real deb 153.0.4~build1 to
# 1:1snap1-0ubuntu5 -- Ubuntu's transitional firefox package, whose only
# job is to depend on snapd and reinstall Firefox as a snap. That one
# unattended run silently undid the purge. Symptom that surfaced it:
# Meta+W stopped launching Firefox because kglobalaccel's shortcut still
# pointed at the now-gone firefox.desktop id.
#
# Stage 1 (this script): block firefox and snapd specifically via
# Package-Blacklist, a narrow one-line-per-package regex list -- leaves
# Allowed-Origins untouched so ordinary security-origin auto-upgrades for
# everything else keep working exactly as before. Stage 2 (separate,
# deliberately not bundled here): decide how to get real Firefox back
# and whether Allowed-Origins itself needs narrowing.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

CONF="/etc/apt/apt.conf.d/50unattended-upgrades"
MARK="// senechal: block firefox/snapd auto-reinstall (see remedies/unattended-upgrades-firefox-snap.sh)"

do_enable() {
  say "senechal remedy: block unattended-upgrades from touching firefox/snapd"
  [ -f "$CONF" ] || die "$CONF not found -- is unattended-upgrades installed?"

  if grep -qF "$MARK" "$CONF"; then
    say "already applied -- nothing to do."
    say "run: ./unattended-upgrades-firefox-snap.sh verify"
    return
  fi

  local backup
  backup="$(backup_file "$CONF")" || die "backup failed, aborting before touching $CONF"
  say "backed up $CONF -> $backup"

  say "inserting firefox/snapd into Package-Blacklist (only that block, nothing else in the file changes)"
  sudo python3 - "$CONF" "$MARK" <<'PYEOF' || die "failed to edit $CONF"
import sys
path, mark = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.readlines()
out = []
inserted = False
for line in lines:
    out.append(line)
    if not inserted and line.strip() == "Unattended-Upgrade::Package-Blacklist {":
        out.append(f'    {mark}\n')
        out.append('    "^firefox$";\n')
        out.append('    "^snapd$";\n')
        inserted = True
if not inserted:
    sys.exit("Package-Blacklist block not found")
with open(path, "w") as f:
    f.writelines(out)
PYEOF

  say "done. Firefox and snapd are now excluded from unattended-upgrade runs."
  say ""
  say "Not done for you (Stage 2, needs your call):"
  say "  - Firefox is currently the snap again (installed 2026-08-19). Decide how"
  say "    you want it going forward (Mozilla's official apt repo, a .deb, or keep the snap)."
  say "  - Whether Allowed-Origins should be narrowed to -security only, which would"
  say "    cut off ALL non-security auto-upgrades, not just this one package pair."
  say ""
  say "run: ./unattended-upgrades-firefox-snap.sh verify"
}

do_verify() {
  if [ ! -f "$CONF" ]; then
    skip "$CONF not found -- cannot check"
    finish_verify
    return
  fi

  if grep -qF "$MARK" "$CONF" \
     && grep -qF '"^firefox$"' "$CONF" \
     && grep -qF '"^snapd$"' "$CONF"; then
    ok "unattended-upgrades Package-Blacklist excludes firefox and snapd"
  else
    fail "firefox/snapd are not blacklisted in $CONF -- run: ./unattended-upgrades-firefox-snap.sh enable"
  fi

  finish_verify "OK -- unattended-upgrades can no longer silently reinstall snapd via firefox."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
