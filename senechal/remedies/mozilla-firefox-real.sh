#!/usr/bin/env bash
# senechal: replace the snap firefox with Mozilla's official .deb, and
# purge snapd again -- Stage 2 of the Meta+W / snapd-came-back incident.
#
#   ./mozilla-firefox-real.sh enable    # needs sudo, asks once
#   ./mozilla-firefox-real.sh verify    # non-AI, cron-safe
#
# Context: on 2026-08-19 unattended-upgrade flipped firefox:amd64 from
# Mozilla's pinned deb (153.0.4~build1, Pin-Priority 1000) to Ubuntu's
# transitional package -- its "1:" epoch beat the pin and dragged snapd
# back in. remedies/unattended-upgrades-firefox-snap.sh +
# -security-only.sh close the hole; this undoes the damage. snap
# firefox's runtime deps (bare, core24, gnome-46-2404, gtk-common-themes,
# mesa-2404) are used by no other snap on this box (confirmed via `snap
# list` / `apt-cache rdepends snapd`).
#
# Also rebinds KDE's Meta+W shortcut, which broke when kglobalaccel's
# firefox.desktop id became the snap's firefox_firefox.desktop.
#
# Lesson from the 2026-08-23 first run: migrating the profile directory
# alone is not enough -- each Firefox install path has its own
# install-hash default (installs.ini / profiles.ini's [InstallXXXXXXXX]),
# separate from profiles.ini's Default=1. A fresh deb install creates its
# own empty profile and points its install-hash at that instead of the
# migrated one. Step 4 forces that first run under senechal's control and
# corrects the install-hash default itself.
PRIVILEGED=yes
HOSTS=(mandark)
REACHES=()
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

BROWSER_MIMES=(x-scheme-handler/http x-scheme-handler/https text/html) # text/html: file:// via a file manager
FIREFOX_DESKTOP_ID="firefox.desktop"

desktop_file_path() { # <desktop-id> -> path on stdout; 1 if nowhere; checks XDG_DATA_HOME then XDG_DATA_DIRS
  local id="$1" dir
  local -a dirs=("${XDG_DATA_HOME:-$HOME/.local/share}")
  local -a extra
  IFS=: read -r -a extra <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  dirs+=("${extra[@]}")
  for dir in "${dirs[@]}"; do
    [ -n "$dir" ] || continue
    if [ -f "$dir/applications/$id" ]; then
      printf '%s\n' "$dir/applications/$id"
      return 0
    fi
  done
  return 1
}

