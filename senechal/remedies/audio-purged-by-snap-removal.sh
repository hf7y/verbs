#!/usr/bin/env bash
# senechal: restore the audio stack `apt-get purge -y firefox snapd
# libsnapd-glib-2-1` took out on 2026-08-23 19:13 -- ubuntustudio-desktop
# Recommends firefox, and pipewire/wireplumber/plasma-pa were only auto-installed
# under those metapackages. Reinstalling is NOT enough: the stack comes up
# looking perfect and still SIGKILLs itself when anything plays -- see below.
#
#   ./audio-purged-by-snap-removal.sh enable    # reinstall + start (sudo)
#   ./audio-purged-by-snap-removal.sh verify    # non-AI, cron-safe
PRIVILEGED=yes
HOSTS=(mandark)
REACHES=()
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

PKGS="pipewire pipewire-bin pipewire-pulse pipewire-alsa pipewire-jack
      pipewire-audio libpipewire-0.3-modules wireplumber libwireplumber-0.4-0
      rtkit plasma-pa pavucontrol-qt libcanberra-pulse
      ubuntustudio-pipewire-config pulseaudio-utils"

# pulseaudio-utils is CLIENT tools only; pipewire-pulse serves the protocol.

# The METApackages are the firefox coupling; their content is kept without them.
FORBIDDEN_PKGS="ubuntustudio-desktop ubuntustudio-audio ubuntustudio-audio-core"

USER_UNITS="pipewire pipewire-pulse wireplumber"

SUDO_CMD="${SENECHAL_SUDO_CMD-sudo}"

# --show, NOT --list: --list scans only ~/.local/share/plasma/plasmoids.
volume_applet_present() {
  kpackagetool5 --type Plasma/Applet --show org.kde.plasma.volume >/dev/null 2>&1
}

# A sink, not a service: pipewire runs active and healthy with zero sinks.
sink_count() { pactl list short sinks 2>/dev/null | grep -c .; }

# --- the zero realtime budget ------------------------------------------
# THE FAULT THAT SURVIVES THE REINSTALL. module-rt asks RTKit for realtime and
# leaves RLIMIT_RTTIME at 0, so the kernel SIGKILLs any thread the instant it
# does real RT work: idle survives, playing a sound is fatal. Only module-rt
# loaders had 0 while dbus and the login shell had "unlimited" -- the unit's
# LimitRTTIME=infinity is true and irrelevant, since the module lowers it
# in-process after exec, so read /proc/PID/limits, never the unit. conf.d cannot
# fix it: fragments append so a second module-rt never loads, and the first
# already set the HARD limit to 0, which needs CAP_SYS_RESOURCE to raise. Hence
# full overrides, regenerated from the installed config.
RT_CONF_SRCS="/usr/share/pipewire/pipewire.conf
/usr/share/pipewire/pipewire-pulse.conf
/usr/share/pipewire/client-rt.conf
/usr/share/wireplumber/wireplumber.conf"

rt_conf_dst() { # <src> -- where the user override for this file lives
  case "$1" in
    */wireplumber/*) printf '%s/wireplumber/%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}" "$(basename "$1")" ;;
    *)               printf '%s/pipewire/%s\n'    "${XDG_CONFIG_HOME:-$HOME/.config}" "$(basename "$1")" ;;
  esac
}

# Uncomment rt.time and drop RTKit; the grep proves the edit actually landed.
rt_patch() { # <src> <dst>
  local src="$1" dst="$2"
  [ -f "$src" ] || return 1
  mkdir -p "$(dirname "$dst")" || return 1
  sed -e 's/^\([[:space:]]*\)#rt\.time\.soft.*/\1rt.time.soft = 200000\n\1rlimits.enabled = true\n\1rtkit.enabled = false\n\1rtportal.enabled = false/' \
      -e 's/^\([[:space:]]*\)#rt\.time\.hard.*/\1rt.time.hard = 200000/' \
      "$src" > "$dst" || return 1
  grep -q '^[[:space:]]*rtkit\.enabled = false' "$dst"
}

