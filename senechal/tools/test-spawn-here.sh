#!/usr/bin/env bash
# Tests for tools/spawn-here.
#
#   ./test-spawn-here.sh          # everything runnable here
#   ./test-spawn-here.sh --live   # also spawn real windows (needs DISPLAY)
#   [rest: vault:senechal/header-archaeology-20260818.md]

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPAWN="$HERE/spawn-here"
FAILED=0
LIVE=0
[ "${1:-}" = "--live" ] && LIVE=1

ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; FAILED=1; }
skip() { printf '  skip %s\n' "$*"; }

expect_rc() {
  local want="$1" desc="$2"; shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  [ "$got" = "$want" ] && ok "$desc (rc=$got)" || bad "$desc: wanted rc=$want, got $got"
}

echo "offline:"
[ -x "$SPAWN" ] && ok "spawn-here is executable" || bad "spawn-here is not executable"
expect_rc 2 "no command given exits 2 (could-not-act, not silent success)" "$SPAWN"
expect_rc 2 "no DISPLAY exits 2" env -u DISPLAY "$SPAWN" -- true
expect_rc 1 "unknown option exits 1" "$SPAWN" --nonsense -- true
expect_rc 2 "non-numeric --desktop exits 2" "$SPAWN" --desktop three -- true
expect_rc 0 "--help exits 0" "$SPAWN" --help

if [ -n "${DISPLAY:-}" ] && command -v wmctrl >/dev/null; then
  n=$(wmctrl -d | wc -l)
  expect_rc 2 "--desktop beyond the last desktop exits 2" "$SPAWN" --desktop $((n + 1)) -- true
  expect_rc 1 "a command that opens no window exits 1" "$SPAWN" --timeout 2 -- true
else
  skip "desktop-range and no-window cases (no DISPLAY/wmctrl)"
fi

if [ "$LIVE" != 1 ]; then
  echo "live: skipped (pass --live to run; it opens and closes real windows)"
  exit $FAILED
fi

echo "live:"
if [ -z "${DISPLAY:-}" ] || ! command -v wmctrl >/dev/null; then
  skip "live tests need DISPLAY and wmctrl"
  exit 2
fi

DESKTOPS=$(wmctrl -d | wc -l)
[ "$DESKTOPS" -ge 2 ] || { skip "live race test needs at least 2 virtual desktops"; exit 2; }
HOME_DESK=$(wmctrl -d | awk '$2=="*"{print $1}')          # 0-based
AWAY_DESK=$(( (HOME_DESK + 1) % DESKTOPS ))
restore() { wmctrl -s "$HOME_DESK"; }
trap restore EXIT

# Which desktop did a freshly-spawned konsole end up on? Echoes the
# 0-based desktop index, or empty if no window showed up.
desk_of_new_konsole() {
  local before after id
  before=$(wmctrl -lx | awk '/konsole\.konsole/{print $1}' | sort)
  "$@" &
  local job=$!
  sleep 0.6
  wmctrl -s "$AWAY_DESK"      # <-- the race: leave while the window is still loading
  sleep 4
  after=$(wmctrl -lx | awk '/konsole\.konsole/{print $1}' | sort)
  id=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)
  [ -n "$id" ] && wmctrl -lx | awk -v w="$id" '$1==w{print $2}'
  [ -n "$id" ] && wmctrl -i -c "$id"
  wait "$job" 2>/dev/null
  wmctrl -s "$HOME_DESK"
  sleep 0.5
}

control=$(desk_of_new_konsole konsole -e sleep 12)
if [ -z "$control" ]; then
  skip "control: no konsole window appeared -- cannot demonstrate the race"
elif [ "$control" = "$AWAY_DESK" ]; then
  ok "control reproduces the bug: bare konsole followed us to desktop $((AWAY_DESK + 1))"
else
  skip "control: bare konsole landed on desktop $((control + 1)), race did not reproduce this run"
fi

treatment=$(desk_of_new_konsole "$SPAWN" -q --class konsole -- konsole -e sleep 12)
if [ -z "$treatment" ]; then
  bad "treatment: spawn-here produced no window"
elif [ "$treatment" = "$HOME_DESK" ]; then
  ok "treatment: spawn-here held the window on the launch desktop $((HOME_DESK + 1))"
else
  bad "treatment: window landed on desktop $((treatment + 1)), wanted $((HOME_DESK + 1))"
fi

exit $FAILED
