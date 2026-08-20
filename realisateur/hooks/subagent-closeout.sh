#!/usr/bin/env bash
# subagent-closeout.sh -- SubagentStop guard: a dirty tree at exit is a failed
# run, not a handoff (CLAUDE.md, since the 2026-07-25 sync-crontab.sh incident:
# 76 uncommitted lines a subagent left behind, that the next autocommit
# watcher was positioned to adopt under a human's name). Installed 2026-08-01
# as THE FLOOR gate 3.2 (vault:realisateur/THE-FLOOR.md). Owner: realisateur.
#
# CALLS `closeout-lint --strict --repo` (2026-08-02) rather than reimplementing
# a subset of it inline: closeout-lint also catches unpushed commits and
# host-only branches, which a bare `git status --porcelain` cannot see (the
# 2026-07-27 incident, distinct from 2026-07-25).
#
# CONTRACT. Hook payload as JSON on stdin. Exit 0 lets the subagent stop.
# Exit 2 BLOCKS the stop and feeds stderr back so it cleans up first.
#
# FAILS LOUD, NOT OPEN: an unreadable payload or an unrecognized closeout-lint
# exit code is exit 1 (visible, non-blocking), never a silent 0.
#
# --allow-blind: from inside a linked worktree `git worktree list` always
# reports the main checkout, so BLIND is >= 1 BY CONSTRUCTION for any
# worktree-isolated session -- the standard pattern here. Blocking on that
# would block every subagent, every run. ecosim watches the BLIND population
# instead (filed 2026-08-02) -- the right instrument for a signal that's
# normal in ones and alarming in tens.
#
# Degrades instead of hard-depending on closeout-lint --repo because the
# ~/.local/bin shim can lag one commit behind main; probing and falling back
# to the original inline check keeps the 2026-07-25 protection intact through
# that window, loudly, rather than erroring every subagent stop.
set -uo pipefail

log() { printf 'subagent-closeout: %s\n' "$*" >&2; }

payload="$(cat 2>/dev/null)" || { log "could not read hook payload from stdin"; exit 1; }

# Loop guard: if we already blocked once this stop, do not block forever.
# The subagent has been told; a second identical block would spin.
#
# Herestring, not a pipe. `producer | grep -q` is unsafe under `set -o
# pipefail`: grep -q exits on the first match and closes the pipe, the
# producer takes SIGPIPE and returns 141, and pipefail promotes that to the
# pipeline's status -- so the test reads FALSE precisely when it matched.
# This is BUILD-DISCIPLINE's "pipefail+SIGPIPE guarded" row, and it bit the
# capability probe below for real on 2026-08-02 before being caught.
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

# --- fallback: the original inline dirty-tree check -------------------------
log "closeout-lint --repo is not installed; checking the working tree only."
log "  UNPUSHED COMMITS AND HOST-ONLY BRANCHES ARE NOT BEING CHECKED."
log "  Fix: run realisateur/bin/install-shims.sh once its --repo support is on main."

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