rt_budget() { # <unit>
  local pid
  pid="$(systemctl --user show "$1" -p MainPID --value 2>/dev/null)"
  [ -n "$pid" ] && [ "$pid" != 0 ] || return 1
  awk '/Max realtime timeout/ {print $4; found=1} END {exit !found}' \
    "/proc/$pid/limits" 2>/dev/null
}

APPLET_META=/usr/share/plasma/plasmoids/org.kde.plasma.volume/metadata.json

# On disk is not in the tray: plasmashell loads plasmoids once at startup, so a
# shell predating the reinstall never shows it. CTIME (%Z), not mtime.
plasmashell_predates_applet() {
  local pid started landed
  pid="$(systemctl --user show plasma-plasmashell -p MainPID --value 2>/dev/null)"
  [ -n "$pid" ] && [ "$pid" != 0 ] || return 1
  [ -f "$APPLET_META" ] || return 1
  started="$(date -d "$(ps -o lstart= -p "$pid" 2>/dev/null)" +%s 2>/dev/null)" || return 1
  landed="$(stat -c %Z "$APPLET_META" 2>/dev/null)" || return 1
  [ -n "$started" ] && [ "$started" -lt "$landed" ]
}

do_enable() {
  local skipped=""
  say "senechal remedy: restore the audio stack purged with the snap removal"
  say ""
  say "1/3 reinstalling audio packages -- needs sudo, may prompt."
  # shellcheck disable=SC2086
  $SUDO_CMD apt-get install -y $PKGS || die "apt-get install failed"

  say ""
  say "2/3 marking the stack manually-installed, so removing another"
  say "    snap-era package cannot take it again (this is the real fix)."
  # shellcheck disable=SC2086
  $SUDO_CMD apt-mark manual $PKGS >/dev/null || warn "apt-mark manual failed"

  say ""
  say "3/4 giving the realtime threads a non-zero budget."
  local src dst
  for src in $RT_CONF_SRCS; do
    dst="$(rt_conf_dst "$src")"
    if rt_patch "$src" "$dst"; then
      say "    $(basename "$src") -> $dst"
    else
      warn "could not patch $src -- realtime budget may stay 0"
      skipped="$skipped $(basename "$src")"
    fi
  done

  say ""
  say "4/4 starting the user services."
  # shellcheck disable=SC2086
  systemctl --user daemon-reload 2>/dev/null
  # reset-failed FIRST: Restart=on-failure means a crash burst burns
  # StartLimitBurst and LATCHES the unit failed, after which plain `start` is
  # refused as "repeated too quickly". Only reset-failed clears it.
  # shellcheck disable=SC2086
  systemctl --user reset-failed $USER_UNITS 2>/dev/null
  # shellcheck disable=SC2086
  systemctl --user enable --now $USER_UNITS 2>/dev/null \
    || warn "could not start: $USER_UNITS"
  local u
  for u in $USER_UNITS; do
    systemctl --user is-active --quiet "$u" && say "    $u active" \
      || { warn "$u is not active"; skipped="$skipped $u"; }
  done

  for _ in 1 2 3 4 5; do [ "$(sink_count)" -gt 0 ] && break; sleep 1; done

  say ""
  say "COULD NOT DO FOR YOU: the tray icon needs plasmashell restarted."
  say "  Your panel still has org.kde.plasma.volume configured into the"
  say "  system tray -- it just could not load. Restarting picks it up:"
  say "      systemctl --user restart plasma-plasmashell"
  say "  The media keys come back with it; they are answered by the same"
  say "  plasma-pa the purge removed, not by the still-present bindings."
  if [ -n "$skipped" ]; then
    say ""
    say "ALSO NOT DONE:$skipped -- see 'journalctl --user -u <unit>'."
  fi
  say ""
  say "run: ./audio-purged-by-snap-removal.sh verify"
}

