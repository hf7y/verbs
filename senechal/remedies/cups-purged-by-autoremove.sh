#!/usr/bin/env bash
# senechal: restore the printing stack that `apt-get autoremove --purge -y`
# took out on 2026-08-23 19:14, 65s after the snap-free purge of firefox +
# snapd. The explicit purge spared cups; the unqualified autoremove did not.
#
# Until this is run, mandark is in a trap state: cupsd (PID from 2026-08-22)
# is still serving from a DELETED binary with /etc/cups purged out from under
# it. lpstat looks healthy, but every job dies "Request Entity Too Large" as a
# zero-byte spool entry, and the running daemon's memory is the ONLY copy of
# the three queue definitions -- hence the table below.
#
#   ./cups-purged-by-autoremove.sh enable    # reinstall + rebuild queues (sudo)
#   ./cups-purged-by-autoremove.sh verify    # non-AI, cron-safe
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

# --- target values, defined once, read by both verbs --------------------
PKGS="cups cups-daemon cups-core-drivers cups-server-common cups-ppdc
      cups-browsed printer-driver-hpcups printer-driver-postscript-hp
      printer-driver-splix hplip hplip-data libcupsimage2t64 libhpmud0
      libsane-hpaio bluez-cups avahi-utils"

HP_IP="192.168.0.119"
PHOMEMO_SRC="$HOME/.local/share/phomemo-tools/cups"
# Renamed from HP8710_direct on 2026-08-25. The name is the warning: this queue
# reaches the printer, and the printer's black nozzle row is dead, so every job
# sent here is accepted, reported successful, and printed with the black simply
# missing. It still has to exist -- it is how the printer is reached, and
# HP8710_K2CMY feeds it -- but nothing should default to it.
RENAMED_QUEUES="HP8710_direct"

# No DEFAULT_QUEUE here on purpose. Which queue is safe to default to depends on
# whether the K row is dead, which is not this remedy's business to know;
# remedies/print-black-via-colour.sh owns that and asserts it in its verify.
# Until it runs there is NO default, so `lp file.pdf` fails loudly rather than
# printing a page with the black silently gone. That is the safe direction.

# name|device-uri|lpadmin driver arg|print-color-mode
QUEUES="
HP8710_BROKEN_K|ipp://$HP_IP/ipp/print|-m everywhere|color
M02|phomemo://EAF3B6A27033|-m Phomemo/Phomemo-M02.ppd.gz|monochrome
"

# HP8710_raw (socket://$HP_IP:9100, raw) existed before the purge and is
# deliberately NOT restored (Zach, 2026-08-24). A raw 9100 queue passes bytes
# straight to the print engine, so anything that is not native PCL/PostScript
# -- a PDF, say -- is interpreted literally and spews pages until the paper
# runs out. It was created 2026-08-23 02:31; the printer was hard-unplugged
# out of a runaway print loop, and its cyan and magenta are down to 20%.
# HP8710_direct (IPP Everywhere) already prints everything, with conversion.
# Listed here rather than just deleted, so verify can keep the decision.
FORBIDDEN_QUEUES="HP8710_raw"

SUDO_CMD="${SENECHAL_SUDO_CMD-sudo}"

# lpadmin must NOT run under sudo: it authenticates to cupsd over IPP, and as
# root it asks for the CUPS account "root", which has no password -- an endless
# "Password for root on localhost?" prompt. Run as the invoking user, who is in
# SystemGroup (lpadmin) and is authorised by cupsd directly.
require_lpadmin_group() {
  id -nG | tr ' ' '\n' | grep -qx lpadmin && return 0
  die "$(id -un) is not in the lpadmin group -- run: sudo usermod -aG lpadmin $(id -un), then log out and back in"
}

# The reinstall restores /usr/sbin/cupsd but does NOT necessarily replace the
# running process: systemd saw the unit as already active and left the
# pre-purge daemon in place. That daemon keeps serving with no PPDs on disk,
# so jobs are accepted and then die in "universal filter failed". Compare the
# main PID's start time against the binary's CTIME (when the inode landed here;
# apt preserves mtime from the package build, so mtime is useless) -- a daemon
# older than its own binary is the orphan.
cupsd_is_orphan() {
  local pid started binary
  pid="$(systemctl show cups -p MainPID --value 2>/dev/null)"
  [ -n "$pid" ] && [ "$pid" != 0 ] || return 1
  [ -x /usr/sbin/cupsd ] || return 1
  started="$(date -d "$(ps -o lstart= -p "$pid" 2>/dev/null)" +%s 2>/dev/null)" || return 1
  binary="$(stat -c %Z /usr/sbin/cupsd 2>/dev/null)" || return 1
  [ -n "$started" ] && [ "$started" -lt "$binary" ]
}

hp_reachable() { timeout 3 bash -c "exec 3<>/dev/tcp/$HP_IP/631" 2>/dev/null; }

queue_uri() { lpstat -v "$1" 2>/dev/null | sed -n 's/^device for .*: //p'; }

