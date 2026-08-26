#!/usr/bin/env bash
# Concern: the Plasma panel is not visible on screen.
#
#   ./plasma-panel-visible.sh enable    # apply it (run by hand, once)
#   ./plasma-panel-visible.sh verify    # check it's in effect (no AI, cron-safe)
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

# ---- the concern's definition of "correct", single-sourced -------------
APPLETSRC="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
SHELLRC="$HOME/.config/plasmashellrc"
SERVICE="plasma-plasmashell.service"

KEEP_PANEL=2            # the panel Zach wants (2026-07-28, his call)
DROP_PANEL=53           # hand-built replacement, superseded
DROP_SYSTRAY=59         # its system tray containment

WANT_VISIBILITY=0       # NormalPanel -- always visible, reserves struts

# =======================================================================
# helpers
# =======================================================================

# True if containment $2 in file $1 is an org.kde.panel.
_is_panel() {
  python3 - "$1" "$2" <<'PY'
import sys
f, cid = sys.argv[1], sys.argv[2]
want = f'[Containments][{cid}]'
sec, keys = None, {}
for line in open(f, encoding='utf-8', errors='replace'):
    line = line.rstrip('\n')
    if line.startswith('['):
        sec = line
    elif sec == want and '=' in line:
        k, _, v = line.partition('=')
        keys[k.strip()] = v.strip()
sys.exit(0 if keys.get('plugin') == 'org.kde.panel' else 1)
PY
}

# Every containment id that is a panel, space separated.
_panel_ids() {
  local id out=""
  for id in $(grep -oE '^\[Containments\]\[[0-9]+\]$' "$1" 2>/dev/null \
                | grep -oE '[0-9]+' | sort -un); do
    _is_panel "$1" "$id" && out="$out $id"
  done
  printf '%s' "${out# }"
}

# Read one key from one exact INI section. Empty if absent.
# Section-aware on purpose: common.sh's ini_set matches keys file-wide,
# and panelVisibility legitimately appears under several
# [PlasmaViews][Panel N] sections.
_ini_get() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
f, want, key = sys.argv[1], sys.argv[2], sys.argv[3]
sec = None
for line in open(f, encoding='utf-8', errors='replace'):
    line = line.rstrip('\n')
    if line.startswith('['):
        sec = line
    elif sec == want and '=' in line:
        k, _, v = line.partition('=')
        if k.strip() == key:
            print(v.strip())
            break
PY
}

# Set one key in one exact INI section, creating the section if needed.
_ini_set_section() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
f, want, key, val = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    lines = open(f, encoding='utf-8', errors='replace').read().splitlines(True)
except FileNotFoundError:
    lines = []
out, sec, wrote = [], None, False
for line in lines:
    s = line.rstrip('\n')
    if s.startswith('['):
        if sec == want and not wrote:          # leaving target section
            out.append(f'{key}={val}\n'); wrote = True
        sec = s
    elif sec == want and '=' in s and s.split('=', 1)[0].strip() == key:
        if not wrote:
            out.append(f'{key}={val}\n'); wrote = True
        continue                                # drop old line + duplicates
    out.append(line)
if sec == want and not wrote:
    out.append(f'{key}={val}\n'); wrote = True
if not wrote:
    if out and not out[-1].endswith('\n'):
        out.append('\n')
    out.append(f'\n{want}\n{key}={val}\n')
open(f, 'w', encoding='utf-8').write(''.join(out))
PY
}

# Applet ids present in containment $2 but missing from its AppletOrder.
# These are loaded but never laid out -- invisible passengers.
_orphan_applets() {
  python3 - "$1" "$2" <<'PY'
import sys, re
f, cid = sys.argv[1], sys.argv[2]
sec, order, present = None, None, []
for line in open(f, encoding='utf-8', errors='replace'):
    s = line.rstrip('\n')
    if s.startswith('['):
        sec = s
        m = re.fullmatch(rf'\[Containments\]\[{cid}\]\[Applets\]\[(\d+)\]', s)
        if m:
            present.append(m.group(1))
    elif sec == f'[Containments][{cid}][General]' and s.startswith('AppletOrder='):
        order = s.split('=', 1)[1].strip()
if order is None:
    sys.exit(0)                 # no declared order -- do not guess
listed = {x for x in order.split(';') if x}
print(' '.join(a for a in present if a not in listed))
PY
}

