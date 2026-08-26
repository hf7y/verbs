#!/usr/bin/env bash
# senechal: the HP 8710's black nozzle row is dead, and every automated signal
# says otherwise -- lpstat reports the queue idle and enabled, marker-levels
# reports K at 90%, and the printhead self-reports ConsumableState "ok". It
# reported "ok" on 2026-08-25 while the printer's own diagnostics page came out
# with no black block and none of its own text.
#
# So nothing discovers this by asking the printer. What is checkable is whether
# the guard is still in place: that the default destination routes through the
# k2c backend, which remaps black onto inks that still fire. Anything else
# accepts the job, reports success, and hands back a page with the black gone.
#
# Deliberately hardcodes no queue names. It checks the PROPERTY -- the default
# must go through k2c:/ -- so it survives a rename and still catches the
# queues cups-browsed invents from DNS-SD on its own.
#
#   health/printer-black-channel.sh [-q]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

BACKEND="/usr/lib/cups/backend/k2c"
TOOL="/usr/local/bin/k2c"

parse_common_args "$@"

if ! command -v lpstat >/dev/null 2>&1; then
  skip "lpstat not installed -- no CUPS here to check"
  finish_verify "OK -- no CUPS on this host."
fi
if ! lpstat -r >/dev/null 2>&1; then
  skip "cupsd is not running -- cannot see any queue"
  finish_verify "OK -- nothing to check."
fi

queue_uri() { lpstat -v "$1" 2>/dev/null | sed -n 's/^device for [^:]*: //p'; }

# --- which queues go through the remap? ---------------------------------
head_ "the remapping queue"
remapped=""
while read -r q; do
  [ -n "$q" ] || continue
  case "$(queue_uri "$q")" in k2c:/*) remapped="$remapped $q" ;; esac
done <<< "$(lpstat -a 2>/dev/null | awk '{print $1}')"

if [ -z "$remapped" ]; then
  fail "no queue routes through the k2c backend -- run remedies/print-black-via-colour.sh enable"
else
  ok "remapping queue(s):$remapped"
fi

# --- is it the default? -------------------------------------------------
head_ "default destination"
default=$(lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p')
if [ -z "$default" ]; then
  # No default is the SAFE failure: `lp file.pdf` errors out loudly instead of
  # printing a page with the black silently missing. Still not a pass.
  fail "no system default destination set -- plain 'lp file.pdf' has nowhere to go"
else
  case "$(queue_uri "$default")" in
    k2c:/*) ok "default is $default, which remaps black" ;;
    *) fail "default is $default, which sends black straight to a dead nozzle row -- it will report success and print the black as nothing. Fix: lpoptions -d <a k2c queue>" ;;
  esac
fi

# --- the pieces the backend needs --------------------------------------
head_ "installed pieces"
if [ -e "$BACKEND" ]; then
  [ "$(stat -c %U "$BACKEND" 2>/dev/null)" = root ] \
    && ok "$BACKEND owned by root" || fail "$BACKEND not owned by root"
  [ "$(stat -c %a "$BACKEND" 2>/dev/null)" = 700 ] \
    && ok "$BACKEND mode 700" || fail "$BACKEND not mode 700 -- cupsd must run it as root"
else
  fail "$BACKEND missing -- the remapping queue has nothing to run"
fi
[ -x "$TOOL" ] && ok "$TOOL installed" || fail "$TOOL missing"

# --- name the remaining traps ------------------------------------------
# Every other queue reaching the same printer still eats black. cups-browsed
# recreates its implicitclass:// one from DNS-SD, so this is a standing list,
# not something to delete once.
head_ "queues that still eat black"
target=""
host=""
for q in $remapped; do
  t=$(queue_uri "$q"); t="${t#k2c:/}"
  [ -n "$t" ] && { target="$t"; host=$(queue_uri "$t" | sed -n 's|^[a-z]*://\([^/:]*\).*|\1|p'); break; }
done
found=0
while read -r q; do
  [ -n "$q" ] || continue
  u=$(queue_uri "$q")
  case "$u" in k2c:/*) continue ;; esac
  hit=0
  [ -n "$host" ] && case "$u" in *"$host"*) hit=1 ;; esac
  case "$u" in implicitclass://*8710*|implicitclass://*OfficeJet*) hit=1 ;; esac
  if [ "$hit" = 1 ]; then
    found=$((found + 1))
    note "$q ($u) -- prints black as nothing"
  fi
done <<< "$(lpstat -a 2>/dev/null | awk '{print $1}')"
[ "$found" -gt 0 ] && note "leave them; they are how the printer is reached. Just never default to one." \
                   || note "none besides the remap target itself"

finish_verify "OK -- black is routed away from the dead nozzle row."
