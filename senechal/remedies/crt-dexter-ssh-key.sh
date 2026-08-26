#!/usr/bin/env bash
# senechal: trust crt's deploy key for zach@dexter (Windows host).
#
#   ./crt-dexter-ssh-key.sh enable    # push the key (asks for dexter's password once)
#   ./crt-dexter-ssh-key.sh verify    # non-AI, cron-safe: does the key already authenticate?
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

# --- target values, defined once, read by both verbs --------------------
PUBKEY="$HOME/.ssh/crt_deploy_key.pub"
KEY_COMMENT="crt-deploy-key"
DEXTER_HOST="dexter"          # ~/.ssh/config alias -> dexter.tail893f2c.ts.net
TIMEOUT=8

batch_ok() {
  ssh -i "${PUBKEY%.pub}" -o IdentitiesOnly=yes -o BatchMode=yes \
      -o ConnectTimeout="$TIMEOUT" "$DEXTER_HOST" 'exit 0' </dev/null >/dev/null 2>&1
}

do_enable() {
  say "senechal remedy: crt deploy key -> zach@$DEXTER_HOST"
  say ""

  [ -f "$PUBKEY" ] || die "expected public key not found: $PUBKEY (crt was supposed to have generated this already -- nothing to push)"
  [ -f "${PUBKEY%.pub}" ] || warn "private half ${PUBKEY%.pub} not found here -- that's fine if crt runs from a different session/host; this script only pushes the public half"

  if ! grep -qF "$KEY_COMMENT" "$PUBKEY"; then
    warn "$PUBKEY does not carry the expected comment \"$KEY_COMMENT\" -- pushing it anyway, but double check this is really crt's key"
  fi

  if [ -f "${PUBKEY%.pub}" ] && batch_ok; then
    say "dexter already trusts this key -- nothing to do."
    say "run: ./crt-dexter-ssh-key.sh verify"
    return 0
  fi

  if ! ping -c1 -W2 dexter.tail893f2c.ts.net >/dev/null 2>&1 \
     && ! ping -c1 -W2 dexter.local >/dev/null 2>&1; then
    die "dexter is not answering right now (checked Tailscale + LAN name) -- re-run enable once it's up"
  fi

  say "pushing $PUBKEY to \"$DEXTER_HOST\" (this will ask for zach@dexter's password once)"
  if ssh-copy-id -i "$PUBKEY" -o ConnectTimeout="$TIMEOUT" "$DEXTER_HOST"; then
    say "ssh-copy-id reported success."
  else
    warn "ssh-copy-id failed or is unsupported against this host's OpenSSH-on-Windows sshd"
    say ""
    say "steps this script could NOT do for you:"
    say "  - RDP or console into dexter and manually append the contents of"
    say "    $PUBKEY to:"
    say "      - %USERPROFILE%\\.ssh\\authorized_keys   (ordinary account), OR"
    say "      - %ProgramData%\\ssh\\administrators_authorized_keys  (if zach"
    say "        is a local Administrator on dexter -- OpenSSH prefers this"
    say "        file for admin accounts and ignores the per-user one)"
    say "  - if using administrators_authorized_keys, its ACL must grant"
    say "    read-only access to Administrators + SYSTEM only, or sshd will"
    say "    refuse to use it (Windows OpenSSH is strict about this file's"
    say "    permissions -- see 'icacls' in OpenSSH-on-Windows docs)"
  fi

  say ""
  if [ -f "${PUBKEY%.pub}" ] && batch_ok; then
    say "confirmed: BatchMode ssh to dexter now works with this key."
  else
    say "could not confirm from here (private key half may live only on the"
    say "session crt runs from) -- have crt run its own probe, or run"
    say "./crt-dexter-ssh-key.sh verify from wherever ${PUBKEY%.pub} lives."
  fi
  say ""
  say "to revoke later: delete the authorized_keys line ending \"$KEY_COMMENT\" on dexter."
}

do_verify() {
  if [ ! -f "$PUBKEY" ]; then
    skip "expected public key $PUBKEY not found -- nothing to verify"
    finish_verify
  fi
  if [ ! -f "${PUBKEY%.pub}" ]; then
    skip "private key ${PUBKEY%.pub} not present on this host -- cannot probe from here"
    finish_verify
  fi
  ok "key present: $PUBKEY"

  if ! ping -c1 -W2 dexter.tail893f2c.ts.net >/dev/null 2>&1 \
     && ! ping -c1 -W2 dexter.local >/dev/null 2>&1; then
    skip "dexter is not answering -- cannot check key trust while it is off"
    finish_verify
  fi

  if batch_ok; then
    ok "BatchMode ssh to zach@$DEXTER_HOST works with crt's deploy key"
  else
    fail "up, but BatchMode ssh as zach@$DEXTER_HOST is refused with this key -- run: ./crt-dexter-ssh-key.sh enable"
  fi

  finish_verify "OK -- dexter trusts crt's deploy key."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
