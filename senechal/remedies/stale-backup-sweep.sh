#!/usr/bin/env bash
# senechal: sweep the backup and staging artifacts that outlived their
# purpose on mandark -- chiefly the Chromium-to-Firefox migration of
# 2026-08-15, plus the older per-tool backup files that accumulated
# around it (hf7y/senechal#290).
#
#   ./stale-backup-sweep.sh enable    # remove them (needs sudo for the snap)
#   ./stale-backup-sweep.sh verify    # non-AI, cron-safe: are they gone?
#
# Why a remedy and not an unattended fix: every line here is a deletion,
# and the acting authority puts "anything not cleanly reversible" on Zach. The
# `sudo snap remove chromium` also makes `grep -l sudo` opt this whole
# script out of auto-apply-remedies, which is the correct outcome --
# nothing in here should ever run because a PR merged.
#
# THE ONE THING THAT MUST NOT GO WRONG: ~/chromium-migration-2026-08-15
# and ~/chromium-profile-backup-20260815 are the ONLY remaining copies of
# the Chromium profile data once the snap is removed. Firefox has the
# migrated copy, but a migration bug found in week two is unrecoverable
# without these. So the chromium group is date-gated behind KEEP_UNTIL
# and refuses to run early without --force.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=../lib/common.sh
. ../lib/common.sh

# Migrated 2026-08-15; hold the source data one week past that so a
# late-surfacing migration bug is still recoverable.
KEEP_UNTIL=2026-08-22

FF_PROFILE="$HOME/.mozilla/firefox/6z5w2rl8.default"

# Dead on arrival: superseded backups, stale temp files, editor leavings.
# Nothing here is the last copy of anything.
STALE=(
  "$HOME/.claude/settings.json.bak"
  "$HOME/.claude/backups"
  "$HOME/.config/senechal/senechal.json.senechal-backup.20260805-234315"
  "$HOME/.config/gardien/garde.json.senechal-backup.20260813-112337"
  "$HOME/.config/gardien/garde.json.senechal-backup.20260813-110900"
  "$HOME/.local/share/user-places.xbel.bak"
  "$HOME/.config/nicotine/config.old"
  "$HOME/.ssh/known_hosts.old"
  "$HOME/Downloads/thunderbird.tmp"
  "$FF_PROFILE/domain_to_categories.sqlite-journal"
)

# The Chromium migration's own artifacts. Gated behind KEEP_UNTIL.
CHROMIUM=(
  "$HOME/chromium-migration-2026-08-15"
  "$HOME/chromium-profile-backup-20260815"
  "$HOME/.config/chromium"
)

# Looks like junk, is not. Named here so a future sweep does not "tidy"
# it, and so verify keeps saying it out loud until Zach deals with it.
# ~/Downloads/backup_codes.txt is 129 bytes of what the name says:
# two-factor recovery codes, in plaintext, in the downloads folder since
# 2026-05-30. Deleting it could lock Zach out of an account; leaving it
# there is its own problem. Neither is this script's call.
NEVER_DELETE=(
  "$HOME/Downloads/backup_codes.txt"
)

# senechal's own dated backup dirs are the undo path for every remedy
# that ever ran, so this prunes by age rather than deleting the tree --
# a sweep that removes the ability to undo previous sweeps is a trap.
BACKUP_KEEP_DAYS=30

prune_remedy_backups() {
  local root="$HOME/.senechal-remedy-backups" d
  [[ -d "$root" ]] || { say "   already gone: $root"; return; }
  while IFS= read -r d; do
    say "   pruning $(size_of "$d")  $d"
    rm -rf -- "$d" || die "could not remove $d"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d \
             -mtime "+$BACKUP_KEEP_DAYS" 2>/dev/null)
}

stale_remedy_backups() {
  find "$HOME/.senechal-remedy-backups" -mindepth 1 -maxdepth 1 -type d \
    -mtime "+$BACKUP_KEEP_DAYS" 2>/dev/null | wc -l
}

past_keep_until() {
  [[ "$(date +%F)" > "$KEEP_UNTIL" || "$(date +%F)" == "$KEEP_UNTIL" ]]
}

# du that survives a missing path, so both verbs can report size without
# guarding every call site.
size_of() { du -sh "$1" 2>/dev/null | cut -f1 || echo '?'; }

