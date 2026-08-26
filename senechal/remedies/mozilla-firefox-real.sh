#!/usr/bin/env bash
# senechal: replace the snap firefox with Mozilla's official .deb, and
# purge snapd again -- Stage 2 of the Meta+W / snapd-came-back incident.
#
#   ./mozilla-firefox-real.sh enable    # needs sudo, asks once
#   ./mozilla-firefox-real.sh verify    # non-AI, cron-safe
#
# Context: Zach purged snapd on 2026-08-16. On 2026-08-19 06:29:42,
# unattended-upgrade upgraded firefox:amd64 from the real Mozilla-repo
# deb (153.0.4~build1, installed 2026-08-08 from the official
# packages.mozilla.org repo already configured on this box with
# Pin-Priority 1000) to Ubuntu's transitional package
# (1:1snap1-0ubuntu5), whose epoch ("1:") appears to have beaten the
# Mozilla pin during that automatic run and dragged snapd back in as a
# dependency. remedies/unattended-upgrades-firefox-snap.sh +
# unattended-upgrades-security-only.sh close the hole that let this
# happen unattended; this script undoes the actual damage: snap firefox
# and firefox's snap runtime deps (bare, core24, gnome-46-2404,
# gtk-common-themes, mesa-2404) are only used by the firefox snap on
# this box -- confirmed via `snap list` and `apt-cache rdepends snapd`
# (no reverse deps) before writing this.
#
# Also repoints the KDE Meta+W global shortcut, which broke because
# kglobalaccel had it bound to the firefox.desktop id that stopped
# existing once firefox became a snap (snap's id is
# firefox_firefox.desktop). After this script, real firefox.desktop
# comes back and the shortcut is rebound to it.
#
# Lesson from the first run of this script (2026-08-23): migrating the
# profile directory is not enough. Each distinct Firefox install path
# gets its own entry in installs.ini / the [InstallXXXXXXXX] section of
# profiles.ini, recording which profile THAT install defaults to --
# separate from profiles.ini's own Default=1 flag. The deb install is a
# new install path, so the first time it ran it created a brand new
# empty profile and pointed its own install-hash default at that, not at
# the migrated profile -- Firefox opened looking nothing like the old
# browser even though the real data was sitting right there untouched.
# Step 4 below forces that first run under senechal's control and then
# corrects the install-hash default itself, instead of leaving it to
# whatever launches Firefox first (a user click, a session-restore
# autostart) with no one watching.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

SHORTCUTS_CONF="$HOME/.config/kglobalshortcutsrc"
SNAP_PROFILE_DIR="$HOME/snap/firefox/common/.mozilla/firefox"
DEB_PROFILE_DIR="$HOME/.mozilla/firefox"

