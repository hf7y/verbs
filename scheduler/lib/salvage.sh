#!/usr/bin/env bash
# salvage.sh -- put a scheduled job's workspace on origin's state WITHOUT
# destroying anything a previous run left behind.
#
# Replaces `git stash push -u` + `git branch rescue/...` + `git reset --hard`
# (lib/sweep-loop-common.sh, until 2026-08-06). Those preserved work LOCALLY,
# and local was the bug: in a disposable clone the stash and the rescue ref
# died with the directory, and in any checkout they are invisible to
# everything that counts work -- no branch list, no PR, no issue, no report.
# ecosim's auto-stash held PARADIGM 4 (verdict designs), a supervisor
# history-loss fix and 87 lines of tests, and sat unread for days because
# nothing in the system had a reason to look in a stash.
#
# The rule here is: preserve where it can be SEEN (a branch on origin), and
# treat a failure to preserve as a reason to STOP, not to proceed. No
# discarding step runs until `git push` has said yes.
#
# Extracted into its own lib so it has a witness (tests/salvage-witness.sh).
# The old inline version could only be exercised by running a whole nightly
# batch, which is why "reset --hard eats work" was a story told in comments
# rather than a case that fails a test.
#
# SECRETS. A salvage branch is PUSHED, so anything it sweeps up becomes
# public-to-the-remote. The engine copies SECRETS_SRC_DIR into
# $REPO/$SECRETS_DEST_SUBDIR inside the workspace, and with the disposable
# clone retired that directory now SURVIVES between runs, sitting in the tree
# looking exactly like uncommitted work. `git add -A` would commit it and
# `git push` would publish it. So the caller passes those paths in
# SALVAGE_EXCLUDE and they are excluded from BOTH the detection and the
# commit -- excluding only the commit would leave every run seeing a dirty
# tree and salvaging an empty branch forever.
#
# Usage:  salvage_then_restore <branch> <label> [log_fn]
#   cwd must already be the workspace.
#   SALVAGE_EXCLUDE  optional space-separated list of repo-relative paths
#                    that must never be salvaged (no spaces in the paths).
#   Returns:
#     0  workspace is at origin/<branch>; SALVAGE_REF is set if work was saved
#     1  nothing was discarded, and the caller must abort (see SALVAGE_ERROR)
# The caller owns notification -- this lib does not know what `notify` means.

# shellcheck disable=SC2034
SALVAGE_REF=""
SALVAGE_ERROR=""
SALVAGE_ISSUE_URL=""
: "${SALVAGE_EXCLUDE:=}"
: "${SALVAGE_GH_BIN:=gh}"
: "${SALVAGE_GH_TIMEOUT:=20}"

# owner/name from origin -- same shape as lib/run-record.sh's
# run_record_repo_slug (self-dev accounts point origin at a per-repo SSH host
# alias, not literal github.com).
salvage_repo_slug() {
  local url; url="$(git remote get-url origin 2>/dev/null)" || return 1
  case "$url" in
    *github.com*|*github-*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$url" | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##'
}

