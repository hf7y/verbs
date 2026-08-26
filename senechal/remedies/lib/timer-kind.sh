#!/usr/bin/env bash
# Shared engine for remedies that are "a systemd --user timer + oneshot
# service, installed from generated unit content, checked for drift on
# verify" -- #348 phase 4. Two callers so far, auto-apply-remedies-timer.sh
# and estate-health-timer.sh, which before this were ~85% identical files
# (same install/enable/disable/verify shape, same LIVE test-mode gate,
# different unit content and epilogue text).
#
# Not sourced standalone -- a caller sources ../lib/common.sh first, then
# this file, then defines service_content/timer_content (the unit file
# generators) and the data vars below, then calls the toggle_timer_*
# functions. This file has no CLI of its own and is not picked up by
# verify-all.sh's `./*.sh` glob or auto-apply-remedies.sh's
# `remedies/*.sh` pathspec (neither crosses the lib/ subdirectory) --
# same shape as toggle-kinds.sh, whose header explains why that matters
# for the auto-apply safety gate.
#
# Vars read: INTERVAL, INTERVAL_CFG_KEY (dotted senechal.json key, for the
# malformed-interval error message -- leave unset/empty for a caller whose
# timer isn't interval-driven, e.g. an OnCalendar=daily one: the format
# check and the "interval $INTERVAL" verify wording both skip), SERVICE_NAME,
# TIMER_NAME, UNIT_DIR, LIVE.
#
# Optional hook, no-op by default: timer_enable_post, called once the
# timer is armed (LIVE only) -- a caller with an epilogue (e.g. "run one
# check now", extra "check it worked with" lines) redefines it AFTER
# sourcing this file, same function-redefinition-wins-at-call-time pattern
# toggle-kinds.sh uses for _mask_run/_mask_query.
timer_enable_post() { :; }

# A systemd time span (15m, 1h, 2d, 30s) as seconds. Callers validate the
# format with the same case pattern toggle_timer_enable uses; anything
# unparseable echoes 0, which a caller must treat as "could not tell".
interval_seconds() {
  local v="${1:-}" n="${1%[smhd]}" unit="${1: -1}"
  case "$n" in ''|*[!0-9]*) printf '0\n'; return ;; esac
  case "$unit" in
    s) printf '%s\n' "$n" ;;
    m) printf '%s\n' "$(( n * 60 ))" ;;
    h) printf '%s\n' "$(( n * 3600 ))" ;;
    d) printf '%s\n' "$(( n * 86400 ))" ;;
    *) printf '0\n' ;;
  esac
}

# Transport indirection, same function-redefinition-after-sourcing pattern
# as toggle-kinds.sh's _mask_run/_mask_query. Local default: a --user
# timer, plain file writes -- both existing callers (auto-apply-remedies,
# estate-health) are this shape and never need to know these exist. A
# caller installing a SYSTEM unit (root-owned files, sudo systemctl, no
# --user) redefines all four after sourcing this file -- smart-health.sh
# is the first (#348 phase 4 fourth kind).
_timer_ctl() { systemctl --user "$@"; }
_timer_ctl_reachable() { systemctl --user show-environment >/dev/null 2>&1; }
_timer_write_file() { # $1 dest, $2 mode, content on stdin
  local dest="$1" mode="$2" content
  content="$(cat)"
  mkdir -p "$(dirname "$dest")" || die "could not create $(dirname "$dest")"
  printf '%s\n' "$content" > "$dest" || die "could not write $dest"
  chmod "$mode" "$dest"
}
_timer_remove_file() { rm -f "$1"; }

_timer_install_file() { # $1 dest, $2 mode (default 0644), content on stdin
  local dest="$1" mode="${2:-0644}" content
  content="$(cat)"
  if [ -f "$dest" ] && [ "$(cat "$dest" 2>/dev/null)" = "$content" ]; then
    say "  $dest -- already correct, untouched"
    return 0
  fi
  local b
  b="$(backup_file "$dest")" && [ -n "$b" ] && say "  backed up old $dest -> $b"
  printf '%s\n' "$content" | _timer_write_file "$dest" "$mode"
  say "  wrote $dest"
}

toggle_timer_enable() {
  if [ -n "${INTERVAL_CFG_KEY:-}" ]; then
    case "$INTERVAL" in
      *[!0-9a-z]*|''|[!0-9]*|*[!smhd]) die "$INTERVAL_CFG_KEY='$INTERVAL' is not a simple systemd time span (e.g. 15m, 1h)" ;;
    esac
  fi
  [ "$LIVE" -eq 1 ] || say "  (test mode: unit dir overridden, no systemctl will run)"

  # THE UNIT IS READ LONG AFTER THIS RUN. Whatever path lands in ExecStart
  # or WorkingDirectory is what systemd executes for months, so it is
  # checked HERE -- against the generated content, not against a caller's
  # variable, so a caller cannot forget the guard by naming its path
  # something else. Both callers reached this line with $SENECHAL_ROOT
  # baked in, and on 2026-08-22 21:23 that was a mktemp -d.
  local unit line path
  unit="$(service_content)"
  while IFS= read -r line; do
    case "$line" in
      ExecStart=*|WorkingDirectory=*) path="${line#*=}"; path="${path%% *}" ;;
      *) continue ;;
    esac
    [ -n "$path" ] || continue
    refuse_undeployable_path "$path" "$SERVICE_NAME's ${line%%=*}" || return "$RC_INCOMPLETE"
  done <<<"$unit"

  printf '%s\n' "$unit" | _timer_install_file "$UNIT_DIR/$SERVICE_NAME"
  timer_content   | _timer_install_file "$UNIT_DIR/$TIMER_NAME"

  if [ "$LIVE" -eq 1 ]; then
    _timer_ctl daemon-reload || die "daemon-reload failed"
    _timer_ctl enable --now "$TIMER_NAME" || die "could not enable $TIMER_NAME"
    say "  timer armed; next run: $(_timer_ctl show "$TIMER_NAME" -p NextElapseUSecRealtime --value 2>/dev/null || echo '?')"
    timer_enable_post
  else
    say "  (test mode: skipped daemon-reload / enable)"
  fi
}