# Remove whole INI sections whose header starts with any given prefix.
_strip_sections() {
  local f="$1"; shift
  python3 - "$f" "$@" <<'PY'
import sys
f, prefixes = sys.argv[1], tuple(sys.argv[2:])
drop, out = False, []
for line in open(f, encoding='utf-8', errors='replace'):
    if line.startswith('['):
        drop = line.rstrip('\n').startswith(prefixes)
    if not drop:
        out.append(line)
sys.stdout.write(''.join(out))
PY
}

_stop_shell() {
  systemctl --user is-active --quiet "$SERVICE" || return 1
  systemctl --user stop "$SERVICE"
  local i=0
  while systemctl --user is-active --quiet "$SERVICE" && [ $i -lt 20 ]; do
    sleep 0.5; i=$((i + 1))
  done
  return 0
}

# =======================================================================
# enable
# =======================================================================
cmd_enable() {
  say "senechal remedy: rebuild the Plasma panel's view so it shows again"
  say "Backups go to $BACKUP_ROOT/<timestamp>/"
  say ""

  [ -f "$APPLETSRC" ] || die "no $APPLETSRC -- nothing to fix. Is Plasma installed?"
  if ! _is_panel "$APPLETSRC" "$KEEP_PANEL"; then
    die "containment $KEEP_PANEL is not an org.kde.panel -- refusing to guess. Inspect $APPLETSRC by hand."
  fi
  say "1/5 panel containment $KEEP_PANEL present, with its applets intact."

  # --- 2. stop the shell BEFORE editing --------------------------------
  # plasmashell rewrites BOTH files on exit. Editing live means the
  # running shell clobbers the edit the moment it shuts down. This is
  # also why the fix cannot be applied through the scripting API alone.
  local was_running=0
  if _stop_shell; then
    was_running=1
    say "2/5 stopped $SERVICE so it cannot overwrite our edits on exit."
  else
    say "2/5 $SERVICE not running -- editing directly."
  fi

  # --- 3a. THE FIX, part one: panel visibility mode ----------------------
  local b cur
  b="$(backup_file "$SHELLRC")"
  [ -n "$b" ] && say "3/5 backed up -> $b"

  cur="$(_ini_get "$SHELLRC" "[PlasmaViews][Panel $KEEP_PANEL]" panelVisibility)"
  _ini_set_section "$SHELLRC" "[PlasmaViews][Panel $KEEP_PANEL]" \
                   panelVisibility "$WANT_VISIBILITY"
  say "3/5 Panel $KEEP_PANEL panelVisibility: ${cur:-<unset>} -> $WANT_VISIBILITY (always visible)."

  # Stale view state for the superseded panel, so it cannot resurface.
  if [ -f "$SHELLRC" ] && grep -q "^\[PlasmaViews\]\[Panel $DROP_PANEL\]" "$SHELLRC"; then
    local tmp="$SHELLRC.senechal-tmp"
    _strip_sections "$SHELLRC" "[PlasmaViews][Panel $DROP_PANEL]" > "$tmp"
    mv "$tmp" "$SHELLRC"
    say "3/5 removed stale view state [PlasmaViews][Panel $DROP_PANEL]."
  fi

  # --- 3b. THE FIX, part two: orphaned applets --------------------------
  # Applets present in the containment but absent from AppletOrder are
  # loaded and never laid out. Nine had accumulated.
  local orphans
  orphans="$(_orphan_applets "$APPLETSRC" "$KEEP_PANEL")"
  if [ -n "$orphans" ]; then
    local b3 tmp3 pfx=""
    b3="$(backup_file "$APPLETSRC")"
    [ -n "$b3" ] && say "3/5 backed up -> $b3"
    local o
    for o in $orphans; do
      pfx="$pfx [Containments][$KEEP_PANEL][Applets][$o]"
    done
    tmp3="$APPLETSRC.senechal-tmp"
    # shellcheck disable=SC2086
    _strip_sections "$APPLETSRC" $pfx > "$tmp3"
    mv "$tmp3" "$APPLETSRC"
    say "3/5 removed orphaned applets not in AppletOrder:$(printf ' %s' $orphans)"
  else
    say "3/5 no orphaned applets in containment $KEEP_PANEL."
  fi

  # --- 4. the duplicate containment, if still present -------------------
  if _is_panel "$APPLETSRC" "$DROP_PANEL"; then
    local b2 tmp2
    b2="$(backup_file "$APPLETSRC")"
    [ -n "$b2" ] && say "4/5 backed up -> $b2"
    tmp2="$APPLETSRC.senechal-tmp"
    _strip_sections "$APPLETSRC" \
      "[Containments][$DROP_PANEL]" "[Containments][$DROP_SYSTRAY]" > "$tmp2"
    if ! grep -q "^\[Containments\]\[$KEEP_PANEL\]$" "$tmp2"; then
      rm -f "$tmp2"
      die "post-edit file lost containment $KEEP_PANEL -- refusing to install it. Original untouched."
    fi
    mv "$tmp2" "$APPLETSRC"
    say "4/5 removed duplicate containments $DROP_PANEL and $DROP_SYSTRAY."
  else
    say "4/5 no duplicate panel containment -- nothing to remove."
  fi

  # --- 5. bring the shell back -----------------------------------------
  if [ "$was_running" -eq 1 ]; then
    say "5/5 starting $SERVICE..."
    systemctl --user start "$SERVICE"
    sleep 8
  else
    say "5/5 leaving $SERVICE stopped (it was not running when we started)."
  fi

  say ""
  say "Done. What senechal could NOT do for you:"
  say "  - Confirm with your own eyes that the panel is on screen."
  say "    Run: $0 verify"
  say "  - If it is still missing, restore with:"
  say "      systemctl --user stop $SERVICE"
  say "      cp '$b' '$SHELLRC'"
  say "      systemctl --user start $SERVICE"
  say "    and tell senechal: neither the visibility mode nor the orphaned"
  say "    applets were the cause, which leaves clearing the panel's"
  say "    persisted view state, then rebuilding onto a fresh containment."
}

