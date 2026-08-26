#!/usr/bin/env bash
# senechal: narrow unattended-upgrades to security-origin packages only.
#
#   ./unattended-upgrades-security-only.sh enable    # needs sudo, asks once
#   ./unattended-upgrades-security-only.sh verify    # non-AI, cron-safe
#
# Root cause (see remedies/unattended-upgrades-firefox-snap.sh for the
# full incident): Allowed-Origins included the plain
# "${distro_id}:${distro_codename}" pocket (all of noble's main archive,
# not just security patches). That is what let an ordinary version bump
# of firefox -- Ubuntu's transitional snap-wrapper package -- through
# unattended-upgrade and silently reinstall snapd, three days after Zach
# purged it. Package-Blacklist closes the hole for firefox/snapd
# specifically; this closes it for every package: only origins with
# "-security" (or ESM security) in the pocket name stay allowed, so
# unattended-upgrades only ever applies security patches unattended --
# ordinary feature/version-bump upgrades from noble/noble-updates now
# require a manual `apt upgrade`, same as they always should have.
#
# Comments out one line in the existing Allowed-Origins block; every
# other line (the -security and ESM entries, and the already-commented
# -updates/-proposed/-backports lines) is left exactly as-is.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

CONF="/etc/apt/apt.conf.d/50unattended-upgrades"
TARGET_LINE='	"${distro_id}:${distro_codename}";'
MARK="// senechal: disabled -- see remedies/unattended-upgrades-security-only.sh (2026-08-19 snapd-came-back incident)"

do_enable() {
  say "senechal remedy: restrict unattended-upgrades to -security origins"
  [ -f "$CONF" ] || die "$CONF not found -- is unattended-upgrades installed?"

  if grep -qF "$MARK" "$CONF"; then
    say "already applied -- nothing to do."
    say "run: ./unattended-upgrades-security-only.sh verify"
    return
  fi

  if ! grep -qxF "$TARGET_LINE" "$CONF"; then
    die "expected line not found verbatim in $CONF -- refusing to guess, edit by hand: $TARGET_LINE"
  fi

  local backup
  backup="$(backup_file "$CONF")" || die "backup failed, aborting before touching $CONF"
  say "backed up $CONF -> $backup"

  say "commenting out the plain noble (non-security) origin line"
  sudo python3 - "$CONF" "$TARGET_LINE" "$MARK" <<'PYEOF' || die "failed to edit $CONF"
import sys
path, target, mark = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    lines = f.readlines()
out, done = [], False
for line in lines:
    if not done and line.rstrip("\n") == target:
        out.append(f"//{target}  {mark}\n")
        done = True
    else:
        out.append(line)
if not done:
    sys.exit("target line not found during rewrite")
with open(path, "w") as f:
    f.writelines(out)
PYEOF

  say "done. unattended-upgrades will now only auto-apply -security (and ESM-security) origins."
  say ""
  say "Not done for you: ordinary version bumps (feature releases, non-security"
  say "packages from noble/noble-updates) will now need your own \`apt upgrade\`."
  say "run: ./unattended-upgrades-security-only.sh verify"
}

do_verify() {
  if [ ! -f "$CONF" ]; then
    skip "$CONF not found -- cannot check"
    finish_verify
    return
  fi

  if grep -qF "$MARK" "$CONF"; then
    ok "plain (non-security) noble origin is disabled in Allowed-Origins"
  else
    fail "plain noble origin is still allowed in $CONF -- run: ./unattended-upgrades-security-only.sh enable"
  fi

  if grep -qF '"${distro_id}:${distro_codename}-security";' "$CONF"; then
    ok "security origin is still allowed (unattended-upgrades still patches CVEs)"
  else
    fail "security origin line is missing from $CONF -- this should not have been touched, check the backup"
  fi

  finish_verify "OK -- unattended-upgrades is security-only."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
