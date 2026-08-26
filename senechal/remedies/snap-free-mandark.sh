#!/usr/bin/env bash
# senechal: replace mandark's four mechanically-swappable snaps with
# their native packages (hf7y/senechal#285, #286, #287, #288).
#
#   ./snap-free-mandark.sh enable    # install replacements, remove snaps (needs sudo)
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

CHARM_KEYRING=/etc/apt/keyrings/charm.gpg
CHARM_LIST=/etc/apt/sources.list.d/charm.list
TS_SNAP_STATE=/var/snap/tailscale/common/tailscaled.state
TS_DEB_STATE=/var/lib/tailscale/tailscaled.state
OBSIDIAN_RELEASES_API=https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest

# snap name -> the deb that replaces it. Read by both verbs, so they can
# never disagree about what "swapped" means.
declare -A REPLACEMENT=(
  [tailscale]=tailscale
  [firmware-updater]=gnome-firmware
  [glow]=glow
  [obsidian]=obsidian
)

snap_present()  { snap list "$1" >/dev/null 2>&1; }
deb_installed() { dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -q '^installed$'; }

apt_install() {
  say "   installing apt package(s): $*"
  sudo apt-get install -y "$@" || die "apt-get install $* failed"
}

remove_snap() {
  if snap_present "$1"; then
    say "   removing snap: $1"
    sudo snap remove "$1" || die "snap remove $1 failed"
  else
    say "   snap $1 already absent"
  fi
}

# --- per-snap swaps -------------------------------------------------

swap_tailscale() {
  say "tailscale: snap -> apt"
  if deb_installed tailscale; then
    say "   apt tailscale already installed"
  else
    # Carry the node identity across before the snap (and its state) go
    # away, or this machine drops out of the tailnet and needs re-auth.
    if [ ! -e "$TS_DEB_STATE" ] && sudo test -e "$TS_SNAP_STATE"; then
      say "   preserving tailnet node identity: $TS_SNAP_STATE -> $TS_DEB_STATE"
      sudo install -d -m 700 "$(dirname "$TS_DEB_STATE")" || die "could not create $(dirname "$TS_DEB_STATE")"
      sudo cp -a "$TS_SNAP_STATE" "$TS_DEB_STATE" || die "could not copy tailscaled.state"
    elif [ -e "$TS_DEB_STATE" ]; then
      say "   $TS_DEB_STATE already exists -- left alone"
    else
      warn "   no $TS_SNAP_STATE found -- you will have to re-run 'sudo tailscale up' after this"
    fi
    apt_install tailscale
  fi
  remove_snap tailscale

  # Found live on mandark 2026-08-15: the deb leaves tailscaled *enabled
  # but not started* -- so it only comes up at the next boot, and until
  # then `tailscale up` fails with "failed to connect to local
  # tailscaled". The state copy above had worked fine; nothing had
  # started the daemon that reads it.
  if systemctl is-active --quiet tailscaled; then
    say "   tailscaled is running"
  else
    say "   starting tailscaled (the deb enables it but does not start it)"
    sudo systemctl start tailscaled || die "could not start tailscaled"
  fi
}

swap_firmware_updater() {
  say "firmware-updater: snap -> gnome-firmware"
  if deb_installed gnome-firmware; then
    say "   gnome-firmware already installed"
  else
    apt_install gnome-firmware
  fi
  remove_snap firmware-updater
}

swap_glow() {
  say "glow: snap -> apt (repo.charm.sh)"
  if deb_installed glow; then
    say "   apt glow already installed"
  else
    if [ ! -s "$CHARM_KEYRING" ]; then
      say "   adding charm signing key -> $CHARM_KEYRING"
      sudo install -d -m 755 /etc/apt/keyrings || die "could not create /etc/apt/keyrings"
      curl -fsSL https://repo.charm.sh/apt/gpg.key \
        | sudo gpg --dearmor -o "$CHARM_KEYRING" || die "could not fetch/dearmor the charm signing key"
      sudo chmod 644 "$CHARM_KEYRING"
    else
      say "   charm signing key already present"
    fi
    if [ ! -s "$CHARM_LIST" ]; then
      say "   adding charm apt repo -> $CHARM_LIST"
      echo "deb [signed-by=$CHARM_KEYRING] https://repo.charm.sh/apt/ * *" \
        | sudo tee "$CHARM_LIST" >/dev/null || die "could not write $CHARM_LIST"
    else
      say "   charm apt repo already present"
    fi
    sudo apt-get update -o Dir::Etc::sourcelist="$CHARM_LIST" \
                        -o Dir::Etc::sourceparts=/dev/null \
                        -o APT::Get::List-Cleanup=0 || die "apt-get update for the charm repo failed"
    apt_install glow
  fi
  remove_snap glow
}

