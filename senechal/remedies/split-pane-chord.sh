#!/usr/bin/env bash
# Concern: ctrl+shift+enter opens a split pane, in kitty and Firefox (Zach
# taste, 2026-08-27; here not in a dotfile since #344 rebuilds this machine).
#
# kitty 0.32.2: unset enabled_layouts defaults to `fat`, and --location= is
# honoured only by `splits` (kitty/layout/splits.py:442) -- a map line alone
# silently no-ops without `enabled_layouts splits`, which verify checks
# explicitly rather than trusting the map line's presence. Exit contract
# (lib/common.sh): 0 pass / 5 fail / 2 could-not-check.

PRIVILEGED=no
HOSTS=(mandark)
REACHES=()
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh
# shellcheck source=lib/kitty-proc.sh
. lib/kitty-proc.sh   # kitty_pid_starts -- shared with kitty-window-tint.sh

TASTE_ID="split-pane-chord"
TASTE_BLOCK="../lib/taste-block.sh"

# Overridable so the test can sandbox every path.
KITTY_CONF="${SENECHAL_KITTY_CONF:-$HOME/.config/kitty/kitty.conf}"
FF_ROOT="${SENECHAL_FIREFOX_ROOT:-$HOME/.mozilla/firefox}"
# A command, not a boolean, so the test can swap it.
FF_PGREP="${SENECHAL_FIREFOX_PGREP:-pgrep -x firefox}"

FF_KEY_ID="key_addTabSplitView"
FF_MODIFIERS="accel,shift"
FF_KEYCODE="VK_RETURN"

# ---- the kitty half's content, read by every verb ---------------------
read -r -d '' KITTY_CONTENT <<'EOF' || true
# Zach taste (2026-08-27). enabled_layouts is load-bearing -- see the
# header of remedies/split-pane-chord.sh. `stack` is kept second so
# ctrl+shift+l becomes zoom-this-pane rather than going inert.
enabled_layouts splits,stack

# --location=split measures the ACTIVE PANE and splits along its longer
# side (splits.py:463), re-read every split: side-by-side on a wide
# window, stacked once a pane is taller than wide. Resizing changes
# FUTURE splits; existing ones are flipped by hand with the key below.
map kitty_mod+enter launch --location=split --cwd=current

# backslash: ctrl+shift+r is already start_resizing_window.
map kitty_mod+backslash layout_action rotate 90
EOF

KITTY_CONTENT_B64="$(printf '%s' "$KITTY_CONTENT" | base64 -w0)"

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

