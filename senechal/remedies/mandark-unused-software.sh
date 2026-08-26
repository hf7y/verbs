#!/usr/bin/env bash
# senechal: remove software installed by hand on mandark and never used
# since -- confirmed by config/data-directory evidence, not just a
# binary's own atime (binary atime turned out unreliable during the
# 2026-08-11 audit -- dcpomatic, lilypond, openscad, sublime-text all
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

LOCALBIN_DIR="$HOME/.local/bin"
PLASMA_CONF="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"

# Remove "applications:$1" from every [section] launchers= line that has
# it. No-op (and silent) if the config or the token isn't there.
unpin_desktop_launcher() {
  local desktop_id="$1" token
  [ -n "$desktop_id" ] || return 0
  [ -f "$PLASMA_CONF" ] || return 0
  token="applications:$desktop_id"
  grep -qF "$token" "$PLASMA_CONF" 2>/dev/null || return 0

  local backed_up=0 sec cur new
  while IFS= read -r sec; do
    [ -n "$sec" ] || continue
    cur="$(ini_get "$PLASMA_CONF" "$sec" launchers)"
    case ",$cur," in
      *",$token,"*)
        if [ "$backed_up" -eq 0 ]; then
          local b; b="$(backup_file "$PLASMA_CONF")"
          [ -n "$b" ] && say "   backed up plasma panel config -> $b"
          backed_up=1
        fi
        new="$(printf '%s' "$cur" | awk -v t="$token" '
          BEGIN{RS=","; ORS=""}
          { if ($0 != t) { if (n++) printf ","; printf "%s", $0 } }
        ')"
        ini_set "$PLASMA_CONF" "$sec" launchers "$new"
        say "   unpinned $desktop_id from panel section [$sec]"
        ;;
    esac
  done < <(ini_sections_with_key "$PLASMA_CONF" launchers)
}

do_enable() {
  say "senechal remedy: remove unused mandark software"
  say "Registry: senechal.json's unused_software.items"
  say ""

  local any=0 name kind evidence desktop_id
  local -a apt_to_remove=()
  local -A desktop_id_of=()
  while IFS=$'\x1f' read -r name kind evidence desktop_id; do
    [ -n "$name" ] || continue
    any=1
    [ -n "$desktop_id" ] && desktop_id_of["$name"]="$desktop_id"
    case "$kind" in
      apt)
        if dpkg -l "$name" 2>/dev/null | grep -q '^ii'; then
          apt_to_remove+=("$name")
        else
          say "apt package $name already absent -- nothing to do."
          unpin_desktop_launcher "$desktop_id"
        fi
        ;;
      snap)
        if snap list "$name" >/dev/null 2>&1; then
          say "removing snap: $name"
          sudo snap remove "$name" || die "snap remove $name failed"
          unpin_desktop_launcher "$desktop_id"
        else
          say "snap $name already absent -- nothing to do."
          unpin_desktop_launcher "$desktop_id"
        fi
        ;;
      localbin)
        if [ -e "$LOCALBIN_DIR/$name" ]; then
          say "removing $LOCALBIN_DIR/$name"
          rm -f "$LOCALBIN_DIR/$name" || die "rm $LOCALBIN_DIR/$name failed"
          unpin_desktop_launcher "$desktop_id"
        else
          say "$LOCALBIN_DIR/$name already absent -- nothing to do."
          unpin_desktop_launcher "$desktop_id"
        fi
        ;;
      *)
        warn "unused_software item '$name' has unknown kind '$kind' (want apt|snap|localbin) -- skipped. Fix it in senechal.json."
        ;;
    esac
  done < <(cfg_unused_software)

  [ "$any" -eq 1 ] || say "unused_software.items is empty in senechal.json -- nothing registered. See senechal.json.example."

  if [ "${#apt_to_remove[@]}" -gt 0 ]; then
    say ""
    say "removing apt packages: ${apt_to_remove[*]} -- you may be prompted for your sudo password."
    sudo apt-get remove -y "${apt_to_remove[@]}" || die "apt-get remove failed"
    for name in "${apt_to_remove[@]}"; do
      unpin_desktop_launcher "${desktop_id_of[$name]:-}"
    done
  fi

  say ""
  say "run: ./mandark-unused-software.sh verify"
}

do_verify() {
  local any=0 name kind evidence desktop_id
  while IFS=$'\x1f' read -r name kind evidence desktop_id; do
    [ -n "$name" ] || continue
    any=1
    case "$kind" in
      apt)
        if dpkg -l "$name" 2>/dev/null | grep -q '^ii'; then
          fail "apt package $name still installed -- run: ./mandark-unused-software.sh enable"
        else
          ok "apt package $name is not installed"
        fi
        ;;
      snap)
        if snap list "$name" >/dev/null 2>&1; then
          fail "snap $name still installed -- run: ./mandark-unused-software.sh enable"
        else
          ok "snap $name is not installed"
        fi
        ;;
      localbin)
        if [ -e "$LOCALBIN_DIR/$name" ]; then
          fail "$LOCALBIN_DIR/$name still present -- run: ./mandark-unused-software.sh enable"
        else
          ok "$LOCALBIN_DIR/$name is not present"
        fi
        ;;
      *)
        skip "unused_software item '$name' has unknown kind '$kind' (want apt|snap|localbin) -- fix it in senechal.json"
        continue
        ;;
    esac
    if [ -n "$desktop_id" ]; then
      if [ -f "$PLASMA_CONF" ] && grep -qF "applications:$desktop_id" "$PLASMA_CONF" 2>/dev/null; then
        fail "$name is still pinned to the KDE panel (applications:$desktop_id in $PLASMA_CONF) -- run: ./mandark-unused-software.sh enable"
      else
        ok "$name is not pinned to the KDE panel"
      fi
    fi
  done < <(cfg_unused_software)

  [ "$any" -eq 1 ] || skip "unused_software.items is empty in senechal.json -- nothing registered to verify"

  finish_verify "OK -- every registered package in unused_software.items is removed."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
