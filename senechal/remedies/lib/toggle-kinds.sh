#!/usr/bin/env bash
# Shared engine for remedies that boil down to "is this one setting on or
# off" -- probe for #348 phase 4 (does a remedy collapse into engine +
# data?). Two kinds live here: grub-kernel-param and systemd-mask-unit.
# mandark-unused-software.sh already proves a third kind (per-item
# apt/snap/localbin removal, dispatched off senechal.json data) without
# needing this file.
#
# Not sourced standalone -- a caller sources ../lib/common.sh first (for
# say/ok/fail/skip/warn_/note/die/backup_file), then this file, then sets
# the kind's data variables before calling its enable/disable/verify
# functions. This file has no CLI of its own and is not picked up by
# verify-all.sh's `./*.sh` glob or auto-apply-remedies.sh's
# `remedies/*.sh` pathspec (neither crosses the lib/ subdirectory).
#
# Escape hatch found by the probe: a privileged action (sudo) must stay
# TEXTUALLY present in the calling wrapper, not just in this file --
# tools/auto-apply-remedies.sh greps each remedies/*.sh file itself for
# `\bsudo\b` to decide whether enable is safe to auto-apply. Moving the
# sudo invocation itself in here would make that grep blind to it. Both
# kinds below take SUDO_CMD as a variable so the wrapper's own
# `SUDO_CMD="${SENECHAL_SUDO_CMD-sudo}"` line keeps the literal token
# where the safety gate can see it.
#
# Second escape hatch, found probing systemd-mask-unit against a REMOTE
# unit (dexter-getty-tty1.sh, masked over ssh, not local): the kind
# cannot always run systemctl directly. toggle_systemd_mask_* therefore
# never calls $SYSTEMCTL itself -- it goes through _mask_run (privileged:
# mask/reset-failed/unmask) and _mask_query (read-only: is-enabled/
# list-units), each with a local-default definition below. A caller with
# no local systemd to talk to redefines both AFTER sourcing this file
# (function redefinition wins at call time, not source time) to wrap the
# same commands in its own transport -- ssh, for dexter-getty-tty1.sh.
# Local callers (postfix-delegate-home-assistant.sh) never need to know
# this indirection exists.

# --- kind: grub-kernel-param ------------------------------------------
# A single token inside GRUB_CMDLINE_LINUX_DEFAULT="...". Vars read:
# GRUB_FILE, SUDO_CMD, UPDATE_GRUB_CMD, PARAM.

_grub_current_cmdline() {
  [ -f "$GRUB_FILE" ] || return 0
  sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$GRUB_FILE" | head -n1
}

_grub_has_param() {
  local cur
  cur="$(_grub_current_cmdline)"
  case " $cur " in
    *" $PARAM "*) return 0 ;;
    *) return 1 ;;
  esac
}

_grub_edit_cmdline() { # <new cmdline>
  local cur new backup
  [ -f "$GRUB_FILE" ] || die "$GRUB_FILE does not exist -- not a GRUB machine?"
  cur="$(_grub_current_cmdline)"
  [ -n "$cur" ] || die "GRUB_CMDLINE_LINUX_DEFAULT not found in $GRUB_FILE in the expected quoted form -- refusing to guess, edit it by hand"
  new="$1"
  backup="$(backup_file "$GRUB_FILE")"
  say "backed up $GRUB_FILE -> $backup"
  $SUDO_CMD sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"${cur}\"\$|GRUB_CMDLINE_LINUX_DEFAULT=\"${new}\"|" "$GRUB_FILE" \
    || die "failed to edit $GRUB_FILE"
  say "GRUB_CMDLINE_LINUX_DEFAULT: \"$cur\" -> \"$new\""
  say "running $SUDO_CMD $UPDATE_GRUB_CMD..."
  $SUDO_CMD $UPDATE_GRUB_CMD || die "update-grub failed -- $GRUB_FILE was edited but the boot config was not regenerated; fix and re-run update-grub by hand"
}

