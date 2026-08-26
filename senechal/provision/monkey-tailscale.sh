#!/usr/bin/env bash
# monkey-tailscale.sh -- put the self-dev host `monkey` on the tailnet.
#
#   [rest: vault:realisateur/guard-archaeology-20260817.md]

set -euo pipefail

JUMP="${MONKEY_JUMP:-dexter}"          # reached via ~/.ssh/config alias
KEYFILE="${MONKEY_KEYFILE:-\$HOME/.ssh/selfdev_monkey}"   # lives ON the jump host
PORT="${MONKEY_PORT:-2225}"
USER_ON_MONKEY="${MONKEY_USER:-zach}"
HOSTNAME_WANTED="${MONKEY_TS_HOSTNAME:-monkey}"

die()  { printf 'monkey-tailscale: %s\n' "$*" >&2; exit 1; }
info() { printf '  %-8s %s\n' "$1" "$2"; }

# Run a script on monkey, through dexter. The script is base64-encoded so it
# crosses two shells without quoting damage -- the ancestor script records a
#   [rest: vault:realisateur/guard-archaeology-20260817.md]
on_monkey() {
  local script b64
  script="$1"
  b64="$(printf '%s' "$script" | base64 -w0)"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$JUMP" \
    "ssh -i $KEYFILE -o BatchMode=yes -o ConnectTimeout=10 -p $PORT \
        ${USER_ON_MONKEY}@127.0.0.1 \"echo $b64 | base64 -d | bash -s\""
}

# Put a secret on monkey, reading it from STDIN, at mode 0600.
#
#   [rest: vault:realisateur/guard-archaeology-20260817.md]
push_secret() {                 # $1 = filename under $HOME on monkey
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$JUMP" \
    "ssh -i $KEYFILE -o BatchMode=yes -o ConnectTimeout=10 -p $PORT \
        ${USER_ON_MONKEY}@127.0.0.1 \"umask 077; cat > \\\$HOME/$1\""
}

MODE="${1:---check}"

case "$MODE" in
--check)
  echo "== monkey tailscale (--check) =="
  out="$(on_monkey '
    printf "HOST=%s\n" "$(hostname -s)"
    printf "TAILSCALE=%s\n" "$(command -v tailscale || echo none)"
    printf "TAILSCALED=%s\n" "$(systemctl is-active tailscaled 2>/dev/null || echo inactive)"
    printf "STATUS=%s\n" "$(tailscale ip -4 2>/dev/null | head -1 || echo none)"
    printf "SUDO_NOPASS=%s\n" "$(sudo -n true 2>/dev/null && echo yes || echo no)"
    printf "OS=%s\n" "$(. /etc/os-release; echo "$ID $VERSION_ID")"
  ' 2>&1)" || die "cannot reach monkey through $JUMP -- $out"

  # Parsed, never eval'd. `OS=ubuntu 24.04` through `eval` runs `24.04` as a
  # command -- which is both a bug and a reminder that this text came off
  # another machine and has no business being executed here.
  field() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }
  HOST="$(field HOST)";           TAILSCALE="$(field TAILSCALE)"
  TAILSCALED="$(field TAILSCALED)"; STATUS="$(field STATUS)"
  SUDO_NOPASS="$(field SUDO_NOPASS)"; OS="$(field OS)"
  [ "$HOST" = "monkey" ] || die "reached a host named '$HOST', not monkey -- refusing to go further"
  info OK "reached monkey through $JUMP ($OS)"
  if [ "$TAILSCALE" = none ]; then
    info MISSING "tailscale is not installed"
  else
    info OK "tailscale at $TAILSCALE (daemon: $TAILSCALED, ip: $STATUS)"
  fi
  [ "$SUDO_NOPASS" = yes ] \
    && info OK      "sudo needs no password; --install can run unattended" \
    || info NEEDS   "sudo needs a password -> run ./monkey-nopasswd.sh --install once"
  echo
  echo "check only. Nothing changed."
  ;;

