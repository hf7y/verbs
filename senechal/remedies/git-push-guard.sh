#!/usr/bin/env bash
# senechal: make "land it as a PR, not a direct push" refuse instead of ask.
#
# This was a heading in CLAUDE.md from 2026-08-04. Prose cannot refuse a push,
# and CLAUDE.md was deleted for drifting -- four of its factual claims were
# measured wrong in one session on 2026-08-25. The reason it gave is still
# right: origin/main can move mid-session and a plain push does not surface
# that, it just fails or races.
#
# Points core.hooksPath at the tracked .githooks/ rather than writing into
# .git/hooks, so the guard is version-controlled, travels with a fresh clone,
# and cannot rot out of sync with the repo it guards.
#
#   ./git-push-guard.sh enable    # point this clone's hooks at .githooks/
#   ./git-push-guard.sh verify    # non-AI, cron-safe
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

HOOKS_DIR=".githooks"
HOOK="pre-push"
REPO_ROOT="$(cd .. && pwd)"

do_enable() {
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
    || die "not a git checkout: $REPO_ROOT"
  [ -x "$REPO_ROOT/$HOOKS_DIR/$HOOK" ] \
    || die "$HOOKS_DIR/$HOOK missing or not executable in $REPO_ROOT"

  local current
  current="$(git -C "$REPO_ROOT" config --local --get core.hooksPath || true)"
  if [ "$current" = "$HOOKS_DIR" ]; then
    say "already correct: core.hooksPath is $HOOKS_DIR"
  else
    [ -n "$current" ] && say "core.hooksPath was '$current'; repointing to $HOOKS_DIR"
    git -C "$REPO_ROOT" config --local core.hooksPath "$HOOKS_DIR" \
      || die "could not set core.hooksPath"
    say "core.hooksPath -> $HOOKS_DIR"
  fi

  say ""
  say "A push to main from this clone now refuses. Deliberate bypass: git push --no-verify"
  say ""
  say "What this script could NOT do for you:"
  say "  - core.hooksPath is per-clone and NOT carried by git clone. Every"
  say "    other checkout of this repo needs its own enable."
  say "  - It does not guard the GitHub side. Anyone with push rights can"
  say "    still push to main from elsewhere; branch protection is the"
  say "    server-side answer and is not senechal's to set."
}

do_verify() {
  head_ "push guard"
  if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    skip "not a git checkout"
    finish_verify
  fi

  if [ -x "$REPO_ROOT/$HOOKS_DIR/$HOOK" ]; then
    ok "$HOOKS_DIR/$HOOK present and executable"
  else
    fail "$HOOKS_DIR/$HOOK missing or not executable"
  fi

  local current
  current="$(git -C "$REPO_ROOT" config --local --get core.hooksPath || true)"
  if [ "$current" = "$HOOKS_DIR" ]; then
    ok "core.hooksPath is $HOOKS_DIR"
  else
    fail "core.hooksPath is '${current:-unset}', not $HOOKS_DIR -- a push to main would not be refused. Run: $0 enable"
  fi

  # The hook existing proves nothing about whether it refuses. Exercise it the
  # way git does: feed it a ref line on stdin and require a nonzero exit.
  head_ "it actually refuses"
  if [ -x "$REPO_ROOT/$HOOKS_DIR/$HOOK" ]; then
    local out rc
    out=$(printf 'refs/heads/main %s refs/heads/main %s\n' "$(printf '1%.0s' {1..40})" "$(printf '0%.0s' {1..40})" \
          | "$REPO_ROOT/$HOOKS_DIR/$HOOK" origin https://example.invalid/x.git 2>&1) && rc=0 || rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q refusing; then
      ok "a push to main is refused"
    else
      fail "the hook let a push to main through (exit $rc) -- it is present but not guarding"
    fi
    # And it must NOT refuse everything, or people will disable it.
    out=$(printf 'refs/heads/topic %s refs/heads/topic %s\n' "$(printf '1%.0s' {1..40})" "$(printf '0%.0s' {1..40})" \
          | "$REPO_ROOT/$HOOKS_DIR/$HOOK" origin https://example.invalid/x.git 2>&1) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] && ok "a push to a topic branch passes" \
                    || fail "the hook refuses topic branches too (exit $rc) -- too blunt to survive"
  else
    skip "no hook to exercise"
  fi

  finish_verify "OK -- direct pushes to main are refused in this clone."
}

case "${1:-}" in
  enable) shift; parse_common_args "$@"; do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
