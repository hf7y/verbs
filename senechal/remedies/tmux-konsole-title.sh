#!/usr/bin/env bash
# Concern: tmux -> Konsole window/tab title. See ../CONCERNS.md.
#
#   ./tmux-konsole-title.sh enable    # apply it (run by hand, once)
#   ./tmux-konsole-title.sh verify    # check it's in effect (no AI, cron-safe)
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

# ---- the concern's definition of "correct", single-sourced -------------
TMUX_CONF="$HOME/.tmux.conf"
BASHRC="$HOME/.bashrc"
KONSOLE_DIR="$HOME/.local/share/konsole"

WANT_TITLE_STRING='#S'          # tmux: session name, nothing else
WANT_KONSOLE_FORMAT='%w'        # Konsole: show tmux's string verbatim
DEAD_BASH_HOOK='precmd'         # zsh hook bash never calls -- must not be live

# =======================================================================
# enable
# =======================================================================
cmd_enable() {
  say "senechal remedy: tmux -> Konsole title"
  say "Backups go to $BACKUP_ROOT/<timestamp>/"
  say ""
  local changed=0 b

  # --- 1. tmux owns the title -----------------------------------------
  if [ -f "$TMUX_CONF" ] \
     && grep -qE '^[[:space:]]*set(-option)? -g set-titles on' "$TMUX_CONF" \
     && grep -qF "set-titles-string \"$WANT_TITLE_STRING\"" "$TMUX_CONF"; then
    say "1/3 ~/.tmux.conf already correct -- left alone."
  else
    b="$(backup_file "$TMUX_CONF")"
    [ -n "$b" ] && say "1/3 backed up ~/.tmux.conf -> $b"
    # Drop any existing set-titles* lines, then write ours. Other tmux
    # settings in the file are preserved.
    if [ -f "$TMUX_CONF" ]; then
      grep -vE '^[[:space:]]*set(w|-option|-window-option)? *-g *set-titles' "$TMUX_CONF" > "$TMUX_CONF.senechal-tmp" || true
      mv "$TMUX_CONF.senechal-tmp" "$TMUX_CONF"
    fi
    cat >> "$TMUX_CONF" <<EOF

# tmux owns the outer terminal's title; the shell doesn't touch it.
set -g set-titles on
set -g set-titles-string "$WANT_TITLE_STRING"
EOF
    # allow-rename off is load-bearing: it stops the app running *inside*
    # tmux (e.g. Claude Code, which sets its own OSC title) from
    # clobbering the session name. Only add if absent.
    grep -qE '^[[:space:]]*set -g allow-rename' "$TMUX_CONF" \
      || printf '%s\n' 'set -g allow-rename off        # stop in-tmux apps clobbering the title' >> "$TMUX_CONF"
    say "1/3 wrote set-titles / set-titles-string \"$WANT_TITLE_STRING\" to ~/.tmux.conf"
    changed=1
  fi

  # --- 2. the shell stops trying ---------------------------------------
  if [ -f "$BASHRC" ] && grep -qE "^[[:space:]]*${DEAD_BASH_HOOK}\(\)" "$BASHRC"; then
    b="$(backup_file "$BASHRC")"
    say "2/3 backed up ~/.bashrc -> $b"
    # Remove the precmd function block (function line through its closing
    # brace at column 0) -- it's a zsh hook, bash never called it.
    awk '
      /^[[:space:]]*precmd\(\)/ { inblock=1; next }
      inblock && /^\}/          { inblock=0; next }
      inblock                   { next }
      { print }
    ' "$BASHRC" > "$BASHRC.senechal-tmp"
    mv "$BASHRC.senechal-tmp" "$BASHRC"
    say "2/3 removed the dead ${DEAD_BASH_HOOK}() block from ~/.bashrc"
    changed=1
  else
    say "2/3 ~/.bashrc has no live ${DEAD_BASH_HOOK}() -- nothing to remove."
  fi

  # --- 3. Konsole displays it verbatim ---------------------------------
  if [ -d "$KONSOLE_DIR" ] && compgen -G "$KONSOLE_DIR/*.profile" >/dev/null; then
    for p in "$KONSOLE_DIR"/*.profile; do
      if grep -qxF "LocalTabTitleFormat=$WANT_KONSOLE_FORMAT" "$p"; then
        say "3/3 $(basename "$p") already correct -- left alone."
        continue
      fi
      b="$(backup_file "$p")"
      say "3/3 backed up $(basename "$p") -> $b"
      ini_set "$p" General LocalTabTitleFormat "$WANT_KONSOLE_FORMAT"
      say "3/3 set LocalTabTitleFormat=$WANT_KONSOLE_FORMAT in $(basename "$p")"
      changed=1
    done
  else
    warn "no Konsole profile found in $KONSOLE_DIR -- skipping step 3."
    note ""
    say "    Konsole only writes a profile once you've customised one."
    say "    Create a profile (Settings > Manage Profiles > New), then re-run."
  fi

  # --- hand-holding: what's live, and what you must still do -----------
  say ""
  if [ "$changed" -eq 0 ]; then
    say "Nothing to change -- already applied."
  fi
  say "Config edits alone change nothing. Two steps to make it live:"
  say ""
  if have_tmux_server; then
    tmux source-file "$TMUX_CONF"
    tmux refresh-client 2>/dev/null || true
    say "  1. reload tmux .................. DONE, did it for you"
  else
    say "  1. reload tmux .................. NOT NEEDED, no server running"
    say "     (it reads the config when it next starts)"
  fi
  say "  2. open a NEW Konsole window .... YOU MUST DO THIS"
  say "     Existing windows keep the old title format until Konsole"
  say "     re-reads the profile. Nothing else will make them update."
  say ""
  say "Then check it worked:   ./tmux-konsole-title.sh verify"
}

# =======================================================================
# verify -- no AI, no network, safe to cron
# =======================================================================
cmd_verify() {
  head_ "tmux -> Konsole title (see CONCERNS.md)"

  # --- disk state ------------------------------------------------------
  if [ ! -f "$TMUX_CONF" ]; then
    fail "~/.tmux.conf does not exist"
  else
    grep -qE '^[[:space:]]*set(-option)? -g set-titles on' "$TMUX_CONF" \
      && ok "~/.tmux.conf: set-titles on" \
      || fail "~/.tmux.conf: 'set -g set-titles on' missing"
    grep -qF "set-titles-string \"$WANT_TITLE_STRING\"" "$TMUX_CONF" \
      && ok "~/.tmux.conf: set-titles-string \"$WANT_TITLE_STRING\"" \
      || fail "~/.tmux.conf: set-titles-string is not \"$WANT_TITLE_STRING\""
  fi

  if [ -f "$BASHRC" ] && grep -qE "^[[:space:]]*${DEAD_BASH_HOOK}\(\)" "$BASHRC"; then
    fail "~/.bashrc defines ${DEAD_BASH_HOOK}() again -- a zsh hook bash never calls (dead code, and it fought tmux for the title)"
  else
    ok "~/.bashrc: no dead ${DEAD_BASH_HOOK}() hook"
  fi

  if [ -d "$KONSOLE_DIR" ] && compgen -G "$KONSOLE_DIR/*.profile" >/dev/null; then
    for p in "$KONSOLE_DIR"/*.profile; do
      if grep -qxF "LocalTabTitleFormat=$WANT_KONSOLE_FORMAT" "$p"; then
        ok "$(basename "$p"): LocalTabTitleFormat=$WANT_KONSOLE_FORMAT"
      elif grep -q '^LocalTabTitleFormat=' "$p"; then
        fail "$(basename "$p"): LocalTabTitleFormat=$(grep -m1 '^LocalTabTitleFormat=' "$p" | cut -d= -f2-) (want $WANT_KONSOLE_FORMAT)"
        note "if you changed this in Konsole's own settings dialog, that's your"
        note "call, not drift -- update WANT_KONSOLE_FORMAT here instead."
      else
        fail "$(basename "$p"): no LocalTabTitleFormat set"
      fi
    done
  else
    skip "no Konsole profile in $KONSOLE_DIR"
  fi

  # --- live state: disk != what's loaded -------------------------------
  if have_tmux_server; then
    local live_on live_str
    live_on="$(tmux show -gv set-titles 2>/dev/null || echo '?')"
    live_str="$(tmux show -gv set-titles-string 2>/dev/null || echo '?')"
    [ "$live_on" = "on" ] \
      && ok "running tmux server: set-titles=on" \
      || fail "running tmux server: set-titles=$live_on -- config on disk was never loaded. Run: tmux source-file ~/.tmux.conf"
    [ "$live_str" = "$WANT_TITLE_STRING" ] \
      && ok "running tmux server: set-titles-string=$live_str" \
      || fail "running tmux server: set-titles-string=$live_str (want $WANT_TITLE_STRING). Run: tmux source-file ~/.tmux.conf"
  else
    skip "no tmux server running -- cannot check live options"
  fi

  # --- the witness: did the title reach the glass? ---------------------
  # Guarded, because wmctrl through a pipe returns the pipeline's status
  # and a missing display would otherwise read as a silent pass.
  if ! have_display; then
    skip "no reachable display (or wmctrl absent) -- cannot read window titles"
    note "expected under cron; it has no DISPLAY. Everything above still holds."
  elif ! have_tmux_server; then
    skip "no tmux server -- nothing to match window titles against"
  else
    # Only Konsole windows (wmctrl -lx field 3 is the WM class) -- matching
    # against every window on the desktop false-positives immediately, e.g.
    # plasmashell's "Desktop @ QRect(0,0 1920x1080)" contains "0" and "1",
    # which would "confirm" sessions named 0 and 1.
    local titles sessions s
    titles="$(wmctrl -lx 2>/dev/null | awk '$3 ~ /[Kk]onsole/ { $1=$2=$3=$4=""; sub(/^ +/,""); print }')"
    # Only *attached* sessions -- a detached session has no terminal
    # window by definition, so requiring one would always fail.
    sessions="$(tmux list-clients -F '#{client_session}' 2>/dev/null | sort -u)"

    if [ -z "$titles" ]; then
      skip "no Konsole windows found -- cannot witness the title"
    elif [ -z "$sessions" ]; then
      skip "no attached tmux client -- nothing that should be showing a title"
    else
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        if printf '%s' "$titles" | grep -qF -- "$s"; then
          ok "a Konsole window title contains attached tmux session \"$s\""
        else
          fail "no Konsole window title contains attached session \"$s\" -- the title is not reaching Konsole"
          note "Konsole titles seen: $(printf '%s' "$titles" | tr '\n' '|')"
          note "if you only just ran enable, open a NEW Konsole window first."
        fi
      done <<< "$sessions"
    fi
  fi

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
      say "  enable   apply the tmux -> Konsole title fix (idempotent)"
      say "  verify   check it is actually in effect; exit 0 pass / 1 fail / 2 could-not-check"
      exit 64
      ;;
  esac
}
main "$@"