--install)
  [ -n "${TS_AUTHKEY:-}" ] || die "TS_AUTHKEY is unset. Generate one at
    https://login.tailscale.com/admin/settings/keys and export it. This script
    will not invent a credential, and will not read one out of a file."

  # PRECONDITION, not a fallback. An earlier version accepted a sudo password
  # as an alternative and fed it to `sudo -S`; that path is gone, because it
  #   [rest: vault:realisateur/guard-archaeology-20260817.md]
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$JUMP" \
     "ssh -i $KEYFILE -o BatchMode=yes -p $PORT ${USER_ON_MONKEY}@127.0.0.1 \
      'sudo -n true'" >/dev/null 2>&1 \
    || die "sudo on monkey still needs a password. Run
    ./monkey-nopasswd.sh --install once, from a terminal, and re-run this."
  echo "  OK       sudo is passwordless on monkey"

  echo "== monkey tailscale (--install) =="

  # The key travels on STDIN into a 0600 file. See push_secret for why not
  # env (it does not cross ssh) and why not argv (visible in `ps`).
  printf '%s' "$TS_AUTHKEY" | push_secret .ts-authkey \
    || die "could not place the auth key on monkey"

  # Idempotent: re-running `tailscale up` with the same flags is a no-op
  # rather than a second node.
  out="$(on_monkey '
    set -e
    K="$HOME/.ts-authkey"
    # Delete the key on ANY exit path, including failure. A credential left
    # in a home directory because the script died early is worse than the
    # failure that killed it.
    trap "rm -f \"$K\"" EXIT
    KEY="$(cat "$K" 2>/dev/null || true)"

    # THE GUARD THIS SCRIPT DID NOT HAVE, and the reason the first run hung.
    # `tailscale up --authkey=` with an EMPTY value is not an error to
    #   [rest: vault:realisateur/guard-archaeology-20260817.md]
    case "$KEY" in
      "")        echo "REFUSED: the auth key arrived EMPTY on monkey" >&2; exit 2 ;;
      tskey-*)   : ;;
      *)         echo "REFUSED: value does not look like a tailscale auth key" >&2; exit 2 ;;
    esac

    if ! command -v tailscale >/dev/null 2>&1; then
      echo "installing tailscale..."
      curl -fsSL https://tailscale.com/install.sh -o /tmp/ts-install.sh
      sudo -n bash /tmp/ts-install.sh >/dev/null 2>&1
      rm -f /tmp/ts-install.sh
    else
      echo "tailscale already present: $(tailscale --version | head -1)"
    fi
    sudo -n systemctl enable --now tailscaled

    # --timeout so a wedged join fails instead of hanging the whole chain.
    sudo -n tailscale up --authkey="$KEY" \
        --hostname="'"$HOSTNAME_WANTED"'" --ssh=false --timeout=90s
    printf "IP=%s\n" "$(tailscale ip -4 | head -1)"
    printf "BACKEND=%s\n" "$(tailscale status | head -1)"
  ' 2>&1)" || die "install failed:
$out"
  printf '%s\n' "$out" | sed 's/^/  /'
  echo
  echo "Now verify FROM mandark (this is the witness that matters):"
  echo "    tailscale status | grep monkey"
  echo "    ssh monkey hostname -s        # should print: monkey"
  echo "    cd ~/Documents/Projects/ecosim && sonde run rotation | grep monkey"
  echo
  echo "Then file it, because a systemd unit on another host is machine-wide:"
  echo "    notify-senechal 'monkey joined the tailnet: tailscaled installed and"
  echo "    enabled on the monkey VM (VirtualBox guest on dexter). Owned by"
  echo "    realisateur/provision/monkey-tailscale.sh. Retire with:"
  echo "    sudo tailscale logout && sudo systemctl disable --now tailscaled'"
  ;;

*) die "usage: monkey-tailscale.sh [--check|--install]" ;;
esac
