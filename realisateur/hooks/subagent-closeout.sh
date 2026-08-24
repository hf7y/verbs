#!/usr/bin/env bash
# subagent-closeout.sh -- SubagentStop guard: a dirty tree at exit is a failed
# run, not a handoff (CLAUDE.md, since the 2026-07-25 sync-crontab.sh incident:
# 76 uncommitted lines the next autocommit watcher was positioned to adopt
# under a human's name). THE FLOOR gate 3.2. Owner: realisateur.
#
# CALLS `closeout-lint --strict --repo` rather than reimplementing a subset
# inline: it also catches unpushed commits and host-only branches, which
# `git status --porcelain` cannot see (the 2026-07-27 incident).
#
# CONTRACT. Hook payload as JSON on stdin. Exit 0 lets the subagent stop.
# Exit 2 BLOCKS the stop and feeds stderr back so it cleans up first.
#
# FAILS LOUD, NOT OPEN: an unreadable payload or an unrecognized closeout-lint
# exit code is exit 1 (visible, non-blocking), never a silent 0.
#
# --allow-blind: inside a linked worktree `git worktree list` reports the main
# checkout, so BLIND is >= 1 BY CONSTRUCTION for any worktree-isolated session
# and blocking on it would block every run. ecosim watches the BLIND
# population instead -- normal in ones, alarming in tens.
#
# Degrades rather than hard-depending on closeout-lint --repo, because the
# ~/.local/bin shim can lag main by a commit; the inline fallback keeps the
# 2026-07-25 protection through that window, loudly.
set -uo pipefail

log() { printf 'subagent-closeout: %s\n' "$*" >&2; }

payload="$(cat 2>/dev/null)" || { log "could not read hook payload from stdin"; exit 1; }

# Loop guard: having blocked once this stop, do not block forever.
#
# Herestring, not a pipe. Under pipefail, `producer | grep -q` reads FALSE
# precisely when it matched: grep -q closes the pipe on first match, the
# producer takes SIGPIPE and returns 141, and pipefail promotes it. This bit
# the capability probe below for real on 2026-08-02.
if grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true' <<<"$payload"; then
  exit 0
fi

# cwd is the SESSION's cwd, not necessarily the tree a subagent worked in.
# Fall back to $PWD if the payload lacks it.
cwd="$(sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q' <<<"$payload")"
[ -n "$cwd" ] || cwd="$PWD"
[ -d "$cwd" ] || { log "cwd from payload is not a directory: $cwd"; exit 1; }

# The SUBAGENT's own transcript, used below to find trees it wrote to (#363).
agent_transcript="$(sed -n 's/.*"agent_transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q' <<<"$payload")"

command -v git >/dev/null 2>&1 || { log "git not on PATH -- cannot check tree state"; exit 1; }

# #363: cwd misses a subagent that cloned or was worktree-isolated elsewhere.
discover_written_trees() {
  local transcript="$1" exclude="$2"
  [ -n "$transcript" ] && [ -r "$transcript" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '
    select(.message.content != null) |
    .message.content[]? |
    select(.type == "tool_use") |
    select(.name == "Write" or .name == "Edit" or .name == "NotebookEdit") |
    .input.file_path // empty
  ' "$transcript" 2>/dev/null |
  while IFS= read -r fp; do
    [ -n "$fp" ] || continue
    d="$(dirname -- "$fp" 2>/dev/null)" || continue
    root="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || continue
    [ -n "$root" ] && [ "$root" != "$exclude" ] && printf '%s\n' "$root"
  done | sort -u
}

# A PR THIS RUN OPENED is the other half of "did the work land": the tree is
# clean precisely because it was pushed to a branch nobody merged.
discover_opened_prs() {
  local transcript="$1"
  [ -n "$transcript" ] && [ -r "$transcript" ] || return 0
  grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' "$transcript" 2>/dev/null | sort -u
}

trees=("$cwd")
while IFS= read -r extra; do
  [ -n "$extra" ] && trees+=("$extra")
done < <(discover_written_trees "$agent_transcript" "$cwd")

# Not a git repo is not a violation; no-op only when every tree is a non-repo.
any_repo=0
for t in "${trees[@]}"; do
  git -C "$t" rev-parse --is-inside-work-tree >/dev/null 2>&1 && any_repo=1
done
[ "$any_repo" -eq 1 ] || exit 0

advice() {
  echo
  echo "A dirty tree at exit is a failed run, not a handoff -- an uncommitted change"
  echo "to a live script is indistinguishable from an abandoned one, and the next"
  echo "autocommit may adopt it under a human's name. An unpushed commit is the same"
  echo "failure one step later: the nightly clones the REF, not this working tree."
  echo
  echo "Before stopping, do ONE of these:"
  echo "  1. Commit the work you meant to keep, to a BRANCH (never main):"
  echo "       git add <specific paths>   # never 'git add -A'"
  echo "       git commit -F <msgfile>"
  echo "  2. Push it, so the branch exists on origin and not only on this host:"
  echo "       git push -u origin <branch>"
  echo "  3. Revert what you did not mean to keep:  git restore <paths>"
  echo "  4. If a file is deliberately untracked, add it to .gitignore and commit that."
  echo
  echo "Then report every file you touched, including the ones you reverted."
}

# A clean tree says the work was saved, not that it landed. Checked only
# when the tracker can be read: a hook that cannot look must not become a
# hook nobody can get past.
pr_report=""
if command -v gh >/dev/null 2>&1; then
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    slug="${url#https://github.com/}"; num="${slug##*/}"; slug="${slug%/pull/*}"
    meta="$(gh api "repos/$slug/pulls/$num" --jq '"\(.state)\t\(.draft)\t\(.body // "")"' 2>/dev/null)" || {
      log "could not read $url -- not blocking on a tracker this hook cannot reach"; continue; }
    st="${meta%%$'\t'*}"; rest="${meta#*$'\t'}"; dr="${rest%%$'\t'*}"; body="${rest#*$'\t'}"
    [ "$st" = open ] || continue
    if [ "$dr" = true ]; then
      log "note: $url is still a DRAFT -- a draft claims nothing, which is a valid way to stop."
      continue
    fi
    pr_report+="  $url is still open and not a draft"$'\n'
    case "$body" in
      *DELIVERS*) : ;;
      *) pr_report+="    and carries no DELIVERS block, so nothing can check whether it landed"$'\n' ;;
    esac
  done < <(discover_opened_prs "$agent_transcript")