do_enable() {
  say "senechal remedy: real Firefox back from Mozilla's repo, snap/snapd out again"

  if [ -d "$SNAP_PROFILE_DIR" ]; then
    say "0/5 migrating your live profile (bookmarks/logins/history/extensions) out of the snap"
    say "    before it's deleted -- the deb build reads ~/.mozilla/firefox, which currently"
    say "    holds a stale pre-snap-switch copy."
    pkill -x firefox 2>/dev/null && { say "    closed running Firefox first."; sleep 1; }
    if [ -d "$DEB_PROFILE_DIR" ]; then
      local stale_backup
      stale_backup="$(backup_file "$DEB_PROFILE_DIR" 2>/dev/null || true)"
      if [ -z "$stale_backup" ]; then
        stale_backup="$HOME/.mozilla-firefox-stale-backup-$(date +%Y%m%d%H%M%S)"
        cp -a "$DEB_PROFILE_DIR" "$stale_backup"
      fi
      say "    backed up the stale deb profile -> $stale_backup"
    fi
    mkdir -p "$HOME/.mozilla"
    rsync -a --delete "$SNAP_PROFILE_DIR/" "$DEB_PROFILE_DIR/" \
      || die "profile migration failed -- aborting before touching the snap, nothing else changed"
    say "    done -- $DEB_PROFILE_DIR now mirrors the snap's live profile."

    MIGRATED_PROFILE="$(python3 -c '
import configparser, sys
c = configparser.ConfigParser()
c.read(sys.argv[1])
for s in c.sections():
    if s.startswith("Profile") and c.get(s, "Default", fallback="") == "1":
        print(c.get(s, "Path"))
        break
' "$DEB_PROFILE_DIR/profiles.ini")"
    [ -n "$MIGRATED_PROFILE" ] || die "could not identify the migrated default profile from $DEB_PROFILE_DIR/profiles.ini -- aborting before touching the snap"
    say "    migrated default profile: $MIGRATED_PROFILE"
  else
    warn "no snap profile found at $SNAP_PROFILE_DIR -- skipping migration, deb Firefox will use whatever is already at $DEB_PROFILE_DIR"
  fi

  say ""
  say "1/6 removing the firefox snap and its runtime bases (bare, core24, gnome-46-2404, gtk-common-themes, mesa-2404)"
  say "    this needs sudo -- you may be prompted for your password."
  sudo snap remove --purge firefox 2>&1 | sed 's/^/    /'
  for base in gnome-46-2404 gtk-common-themes mesa-2404 core24 bare; do
    sudo snap remove --purge "$base" 2>/dev/null | sed 's/^/    /' || true
  done

  say ""
  say "2/6 purging the Ubuntu transitional firefox deb and snapd"
  sudo apt-get purge -y firefox snapd libsnapd-glib-2-1:amd64 libsnapd-glib-2-1:i386 2>&1 | tail -20
  sudo apt-get autoremove --purge -y 2>&1 | tail -20

  say ""
  say "3/6 reinstalling firefox -- Mozilla's repo (Pin-Priority 1000 in"
  say "    /etc/apt/preferences.d/mozilla) is already configured, so a clean"
  say "    install resolves to their build, not Ubuntu's transitional package."
  sudo apt-get update >/tmp/senechal-mozilla-firefox-update.log 2>&1 \
    || warn "apt-get update reported problems -- see /tmp/senechal-mozilla-firefox-update.log"
  sudo apt-get install -y firefox || die "apt-get install firefox failed"

  local origin
  origin="$(apt-cache policy firefox | awk '/\*\*\*/{getline; print $2; exit}')"
  case "$origin" in
    *packages.mozilla.org*) say "    confirmed: installed from packages.mozilla.org" ;;
    *) warn "installed firefox but its origin looks like '$origin', not packages.mozilla.org -- check apt-cache policy firefox" ;;
  esac

  if [ -n "${MIGRATED_PROFILE:-}" ]; then
    say ""
    say "4/6 forcing Firefox's first run under our control, so its new install-hash"
    say "    default gets pointed at the migrated profile, not a fresh empty one"
    pkill -x firefox 2>/dev/null
    sleep 1
    timeout 8 firefox --headless -P "$MIGRATED_PROFILE" --no-remote >/dev/null 2>&1
    pkill -x firefox 2>/dev/null
    sleep 1

    python3 -c '
import configparser, sys
profiles_ini, installs_ini, migrated = sys.argv[1], sys.argv[2], sys.argv[3]

for path in (profiles_ini, installs_ini):
    c = configparser.RawConfigParser()
    c.read(path)
    changed = False
    for s in c.sections():
        if (s.startswith("Install") or path == installs_ini) and c.has_option(s, "Default"):
            if c.get(s, "Default") != migrated:
                c.set(s, "Default", migrated)
                changed = True
    if changed:
        with open(path, "w") as f:
            c.write(f, space_around_delimiters=False)
' "$DEB_PROFILE_DIR/profiles.ini" "$DEB_PROFILE_DIR/installs.ini" "$MIGRATED_PROFILE" \
      || warn "could not verify/correct the install-hash default -- check $DEB_PROFILE_DIR/profiles.ini and installs.ini by hand"
    say "    install-hash default now points at $MIGRATED_PROFILE"
  fi

  say ""
  say "5/6 repointing the Meta+W shortcut at the real firefox.desktop"
  if [ -f "$SHORTCUTS_CONF" ] && command -v kwriteconfig5 >/dev/null 2>&1; then
    backup_file "$SHORTCUTS_CONF" >/dev/null
    kwriteconfig5 --file kglobalshortcutsrc --group firefox_firefox.desktop --key _launch --delete
    kwriteconfig5 --file kglobalshortcutsrc --group firefox_firefox.desktop --key _k_friendly_name --delete
    kwriteconfig5 --file kglobalshortcutsrc --group firefox.desktop --key _launch "Meta+W,none,Firefox Web Browser"
    if command -v kquitapp5 >/dev/null 2>&1 && pgrep -x kglobalaccel5 >/dev/null; then
      kquitapp5 kglobalaccel 2>/dev/null
      sleep 1
      # cd $HOME first: kglobalaccel is what fork/execs every _launch
      # shortcut, so whatever cwd it inherits becomes the cwd of every app
      # it starts. Restarting it from remedies/ made Meta+T open kitty in
      # remedies/ (2026-08-23).
      (cd "$HOME" && kglobalaccel5 >/dev/null 2>&1 &)
      sleep 1
      say "    kglobalaccel restarted so it re-reads the shortcut."
    else
      warn "kglobalaccel5 not running or kquitapp5 missing -- log out/in to pick up the new shortcut."
    fi
  else
    warn "no $SHORTCUTS_CONF or no kwriteconfig5 -- skipping the shortcut fix (not a KDE session?)"
  fi

  say ""
  say "6/6 done."
  say "run: ./mozilla-firefox-real.sh verify"
}