do_verify() {
  local missing="" p
  for p in $PKGS; do
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null)" = installed ] \
      || missing="$missing $p"
  done
  if [ -z "$missing" ]; then
    ok "audio packages are installed"
  else
    fail "purged audio packages still missing:$missing -- run: ./audio-purged-by-snap-removal.sh enable"
  fi

  local bad
  for bad in $FORBIDDEN_PKGS; do
    if [ "$(dpkg-query -W -f='${db:Status-Status}' "$bad" 2>/dev/null)" = installed ]; then
      fail "$bad is back -- it Recommends firefox, so removing the snap browser will purge sound again; run: sudo apt-get remove $bad"
    else
      ok "$bad is absent (the firefox->audio coupling, deliberately not restored)"
    fi
  done

  local u
  for u in $USER_UNITS; do
    if ! systemctl --user cat "$u" >/dev/null 2>&1; then
      fail "user unit $u does not exist -- the package is gone, not just stopped"
    elif systemctl --user is-active --quiet "$u"; then
      ok "$u is active"
    elif [ "$(systemctl --user is-failed "$u" 2>/dev/null)" = failed ]; then
      fail "$u is FAILED, likely having burned StartLimitBurst -- plain start is refused as 'repeated too quickly'; run: systemctl --user reset-failed $u && systemctl --user start $u"
    else
      fail "$u is not active (is-enabled would still say enabled) -- run: systemctl --user start $u"
    fi
  done

  local sinks
  sinks="$(sink_count)"
  if ! command -v pactl >/dev/null 2>&1; then
    fail "pactl is not installed (pulseaudio-utils) -- the sink count cannot be taken, which is not the same as there being no sinks"
  elif [ "$sinks" -gt 0 ]; then
    ok "pipewire is serving $sinks sink(s)"
  else
    fail "no audio sinks -- pactl sees nothing to play to, whatever the services say"
  fi

  # Nothing above catches this: the stack looks perfect until something plays.
  local unit budget
  for unit in $USER_UNITS; do
    if ! budget="$(rt_budget "$unit")"; then
      skip "could not read the realtime budget for $unit"
    elif [ "$budget" = 0 ]; then
      fail "$unit has RLIMIT_RTTIME=0 -- the kernel SIGKILLs it the instant anything plays, however healthy it looks now; run: ./audio-purged-by-snap-removal.sh enable"
    else
      ok "$unit realtime budget is $budget, not 0"
    fi
  done

  if id -nG | tr ' ' '\n' | grep -qx audio; then
    ok "$(id -un) is in @audio, so direct realtime is permitted"
  else
    fail "$(id -un) is NOT in @audio -- limits.d grants rtprio to that group, and the override takes RTKit out of the path, so realtime would be refused; run: sudo usermod -aG audio $(id -un), then log out and back in"
  fi

  # Not kglobalshortcutsrc/kglobalaccel: both describe working keys with no stack.
  if ! command -v kpackagetool5 >/dev/null 2>&1; then
    skip "kpackagetool5 not installed -- cannot ask Plasma for its applet list"
  elif ! volume_applet_present; then
    fail "Plasma cannot find org.kde.plasma.volume -- plasma-pa is missing, so the volume tray icon and the Volume Up/Down/Mute keys are dead despite still being bound in kglobalshortcutsrc"
  elif plasmashell_predates_applet; then
    fail "org.kde.plasma.volume is on disk but the running plasmashell started BEFORE it landed -- the tray icon is not loaded and the media keys are still dead; run: systemctl --user restart plasma-plasmashell"
  else
    ok "Plasma can load org.kde.plasma.volume and the running shell postdates it"
  fi

  # `apt-mark showauto` is silent about absent packages, so scope it.
  local auto installed=""
  for p in $PKGS; do
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null)" = installed ] \
      && installed="$installed $p"
  done
  if [ -z "${installed// /}" ]; then
    fail "none of the audio stack is installed, so there is nothing to pin -- the autoremove guard cannot be checked until enable has run"
  else
    # shellcheck disable=SC2086
    auto="$(apt-mark showauto $installed 2>/dev/null | tr '\n' ' ')"
    if [ -z "${auto// /}" ]; then
      ok "installed audio stack is marked manual -- a dependency cascade cannot purge it again"
    else
      fail "still marked auto (a future removal will repeat 2026-08-23): $auto"
    fi
  fi

  finish_verify "OK -- audio stack restored and pinned against dependency cascade."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