toggle_grub_param_enable() {
  say "senechal remedy: enable kernel parameter $PARAM"
  if _grub_has_param; then
    say "$PARAM already present in $GRUB_FILE -- nothing to do."
    return
  fi
  local cur new
  cur="$(_grub_current_cmdline)"
  if [ -z "$cur" ]; then new="$PARAM"; else new="$cur $PARAM"; fi
  _grub_edit_cmdline "$new"
  say ""
  say "done. Reboot for the kernel parameter to take effect."
}

toggle_grub_param_disable() {
  say "senechal remedy: remove kernel parameter $PARAM"
  if ! _grub_has_param; then
    say "$PARAM not present in $GRUB_FILE -- nothing to do."
    return
  fi
  local cur new
  cur="$(_grub_current_cmdline)"
  # Remove the token and collapse any resulting double space.
  new="$(printf '%s' " $cur " | sed "s/ $PARAM / /" | sed 's/^ *//;s/ *$//')"
  _grub_edit_cmdline "$new"
  say ""
  say "done. Reboot for the change to take effect."
}

toggle_grub_param_verify() {
  if [ ! -f "$GRUB_FILE" ]; then
    skip "$GRUB_FILE does not exist -- not a GRUB machine, or needs root to read"
  elif _grub_has_param; then
    ok "$PARAM present in $GRUB_FILE's GRUB_CMDLINE_LINUX_DEFAULT"
  else
    fail "$PARAM not present in $GRUB_FILE -- run: enable"
  fi

  if [ -r /proc/cmdline ]; then
    if grep -q "$PARAM" /proc/cmdline; then
      ok "$PARAM present in the currently-running kernel's /proc/cmdline"
    elif _grub_has_param 2>/dev/null; then
      warn_ "$PARAM is in $GRUB_FILE but not in the running /proc/cmdline -- reboot to apply"
    else
      note "$PARAM not in the running kernel (expected if never enabled)"
    fi
  else
    skip "/proc/cmdline not readable"
  fi
}

# --- kind: systemd-mask-unit -------------------------------------------
# A systemd unit that must stay masked (never started). Vars read: UNIT,
# SUDO_CMD, SYSTEMCTL, TOGGLE_LIVE (1 when SYSTEMCTL is the real
# systemctl -- gates the one check a fake systemctl stub can't answer).
#
# _mask_run/_mask_query are the transport indirection described up top.
# Local default: run $SYSTEMCTL directly (privileged calls through
# SUDO_CMD, read-only ones without). A caller talking to a remote unit
# redefines both after sourcing this file.
_mask_run() { $SUDO_CMD "$SYSTEMCTL" "$@"; }
_mask_query() { "$SYSTEMCTL" "$@"; }

toggle_systemd_mask_enable() {
  say "senechal remedy: masking $UNIT"
  [ "$TOGGLE_LIVE" -eq 1 ] || say "  (test mode: not talking to a live systemd)"
  _mask_run mask "$UNIT" || die "could not mask $UNIT"
  _mask_run reset-failed "$UNIT" 2>/dev/null || true
  say "  $UNIT masked -- it will never be started again"
}

toggle_systemd_mask_disable() {
  say "senechal remedy: UNMASKING $UNIT (undo)"
  _mask_run unmask "$UNIT" || die "could not unmask $UNIT"
  say "  $UNIT unmasked. It will be instantiated again on next attempt."
}

toggle_systemd_mask_verify() {
  local state
  state="$(_mask_query is-enabled "$UNIT" 2>/dev/null || true)"
  if [ "$state" = "masked" ]; then
    ok "$UNIT is masked"
  elif [ -z "$state" ] && [ "$TOGGLE_LIVE" -eq 0 ]; then
    fail "$UNIT not masked (fake systemctl reported nothing) -- run enable"
  else
    fail "$UNIT is '$state', not masked -- run enable"
  fi

  if [ "$TOGGLE_LIVE" -eq 1 ]; then
    if _mask_query list-units --state=failed --no-legend --plain 2>/dev/null | grep -q "^$UNIT "; then
      fail "$UNIT still shows as failed -- run: sudo systemctl reset-failed $UNIT"
    else
      ok "$UNIT not in the failed-units list"
    fi
  else
    skip "test mode -- no live systemd to ask about the failed-units list"
  fi
}