remove_path() {
  local p="$1"
  if [[ ! -e "$p" && ! -L "$p" ]]; then
    say "   already gone: $p"
    return
  fi
  say "   removing $(size_of "$p")  $p"
  rm -rf -- "$p" || die "could not remove $p"
}

# --- enable ---------------------------------------------------------
do_enable() {
  local force=0
  [[ "${1:-}" == "--force" ]] && force=1

  say "== stale backups and temp files"
  local p
  for p in "${STALE[@]}"; do remove_path "$p"; done

  say
  say "== senechal remedy backups older than $BACKUP_KEEP_DAYS days"
  prune_remedy_backups

  say
  say "== Chromium migration artifacts (hold until $KEEP_UNTIL)"
  if past_keep_until || (( force )); then
    (( force )) && ! past_keep_until \
      && warn "--force: removing the Chromium source data before $KEEP_UNTIL"
    for p in "${CHROMIUM[@]}"; do remove_path "$p"; done
    if snap list chromium >/dev/null 2>&1; then
      say "   removing the chromium snap (this also drops ~/snap/chromium)"
      sudo snap remove chromium || die "snap remove chromium failed"
    else
      say "   already gone: chromium snap"
    fi
  else
    say "   HELD until $KEEP_UNTIL -- these are the only remaining copies"
    say "   of the Chromium profile data. Re-run then, or --force to"
    say "   override once you are confident in the Firefox migration."
    for p in "${CHROMIUM[@]}"; do
      [[ -e "$p" || -L "$p" ]] && say "     held $(size_of "$p")  $p"
    done
  fi

  say
  say "== NOT removed, deliberately"
  for p in "${NEVER_DELETE[@]}"; do
    [[ -e "$p" ]] && say "   $p -- plaintext 2FA recovery codes; move them"
    [[ -e "$p" ]] && say "     into a password manager and delete by hand"
  done

  say
  say "Could not do for you:"
  say "  - ~/.local/share/Trash is $(size_of "$HOME/.local/share/Trash"). Emptying it is"
  say "    your call, not a cleanup rule: emptying the trash is what the"
  say "    trash is for, but nothing here knows what you put in it."
  say "    Empty with: gio trash --empty"
  say "  - profiles.ini still lists a profile directory that does not"
  say "    exist (ob15k19o.default-release-1). Harmless, but Firefox's"
  say "    profile manager will show it. Remove the [Profile1] block by"
  say "    hand if it bothers you."
  say "  - old disabled snap revisions (cups, gnome-42-2204, gnome-46-2404,"
  say "    mesa-2404, snapd-desktop-integration) are held by snapd's own"
  say "    retention policy, not by this script. Cap them with:"
  say "      sudo snap set system refresh.retain=2"
}

# --- verify ---------------------------------------------------------
do_verify() {
  local p n_old
  for p in "${STALE[@]}"; do
    if [[ -e "$p" || -L "$p" ]]; then
      fail "still present ($(size_of "$p")): $p -- run: ./stale-backup-sweep.sh enable"
    else
      ok "gone: $p"
    fi
  done

  n_old="$(stale_remedy_backups)"
  if [[ "$n_old" -gt 0 ]]; then
    fail "$n_old remedy backup dir(s) older than $BACKUP_KEEP_DAYS days in ~/.senechal-remedy-backups -- run: ./stale-backup-sweep.sh enable"
  else
    ok "no remedy backups older than $BACKUP_KEEP_DAYS days"
  fi

  if past_keep_until; then
    for p in "${CHROMIUM[@]}"; do
      if [[ -e "$p" || -L "$p" ]]; then
        fail "still present ($(size_of "$p")): $p -- run: ./stale-backup-sweep.sh enable"
      else
        ok "gone: $p"
      fi
    done
    if snap list chromium >/dev/null 2>&1; then
      fail "the chromium snap is still installed -- run: ./stale-backup-sweep.sh enable"
    else
      ok "gone: chromium snap"
    fi
  else
    note "Chromium artifacts held until $KEEP_UNTIL (not a failure)"
  fi

  # Never a pass, never a hard fail: it is a real exposure, but deleting
  # it is not this script's decision, so it must not block a clean cron.
  for p in "${NEVER_DELETE[@]}"; do
    [[ -e "$p" ]] && warn_ "still exposed: $p -- plaintext 2FA codes, move by hand"
  done

  finish_verify "OK -- no stale backup or staging artifacts left."
}

case "${1:-}" in
  enable) shift; do_enable "$@" ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable [--force]|verify [-q]" ;;
esac
