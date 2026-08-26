#!/usr/bin/env bash
# Concern: color-hashed user@host prompt, one Zach "taste" applied across
# every home he has a shell on. See CONCERNS.md and senechal.json's
# estate.taste (id: colorhash-prompt).
#
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

TASTE_ID="colorhash-prompt"
TASTE_BLOCK="../lib/taste-block.sh"
SSH_TIMEOUT=8

# ---- the concern's content, single-sourced, read by both verbs --------
# Live at every shell start: hashes "$(whoami)" and "$(hostname)"
# SEPARATELY, each into its own 256-color cube code, and colors \u and
# \h independently -- the "@" stays with the host, uncolored on its own,
#   [rest: vault:senechal/header-archaeology-20260818.md]
read -r -d '' TASTE_CONTENT <<'EOF' || true
# Zach taste: color-hash user and host separately in the prompt so each
# home/session is visually distinct at a glance (scheduler -i 2026-07-29
# 22:44; hashed separately per Zach 2026-08-05).
__senechal_taste_colorhash() {
  local h
  h=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
  echo $(( 16 + (h % 216) ))
}
PS1='${debian_chroot:+($debian_chroot)}\[\e[38;5;'"$(__senechal_taste_colorhash "$(whoami)")"'m\]\u\[\e[00m\]@\[\e[38;5;'"$(__senechal_taste_colorhash "$(hostname)")"'m\]\h\[\e[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
EOF

TASTE_CONTENT_B64="$(printf '%s' "$TASTE_CONTENT" | base64 -w0)"

# ---- read the taste's own registry row ---------------------------------
# homes field: comma-joined `account@host` tokens. This entry still
# declares plain `hosts: [...]` in senechal.json and deliberately has NOT
# been migrated -- cfg_taste expands that shorthand to zach@<host>, which
# is what it always meant. Reaching each home is resolve_home's job
# (lib/common.sh), shared with remedies/claude-slash-commands.sh, so
# neither script carries its own idea of who lives where.
taste_row() {
  local id file homes status owner notes
  while IFS=$'\x1f' read -r id file homes status owner notes; do
    [ "$id" = "$TASTE_ID" ] || continue
    printf '%s\x1f%s\x1f%s\x1f%s\n' "$id" "$file" "$homes" "$status"
    return 0
  done <<< "$(cfg_taste)"
  return 1
}

# =======================================================================
# enable
# =======================================================================
cmd_enable() {
  say "senechal remedy: color-hashed user@host prompt (id: $TASTE_ID)"
  say ""

  local row id file homes status
  if ! row="$(taste_row)"; then
    die "senechal.json has no estate.taste entry with id \"$TASTE_ID\" -- nothing to apply."
  fi
  IFS=$'\x1f' read -r id file homes status <<< "$row"

  if [ "$status" != "enabled" ]; then
    say "estate.taste[$id].status is \"$status\", not \"enabled\" -- nothing to do."
    say "(flip it to \"enabled\" in senechal.json to apply this taste again.)"
    return 0
  fi

  local h mode arg rc=0
  IFS=',' read -ra HOME_LIST <<< "$homes"
  for h in "${HOME_LIST[@]}"; do
    [ -n "$h" ] || continue
    IFS=$'\x1f' read -r mode arg <<< "$(resolve_home "$h")"
    case "$mode" in
      local)
        say "$h (local): $HOME/$file"
        "$TASTE_BLOCK" install "$HOME/$file" "$id" "$TASTE_CONTENT_B64" | sed "s/^/  /"
        ;;
      ssh)
        say "$h (ssh $arg): ~/$file"
        if ! enable_remote "$arg" "$file" "$id"; then
          warn "$h: could not reach or write ~/$file over ssh -- left unchanged"
          rc=1
        fi
        ;;
      *)
        warn "$h: $arg -- skipping"
        rc=1
        ;;
    esac
  done

  say ""
  say "Config edits alone change nothing for shells already running."
  say "Open a NEW terminal (or \`source ~/.bashrc\`) on each host to see it."
  say ""
  say "Then check it worked:   ./colorhash-prompt.sh verify"
  return "$rc"
}

# Apply the block to a remote ~/<file> by round-tripping it through a
# local temp copy: fetch, mutate with the same idempotent installer used
# locally, write back only if it actually changed. Never pushes any
# script to the remote host -- the remote side only ever sees `cat`.
enable_remote() {
  local ssh_host="$1" file="$2" id="$3" tmp before after
  tmp="$(mktemp)"
  if ! ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$ssh_host" \
        "cat ~/$file 2>/dev/null" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  before="$(cat "$tmp")"
  "$TASTE_BLOCK" install "$tmp" "$id" "$TASTE_CONTENT_B64" | sed "s/^/  /"
  after="$(cat "$tmp")"
  if [ "$before" = "$after" ]; then
    rm -f "$tmp"
    return 0
  fi
  if ! ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$ssh_host" \
        "cp ~/$file ~/$file.senechal-taste-backup.\$(date +%Y%m%d-%H%M%S) 2>/dev/null; cat > ~/$file" < "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  return 0
}

# =======================================================================
# verify -- no AI, no network beyond a BatchMode ssh, safe to cron
# =======================================================================
cmd_verify() {
  head_ "color-hashed user@host prompt (id: $TASTE_ID, see CONCERNS.md)"

  local row id file homes status
  if ! row="$(taste_row)"; then
    fail "senechal.json has no estate.taste entry with id \"$TASTE_ID\""
    finish_verify
    return
  fi
  IFS=$'\x1f' read -r id file homes status <<< "$row"

  if [ "$status" != "enabled" ]; then
    skip "estate.taste[$id].status is \"$status\" -- not expected to be in effect"
    finish_verify
    return
  fi

  local h mode arg out rc
  IFS=',' read -ra HOME_LIST <<< "$homes"
  for h in "${HOME_LIST[@]}"; do
    [ -n "$h" ] || continue
    IFS=$'\x1f' read -r mode arg <<< "$(resolve_home "$h")"
    case "$mode" in
      local)
        out="$("$TASTE_BLOCK" verify "$HOME/$file" "$id" "$TASTE_CONTENT_B64" 2>&1)"; rc=$?
        [ "$rc" -eq 0 ] && ok "$h: $out" || fail "$h: $out"
        ;;
      ssh)
        local tmp
        tmp="$(mktemp)"
        if ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$arg" \
              "cat ~/$file 2>/dev/null" > "$tmp" 2>/dev/null; then
          out="$("$TASTE_BLOCK" verify "$tmp" "$id" "$TASTE_CONTENT_B64" 2>&1)"; rc=$?
          [ "$rc" -eq 0 ] && ok "$h: $out" || fail "$h: $out"
        else
          skip "$h: could not reach over BatchMode ssh -- not known to be broken"
        fi
        rm -f "$tmp"
        ;;
      undeclared)
        fail "$h: $arg"
        ;;
      *)
        skip "$h: $arg"
        ;;
    esac
  done

  finish_verify
}

# =======================================================================
main() {
  local verb="${1:-}"
  shift || true
  parse_common_args "$@"
  case "$verb" in
    enable) cmd_enable ;;
    verify) cmd_verify ;;
    *)
      say "usage: $(basename "$0") {enable|verify} [-q|--quiet]"
      say ""
      say "  enable   apply the color-hashed user@host prompt on every host in"
      say "           estate.taste[$TASTE_ID]'s homes (idempotent)"
      say "  verify   check it is actually in effect everywhere; exit 0 pass /"
      say "           1 fail / 2 could-not-check"
      exit 64
      ;;
  esac
}
main "$@"