do_verify() {
  if [ -f "$DEB_PROFILE_DIR/profiles.ini" ] && grep -q '^Default=1$' "$DEB_PROFILE_DIR/profiles.ini" 2>/dev/null; then
    ok "$DEB_PROFILE_DIR has a profiles.ini with a default profile"
  else
    fail "$DEB_PROFILE_DIR/profiles.ini missing or has no default profile -- profile migration did not land, check the stale-backup"
  fi

  if [ -f "$DEB_PROFILE_DIR/profiles.ini" ] && [ -f "$DEB_PROFILE_DIR/installs.ini" ]; then
    local mismatch
    mismatch="$(python3 -c '
import configparser, sys
profiles_ini, installs_ini = sys.argv[1], sys.argv[2]

pc = configparser.ConfigParser()
pc.read(profiles_ini)
default_profile = ""
for s in pc.sections():
    if s.startswith("Profile") and pc.get(s, "Default", fallback="") == "1":
        default_profile = pc.get(s, "Path")
        break

for path in (profiles_ini, installs_ini):
    c = configparser.RawConfigParser()
    c.read(path)
    for s in c.sections():
        if (s.startswith("Install") or path == installs_ini) and c.has_option(s, "Default"):
            if c.get(s, "Default") != default_profile:
                got = c.get(s, "Default")
                print(f"{path}:{s}={got} (expected {default_profile})")
' "$DEB_PROFILE_DIR/profiles.ini" "$DEB_PROFILE_DIR/installs.ini")"
    if [ -z "$mismatch" ]; then
      ok "install-hash default profile matches profiles.ini's Default=1 profile"
    else
      fail "install-hash default profile mismatch ($mismatch) -- Firefox will open the wrong profile; run: ./mozilla-firefox-real.sh enable"
    fi
  fi

  if command -v snap >/dev/null 2>&1 && snap list firefox >/dev/null 2>&1; then
    fail "firefox is still installed as a snap -- run: ./mozilla-firefox-real.sh enable"
  else
    ok "firefox is not a snap"
  fi

  if dpkg -s snapd >/dev/null 2>&1; then
    fail "snapd is still installed -- run: ./mozilla-firefox-real.sh enable"
  else
    ok "snapd is not installed"
  fi

  local ffpkg
  ffpkg="$(dpkg-query -W -f='${Version}' firefox 2>/dev/null || true)"
  case "$ffpkg" in
    1:*) fail "installed firefox package version ($ffpkg) is still Ubuntu's transitional package -- run: ./mozilla-firefox-real.sh enable" ;;
    "") fail "firefox is not installed at all -- run: ./mozilla-firefox-real.sh enable" ;;
    *) ok "firefox package version ($ffpkg) is a real build, not the transitional epoch" ;;
  esac

  if [ -f /usr/share/applications/firefox.desktop ]; then
    ok "/usr/share/applications/firefox.desktop exists"
  else
    fail "/usr/share/applications/firefox.desktop is missing -- Meta+W has nothing valid to point at"
  fi

  if [ -f "$SHORTCUTS_CONF" ]; then
    if grep -qF '[firefox.desktop]' "$SHORTCUTS_CONF" && grep -A2 '^\[firefox\.desktop\]' "$SHORTCUTS_CONF" | grep -q '^_launch=Meta+W'; then
      ok "Meta+W is bound to firefox.desktop in $SHORTCUTS_CONF"
    else
      fail "Meta+W is not bound to firefox.desktop in $SHORTCUTS_CONF -- run: ./mozilla-firefox-real.sh enable"
    fi
  else
    skip "$SHORTCUTS_CONF not found -- not a KDE session, cannot check the shortcut"
  fi

  finish_verify "OK -- real Firefox from Mozilla's repo, snapd gone, Meta+W rebound."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