# =======================================================================
# verify -- non-AI, cron-safe
# =======================================================================
cmd_verify() {
  head_ "Plasma panel: visibility mode is 'always visible'"
  if [ ! -f "$SHELLRC" ]; then
    skip "$SHELLRC does not exist"
  else
    local vis
    vis="$(_ini_get "$SHELLRC" "[PlasmaViews][Panel $KEEP_PANEL]" panelVisibility)"
    case "${vis:-0}" in
      0) ok "Panel $KEEP_PANEL panelVisibility=${vis:-unset (defaults to 0)} -- always visible" ;;
      1) fail "Panel $KEEP_PANEL panelVisibility=1 (AutoHide) -- hidden until you hover the screen edge" ;;
      2) fail "Panel $KEEP_PANEL panelVisibility=2 (LetWindowsCover) -- sits below windows, invisible whenever anything is on screen" ;;
      3) warn_ "Panel $KEEP_PANEL panelVisibility=3 (WindowsGoBelow) -- unusual but not hidden" ;;
      *) warn_ "Panel $KEEP_PANEL panelVisibility=$vis -- unrecognised value" ;;
    esac
  fi

  head_ "Plasma panel: no orphaned applets"
  if [ ! -f "$APPLETSRC" ]; then
    skip "$APPLETSRC does not exist"
  else
    local orph
    orph="$(_orphan_applets "$APPLETSRC" "$KEEP_PANEL")"
    if [ -z "$orph" ]; then
      ok "every applet in containment $KEEP_PANEL is in AppletOrder"
    else
      warn_ "applets loaded but not laid out:$(printf ' %s' $orph)"
      note "invisible passengers -- they accumulate across crashes; $0 enable clears them"
    fi
  fi

  head_ "Plasma panel: exactly one bottom-edge panel containment"
  if [ ! -f "$APPLETSRC" ]; then
    skip "$APPLETSRC does not exist"
  else
    local panels count
    panels="$(_panel_ids "$APPLETSRC")"
    count="$(printf '%s\n' $panels | grep -c . || true)"
    if [ "$count" -eq 0 ]; then
      fail "no org.kde.panel containment -- you have no panel at all"
    elif [ "$count" -eq 1 ] && [ "$panels" = "$KEEP_PANEL" ]; then
      ok "exactly one panel containment, and it is the intended one ($KEEP_PANEL)"
    elif [ "$count" -eq 1 ]; then
      warn_ "one panel containment, but it is $panels, not the intended $KEEP_PANEL"
    else
      fail "$count panel containments compete for the same edge: $panels"
    fi
  fi

  # --- the witness that actually matters --------------------------------
  # A panel can be present, correctly configured, at the right geometry,
  # and still invisible -- that was this entire outage. WM_STATE is the
  # discriminator: it only exists once the window manager has actually
  # managed a mapped window.
  head_ "Plasma panel: a dock window is mapped and managed by the WM"
  if ! have_display; then
    skip "no reachable display -- cannot look at the screen"
  elif [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    skip "Wayland session -- X window inspection would not see the panel surface"
  elif ! command -v xwininfo >/dev/null 2>&1 || ! command -v xprop >/dev/null 2>&1; then
    skip "xwininfo/xprop not installed -- cannot inspect windows"
  else
    local w docks=0 mapped=0 managed=0
    for w in $(xwininfo -root -tree 2>/dev/null | grep -oE '0x[0-9a-f]+' | sort -u); do
      xprop -id "$w" _NET_WM_WINDOW_TYPE 2>/dev/null | grep -q '_NET_WM_WINDOW_TYPE_DOCK' || continue
      xprop -id "$w" WM_CLASS 2>/dev/null | grep -q 'plasmashell' || continue
      docks=$((docks + 1))
      xwininfo -id "$w" 2>/dev/null | grep -q 'Map State: IsViewable' && mapped=$((mapped + 1))
      xprop -id "$w" WM_STATE 2>/dev/null | grep -q 'window state' && managed=$((managed + 1))
    done
    if [ "$docks" -eq 0 ]; then
      fail "plasmashell has no dock window at all -- no panel exists on screen"
    elif [ "$mapped" -eq 0 ]; then
      fail "$docks plasmashell dock window(s) exist but NONE are mapped -- panel is invisible"
      note "if WM_STATE is also absent the view was never mapped: $0 enable"
    elif [ "$managed" -eq 0 ]; then
      fail "$mapped dock window(s) mapped but none have WM_STATE -- the WM never managed them"
    else
      ok "$mapped of $docks dock window(s) mapped, $managed managed by the WM"
    fi
  fi

  head_ "Plasma shell: no recent unclean exit"
  if ! command -v systemctl >/dev/null 2>&1; then
    skip "systemctl not available"
  else
    local n
    n="$(systemctl --user show "$SERVICE" -p NRestarts --value 2>/dev/null || true)"
    if [ -z "$n" ]; then
      skip "could not read $SERVICE restart count"
    elif [ "$n" = "0" ]; then
      ok "$SERVICE has not restarted this session"
    else
      warn_ "$SERVICE has restarted $n time(s) this session"
      note "check for OOM: journalctl --user -u $SERVICE | grep -i oom"
    fi
  fi

  finish_verify "OK -- panel is visible and managed by the window manager."
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
      say "usage: $0 {enable|verify} [-q]"
      say ""
      say "  enable   set panel $KEEP_PANEL always-visible, drop orphaned applets, restart the shell"
      say "  verify   check the panel is configured visible AND mapped on screen"
      exit 64
      ;;
  esac
}

main "$@"
