#!/usr/bin/env bash
# monkey-nopasswd.sh -- give the HANDS account on monkey passwordless sudo.
#
#   [rest: vault:realisateur/guard-archaeology-20260817.md]

set -euo pipefail

JUMP="${MONKEY_JUMP:-dexter}"
KEYFILE="${MONKEY_KEYFILE:-\$HOME/.ssh/selfdev_monkey}"
PORT="${MONKEY_PORT:-2225}"
USER_ON_MONKEY="${MONKEY_USER:-zach}"
DROPIN="/etc/sudoers.d/010-${USER_ON_MONKEY}-nopasswd"

die()  { printf 'monkey-nopasswd: %s\n' "$*" >&2; exit 1; }
info() { printf '  %-8s %s\n' "$1" "$2"; }

remote() {                     # $1 = script, $2 = extra ssh flags (optional)
  local b64; b64="$(printf '%s' "$1" | base64 -w0)"
  # shellcheck disable=SC2086
  ssh ${2:-} -o ConnectTimeout=10 "$JUMP" \
    "ssh ${2:-} -i $KEYFILE -o ConnectTimeout=10 -p $PORT \
        ${USER_ON_MONKEY}@127.0.0.1 \"echo $b64 | base64 -d | bash -s\""
}

case "${1:---check}" in
--check)
  echo "== monkey NOPASSWD (--check) =="
  out="$(remote '
    printf "HOST=%s\n" "$(hostname -s)"
    printf "WHO=%s\n"  "$(id -un)"
    printf "NOPASS=%s\n" "$(sudo -n true 2>/dev/null && echo yes || echo no)"
  ' "-o BatchMode=yes" 2>&1)" || die "cannot reach monkey through $JUMP -- $out"
  f() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }
  [ "$(f HOST)" = monkey ] || die "reached '$(f HOST)', not monkey -- refusing"
  info OK "reached monkey as $(f WHO)"
  [ "$(f NOPASS)" = yes ] \
    && info OK      "passwordless sudo is already in place -- nothing to do" \
    || info MISSING "sudo still requires a password; run --install from a terminal"
  echo
  echo "check only. Nothing changed."
  ;;

--install)
  [ -t 0 ] || die "--install needs a terminal: it prompts for the sudo password
    once, deliberately. Run it from a shell, not from an unattended job."
  echo "== monkey NOPASSWD (--install) =="
  echo "You will be asked for zach@monkey's sudo password once."
  echo
  # `visudo -c` on the CANDIDATE before installing. Writing an invalid file
  # into sudoers.d breaks sudo for everyone on the host.
  remote '
    set -e
    if sudo -n true 2>/dev/null; then
      echo "already passwordless -- nothing to do"; exit 0
    fi
    tmp="$(mktemp)"
    printf "%s ALL=(ALL) NOPASSWD: ALL\n" "'"$USER_ON_MONKEY"'" > "$tmp"
    # Validate as root, because visudo needs to read the whole ruleset.
    sudo visudo -cqf "$tmp" || { rm -f "$tmp"; echo "REFUSED: candidate did not validate" >&2; exit 1; }
    sudo install -o root -g root -m 0440 "$tmp" "'"$DROPIN"'"
    rm -f "$tmp"
    # Prove it, rather than assuming the write took.
    sudo -k
    sudo -n true 2>/dev/null && echo "VERIFIED: passwordless sudo now works" \
      || { echo "INSTALLED BUT NOT EFFECTIVE -- check '"$DROPIN"'" >&2; exit 1; }
  ' "-t"
  echo
  echo "Machine-wide config on another host. File it:"
  echo "    notify-senechal 'monkey: zach@monkey granted passwordless sudo via"
  echo "    $DROPIN (Zach-directed 2026-08-04, to unblock unattended"
  echo "    provisioning). Owned by realisateur/provision/monkey-nopasswd.sh."
  echo "    Project users (ecosim/bibliothecaire/chezz) are UNCHANGED and still"
  echo "    have no sudo. Retire with: sudo rm $DROPIN'"
  ;;

*) die "usage: monkey-nopasswd.sh [--check|--install]" ;;
esac