do_enable() {
  local skipped=""
  say "senechal remedy: restore the purged printing stack"
  say ""
  say "WARNING: the cupsd now running is an orphan from before the purge --"
  say "its in-memory queues are the only copy left. Reinstalling replaces it,"
  say "so this script rebuilds all three queues from its own table."
  say ""
  say "1/4 reinstalling printing packages -- needs sudo, may prompt."
  # shellcheck disable=SC2086
  $SUDO_CMD apt-get install -y $PKGS || die "apt-get install failed"

  say ""
  say "2/4 marking the stack manually-installed, so the next"
  say "    'autoremove --purge' cannot take it again (this is the real fix)."
  # shellcheck disable=SC2086
  $SUDO_CMD apt-mark manual $PKGS >/dev/null || warn "apt-mark manual failed"

  say ""
  say "3/4 rebuilding the Phomemo M02 driver (its PPD lives outside dpkg)."
  if [ -d "$PHOMEMO_SRC" ]; then
    ( cd "$PHOMEMO_SRC" && make ppds >/dev/null 2>&1 \
      && $SUDO_CMD make install >/dev/null 2>&1 ) \
      && say "    done." || { warn "phomemo rebuild failed"; skipped="$skipped M02-driver"; }
  else
    warn "$PHOMEMO_SRC missing -- cannot rebuild the M02 driver"
    skipped="$skipped M02-driver"
  fi

  say ""
  say "4/4 restarting cupsd, then recreating queues."
  if cupsd_is_orphan; then
    say "    the running daemon predates its own binary -- replacing it."
  fi
  $SUDO_CMD systemctl restart cups || die "could not restart cups"
  for _ in 1 2 3 4 5; do lpstat -r >/dev/null 2>&1 && break; sleep 1; done
  say "    cupsd restarted; you will be asked for YOUR password (not root's)"
  say "    once, so cupsd can authorise the queue changes."
  require_lpadmin_group
  hp_reachable || say "    NOTE: $HP_IP:631 is unreachable -- the IPP Everywhere"
  hp_reachable || say "    queue needs the printer POWERED ON to be created."
  local name uri drv mode
  while IFS='|' read -r name uri drv mode; do
    [ -n "$name" ] || continue
    # shellcheck disable=SC2086
    if lpadmin -p "$name" -v "$uri" $drv -o print-color-mode="$mode" \
         -o printer-is-shared=true -E 2>/dev/null; then
      say "    $name -> $uri"
    else
      warn "could not create $name"
      skipped="$skipped $name"
    fi
  done <<< "$QUEUES"
  local bad
  for bad in $FORBIDDEN_QUEUES; do
    if lpstat -v "$bad" >/dev/null 2>&1; then
      say "    removing $bad -- raw 9100 queue, the runaway-page-spew path"
      lpadmin -x "$bad" 2>/dev/null || warn "could not remove $bad"
    fi
  done
  for old in $RENAMED_QUEUES; do
    if lpstat -v "$old" >/dev/null 2>&1; then
      say "    removing $old -- renamed to HP8710_BROKEN_K, which says what it does"
      lpadmin -x "$old" 2>/dev/null || warn "could not remove $old"
    fi
  done

  say ""
  if [ -n "$skipped" ]; then
    say "COULD NOT DO FOR YOU:$skipped"
    say "  power the HP8710 on (and confirm it is at $HP_IP), then re-run enable."
  fi
  say "run: ./cups-purged-by-autoremove.sh verify"
}

do_verify() {
  local missing="" p
  for p in $PKGS; do
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null)" = installed ] \
      || missing="$missing $p"
  done
  if [ -z "$missing" ]; then
    ok "printing packages are installed"
  else
    fail "purged printing packages still missing:$missing -- run: ./cups-purged-by-autoremove.sh enable"
  fi

  # the trap state: a live daemon whose binary and config are gone
  if [ -x /usr/sbin/cupsd ]; then
    ok "/usr/sbin/cupsd exists on disk"
  else
    fail "/usr/sbin/cupsd is DELETED but cupsd may still be running -- jobs will fail as zero-byte 'Request Entity Too Large'"
  fi
  if [ -f /etc/cups/cupsd.conf ]; then
    ok "/etc/cups/cupsd.conf is present"
  else
    fail "/etc/cups/cupsd.conf is missing -- cupsd is running on compiled-in defaults"
  fi
  if cupsd_is_orphan; then
    fail "the running cupsd predates /usr/sbin/cupsd -- it is the pre-purge orphan; jobs die in 'universal filter failed'. run: sudo systemctl restart cups"
  else
    ok "the running cupsd is not older than its own binary"
  fi
  if [ -d /var/spool/cups ]; then
    ok "/var/spool/cups exists"
  else
    fail "/var/spool/cups is missing -- cupsd cannot stage job data"
  fi

  local name uri drv mode actual
  while IFS='|' read -r name uri drv mode; do
    [ -n "$name" ] || continue
    actual="$(queue_uri "$name")"
    if [ -z "$actual" ]; then
      fail "queue $name does not exist"
    elif [ "$actual" != "$uri" ]; then
      fail "queue $name points at $actual, expected $uri"
    else
      ok "queue $name -> $uri"
    fi
  done <<< "$QUEUES"

  local bad
  for bad in $FORBIDDEN_QUEUES; do
    if lpstat -v "$bad" >/dev/null 2>&1; then
      fail "$bad is back -- a raw 9100 queue spews pages on any non-PCL job; run: ./cups-purged-by-autoremove.sh enable"
    else
      ok "$bad is absent (raw 9100 queue, deliberately not restored)"
    fi
  done

  # the recurrence guard: auto-installed means the next autoremove eats it again
  local auto
  auto="$(apt-mark showauto $PKGS 2>/dev/null | tr '\n' ' ')"
  if [ -z "${auto// /}" ]; then
    ok "printing stack is marked manual -- autoremove cannot purge it again"
  else
    fail "still marked auto (a future 'autoremove --purge' will repeat 2026-08-23): $auto"
  fi

  finish_verify "OK -- printing stack restored and pinned against autoremove."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
