#!/usr/bin/env bash
kitty_pid_starts() {  # "pid epoch" lines; shared by split-pane-chord.sh + kitty-window-tint.sh (both FAIL a kitty predating kitty.conf's mtime, #503), real or injected via SENECHAL_KITTY_PID_STARTS
  if [ -n "${SENECHAL_KITTY_PID_STARTS+x}" ]; then
    printf '%s\n' "$SENECHAL_KITTY_PID_STARTS"
    return 0
  fi
  command -v pgrep >/dev/null 2>&1 || return 1
  local pid start epoch
  while read -r pid; do
    [ -n "$pid" ] || continue
    start="$(ps -o lstart= -p "$pid" 2>/dev/null)" || continue
    epoch="$(date -d "$start" +%s 2>/dev/null)" || continue
    printf '%s %s\n' "$pid" "$epoch"
  done < <(pgrep -x kitty 2>/dev/null)
  return 0
}