toggle_timer_disable() {
  if [ "$LIVE" -eq 1 ]; then
    _timer_ctl disable --now "$TIMER_NAME" 2>/dev/null || say "  (timer was not enabled)"
  fi
  local f
  for f in "$UNIT_DIR/$SERVICE_NAME" "$UNIT_DIR/$TIMER_NAME"; do
    [ -f "$f" ] && _timer_remove_file "$f" && say "  removed $f"
  done
  [ "$LIVE" -eq 1 ] && _timer_ctl daemon-reload
}

# The common drift + armed-state checks. The missing-files early exit
# calls finish_verify directly (it prints the buffered report and exits
# the process) exactly like the two callers already did before this
# existed -- nothing else is worth checking if the unit isn't even
# installed. The no-systemd-to-ask paths (test mode / no session bus)
# `return` instead, on purpose: a caller with its own post-engine checks
# that don't touch systemd (smart-health.sh's dump-file analysis) must
# still run them, not be truncated by an exit buried in here. A caller's
# own verify_ wraps this between a head_ and a closing finish_verify
# "OK -- ..." message, since only the caller knows what "OK" should say.
toggle_timer_verify() {
  local missing=0 f
  for f in "$UNIT_DIR/$SERVICE_NAME" "$UNIT_DIR/$TIMER_NAME"; do
    [ -f "$f" ] || { fail "$f missing -- remedy not installed (run: ./$(basename "$0") enable)"; missing=1; }
  done
  [ "$missing" -eq 0 ] || finish_verify

  [ "$(cat "$UNIT_DIR/$SERVICE_NAME")" = "$(service_content)" ] \
    && ok "$SERVICE_NAME matches this script's content" \
    || fail "$SERVICE_NAME drifted from this script -- re-run enable"
  if [ -n "${INTERVAL_CFG_KEY:-}" ]; then
    [ "$(cat "$UNIT_DIR/$TIMER_NAME")" = "$(timer_content)" ] \
      && ok "$TIMER_NAME matches this script's content (interval $INTERVAL)" \
      || fail "$TIMER_NAME drifted (senechal.json says $INTERVAL) -- re-run enable"
  else
    [ "$(cat "$UNIT_DIR/$TIMER_NAME")" = "$(timer_content)" ] \
      && ok "$TIMER_NAME matches this script's content" \
      || fail "$TIMER_NAME drifted -- re-run enable"
  fi

  if [ "$LIVE" -ne 1 ]; then
    skip "test mode -- no live systemd to ask about $TIMER_NAME"
    return
  fi

  # A --user timer needs a session bus to be asked about at all. Under
  # cron there is none, and "systemctl --user" fails: that is a SKIP,
  # never a pass -- same trap as the missing-DISPLAY one. A SYSTEM timer
  # caller redefines _timer_ctl_reachable to always succeed: no session
  # bus is needed to read system-unit state, even under cron.
  if ! _timer_ctl_reachable; then
    skip "no user session bus reachable (cron/ssh context) -- cannot ask whether $TIMER_NAME is armed"
    return
  fi

  [ "$(_timer_ctl is-enabled "$TIMER_NAME" 2>/dev/null)" = "enabled" ] \
    && ok "$TIMER_NAME is enabled" \
    || fail "$TIMER_NAME not enabled -- re-run enable"
  _timer_ctl is-active --quiet "$TIMER_NAME" 2>/dev/null \
    && ok "$TIMER_NAME is active (waiting for next elapse)" \
    || fail "$TIMER_NAME not active -- re-run enable"

  # ARMED IS NOT RUNNING. Every check above passes for a timer that fires
  # perfectly on schedule into a service that dies instantly -- which is
  # what both --user timers did for 22 hours after their ExecStart was
  # baked as a temp path (203/EXEC, "Exec format error / no such file").
  # The timer was enabled, active, and next-elapse was minutes away the
  # whole time. Ask the SERVICE how its last run went.
  local result
  result="$(_timer_ctl show "$SERVICE_NAME" -p Result --value 2>/dev/null)"
  case "$result" in
    success|'')
      ok "$SERVICE_NAME's last run did not fail (Result=${result:-none yet})" ;;
    exit-code)
      # SuccessExitStatus= already absorbs each caller's reporting codes, so
      # reaching here means an exit the caller did NOT declare survivable.
      fail "$SERVICE_NAME last exited outside its declared success codes (Result=$result, status=$(_timer_ctl show "$SERVICE_NAME" -p ExecMainStatus --value 2>/dev/null)) -- run: systemctl --user status $SERVICE_NAME" ;;
    *)
      fail "$SERVICE_NAME's last run failed (Result=$result) -- the timer is armed and firing into a service that dies. Run: systemctl --user status $SERVICE_NAME" ;;
  esac
}
