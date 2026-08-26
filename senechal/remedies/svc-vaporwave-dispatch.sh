#!/usr/bin/env bash
# senechal remedy: park the second dispatcher on mandark -- the
# svc-vaporwave crontab.
#
#   ./svc-vaporwave-dispatch.sh verify    # non-AI, cron-safe, read-only
#   ./svc-vaporwave-dispatch.sh enable    # Zach runs this by hand (needs sudo)
#   ./svc-vaporwave-dispatch.sh disable   # undo: restore the crontab
#
# WHY (found 2026-07-30 while writing the per-project unwiring brief).
# Every document in this ecosystem says mandark stopped developing itself
# on 2026-07-29: realisateur's THE-UNWIRING.md §3 opens with "the valve
# was already shut", steward-survey reads 0 live / 17 dark, and the
# crontab was emptied that afternoon. For 15 of 17 projects that is true.
#
# It is false for aedile and vkv-inventory, because THEY ARE NOT IN
# ZACH'S CRONTAB. They run out of the crontab of `svc-vaporwave`
# (uid 1001, "vaporwave headless service account"), on fixed times, from
# that account's OWN copies of the wrappers under
# /home/svc-vaporwave/bin/ -- not the ~/.local/bin ones every teardown
# plan so far has been counting. Emptying zach's crontab did not touch
# them and was never going to:
#
#   0 3 * * *  /home/svc-vaporwave/bin/aedile-nightly-batch-loop.sh
#   0 4 * * *  /home/svc-vaporwave/bin/vkv-inventory-nightly-batch-loop.sh
#
# Witnessed in the journal, not inferred -- they fired 03:00 and 04:00
# every day through 2026-07-29, including the day the "valve was shut",
# while zach's own cron went silent at 14:25 that same afternoon:
#
#   journalctl _COMM=cron --since "2026-07-23" | grep '(svc-vaporwave) CMD'
#
# This is the exact shape of ESTATE.md finding 1 (gardien failing loud for
# weeks with nobody listening), inverted: two agents SUCCEEDING nightly
# with nobody listening. And it is worse than a stale wrapper, because
# unwiring the ~/.local/bin copies would leave these two running while
# every report claimed the ecosystem was parked.
#
# WHY IT IS A REMEDY AND NOT AN UNATTENDED FIX. Reading, let alone
# editing, another account's crontab needs root. That is privilege-
# touching and squarely the "leave a remedy script" class. It is
# also the only wiring senechal cannot even PROBE directly -- see the
# `verify` note below for what it does instead.
#
# PARK, DO NOT DELETE -- for the same reason schedule/_paced.conf says so
# in its own header: fixed-cron suppression keys on rotation MEMBERSHIP,
# not on the enabled flag. These two lines are commented out with a dated
# marker, matching how the mandark sweep backstop was parked on
# 2026-07-29 (`#DISABLED-2026-07-29-zach-...#`), so the record of what ran
# survives the parking and `disable` is a one-line revert.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

SVC_USER="svc-vaporwave"
MARKER="#PARKED-2026-07-30-senechal-self-dev-off-mandark#"
# The two jobs, by the loop script each cron line invokes.
JOBS='aedile-nightly-batch-loop\.sh|vkv-inventory-nightly-batch-loop\.sh'
# How far back `verify` looks for evidence of a firing. Both jobs are
# daily, so a 2-day window catches a live dispatcher while tolerating one
# missed night.
LOOKBACK_DAYS=2
BACKUP="$HOME/.senechal-remedy-backups/svc-vaporwave-crontab"

usage() { sed -n '2,8p' "$0"; exit 1; }