# A salvage branch nobody reads is the same class of silent failure as work
# that was never preserved at all (hf7y/scheduler#257 -- 47 unread branches on
# realisateur, two of them finished work that sat stranded for days). Give the
# branch a reader. Best-effort and never fatal: filing failing must not turn a
# successful salvage into an aborted run, so every failure path here only warns.
salvage_file_issue() {
  local ref="$1" label="$2" changed="$3" branch="$4" log_fn="${5:-echo}" slug body
  slug="$(salvage_repo_slug)" || {
    "$log_fn" "salvage: issue not filed -- origin is not a GitHub remote"
    return 1
  }
  if ! command -v "$SALVAGE_GH_BIN" >/dev/null 2>&1; then
    "$log_fn" "salvage: issue not filed -- '$SALVAGE_GH_BIN' not on PATH"
    return 1
  fi
  body="A previous run ($label) left work behind and it was salvaged rather than discarded.

branch:  $ref
files:   $changed changed path(s)

Review \`git log origin/$branch..origin/$ref\` and either open a PR from it or
fold the changes in by hand, then delete the branch. Filed automatically by
lib/salvage.sh (hf7y/scheduler#257) -- a branch nobody reads is the same class
of silent failure as work that was never preserved."
  SALVAGE_ISSUE_URL="$(timeout "$SALVAGE_GH_TIMEOUT" "$SALVAGE_GH_BIN" issue create -R "$slug" \
      --title "salvage: $ref caught $changed changed path(s)" \
      --body "$body" 2>/dev/null)" || {
    "$log_fn" "WARNING: salvage branch '$ref' pushed but issue creation failed -- review it by hand"
    SALVAGE_ISSUE_URL=""
    return 1
  }
  "$log_fn" "salvage: filed $SALVAGE_ISSUE_URL"
  return 0
}

salvage_then_restore() {
  local branch="$1" label="$2" log_fn="${3:-echo}"
  SALVAGE_REF=""
  SALVAGE_ERROR=""
  SALVAGE_ISSUE_URL=""

  if ! git rev-parse --verify --quiet "origin/$branch" >/dev/null; then
    SALVAGE_ERROR="origin/$branch does not exist -- refusing to guess a base"
    return 1
  fi

  # Build the pathspec once and use it for BOTH detection and staging.
  local -a scope=(--)
  local p
  scope+=(".")
  for p in ${SALVAGE_EXCLUDE:-}; do
    scope+=(":(exclude)$p")
  done

  local working_state ahead changed ref
  working_state="$(git status --porcelain "${scope[@]}" 2>/dev/null)"
  ahead="$(git rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)"

  # HEAD may be sitting on its OWN already-pushed feature branch, left there
  # by a run that opened a PR and simply never switched back -- not abandoned
  # work. hf7y/realisateur#533/#532: a single in-flight PR branch
  # (fix-blind-exit-code-334, PR #513) got re-salvaged into a NEW duplicate
  # branch on two separate subsequent ticks before the PR finally merged,
  # because this function only ever compared HEAD against origin/$branch and
  # had no notion of "already safe under a different name." Nothing was
  # lost either time -- the duplicates were the symptom, not the risk -- but
  # a salvage branch nobody reads is exactly the silent-failure class
  # salvage_file_issue() exists to prevent, and three copies of the same
  # content is three chances for a reader to act on a stale one.
  #
  # Narrow on purpose: only skips when the tree is clean AND HEAD is the
  # exact tip already pushed to origin under the current branch's own name.
  # Any uncommitted diff, or any commit not yet reachable from that origin
  # ref, still falls through to the ordinary salvage path below.
  if [ -z "$working_state" ] && [ "$ahead" -gt 0 ]; then
    local cur_branch
    cur_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -n "$cur_branch" ] && [ "$cur_branch" != "HEAD" ] && [ "$cur_branch" != "$branch" ] &&
       git rev-parse --verify --quiet "origin/$cur_branch" >/dev/null &&
       [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$cur_branch")" ]; then
      "$log_fn" "salvage: HEAD is already pushed to origin/$cur_branch ($ahead commit(s) ahead of origin/$branch) -- an in-flight PR branch, not abandoned work; skipping a duplicate salvage branch"
      ahead=0
    fi
  fi

  if [ -n "$working_state" ] || [ "$ahead" -gt 0 ]; then
    changed="$(printf '%s\n' "$working_state" | grep -c .)"
    ref="salvage/${label}-$(date +%Y%m%d%H%M%S)"
    "$log_fn" "WARNING: previous run left work behind ($ahead unpushed commit(s), $changed changed path(s)) -- salvaging to '$ref' before restoring to origin/$branch"

    if ! git checkout -b "$ref" >/dev/null 2>&1; then
      SALVAGE_ERROR="cannot create salvage branch '$ref' -- workspace left UNTOUCHED, nothing discarded"
      return 1
    fi
    if [ -n "$working_state" ]; then
      # -A is correct HERE specifically: this workspace has no other writer
      # (a human editing it defers the whole run via registry_should_defer),
      # and .gitignore still applies, so build debris does not ride along.
      git add -A "${scope[@]}"
      git commit -q -m "salvage: uncommitted work found by $label at $(date -Is)"
    fi
    if ! git push -u origin "$ref" >/dev/null 2>&1; then
      SALVAGE_ERROR="could not push salvage branch '$ref' -- the workspace is left ON that branch with the work intact; NOTHING was discarded. Push it by hand, or delete the branch once it is judged worthless."
      return 1
    fi
    SALVAGE_REF="$ref"
    "$log_fn" "salvaged: origin/$ref -- review it; this run continues from origin/$branch"
    salvage_file_issue "$ref" "$label" "$changed" "$branch" "$log_fn" || true
  fi

  # Only now, with anything worth keeping visible on origin, move the
  # workspace onto origin's state.
  if ! git checkout -B "$branch" "origin/$branch" >/dev/null 2>&1; then
    SALVAGE_ERROR="cannot put '$branch' at origin/$branch -- aborting before any claude work"
    return 1
  fi
  return 0
}
