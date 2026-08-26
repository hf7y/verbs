#!/usr/bin/env bash
# senechal: clear failed TRANSIENT app scopes out of systemd --user.
#
#   ./reap-failed-scopes.sh            # clear them, report what was cleared
#   ./reap-failed-scopes.sh --dry-run  # say what would be cleared, touch nothing
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run|-n) DRY=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "unknown argument: $a (try --dry-run)" ;;
  esac
done

if ! systemctl --user show-environment >/dev/null 2>&1; then
  say "cannot reach a systemd --user instance (no session bus?) -- nothing checked."
  exit "$RC_INCOMPLETE"
fi

failed="$(systemctl --user list-units --state=failed --no-legend --plain 2>/dev/null \
  | awk '{print $1}' | grep -v '^$' || true)"

reaped=0 skipped=0 errors=0
while IFS= read -r u; do
  [ -n "$u" ] || continue
  if ! is_transient_scope "$u"; then
    skipped=$((skipped + 1))
    say "keep   $u  (not a transient app scope -- a real failure, left alone)"
    continue
  fi
  if [ "$DRY" -eq 1 ]; then
    say "would  $u"
    reaped=$((reaped + 1))
    continue
  fi
  if systemctl --user reset-failed "$u" >/dev/null 2>&1; then
    say "reaped $u"
    reaped=$((reaped + 1))
  else
    say "ERROR  $u -- reset-failed refused"
    errors=$((errors + 1))
  fi
done <<< "$failed"

if [ "$reaped" -eq 0 ] && [ "$skipped" -eq 0 ] && [ "$errors" -eq 0 ]; then
  say "no failed user units at all."
else
  say ""
  say "$( [ "$DRY" -eq 1 ] && echo 'would reap' || echo 'reaped') $reaped, left $skipped real failure(s) alone, $errors error(s)."
fi

[ "$errors" -gt 0 ] && exit "$RC_FAIL"
exit "$RC_PASS"
