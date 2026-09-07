#!/usr/bin/env bash
# senechal: apply newly-merged non-privileged remedies automatically,
# so a merge to origin/main is the last human step -- not "merge, then
# also go run this script by hand and watch it work."
#
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

# This tree's own origin when it has one (the test harness runs from a clone of
# a fixture origin); an owner/name slug when it does not, i.e. the verb build.
SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
REPO="${SENECHAL_AUTOAPPLY_REPO:-$(git -C "$SELF_ROOT" remote get-url origin 2>/dev/null \
  || echo hf7y/senechal)}"
REMOTE_REF="${SENECHAL_AUTOAPPLY_REF:-origin/main}"
STATE_DIR="${SENECHAL_AUTOAPPLY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/senechal}"
STATE_FILE="$STATE_DIR/auto-apply-remedies.sha"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

mkdir -p "$STATE_DIR"

# A per-run clone, NOT this script's own tree: ExecStart must name the verb build
# (the guard rejects temp dirs AND clones) and that build is no git repo.
CLONE="$(mktemp -d)"
WT=""
CLONE_ERR="$(mktemp)"
cleanup() {
  [ -n "$WT" ] && git -C "$CLONE" worktree remove --force "$WT" >/dev/null 2>&1
  rm -rf "$WT" "$CLONE"
  rm -f "$CLONE_ERR"
}
trap cleanup EXIT
case "$REPO" in
  */*/*|/*|.*|*:*)
    git clone --quiet "$REPO" "$CLONE" 2>"$CLONE_ERR" ;;
  */*)
    if ! command -v gh >/dev/null 2>&1; then
      echo "gh is not on PATH" > "$CLONE_ERR"; false
    elif ! gh auth status >/dev/null 2>&1; then
      echo "gh is not authenticated" > "$CLONE_ERR"; false
    else
      gh repo clone "$REPO" "$CLONE" -- --quiet 2>"$CLONE_ERR"
    fi ;;
  *)
    echo "'$REPO' is not a path, URL or owner/name slug" > "$CLONE_ERR"; false ;;
esac || { echo "auto-apply-remedies: could not clone $REPO:" >&2; sed 's/^/  /' "$CLONE_ERR" >&2; exit 2; }
cd "$CLONE" || { echo "auto-apply-remedies: could not enter $CLONE" >&2; exit 2; }
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

# A pathspec glob does not cross '/', so a lib edit under remedies/lib/*.sh is
# invisible to CHANGED above. Treat any remedy naming a changed lib's basename as
# changed: over-inclusion costs one verify call, a false negative is the danger.
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

  # Declared, not guessed (#481) -- undeclared reads as privileged.
  priv="$(sed -n 's/^PRIVILEGED=\([a-z]*\)$/\1/p' "$script" | head -1)"
  case "$priv" in
    no) ;;
    yes)
      echo "SKIP  $base -- declares PRIVILEGED=yes, stays a by-hand step (privilege-granting is a different risk class)"
      continue ;;
    *)
      echo "SKIP  $base -- no 'PRIVILEGED=yes|no' line, so it is treated as privileged"
      continue ;;
  esac

  rc_before=0
  bash "$script" verify -q >/dev/null 2>&1 || rc_before=$?
  if [ "$rc_before" -ne 5 ]; then
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