# =======================================================================
# Firefox profile resolution
# =======================================================================
# The [ProfileN] section with Default=1. THE PREFIX FILTER IS
# LOAD-BEARING: [InstallXXXX] also has a Default key, holding a profile
# path rather than the flag, and would otherwise match. Derived, never
# hardcoded -- a retired remedy (stale-backup-sweep.sh, hf7y/senechal#451
# step 3) once pinned a literal profile while mozilla-firefox-real.sh
# derives it, and those two already disagreed.
ff_profile_dir() {
  local ini="$FF_ROOT/profiles.ini" sec path
  [ -f "$ini" ] || return 1
  while read -r sec; do
    case "$sec" in Profile*) ;; *) continue ;; esac
    [ "$(ini_get "$ini" "$sec" Default)" = "1" ] || continue
    path="$(ini_get "$ini" "$sec" Path)"
    [ -n "$path" ] || continue
    case "$path" in
      /*) printf '%s\n' "$path" ;;
      *)  printf '%s\n' "$FF_ROOT/$path" ;;
    esac
    return 0
  done <<< "$(ini_sections_with_key "$ini" Default)"
  return 1
}

ff_custom_keys() { printf '%s/customKeys.json' "$1"; }

# The chord Firefox holds for our key id, as "<modifiers> <keycode>".
# Absent file, bad JSON and absent key are all "not set".
ff_current_chord() {
  local f="$1"
  [ -f "$f" ] || return 1
  python3 - "$f" "$FF_KEY_ID" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
e = d.get(sys.argv[2])
if not isinstance(e, dict):
    sys.exit(1)
print("%s %s" % (e.get("modifiers", ""), e.get("keycode", "")))
PY
}

# =======================================================================
# enable
# =======================================================================
cmd_enable() {
  say "senechal remedy: ctrl+shift+enter splits, in kitty and Firefox (id: $TASTE_ID)"
  say ""

  if taste_disabled; then
    say "estate.taste[$TASTE_ID].status is \"disabled\" -- nothing to do."
    return 0
  fi

  local kitty_rc=0 ff_rc=0

  # ---- kitty ----------------------------------------------------------
  say "kitty: $KITTY_CONF"
  if [ -f "$KITTY_CONF" ]; then
    backup_file "$KITTY_CONF" >/dev/null
  fi
  if "$TASTE_BLOCK" install "$KITTY_CONF" "$TASTE_ID" "$KITTY_CONTENT_B64" | sed 's/^/  /'; then
    :
  else
    warn "could not write $KITTY_CONF"
    kitty_rc=$RC_FAIL
  fi

  # ---- Firefox --------------------------------------------------------
  say ""
  local prof f
  if ! prof="$(ff_profile_dir)"; then
    warn "no [Profile*] section with Default=1 in $FF_ROOT/profiles.ini -- cannot tell which profile is yours"
    ff_rc=$RC_INCOMPLETE
  elif [ ! -d "$prof" ]; then
    warn "profiles.ini names $prof, which does not exist"
    ff_rc=$RC_INCOMPLETE
  else
    f="$(ff_custom_keys "$prof")"
    say "Firefox: $f"
    # Before the liveness refusal: an already-correct chord needs no
    # write, and reporting INCOMPLETE there would cry about a machine
    # that is fully configured. about:keyboard is how this gets set.
    if [ "$(ff_current_chord "$f" 2>/dev/null)" = "$FF_MODIFIERS $FF_KEYCODE" ]; then
      say "  already correct -- left alone"
    # Firefox holds customKeys in memory and saveSoon()s it
    # (CustomKeys.sys.mjs:30), so a write under a running Firefox is
    # silently discarded on exit. Refuse rather than write into the void.
    elif $FF_PGREP >/dev/null 2>&1; then
      warn "Firefox is running -- a write here is discarded when it exits. Quit Firefox, then re-run."
      ff_rc=$RC_INCOMPLETE
    else
      [ -f "$f" ] && backup_file "$f" >/dev/null
      # Merge, never overwrite: this file is the whole about:keyboard set.
      if python3 - "$f" "$FF_KEY_ID" "$FF_MODIFIERS" "$FF_KEYCODE" <<'PY'
import json, os, sys
path, key, mods, code = sys.argv[1:5]
d = {}
if os.path.exists(path):
    try:
        d = json.load(open(path))
    except Exception:
        d = {}
    if not isinstance(d, dict):
        d = {}
d[key] = {"modifiers": mods, "keycode": code}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as fh:
    json.dump(d, fh, separators=(",", ":"))
PY
      then
        say "  set $FF_KEY_ID -> $FF_MODIFIERS $FF_KEYCODE"
      else
        warn "could not write $f"
        ff_rc=$RC_FAIL
      fi
    fi
  fi

  say ""
  say "Neither half reaches a process that is already running."
  say "  kitty:   restart it, or press ctrl+shift+f5 to reload the config"
  say "  Firefox: restart it"
  say ""
  say "Then check it worked:   ./split-pane-chord.sh verify"

  # Worst half wins, by severity rather than by number.
  if [ "$(rc_severity "$kitty_rc")" -ge "$(rc_severity "$ff_rc")" ]; then
    return "$kitty_rc"
  fi
  return "$ff_rc"
}

# =======================================================================
# disable
# =======================================================================
# taste-block.sh installs but does not remove. Deletes the marker pair
# AND the blank line install prepends, so disable restores the file byte
# for byte -- asserted by the test, since "reversible" claimed and not
# measured is how a remedy becomes one-way.

cmd_disable() {
  say "senechal remedy: removing the ctrl+shift+enter split chord (id: $TASTE_ID)"
  say ""

  say "kitty: $KITTY_CONF"
  if [ -f "$KITTY_CONF" ]; then
    backup_file "$KITTY_CONF" >/dev/null
    "$TASTE_BLOCK" remove "$KITTY_CONF" "$TASTE_ID" >/dev/null
    say "  block removed (kitty falls back to its stock fat layout)"
  else
    say "  absent -- nothing to remove"
  fi

  say ""
  local prof f
  if prof="$(ff_profile_dir)" && [ -d "$prof" ]; then
    f="$(ff_custom_keys "$prof")"
    say "Firefox: $f"
    if $FF_PGREP >/dev/null 2>&1; then
      warn "Firefox is running -- quit it first, or this edit is discarded on exit."
      return "$RC_INCOMPLETE"
    fi
    if [ -f "$f" ]; then
      backup_file "$f" >/dev/null
      # Only our key. Firefox reads an absent entry as "use the default",
      # and the shipped default for this id is no chord (browser.xhtml:392).
      python3 - "$f" "$FF_KEY_ID" <<'PY'
import json, os, sys
path, key = sys.argv[1:3]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(0)
if isinstance(d, dict) and key in d:
    del d[key]
    if d:
        with open(path, "w") as fh:
            json.dump(d, fh, separators=(",", ":"))
    else:
        os.remove(path)
PY
      say "  $FF_KEY_ID unset"
    else
      say "  absent -- nothing to remove"
    fi
  else
    say "Firefox: no default profile resolved -- nothing to remove"
  fi
  return "$RC_PASS"
}

# =======================================================================
# verify -- no AI, no network, safe to cron
# =======================================================================
cmd_verify() {
  head_ "ctrl+shift+enter splits, in kitty and Firefox (id: $TASTE_ID)"

  if taste_disabled; then
    skip "estate.taste[$TASTE_ID].status is \"disabled\" -- not expected to be in effect"
    finish_verify
    return
  fi

  # ---- kitty ----------------------------------------------------------
  local out rc
  out="$("$TASTE_BLOCK" verify "$KITTY_CONF" "$TASTE_ID" "$KITTY_CONTENT_B64" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "kitty: $out"
  else
    fail "kitty: $out"
  fi

  # Separately from the block check above, which passes or fails as one
  # unit: these name WHICH line a hand-edit removed.
  if [ -f "$KITTY_CONF" ]; then
    if grep -qE '^[[:space:]]*enabled_layouts[[:space:]]+splits' "$KITTY_CONF"; then
      ok "kitty: enabled_layouts starts with splits (without this, --location is ignored)"
    else
      fail "kitty: no active 'enabled_layouts splits...' line -- the map line alone is a silent no-op"
    fi
    if grep -qE '^[[:space:]]*map[[:space:]]+kitty_mod\+enter[[:space:]]+launch[[:space:]]+--location=split' "$KITTY_CONF"; then
      ok "kitty: kitty_mod+enter is bound to launch --location=split"
    else
      fail "kitty: kitty_mod+enter is not bound to launch --location=split"
    fi

    local conf_epoch pid epoch stale=0 starts
    conf_epoch="$(stat -c %Y "$KITTY_CONF" 2>/dev/null)" # on disk != in memory: kitty reads its config once at startup (#503)
    if [ -n "$conf_epoch" ]; then
      if starts="$(kitty_pid_starts)"; then
        while read -r pid epoch; do
          [ -n "$pid" ] || continue
          if [ "$epoch" -lt "$conf_epoch" ]; then
            fail "kitty: pid $pid started $(date -d "@$epoch" '+%F %T') before the config's last change $(date -d "@$conf_epoch" '+%F %T') -- reload with ctrl+shift+f5 or restart"
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
  else
    skip "kitty: $KITTY_CONF does not exist"
  fi

  # ---- Firefox --------------------------------------------------------
  local prof f chord want
  want="$FF_MODIFIERS $FF_KEYCODE"
  if ! prof="$(ff_profile_dir)"; then
    skip "Firefox: no [Profile*] with Default=1 in $FF_ROOT/profiles.ini"
  elif [ ! -d "$prof" ]; then
    fail "Firefox: profiles.ini names $prof, which does not exist"
  elif ! chord="$(ff_current_chord "$(ff_custom_keys "$prof")")"; then
    fail "Firefox: $FF_KEY_ID has no chord in $(ff_custom_keys "$prof") -- split view is unbound"
  elif [ "$chord" != "$want" ]; then
    fail "Firefox: $FF_KEY_ID is '$chord', expected '$want'"
  else
    ok "Firefox: $FF_KEY_ID = $chord ($(basename "$prof"))"
  fi

  finish_verify
}

# =======================================================================
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
      say "  enable   bind ctrl+shift+enter to an aspect-aware split in kitty,"
      say "           and to split view in Firefox (idempotent)"
      say "  disable  remove both bindings, restoring kitty.conf byte for byte"
      say "  verify   check both are actually set; exit 0 pass / 5 fail /"
      say "           2 could-not-check"
      exit 64
      ;;
  esac
}
main "$@"
