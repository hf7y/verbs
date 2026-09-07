#!/usr/bin/env bash
PRIVILEGED=yes
HOSTS=(mandark)
REACHES=()
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
. ../lib/common.sh

QUEUE="HP8710_BROKEN_K"
OLD_URI="${SENECHAL_HP8710_OLD_URI:-ipp://192.168.0.119/ipp/print}"
NEW_URI="${SENECHAL_HP8710_NEW_URI:-dnssd://HP%20OfficeJet%20Pro%208710%20%5BF3466A%5D._ipp._tcp.local/?uuid=1c852a4d-b800-1f08-abcd-705a0ff3466a}"
MDNS_HOST="${SENECHAL_HP8710_MDNS_HOST:-HP705A0FF3466A.local}"

require_lpadmin_group() {
  id -nG | tr ' ' '\n' | grep -qx lpadmin && return 0
  die "$(id -un) is not in the lpadmin group -- run: sudo usermod -aG lpadmin $(id -un), then log out and back in"
}

queue_uri() { lpstat -v "$1" 2>/dev/null | sed -n 's/^device for .*: //p'; }

do_enable() {
  say "senechal remedy: retarget $QUEUE from a pinned IP onto its mDNS identity"
  say ""
  require_lpadmin_group

  local actual; actual="$(queue_uri "$QUEUE")"
  [ -n "$actual" ] || die "queue $QUEUE does not exist -- nothing to retarget (run cups-purged-by-autoremove.sh first?)"

  if [ "$actual" = "$NEW_URI" ]; then
    say "$QUEUE already points at $NEW_URI -- nothing to do."
    return 0
  fi
  if [ "$actual" != "$OLD_URI" ]; then
    die "$QUEUE points at '$actual', neither the known old value ($OLD_URI) nor the new one -- refusing to guess, check by hand"
  fi

  if command -v avahi-resolve-host-name >/dev/null 2>&1; then
    local resolved; resolved="$(avahi-resolve-host-name -4 "$MDNS_HOST" 2>/dev/null)"
    if [ -z "$resolved" ]; then
      warn "$MDNS_HOST did not resolve over mDNS just now -- proceeding anyway (dnssd:// resolves lazily per print job, and the printer may just be asleep), but if printing stays broken after this, confirm the printer is on and re-check with: avahi-resolve-host-name -4 $MDNS_HOST"
    else
      say "confirmed: $MDNS_HOST resolves to ${resolved#*$'\t'} right now"
    fi
  else
    warn "avahi-resolve-host-name not on PATH -- cannot confirm the mDNS name resolves before switching (apt install avahi-utils to get this check)"
  fi

  say "lpadmin -p $QUEUE -v '$NEW_URI'"
  lpadmin -p "$QUEUE" -v "$NEW_URI" -E || die "lpadmin failed to retarget $QUEUE"

  local now; now="$(queue_uri "$QUEUE")"
  [ "$now" = "$NEW_URI" ] || die "lpadmin ran but lpstat now reads '$now', not the expected URI -- investigate by hand before trusting this"
  say "confirmed: $QUEUE -> $NEW_URI"
  say ""
  say "print a test page before relying on this: lp -d $QUEUE /etc/hostname"
}

do_verify() {
  local actual; actual="$(queue_uri "$QUEUE")"
  if [ -z "$actual" ]; then
    skip "queue $QUEUE does not exist -- cannot check (cups-purged-by-autoremove.sh owns creating it)"
  elif [ "$actual" = "$NEW_URI" ]; then
    ok "$QUEUE -> $NEW_URI (mDNS, survives a DHCP lease change)"
  elif [ "$actual" = "$OLD_URI" ]; then
    fail "$QUEUE still pins $OLD_URI -- a DHCP lease change breaks it silently; run: ./hp8710-dnssd-retarget.sh enable"
  else
    fail "$QUEUE points at '$actual', which this remedy does not recognise (neither the old pinned IP nor the new mDNS form)"
  fi

  finish_verify "OK -- $QUEUE targets the printer's own identity, not a leaseable address."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
