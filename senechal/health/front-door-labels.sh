#!/usr/bin/env bash
# senechal: do the GitHub labels the typed front door depends on exist?
#
#   ./front-door-labels.sh        # check
#   ./front-door-labels.sh -q     # silent unless a label is missing
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

REPO="${SENECHAL_ISSUE_REPO:-hf7y/senechal}"
# door: what absorb-notices.py queries. idea: issue-janitor's ALLOWED_LABELS.
REQUIRED=(door idea)

QUIET=0
[ "${1:-}" = "-q" ] && QUIET=1
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
loud() { printf '%s\n' "$*" >&2; }

command -v gh >/dev/null || { loud "gh is not on PATH -- cannot check"; exit "$RC_INCOMPLETE"; }
have=$(gh label list --repo "$REPO" --limit 200 --json name -q '.[].name' 2>&1) || {
  loud "could not list labels on $REPO: $have"; exit "$RC_INCOMPLETE"; }

rc="$RC_PASS"
for l in "${REQUIRED[@]}"; do
  if grep -qxF "$l" <<<"$have"; then
    say "ok   label '$l' exists on $REPO"
  else
    loud "FAIL label '$l' does not exist on $REPO -- filings carrying it are REJECTED, silently"
    loud "     create it: gh label create $l --repo $REPO"
    rc="$RC_FAIL"
  fi
done
exit "$rc"