desktop_exec_binary() { # <desktop-file-path> -> binary on stdout; 1 if Exec binary is gone (snap-purge residue)
  local f="$1" line bin
  line="$(grep -m1 '^Exec=' "$f" 2>/dev/null)" || return 1
  line="${line#Exec=}"
  bin="${line%% *}"
  [ -n "$bin" ] || return 1
  case "$bin" in
    /*) [ -x "$bin" ] && printf '%s\n' "$bin" && return 0; return 1 ;;
    *)  command -v "$bin" 2>/dev/null && return 0; return 1 ;;
  esac
}

mimeapps_declared_id() { # <mime> -> id on stdout; 1 if not declared
  # `xdg-mime query` never returns a dead id (falls through to [Added Associations]) -- read the file.
  local mime="$1" f="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
  [ -f "$f" ] || return 1
  awk -F= -v want="$mime" '
    /^\[/ { in_def = ($0 == "[Default Applications]"); next }
    in_def && $1 == want { sub(/;.*$/, "", $2); print $2; found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$f"
}

browser_handler_id() { # <default-web-browser|MIME> -> id on stdout; shared by enable and verify
  if [ "$1" = "default-web-browser" ]; then
    command -v xdg-settings >/dev/null 2>&1 || return 1
    xdg-settings get default-web-browser 2>/dev/null
  else
    command -v xdg-mime >/dev/null 2>&1 || return 1
    xdg-mime query default "$1" 2>/dev/null
  fi
}

SHORTCUTS_CONF="$HOME/.config/kglobalshortcutsrc"
SNAP_PROFILE_DIR="$HOME/snap/firefox/common/.mozilla/firefox"
DEB_PROFILE_DIR="$HOME/.mozilla/firefox"

do_enable() {
  say "senechal remedy: real Firefox back from Mozilla's repo, snap/snapd out again"

  if [ -d "$SNAP_PROFILE_DIR" ]; then
    say "0/7 migrating your live profile (bookmarks/logins/history/extensions) out of the snap"
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
  say "1/7 removing the firefox snap and its runtime bases (bare, core24, gnome-46-2404, gtk-common-themes, mesa-2404)"
  say "    this needs sudo -- you may be prompted for your password."
  sudo snap remove --purge firefox 2>&1 | sed 's/^/    /'
  for base in gnome-46-2404 gtk-common-themes mesa-2404 core24 bare; do
    sudo snap remove --purge "$base" 2>/dev/null | sed 's/^/    /' || true
  done

  say ""
  say "2/7 purging the Ubuntu transitional firefox deb and snapd"
  sudo apt-get purge -y firefox snapd libsnapd-glib-2-1:amd64 libsnapd-glib-2-1:i386 2>&1 | tail -20
  sudo apt-get autoremove --purge -y 2>&1 | tail -20

  say ""
  say "3/7 reinstalling firefox -- Mozilla's repo (Pin-Priority 1000 in"
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
    say "4/7 forcing Firefox's first run under our control, so its new install-hash"
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
  say "5/7 repointing the Meta+W shortcut at the real firefox.desktop"
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
  say "6/7 repointing any dead browser handler at $FIREFOX_DESKTOP_ID" # only dead ones; a working non-Firefox choice is left alone
  if ! command -v xdg-mime >/dev/null 2>&1; then
    warn "xdg-mime missing -- cannot check or repoint the URL handlers"
  elif ! desktop_file_path "$FIREFOX_DESKTOP_ID" >/dev/null; then
    warn "$FIREFOX_DESKTOP_ID is not installed -- nothing safe to repoint at"
  else
    local handler id hpath repointed=0
    for handler in default-web-browser "${BROWSER_MIMES[@]}"; do
      id="$(browser_handler_id "$handler" || true)"
      if [ -n "$id" ] && hpath="$(desktop_file_path "$id")" && desktop_exec_binary "$hpath" >/dev/null; then
        say "    $handler -> $id (alive, left alone)"
        continue
      fi
      if [ "$handler" = "default-web-browser" ]; then
        xdg-settings set default-web-browser "$FIREFOX_DESKTOP_ID" 2>/dev/null
      else
        xdg-mime default "$FIREFOX_DESKTOP_ID" "$handler" 2>/dev/null
      fi
      say "    $handler -> $FIREFOX_DESKTOP_ID (was ${id:-unset}, dead)"
      repointed=$((repointed + 1))
    done
    # xdg-settings only rewrites text/html, not the scheme handlers (observed 2026-09-02); hence each is set explicitly above.
    [ "$repointed" -eq 0 ] && say "    every handler already resolves -- nothing to repoint"
  fi

  say ""
  say "7/7 done."
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

  # Browser handlers, same residue class as Meta+W: dead nowhere-id, or dead Exec binary.
  local handler id hpath hbin
  if ! command -v xdg-mime >/dev/null 2>&1; then
    skip "xdg-mime not installed -- cannot check where a clicked URL would go"
  else
    for handler in default-web-browser "${BROWSER_MIMES[@]}"; do
      if ! id="$(browser_handler_id "$handler")" || [ -z "$id" ]; then
        fail "$handler names no handler at all -- a clicked URL goes nowhere"
        continue
      fi
      if ! hpath="$(desktop_file_path "$id")"; then
        fail "$handler names $id, which exists in no applications/ directory -- run: ./mozilla-firefox-real.sh enable"
      elif ! hbin="$(desktop_exec_binary "$hpath")"; then
        fail "$handler names $id ($hpath) whose Exec binary is gone -- run: ./mozilla-firefox-real.sh enable"
      else
        ok "$handler -> $id ($hbin)"
      fi

      case "$handler" in default-web-browser) continue ;; esac # rest is a mimeapps.list-only check, no per-browser default
      local declared
      if declared="$(mimeapps_declared_id "$handler")" && [ -n "$declared" ]; then
        if desktop_file_path "$declared" >/dev/null; then
          [ "$declared" = "$id" ] || note "  mimeapps.list declares $declared for $handler; the resolver answered $id"
        else
          fail "mimeapps.list declares $declared for $handler and no such .desktop exists -- xdg-mime hides this by falling through to $id; fix the line, do not trust the query"
        fi
      fi
    done
  fi

  finish_verify "OK -- real Firefox from Mozilla's repo, snapd gone, Meta+W rebound."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