swap_obsidian() {
  say "obsidian: snap -> official .deb"
  if deb_installed obsidian; then
    say "   obsidian .deb already installed"
  else
    local url tmp
    url="$(curl -fsSL "$OBSIDIAN_RELEASES_API" \
      | grep -o 'https://[^"]*obsidian_[0-9.]*_amd64\.deb' | head -1)"
    [ -n "$url" ] || die "could not find an amd64 .deb in the latest obsidian release ($OBSIDIAN_RELEASES_API)"
    tmp="$(mktemp -d)"
    say "   downloading $url"
    curl -fsSL "$url" -o "$tmp/obsidian.deb" || { rm -rf "$tmp"; die "download failed: $url"; }
    # Refuse anything that isn't actually a Debian package -- a captive
    # portal or an error page would otherwise reach `apt install`.
    file -b "$tmp/obsidian.deb" | grep -q 'Debian binary package' \
      || { rm -rf "$tmp"; die "downloaded file is not a Debian package -- refusing to install it"; }
    sudo apt-get install -y "$tmp/obsidian.deb" || { rm -rf "$tmp"; die "apt-get install of the obsidian .deb failed"; }
    rm -rf "$tmp"
  fi
  remove_snap obsidian

  # The snap kept the vault under ~/snap/obsidian; the deb reads
  # ~/.config/obsidian. Zach's vaults live in the filesystem either way,
  # so this is a re-open, not a data move -- but say so rather than let
  # it look like the vaults vanished.
  [ -d "$HOME/snap/obsidian" ] && say "   NOTE: ~/snap/obsidian still holds the snap's app config -- your vault files are unaffected; re-open the vault once in the new obsidian, then it can be deleted"
  return 0
}

do_enable() {
  say "senechal remedy: snap-free mandark, the four mechanical swaps"
  say "(chromium #290, cups #291 and the snapd purge #292 are NOT touched here)"
  say "You will be prompted for your sudo password."
  say ""

  swap_tailscale;        say ""
  swap_firmware_updater; say ""
  swap_glow;             say ""
  swap_obsidian;         say ""

  say "Steps this script did NOT do for you:"
  say "  - 'sudo tailscale up' if the node identity could not be carried across (it says so above if that happened)"
  say "  - re-open your Obsidian vault once, in the new deb build"
  say "  - 'rm -rf ~/snap/<name>' for the removed snaps' leftover app config -- check each first"
  say "  - nothing here purges snapd; chromium (#290) still holds that open"
  say ""
  say "run: ./snap-free-mandark.sh verify"
}

do_verify() {
  local snapname deb
  for snapname in "${!REPLACEMENT[@]}"; do
    deb="${REPLACEMENT[$snapname]}"
    if snap_present "$snapname"; then
      fail "snap $snapname is still installed -- run: ./snap-free-mandark.sh enable"
    else
      ok "snap $snapname is gone"
    fi
    if deb_installed "$deb"; then
      ok "replacement package $deb is installed"
    else
      fail "replacement package $deb is NOT installed (was replacing snap $snapname) -- run: ./snap-free-mandark.sh enable"
    fi
  done

  # A tailscale that is installed but not on the tailnet is the failure
  # this swap is most likely to cause, and the one a package check alone
  # would call a pass.
  if deb_installed tailscale; then
    if ! command -v tailscale >/dev/null 2>&1; then
      fail "tailscale is installed but not on PATH"
    elif ! systemctl is-active --quiet tailscaled; then
      # Distinct from "identity lost": the daemon simply isn't up, and
      # `tailscale up` cannot fix that -- it needs a tailscaled to talk to.
      fail "tailscaled is not running (the deb enables it without starting it) -- run: sudo systemctl start tailscaled"
    elif tailscale status >/dev/null 2>&1; then
      ok "tailscale is up on the tailnet"
    else
      fail "tailscale is installed but not connected -- the node identity did not survive the swap; run: sudo tailscale up"
    fi
  fi

  finish_verify "OK -- all four snaps are swapped for native packages."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
