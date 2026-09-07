#!/usr/bin/env bash
PRIVILEGED=no
HOSTS=(mandark)
REACHES=()
set -uo pipefail   # random near-black tint per kitty process (Zach taste, 2026-09-02); RESTART required, listen_on can't reload (options/definition.py:2969)

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh
# shellcheck source=lib/kitty-proc.sh
. lib/kitty-proc.sh   # kitty_pid_starts -- shared with split-pane-chord.sh

TASTE_ID="kitty-window-tint"
TASTE_BLOCK="../lib/taste-block.sh"

KITTY_CONF="${SENECHAL_KITTY_CONF:-$HOME/.config/kitty/kitty.conf}"  # overridable for the test
BASHRC="${SENECHAL_BASHRC:-$HOME/.bashrc}"
KITTEN="${SENECHAL_KITTEN:-kitten}"
SOCKET_GLOB="${SENECHAL_KITTY_SOCKET_GLOB:-${XDG_RUNTIME_DIR:-/nonexistent}/senechal-kitty-*}"

read -r -d '' KITTY_CONTENT <<'EOF' || true
allow_remote_control socket-only
listen_on unix:${XDG_RUNTIME_DIR}/senechal-kitty
draw_minimal_borders yes
window_border_width 1px
EOF

read -r -d '' BASHRC_CONTENT <<'EOF' || true
__SENECHAL_KITTY_TINTS=(
  "#0e0001 #391416"
  "#080200 #2d1f00"
  "#000500 #152708"
  "#00040b #002536"
  "#040110 #231b3b"
  "#0a0007 #33152b"
)

__senechal_kitty_tint() {  # once per PROCESS; stamp records the pair so the next window avoids it
  [ -n "${KITTY_LISTEN_ON:-}" ] || return 0
  [ -n "${KITTY_PID:-}" ] || return 0
  [ -n "${XDG_RUNTIME_DIR:-}" ] || return 0
  local stamp="$XDG_RUNTIME_DIR/senechal-tint.$KITTY_PID"
  [ -e "$stamp" ] && return 0
  : > "$stamp" || return 0
  local taken="" pool pair bg edge f p   # reap dead stamps (socket gone) or all six read taken
  for f in "$XDG_RUNTIME_DIR"/senechal-tint.*; do
    [ -e "$f" ] || continue           # no matches: the glob stays literal
    p="${f##*.}"
    [ "$p" = "$KITTY_PID" ] && continue
    if [ -S "$XDG_RUNTIME_DIR/senechal-kitty-$p" ]; then
      taken="$taken$(cat "$f" 2>/dev/null)"$'\n'
    else
      rm -f "$f"
    fi
  done
  pool="$(printf '%s\n' "${__SENECHAL_KITTY_TINTS[@]}" | grep -vxF "$taken" || true)"  # || true: don't let pipefail kill the shell
  [ -n "$pool" ] || pool="$(printf '%s\n' "${__SENECHAL_KITTY_TINTS[@]}")"
  pair="$(printf '%s\n' "$pool" | shuf -n1)"
  printf '%s\n' "$pair" > "$stamp"
  bg="${pair%% *}"; edge="${pair##* }"  # errors below are swallowed -- a broken tint must not break a login shell
  kitten @ --to "$KITTY_LISTEN_ON" set-colors --all --configured \
    "background=$bg" \
    "active_border_color=$edge" \
    "inactive_border_color=$edge" \
    "tab_bar_background=$edge" \
    "active_tab_background=$edge" >/dev/null 2>&1 || true
}
__senechal_kitty_tint
EOF

KITTY_CONTENT_B64="$(printf '%s' "$KITTY_CONTENT" | base64 -w0)"
BASHRC_CONTENT_B64="$(printf '%s' "$BASHRC_CONTENT" | base64 -w0)"

tint_grounds() {  # derived, not restated, so there's no second list to drift
  printf '%s\n' "$BASHRC_CONTENT" |
    sed -n 's/^  "\(#[0-9a-f]\{6\}\) #[0-9a-f]\{6\}"$/\1/p'
}

