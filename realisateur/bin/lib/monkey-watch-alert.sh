#!/usr/bin/env bash
mw_epoch() { date -u -d "$1" +%s 2>/dev/null; }

mw_alert_decide() {  # <verdict> <last> <state_file> <alert_every_h> <now_iso> -> "NONE" | "TRANSITION <last> <verdict>" | "PERSIST <verdict> <down_h>"
  local verdict="$1" last="$2" state_file="$3" alert_every_h="$4" now_iso="$5"
  local since_file="$state_file.since" alert_file="$state_file.alerted"
  local now_epoch; now_epoch="$(mw_epoch "$now_iso")" || { echo NONE; return 0; }

  if [ "$verdict" != "$last" ]; then
    printf '%s\n' "$verdict" > "$state_file"
    printf '%s\n' "$now_iso" > "$since_file"
    if [ "$verdict" = PAUSED ] || { [ "$last" = PAUSED ] && [ "$verdict" = OK ]; }; then  # #704: entering/leaving a declared pause cleanly is not a fault; PAUSED->anything-but-OK still falls through, loud
      echo NONE
    elif [ -n "$last" ]; then
      echo "TRANSITION $last $verdict"
    else
      echo NONE
    fi
    return 0
  fi

  case "$verdict" in
    DOWN|DEGRADED) : ;;
    *) echo NONE; return 0 ;;
  esac

  local last_alert last_alert_epoch elapsed_alert_h
  last_alert="$(cat "$alert_file" 2>/dev/null || true)"
  last_alert_epoch="$([ -n "$last_alert" ] && mw_epoch "$last_alert" || true)"
  if [ -z "$last_alert_epoch" ]; then
    echo "PERSIST $verdict $(mw_down_hours "$since_file" "$now_epoch")"
    return 0
  fi
  elapsed_alert_h=$(( (now_epoch - last_alert_epoch) / 3600 ))
  if [ "$elapsed_alert_h" -ge "$alert_every_h" ]; then
    echo "PERSIST $verdict $(mw_down_hours "$since_file" "$now_epoch")"
  else
    echo NONE
  fi
}

mw_down_hours() {  # <since_file> <now_epoch> -> hours since the file's timestamp, or 0
  local since since_epoch
  since="$(cat "$1" 2>/dev/null || true)"
  [ -n "$since" ] || { echo 0; return 0; }
  since_epoch="$(mw_epoch "$since")" || { echo 0; return 0; }
  echo $(( ("$2" - since_epoch) / 3600 ))
}

mw_alert_mark_sent() { printf '%s\n' "$2" > "$1.alerted"; }  # <state_file> <now_iso> -- call once zaxon_ask actually returned a ticket