# --- verify -------------------------------------------------------------
# Deliberately does NOT depend on reading the crontab, because senechal
# cannot: /home/svc-vaporwave and /var/spool/cron/crontabs are both
# root-only, and a check that needs sudo can never run unattended. The
#   [rest: vault:senechal/header-archaeology-20260818.md]
do_verify() {
  head_ "second dispatcher: the $SVC_USER crontab"

  if ! getent passwd "$SVC_USER" >/dev/null 2>&1; then
    ok "no $SVC_USER account on this host -- nothing to park"
    finish_verify "OK -- no second dispatcher exists here."
  fi

  if ! command -v journalctl >/dev/null 2>&1; then
    skip "no journalctl, so a firing cannot be witnessed"
    finish_verify
  fi

  local log rc
  log="$(journalctl _COMM=cron --since "-${LOOKBACK_DAYS}d" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    skip "cannot read the cron journal (rc=$rc) -- a live dispatcher would be invisible"
    note "This is not a pass. Re-run as a user in the systemd-journal group."
    finish_verify
  fi

  # An empty window is ambiguous: either cron ran nothing, or the journal
  # does not retain that far. Distinguish them by asking whether the
  # journal has ANY cron record in the window at all.
  if [ -z "$log" ]; then
    skip "the cron journal holds no records for the last ${LOOKBACK_DAYS}d"
    note "Cannot distinguish 'nothing fired' from 'nothing retained'."
    note "Check retention: journalctl --disk-usage; journalctl _COMM=cron | head -1"
    finish_verify
  fi

  local fired
  fired="$(printf '%s\n' "$log" \
    | grep -E "\($SVC_USER\) CMD" | grep -cE "$JOBS")" || fired=0

  if [ "${fired:-0}" -gt 0 ]; then
    fail "$fired dispatch(es) by $SVC_USER in the last ${LOOKBACK_DAYS}d -- STILL LIVE"
    # Fed by a here-string, NOT a pipe: `note` appends to the buffer
    # finish_verify prints, and a pipeline runs its last stage in a
    # SUBSHELL, so piping into this loop silently discarded every example
    # line -- the report claimed 4 firings and then showed none.
    local samples
    samples="$(printf '%s\n' "$log" | grep -E "\($SVC_USER\) CMD" \
               | grep -E "$JOBS" | tail -4)"
    while IFS= read -r l; do
      [ -n "$l" ] && note "$l"
    done <<<"$samples"
    note "aedile and vkv-inventory are still developing themselves on mandark."
    note "Park them: $0 enable"
  else
    ok "no $SVC_USER dispatch in the last ${LOOKBACK_DAYS}d"
    note "Witness: journalctl _COMM=cron --since -${LOOKBACK_DAYS}d | grep '($SVC_USER) CMD'"
  fi

  finish_verify "OK -- the second dispatcher is parked (no firings witnessed)."
}

# --- enable / disable ---------------------------------------------------
do_enable() {
  command -v sudo >/dev/null 2>&1 || die "no sudo on this host"
  say "Reading $SVC_USER's crontab (needs root)..."
  local cur
  cur="$(sudo crontab -u "$SVC_USER" -l 2>/dev/null)" \
    || die "could not read $SVC_USER's crontab -- run this as a user with sudo"

  if [ -z "$cur" ]; then
    say "$SVC_USER has no crontab. Nothing to park."
    return 0
  fi

  mkdir -p "$(dirname "$BACKUP")"
  printf '%s\n' "$cur" > "$BACKUP.$(date +%Y%m%dT%H%M%S).bak"
  say "Backed up to $BACKUP.<stamp>.bak"

  if ! printf '%s\n' "$cur" | grep -vE '^[[:space:]]*#' | grep -qE "$JOBS"; then
    say "No active aedile/vkv-inventory lines found -- already parked."
    return 0
  fi

  say ""
  say "Will comment out these active lines (park, not delete):"
  printf '%s\n' "$cur" | grep -vE '^[[:space:]]*#' | grep -E "$JOBS" \
    | while IFS= read -r l; do say "    $l"; done
  say ""
  printf 'Proceed? [y/N] '
  local ans; read -r ans
  case "$ans" in [yY]*) ;; *) say "Aborted; nothing changed."; return 1 ;; esac

  # Comment out, prefixing the dated marker so the parking is self-
  # documenting and `disable` can find exactly what it undid.
  printf '%s\n' "$cur" \
    | awk -v jobs="$JOBS" -v m="$MARKER" '
        /^[[:space:]]*#/ { print; next }
        $0 ~ jobs        { print m " " $0; next }
        { print }' \
    | sudo crontab -u "$SVC_USER" - \
    || die "failed to install the parked crontab"

  say "Parked. Verifying..."
  say "Note: verify witnesses FIRINGS, so it keeps reporting the last"
  say "${LOOKBACK_DAYS}d of real runs until that window rolls past. Confirm"
  say "the config directly right now with:"
  say "    sudo crontab -u $SVC_USER -l | grep -E '$JOBS'"
  sudo crontab -u "$SVC_USER" -l | grep -E "$JOBS" || true
}

do_disable() {
  command -v sudo >/dev/null 2>&1 || die "no sudo on this host"
  local cur
  cur="$(sudo crontab -u "$SVC_USER" -l 2>/dev/null)" \
    || die "could not read $SVC_USER's crontab"
  printf '%s\n' "$cur" | grep -qF "$MARKER" \
    || die "no $MARKER lines found -- nothing this remedy parked"
  printf '%s\n' "$cur" | sed "s|^$MARKER ||" | sudo crontab -u "$SVC_USER" - \
    || die "failed to restore"
  say "Restored. aedile and vkv-inventory will dispatch again on their fixed times."
}

case "${1:-}" in
  verify)  shift; for a in "$@"; do [ "$a" = "-q" ] && QUIET=1; done; do_verify ;;
  enable)  do_enable ;;
  disable) do_disable ;;
  *)       usage ;;
esac