fi
if [ -n "$pr_report" ]; then
  {
    echo "BLOCKED: this run opened a pull request that is still open."
    echo
    printf '%s' "$pr_report"
    echo
    echo "Merging is the middle of the job, not the end of it. Either land it"
    echo "(green checks, then merge), or convert it to a DRAFT -- a draft claims"
    echo "nothing and is the honest way to stop with work in flight."
  } >&2
  exit 2
fi

# --- preferred path: reuse the tool, do not reimplement it ------------------
LINT="$(command -v closeout-lint 2>/dev/null || true)"
# Capture then match, rather than `"$LINT" --help | grep -q`. See the SIGPIPE
# note on the loop guard above: that pipeline returned 141 under pipefail and
# silently sent every invocation down the fallback path, which reported
# "--repo is not installed" about a closeout-lint that had it.
lint_help=""
[ -n "$LINT" ] && lint_help="$("$LINT" --help 2>/dev/null || true)"
if [ -n "$LINT" ] && [[ "$lint_help" == *"--repo"* ]]; then
  blocked=0
  report=""
  for t in "${trees[@]}"; do
    git -C "$t" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    out="$("$LINT" --strict --allow-blind --repo "$t" 2>&1)"
    rc=$?
    case "$rc" in
      0) continue ;;
      1) blocked=1
         report+="  tree: $t"$'\n'
         report+="$(printf '%s\n' "$out" | grep -E '^\s*(FLAG|BLIND) \[' || printf '%s\n' "$out")"
         report+=$'\n\n'
         ;;
      *)
        log "closeout-lint exited $rc on $t, which this hook does not interpret."
        log "Refusing to report clean on a result it cannot read."
        printf '%s\n' "$out" >&2
        exit 1
        ;;
    esac
  done
  [ "$blocked" -eq 0 ] && exit 0
  {
    echo "BLOCKED: closeout-lint --strict found work this run did not make durable."
    if [ "${#trees[@]}" -gt 1 ]; then
      echo "  (${#trees[@]} trees checked -- cwd plus trees this agent's own"
      echo "  transcript shows it wrote to, per #363)"
    fi
    echo
    printf '%s' "$report"
    advice
  } >&2
  exit 2
fi

# --- the inline dirty-tree check -------------------------------------------
# NOT a degraded fallback waiting on an install. `closeout-lint` was deleted in
# hf7y/realisateur#511 and the shim installer that placed it went with #264, so
# there is no window and nothing to wait for. This branch is the only branch.
#
# The message here told every subagent to "run install-shims.sh once its --repo
# support is on main" -- naming, on every single run, a script deleted three
# days earlier. That is what hf7y/realisateur#572 was filed on.
log "checking the working tree only."
log "  UNPUSHED COMMITS AND HOST-ONLY BRANCHES ARE NOT CHECKED -- by subtraction, not by accident (#511)."

dirty_report=""
dirty_total=0
for t in "${trees[@]}"; do
  git -C "$t" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
  dirty="$(git -C "$t" status --porcelain 2>/dev/null)"
  rc=$?
  if [ $rc -ne 0 ]; then
    log "git status failed in $t (rc=$rc) -- refusing to report clean on a failed probe"
    exit 1
  fi
  [ -z "$dirty" ] && continue
  count="$(printf '%s\n' "$dirty" | grep -c .)"
  dirty_total=$((dirty_total + count))
  dirty_report+="  tree: $t ($count uncommitted change(s))"$'\n'
  dirty_report+="$(printf '%s\n' "$dirty" | head -20)"
  [ "$count" -gt 20 ] && dirty_report+=$'\n'"  ... and $((count - 20)) more"
  dirty_report+=$'\n\n'
done

[ "$dirty_total" -eq 0 ] && exit 0

{
  echo "BLOCKED: you are leaving $dirty_total uncommitted change(s)."
  echo
  printf '%s' "$dirty_report"
  advice
} >&2

exit 2
