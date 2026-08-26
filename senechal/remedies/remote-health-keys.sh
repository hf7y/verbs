#!/usr/bin/env bash
# senechal: BatchMode SSH trust for remote estate health checks.
#
#   ./remote-health-keys.sh enable    # generate key + push to each host (asks for their passwords)
#   ./remote-health-keys.sh verify    # non-AI, cron-safe: does BatchMode ssh reach every reach=ssh device?
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

# --- target values, defined once, read by both verbs --------------------
IDENT="$(cfg health.remote_ssh_identity "$HOME/.ssh/senechal-estate-ed25519")"
IDENT="${IDENT/#\~/$HOME}"
TIMEOUT="$(cfg health.remote_ssh_timeout 6)"
KEY_COMMENT="senechal-estate-health@$(hostname)"

# reach=ssh devices as "name<TAB>addr<TAB>ssh_host<TAB>expect" lines.
ssh_devices() {
  local n k addr reach owner expect ssh_host os
  while IFS=$'\x1f' read -r n k addr reach owner expect ssh_host os; do
    [ -n "$n" ] && [ "$reach" = "ssh" ] || continue
    printf '%s\x1f%s\x1f%s\x1f%s\n' "$n" "$addr" "${ssh_host:-$n}" "$expect"
  done <<< "$(cfg_devices)"
}

# BatchMode probe with the dedicated identity only. `exit 0` is the one
# command every remote shell in this estate understands -- sh, cmd.exe
# and PowerShell alike -- so the same witness works on potato and dexter.
batch_ok() {
  ssh -i "$IDENT" -o IdentitiesOnly=yes -o BatchMode=yes \
      -o ConnectTimeout="$TIMEOUT" "$1" 'exit 0' </dev/null >/dev/null 2>&1
}

# Read ssh_devices into an array up front: ssh/ssh-copy-id inside a
# `while read` loop would silently eat the rest of the device list from
# the loop's stdin (the same bug estate-health.sh guards against).
load_devices() {
  mapfile -t DEVICES <<< "$(ssh_devices)"
  [ "${#DEVICES[@]}" -eq 1 ] && [ -z "${DEVICES[0]}" ] && DEVICES=()
}

do_enable() {
  load_devices
  if [ "${#DEVICES[@]}" -eq 0 ]; then
    die "no reach=ssh devices in $SENECHAL_CONFIG -- nothing to trust"
  fi

  if [ -f "$IDENT" ]; then
    say "key already exists: $IDENT (leaving it alone)"
  else
    say "generating dedicated health-probe key: $IDENT"
    mkdir -p "$(dirname "$IDENT")"
    ssh-keygen -t ed25519 -N '' -C "$KEY_COMMENT" -f "$IDENT" \
      || die "ssh-keygen failed"
  fi

  local line n addr host expect manual=""
  for line in "${DEVICES[@]}"; do
    IFS=$'\x1f' read -r n addr host expect <<< "$line"
    [ -n "$n" ] || continue
    if batch_ok "$host"; then
      say "$n: already trusts this key -- untouched"
      continue
    fi
    if ! ping -c1 -W2 "$addr" >/dev/null 2>&1; then
      say "$n: not answering at $addr right now -- skipping; re-run enable when it is up"
      manual+="  - $n was off: re-run this enable when it is powered on"$'\n'
      continue
    fi
    say "$n: pushing key to \"$host\" (ssh-copy-id will ask for that host's password)"
    if ssh-copy-id -i "$IDENT.pub" -o ConnectTimeout="$TIMEOUT" "$host"; then
      if batch_ok "$host"; then
        say "$n: BatchMode ssh now works"
      else
        warn "$n: key pushed but BatchMode ssh still fails -- the host may restrict key auth (check its sshd_config / authorized_keys perms)"
        manual+="  - $n: investigate why key auth still fails after ssh-copy-id"$'\n'
      fi
    else
      warn "$n: ssh-copy-id failed"
      manual+="  - $n: ssh-copy-id failed; push $IDENT.pub to \"$host\" by hand"$'\n'
    fi
  done

  say ""
  say "done. Note: this key is passphrase-less by design (cron cannot type"
  say "one). To revoke a host later, delete the line ending \"$KEY_COMMENT\""
  say "from that host's authorized_keys."
  if [ -n "$manual" ]; then
    say ""
    say "steps this script could NOT do for you:"
    printf '%s' "$manual"
  fi
  say ""
  say "now run: ./remote-health-keys.sh verify"
}

do_verify() {
  load_devices
  if [ "${#DEVICES[@]}" -eq 0 ]; then
    skip "no reach=ssh devices in senechal.json -- nothing to verify"
    finish_verify
  fi

  if [ ! -f "$IDENT" ]; then
    fail "dedicated key $IDENT does not exist -- run: ./remote-health-keys.sh enable"
    finish_verify
  fi
  ok "dedicated key exists: $IDENT"

  local line n addr host expect
  for line in "${DEVICES[@]}"; do
    IFS=$'\x1f' read -r n addr host expect <<< "$line"
    [ -n "$n" ] || continue
    if ! ping -c1 -W2 "$addr" >/dev/null 2>&1; then
      # Can't witness key trust on a host that's off. estate-health.sh
      # owns the is-it-supposed-to-be-up question; this stays a SKIP
      # either way because "could not look" is never a pass.
      skip "$n is not answering at $addr -- cannot check key trust while it is off${expect:+ (declared $expect)}"
      continue
    fi
    if batch_ok "$host"; then
      ok "$n: BatchMode ssh works as \"$host\" with the dedicated key"
    else
      fail "$n: up, but BatchMode ssh as \"$host\" is refused -- run: ./remote-health-keys.sh enable"
    fi
  done

  finish_verify "OK -- every reachable reach=ssh device trusts the health-probe key."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
