#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
. ../lib/common.sh

EXECUTE=0
MIN_AGE_HOURS=24
for a in "$@"; do
  case "$a" in
    --execute) EXECUTE=1 ;;
    --dry-run|-n) EXECUTE=0 ;;
    --min-age-hours=*) MIN_AGE_HOURS="${a#*=}" ;;
    -h|--help)
      cat <<'EOF'
usage: reap-stale-salvage-branches.sh [--execute] [--min-age-hours=N]

Deletes salvage/senechal-nightly-batch-<YYYYMMDDHHMMSS> branches (the
shape lib/salvage.sh writes on a crash-recovery tick) that are BOTH:

  - older than --min-age-hours (default: 24) -- a branch from tonight's
    tick may be the only copy of a crashed run's work
  - fully merged into main -- every commit on the branch is already
    reachable from main, so deleting it loses nothing

A branch that fails either test is left alone and reported as kept.
Anything not matching the exact generated shape is never even
considered -- this only ever reaps its own kind.

Without --execute this only reports what it would delete. --execute is
required to actually push a deletion.
EOF
      exit 0
      ;;
    *) die "unknown argument: $a (try --execute or --min-age-hours=N)" ;;
  esac
done

case "$MIN_AGE_HOURS" in
  ''|*[!0-9]*) die "--min-age-hours wants a whole number of hours, got: $MIN_AGE_HOURS" ;;
esac
cutoff_seconds=$((MIN_AGE_HOURS * 3600))

main_ref="refs/reap-check/main-$$"
declare -a branch_refs=()
cleanup() {
  git update-ref -d "$main_ref" >/dev/null 2>&1
  for r in "${branch_refs[@]:-}"; do
    [ -n "$r" ] && git update-ref -d "$r" >/dev/null 2>&1
  done
}
trap cleanup EXIT

git fetch -q origin "+refs/heads/main:$main_ref" 2>/dev/null \
  || die "could not fetch origin main to check ancestry"

now="$(date +%s)"
deleted=0 gone=0 kept=0 errors=0

while read -r sha ref; do
  [ -n "${ref:-}" ] || continue
  b="${ref#refs/heads/}"

  case "$b" in
    salvage/senechal-nightly-batch-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) continue ;;
  esac

  stamp="${b##*-}"
  made="$(date -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:8:2}:${stamp:10:2}:${stamp:12:2}" +%s 2>/dev/null)"
  if [ -z "$made" ]; then
    warn "skip   $b  (timestamp does not parse)"
    continue
  fi

  age=$((now - made))
  if [ "$age" -lt "$cutoff_seconds" ]; then
    kept=$((kept + 1))
    say "keep   $b  (younger than ${MIN_AGE_HOURS}h)"
    continue
  fi

  branch_ref="refs/reap-check/branch-$$-${stamp}"
  if ! git fetch -q origin "+refs/heads/$b:$branch_ref" 2>/dev/null; then
    gone=$((gone + 1))
    say "gone   $b  (already deleted)"
    continue
  fi
  branch_refs+=("$branch_ref")

  if ! git merge-base --is-ancestor "$branch_ref" "$main_ref"; then
    kept=$((kept + 1))
    say "keep   $b  (carries commits not on main)"
    continue
  fi

  if [ "$EXECUTE" -eq 0 ]; then
    deleted=$((deleted + 1))
    say "would  $b"
    continue
  fi

  if git push origin --delete "$b" 2>&1; then
    deleted=$((deleted + 1))
    say "deleted $b"
  else
    errors=$((errors + 1))
    warn "could not delete $b"
  fi
done < <(git ls-remote --heads origin 'salvage/senechal-nightly-batch-*')

say "reap-stale-salvage-branches: $deleted deleted, $gone already gone, $kept kept, $errors error(s)"
[ "$errors" -eq 0 ] || exit "$RC_FAIL"
