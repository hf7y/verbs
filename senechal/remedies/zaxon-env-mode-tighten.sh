#!/usr/bin/env bash
PRIVILEGED=yes
HOSTS=(dexter)
REACHES=(ssh)
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
. ../lib/common.sh

DEXTER_ADDR="${ZAXON_ENV_DEXTER_ADDR:-192.168.0.22}"
DEXTER_PORT="${ZAXON_ENV_DEXTER_PORT:-2223}"
DEXTER_USER="${ZAXON_ENV_DEXTER_USER:-zach}"
DEXTER_KEY="${ZAXON_ENV_DEXTER_KEY:-$HOME/.ssh/id_dexter_gardien}"
ENV_PATH="${ZAXON_ENV_PATH:-/srv/zaxon/data/.env}"
TIMEOUT=8
CONTAINERS=(${ZAXON_ENV_CONTAINERS:-zaxon-gateway zaxon-relay zaxon-whisper zaxon-watcher})

dex() {
  ssh -i "$DEXTER_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
      -o ConnectTimeout="$TIMEOUT" -p "$DEXTER_PORT" \
      "$DEXTER_USER@$DEXTER_ADDR" "$@" </dev/null 2>/dev/null
}

dex_up() { dex 'exit 0'; }

file_mode() { dex "stat -c %a '$ENV_PATH' 2>/dev/null"; }
file_uid()  { dex "stat -c %u '$ENV_PATH' 2>/dev/null"; }
container_uid() { dex "docker exec $1 id -u 2>/dev/null"; }
container_running() { dex "docker inspect -f '{{.State.Running}}' $1 2>/dev/null"; }

do_enable() {
  say "senechal remedy: tighten $ENV_PATH on dexter from world-writable to owner-only"
  say ""

  [ -f "$DEXTER_KEY" ] || die "no key at $DEXTER_KEY -- that is the key authorized on dexter's WSL2 distro; without it this script cannot reach it"

  if ! dex_up; then
    die "cannot reach dexter's distro at $DEXTER_ADDR:$DEXTER_PORT -- re-run once it's up (see dexter-wsl-autostart.sh if the distro itself is down)"
  fi
  say "reached the distro over ssh:$DEXTER_PORT."

  local mode; mode="$(file_mode)"
  [ -n "$mode" ] || die "could not stat $ENV_PATH over ssh -- does it still exist at that path?"
  if [ "$mode" = 600 ]; then
    say "$ENV_PATH is already 600 -- nothing to do."
    return 0
  fi
  say "current mode: $mode"

  local fuid; fuid="$(file_uid)"
  [ -n "$fuid" ] || die "stat -c %a worked but -c %u did not -- inconsistent answer from dexter, refusing to guess"

  say "checking every live container reads the file as the uid it will still own after chmod (uid $fuid) -- #656's own wall"
  local c cuid any_running=0
  for c in "${CONTAINERS[@]}"; do
    cuid="$(container_uid "$c")"
    if [ -z "$cuid" ]; then
      say "  $c: not running (or no such container) -- skipping, nothing reads the file as it right now"
      continue
    fi
    any_running=1
    if [ "$cuid" != "$fuid" ]; then
      die "$c reads the mount as uid $cuid but $ENV_PATH is owned by uid $fuid -- chmod 600 would lock $c out of its own credentials. This is exactly the wall #656 named; refusing rather than guessing."
    fi
    say "  $c: reads as uid $cuid -- matches"
  done
  [ "$any_running" = 1 ] || warn "no container in the list (${CONTAINERS[*]}) is running right now -- proceeding on the file's own owner alone, but nothing live confirmed which uid actually reads it"

  say ""
  say "chmod 600 $ENV_PATH"
  dex "chmod 600 '$ENV_PATH'" || die "chmod failed over ssh"

  local newmode; newmode="$(file_mode)"
  [ "$newmode" = 600 ] || die "chmod ran but stat now reads '$newmode', not 600 -- investigate by hand before trusting this"
  say "confirmed: $ENV_PATH is now 600."

  say ""
  say "confirming the containers are still up after the mode change"
  for c in "${CONTAINERS[@]}"; do
    case "$(container_running "$c")" in
      true) say "  $c: still running" ;;
      false) warn "$c is present but NOT running after the chmod -- check: ssh -p $DEXTER_PORT -i $DEXTER_KEY $DEXTER_USER@$DEXTER_ADDR docker logs $c" ;;
      *) say "  $c: not present (unchanged from before)" ;;
    esac
  done
}

do_verify() {
  if [ ! -f "$DEXTER_KEY" ]; then
    skip "no key at $DEXTER_KEY -- cannot probe dexter from here"
    finish_verify
  fi
  if ! dex_up; then
    skip "dexter's distro at $DEXTER_ADDR:$DEXTER_PORT is not answering -- cannot check while it's down"
    finish_verify
  fi

  local mode; mode="$(file_mode)"
  if [ -z "$mode" ]; then
    skip "$ENV_PATH: stat failed over ssh -- cannot check"
  elif [ "$mode" = 600 ]; then
    ok "$ENV_PATH is 600"
  else
    fail "$ENV_PATH is mode $mode, not 600 -- run: ./zaxon-env-mode-tighten.sh enable"
  fi

  finish_verify "OK -- $ENV_PATH is owner-only."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
