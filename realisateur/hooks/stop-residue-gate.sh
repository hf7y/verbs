#!/usr/bin/env bash
set -uo pipefail  # stop-residue-gate.sh: Stop guard one scope up from SubagentStop (#681 SS1), same CONTRACT as hooks/subagent-closeout.sh; #681's unfiled-finding half is deliberately not attempted

log() { printf 'stop-residue-gate: %s\n' "$*" >&2; }

payload="$(cat 2>/dev/null)" || { log "could not read hook payload from stdin"; exit 1; }

if grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true' <<<"$payload"; then  # herestring: pipefail+SIGPIPE misreports a piped `grep -q` (subagent-closeout.sh)
  exit 0
fi

cwd="$(sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q' <<<"$payload")"
[ -n "$cwd" ] || cwd="$PWD"
[ -d "$cwd" ] || { log "cwd from payload is not a directory: $cwd"; exit 1; }

transcript="$(sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q' <<<"$payload")"  # not agent_transcript_path -- that's SubagentStop's field

human_step_violations() { # <this-turn's assistant text> -> one line per HUMAN-STEP block with no verified: field (#714 Rule 2)
  awk '
    /^[[:space:]]*HUMAN-STEP[[:space:]]*$/ {
      if (inblock && !sawverified) print "HUMAN-STEP block with no verified: field" (what == "" ? "" : " (" what ")")
      inblock = 1; sawverified = 0; what = ""; next
    }
    inblock && /^[[:space:]]*what:/ { line = $0; sub(/^[[:space:]]*what:[[:space:]]*/, "", line); what = line }
    inblock && /^[[:space:]]*verified:/ {
      line = $0; sub(/^[[:space:]]*verified:[[:space:]]*/, "", line); gsub(/[[:space:]]+$/, "", line)
      if (line != "") sawverified = 1
      next
    }
    inblock && /^[[:space:]]*$/ {
      if (!sawverified) print "HUMAN-STEP block with no verified: field" (what == "" ? "" : " (" what ")")
      inblock = 0
    }
    END { if (inblock && !sawverified) print "HUMAN-STEP block with no verified: field" (what == "" ? "" : " (" what ")") }
  '
}

if [ -n "$transcript" ] && [ -r "$transcript" ] && command -v jq >/dev/null 2>&1; then
  turn_text="$(jq -rs '
    . as $all |
    ([range(0; length) | select($all[.].type == "user" and ($all[.] | has("toolUseResult") | not))] | last) as $b |
    if $b == null then empty else
      $all[($b + 1):][] | select(.type == "assistant") | (.message.content // [])[] | select(.type == "text") | .text
    end
  ' "$transcript" 2>/dev/null)" || turn_text=""
  hs_report="$(human_step_violations <<<"$turn_text")"
  if [ -n "$hs_report" ]; then
    {
      echo "BLOCKED: this turn asked a human to perform a manual step without confirming it can work."
      echo
      printf '%s\n' "$hs_report"
      echo
      echo "verified: is the load-bearing field -- state HOW you confirmed the target system will"
      echo "accept this, even if the honest answer is that you have not checked yet. Then check."
    } >&2
    exit 2
  fi
fi

command -v git >/dev/null 2>&1 || { log "git not on PATH -- cannot check tree state"; exit 1; }

discover_written_trees() { # a worktree-isolated turn can write outside cwd (#363's shape, one scope up)
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

discover_opened_prs() {
  local transcript="$1"
  [ -n "$transcript" ] && [ -r "$transcript" ] || return 0
  grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' "$transcript" 2>/dev/null | sort -u
}

trees=("$cwd")
while IFS= read -r extra; do
  [ -n "$extra" ] && trees+=("$extra")
done < <(discover_written_trees "$transcript" "$cwd")

any_repo=0
for t in "${trees[@]}"; do
  git -C "$t" rev-parse --is-inside-work-tree >/dev/null 2>&1 && any_repo=1
done
[ "$any_repo" -eq 1 ] || exit 0

advice() {
  echo
  echo "A dirty tree at the end of a turn is a failed run, not a handoff -- an"
  echo "uncommitted change to a live script is indistinguishable from an"
  echo "abandoned one. An unpushed commit is the same failure one step later."
  echo
  echo "Before stopping, do ONE of these:"
  echo "  1. Commit the work you meant to keep, to a BRANCH (never main):"
  echo "       git add <specific paths>   # never 'git add -A'"
  echo "       git commit -F <msgfile>"
  echo "  2. Push it, so the branch exists on origin and not only on this host:"
  echo "       git push -u origin <branch>"
  echo "  3. Revert what you did not mean to keep:  git restore <paths>"
  echo "  4. If a file is deliberately untracked, add it to .gitignore and commit that."
}

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
  done < <(discover_opened_prs "$transcript")
fi
if [ -n "$pr_report" ]; then
  {
    echo "BLOCKED: this turn opened a pull request that is still open."
    echo
    printf '%s' "$pr_report"
    echo
    echo "Merging is the middle of the job, not the end of it. Either land it"
    echo "(green checks, then merge), or convert it to a DRAFT -- a draft claims"
    echo "nothing and is the honest way to stop with work in flight."
  } >&2
  exit 2
fi

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