taste_row() {
  local id file homes status owner notes
  while IFS=$'\x1f' read -r id file homes status owner notes; do
    [ "$id" = "$TASTE_ID" ] || continue
    printf '%s\x1f%s\x1f%s\x1f%s\n' "$id" "$file" "$homes" "$status"
    return 0
  done <<< "$(cfg_taste)"
  return 1
}

taste_disabled() {
  local row id file homes status
  row="$(taste_row)" || return 1
  IFS=$'\x1f' read -r id file homes status <<< "$row"
  [ "$status" = "disabled" ]
}

cmd_enable() {
  say "senechal remedy: a random near-black tint per kitty window (id: $TASTE_ID)"
  say ""

  if taste_disabled; then
    say "estate.taste[$TASTE_ID].status is \"disabled\" -- nothing to do."
    return 0
  fi

  local kitty_rc=0 bashrc_rc=0 out rc

  say "kitty: $KITTY_CONF"
  out="$("$TASTE_BLOCK" install "$KITTY_CONF" "$TASTE_ID" "$KITTY_CONTENT_B64" 2>&1)"; rc=$?
  say "  $out"
  [ "$rc" -eq 0 ] || kitty_rc=$RC_FAIL

  say "bash: $BASHRC"
  out="$("$TASTE_BLOCK" install "$BASHRC" "$TASTE_ID" "$BASHRC_CONTENT_B64" 2>&1)"; rc=$?
  say "  $out"
  [ "$rc" -eq 0 ] || bashrc_rc=$RC_FAIL

  say ""
  say "  RESTART kitty -- do not use ctrl+shift+f5. kitty does not support"
  say "  changing listen_on on a config reload, so a reloaded instance keeps"
  say "  its socket shut and every tint silently does nothing."
  say "  Already-running windows stay black until they are restarted."

  if [ "$(rc_severity "$kitty_rc")" -ge "$(rc_severity "$bashrc_rc")" ]; then
    return "$kitty_rc"
  fi
  return "$bashrc_rc"
}

cmd_disable() {
  say "senechal remedy: removing the kitty window tint (id: $TASTE_ID)"
  say ""

  local out rc worst=0
  say "kitty: $KITTY_CONF"
  out="$("$TASTE_BLOCK" remove "$KITTY_CONF" "$TASTE_ID" 2>&1)"; rc=$?
  say "  $out"
  [ "$rc" -eq 0 ] || worst=$RC_FAIL
  say "bash: $BASHRC"
  out="$("$TASTE_BLOCK" remove "$BASHRC" "$TASTE_ID" 2>&1)"; rc=$?
  say "  $out"
  [ "$rc" -eq 0 ] || worst=$RC_FAIL

  say ""
  say "  Restart kitty to go back to a black background. Stale tint stamps"
  say "  in \$XDG_RUNTIME_DIR are cleared at logout and need no cleanup."
  return "$worst"
}

