#!/usr/bin/env bash
# senechal: apply newly-merged non-privileged remedies automatically,
# so a merge to origin/main is the last human step -- not "merge, then
# also go run this script by hand and watch it work."
#
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

REMOTE_REF="${SENECHAL_AUTOAPPLY_REF:-origin/main}"
STATE_DIR="${SENECHAL_AUTOAPPLY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/senechal}"
STATE_FILE="$STATE_DIR/auto-apply-remedies.sha"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

mkdir -p "$STATE_DIR"

git fetch origin --quiet 2>/dev/null || { echo "auto-apply-remedies: could not fetch origin" >&2; exit 2; }
NEW_SHA="$(git rev-parse "$REMOTE_REF" 2>/dev/null)" || { echo "auto-apply-remedies: could not resolve $REMOTE_REF" >&2; exit 2; }

if [ ! -f "$STATE_FILE" ]; then
  echo "auto-apply-remedies: no prior state -- establishing baseline at $NEW_SHA, applying nothing this run"
  echo "  (this is deliberate: first activation must not retroactively enable every remedy that already existed)"
  [ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$NEW_SHA" > "$STATE_FILE"
  exit 0
fi
OLD_SHA="$(cat "$STATE_FILE")"

if [ "$OLD_SHA" = "$NEW_SHA" ]; then
  echo "auto-apply-remedies: $REMOTE_REF unchanged since last run ($NEW_SHA) -- nothing to do"
  exit 0
fi

if ! git merge-base --is-ancestor "$OLD_SHA" "$NEW_SHA" 2>/dev/null; then
  echo "auto-apply-remedies: $OLD_SHA is not an ancestor of $NEW_SHA -- history was rewritten (force-push/rebase). Not guessing what changed; re-baselining." >&2
  [ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$NEW_SHA" > "$STATE_FILE"
  exit 2
fi

CHANGED="$(git diff --name-only "$OLD_SHA" "$NEW_SHA" -- 'remedies/*.sh' | grep -v '/_test-' || true)"

# A pathspec glob does not cross '/', so a shared-engine edit under
# remedies/lib/*.sh (e.g. toggle-kinds.sh) is invisible to the CHANGED
# check above even though it changes what every sourcing wrapper does.
# Treat any top-level remedy that mentions a changed lib file's basename
# as changed too -- over-inclusion just costs a verify call (line ~70
# below skips anything whose verify doesn't already fail), so a false
# positive here is free and a false negative is the real danger.
CHANGED_LIB="$(git diff --name-only "$OLD_SHA" "$NEW_SHA" -- 'remedies/lib/*.sh' | grep -v '/_test-' || true)"
if [ -n "$CHANGED_LIB" ]; then
  while IFS= read -r libfile; do
    [ -n "$libfile" ] || continue
    libbase="$(basename "$libfile")"
    callers="$(git grep -l -- "$libbase" "$NEW_SHA" -- 'remedies/*.sh' 2>/dev/null | sed -e "s#^$NEW_SHA:##" -e '/\/_test-/d' || true)"
    [ -n "$callers" ] && CHANGED="$(printf '%s\n%s\n' "$CHANGED" "$callers" | sed '/^$/d' | sort -u)"
  done <<< "$CHANGED_LIB"
fi

if [ -z "$CHANGED" ]; then
  echo "auto-apply-remedies: $OLD_SHA..$NEW_SHA advanced but touched no remedies/*.sh -- nothing to apply"
  [ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$NEW_SHA" > "$STATE_FILE"
  exit 0
fi

WT="$(mktemp -d)"
cleanup() { git worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$WT"; }
trap cleanup EXIT

if ! git worktree add --detach --quiet "$WT" "$NEW_SHA" 2>/dev/null; then
  echo "auto-apply-remedies: could not create a worktree at $NEW_SHA" >&2
  exit 2
fi

overall_rc=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  base="$(basename "$rel")"
  script="$WT/$rel"
  [ -f "$script" ] || { echo "SKIP  $base -- removed in $NEW_SHA, nothing to apply"; continue; }

  if grep -q '\bsudo\b' "$script"; then
    echo "SKIP  $base -- enable uses sudo, stays a by-hand step (privilege-granting is a different risk class)"
    continue
  fi

  rc_before=0
  bash "$script" verify -q >/dev/null 2>&1 || rc_before=$?
  if [ "$rc_before" -ne 1 ]; then
    echo "SKIP  $base -- verify exit $rc_before (0=already fine, 2=could not check, 3=warn -- none of these mean 'apply it')"
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "WOULD ENABLE  $base (verify currently FAILs)"
    continue
  fi

  echo "ENABLING  $base"
  if ! out="$(bash "$script" enable 2>&1)"; then
    echo "FAIL  $base -- enable itself exited nonzero:"
    echo "$out" | sed 's/^/      /'
    overall_rc=1
    continue
  fi
  echo "$out" | sed 's/^/      /'

  rc_after=0
  bash "$script" verify -q >/dev/null 2>&1 || rc_after=$?
  if [ "$rc_after" -eq 0 ]; then
    echo "OK    $base -- enabled, verify now passes"
  else
    echo "FAIL  $base -- enabled, but verify still exits $rc_after -- needs a human look"
    overall_rc=1
  fi
done <<< "$CHANGED"

[ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$NEW_SHA" > "$STATE_FILE"
exit "$overall_rc"
