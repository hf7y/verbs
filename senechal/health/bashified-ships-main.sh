#!/usr/bin/env bash
# senechal: the verb build is cut from `origin/bashified` and copies the WHOLE
# tree (cut-verb-build.sh:135, hardcoded), so whatever that branch is missing
# is missing from every deployed host.
#
# #406 diagnosed exactly this: bashified carried 12 files and none of health/,
# remedies/ or tools/, "which is why nothing was deployed". CLAUDE.md was then
# written in the past tense -- "main is now a superset; bashified is
# fast-forwarded from it" -- and the branch was never actually moved. Measured
# 2026-08-25: bashified was 31,246 lines behind main across 155 files, still
# the single-verb `veille` tree, while the doc said otherwise.
#
# A sentence in a file cannot notice that. This can. The invariant is that
# origin/main is an ancestor of origin/bashified, i.e. everything on main ships.
#
# Reads remote-tracking refs only -- no network, cron-safe. A stale fetch gives
# a stale answer, so the nightly batch should fetch before trusting a pass.
#
#   health/bashified-ships-main.sh [-q]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

SHIP_REF="${SENECHAL_SHIP_REF:-refs/remotes/origin/bashified}"
MAIN_REF="${SENECHAL_MAIN_REF:-refs/remotes/origin/main}"

parse_common_args "$@"

head_ "the branch the verb build ships from carries all of main"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  skip "not a git checkout -- nothing to compare"
  finish_verify "OK -- nothing to check."
fi

ship=$(git rev-parse --verify -q "$SHIP_REF" 2>/dev/null)
main=$(git rev-parse --verify -q "$MAIN_REF" 2>/dev/null)
if [ -z "$main" ]; then
  skip "$MAIN_REF does not resolve here (no fetch yet?)"
  finish_verify "OK -- nothing to check."
fi
if [ -z "$ship" ]; then
  fail "$SHIP_REF does not resolve -- the verb build has no branch to cut from"
  finish_verify
fi

if git merge-base --is-ancestor "$main" "$ship" 2>/dev/null; then
  ahead=$(git rev-list --count "$main..$ship" 2>/dev/null || echo 0)
  if [ "${ahead:-0}" -gt 0 ]; then
    # Not a pass: bashified is documented as never edited directly, so anything
    # on it that main lacks is drift that will be destroyed by the next
    # fast-forward, silently, along with whatever it was.
    warn_ "$ahead commit(s) on the ship branch are not on main -- it is edited directly somewhere, and the next fast-forward will drop them"
  else
    ok "everything on main ships"
  fi
else
  behind=$(git rev-list --count "$ship..$main" 2>/dev/null || echo "?")
  files=$(git diff --name-only "$ship" "$main" 2>/dev/null | wc -l)
  fail "the verb build ships a stale tree: $behind commit(s), $files file(s) on main are missing from it"
  note "every deployed host is running that stale tree, and nothing else reports it"
  note "fix: git push origin main:bashified --force-with-lease"
fi

finish_verify "OK -- the ship branch carries all of main."