cmd_verify() {
  head_ "a random near-black tint per kitty window (id: $TASTE_ID)"

  if taste_disabled; then
    skip "estate.taste[$TASTE_ID].status is \"disabled\" -- not expected to be in effect"
    finish_verify
    return
  fi

  local out rc
  out="$("$TASTE_BLOCK" verify "$KITTY_CONF" "$TASTE_ID" "$KITTY_CONTENT_B64" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "kitty: $out" || fail "kitty: $out"

  out="$("$TASTE_BLOCK" verify "$BASHRC" "$TASTE_ID" "$BASHRC_CONTENT_B64" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "bash: $out" || fail "bash: $out"

  if [ -f "$KITTY_CONF" ]; then
    if grep -qE '^[[:space:]]*allow_remote_control[[:space:]]+(socket-only|socket|yes)[[:space:]]*$' "$KITTY_CONF"; then
      ok "kitty: allow_remote_control permits the socket"
    else
      fail "kitty: no active allow_remote_control line -- listen_on is ignored without it, so the socket never opens"
    fi
    if grep -qE '^[[:space:]]*listen_on[[:space:]]+unix:' "$KITTY_CONF"; then
      ok "kitty: listen_on names a unix socket"
    else
      fail "kitty: no active 'listen_on unix:...' line -- the shell has nothing to talk to"
    fi
  else
    skip "kitty: $KITTY_CONF does not exist"
  fi

  local conf_epoch pid epoch stale=0 starts
  conf_epoch="$(stat -c %Y "$KITTY_CONF" 2>/dev/null)"
  if [ -n "$conf_epoch" ]; then
    if starts="$(kitty_pid_starts)"; then
      while read -r pid epoch; do
        [ -n "$pid" ] || continue
        if [ "$epoch" -lt "$conf_epoch" ]; then
          fail "kitty: pid $pid started $(date -d "@$epoch" '+%F %T') before the config's last change $(date -d "@$conf_epoch" '+%F %T') -- restart it, ctrl+shift+f5 will not open the socket"
          stale=1
        fi
      done <<< "$starts"
      [ "$stale" -eq 0 ] && ok "kitty: no running instance predates the config"
    else
      skip "kitty: pgrep unavailable -- cannot check whether a running instance predates the config"
    fi
  else
    skip "kitty: could not stat $KITTY_CONF's mtime"
  fi

  local sock socks=() ground grounds live=0 untinted=0
  for sock in $SOCKET_GLOB; do [ -S "$sock" ] && socks+=("$sock"); done

  if ! command -v "$KITTEN" >/dev/null 2>&1; then
    skip "live: $KITTEN not on PATH -- cannot ask any window its colour"
  elif [ "${#socks[@]}" -eq 0 ]; then
    skip "live: no control socket at $SOCKET_GLOB -- no kitty started since this was enabled, so nothing can be proved tinted"
  else
    grounds="$(tint_grounds)"
    local n_tints; n_tints="$(printf '%s\n' "$grounds" | grep -c .)"
    for sock in "${socks[@]}"; do
      ground="$("$KITTEN" @ --to "unix:$sock" get-colors 2>/dev/null |
                sed -n 's/^background[[:space:]]\+\(#\?[0-9a-fA-F]\{6\}\)[[:space:]]*$/\1/p' |
                head -n1)"
      ground="$(printf '%s' "$ground" | tr 'A-F' 'a-f')"
      case "$ground" in '#'*) ;; ?*) ground="#$ground" ;; esac
      if [ -z "$ground" ] || [ "$ground" = "#" ]; then
        fail "live: $(basename "$sock") answered no background colour -- the socket is open but set-colors never landed"
        untinted=1
      elif [ "$ground" = "#000000" ]; then
        fail "live: $(basename "$sock") is still #000000 -- config is on disk but this window was never tinted"
        untinted=1
      elif ! printf '%s\n' "$grounds" | grep -qxF "$ground"; then
        fail "live: $(basename "$sock") is $ground, which is not one of the $n_tints tints in $BASHRC -- a hand-edit or a stale block"
        untinted=1
      fi
      live=$((live + 1))
    done
    [ "$untinted" -eq 0 ] && ok "live: all $live running kitty window(s) carry a tint from the palette"
  fi

  finish_verify
}

main() {
  local verb="${1:-}"
  shift || true
  parse_common_args "$@"
  case "$verb" in
    enable)  cmd_enable ;;
    disable) cmd_disable ;;
    verify)  cmd_verify ;;
    *)
      say "usage: $(basename "$0") {enable|disable|verify} [-q|--quiet]"
      say ""
      say "  enable   open kitty's control socket and install the per-process"
      say "           random tint into .bashrc (idempotent)"
      say "  disable  remove both blocks, restoring each file byte for byte"
      say "  verify   check the config AND ask the running windows what colour"
      say "           they are; exit 0 pass / 5 fail / 2 could-not-check"
      exit 64
      ;;
  esac
}
main "$@"
