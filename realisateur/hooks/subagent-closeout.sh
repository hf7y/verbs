#!/usr/bin/env bash
# subagent-closeout.sh -- SubagentStop guard: a dirty tree at exit is a failed
# run, not a handoff (CLAUDE.md, since the 2026-07-25 sync-crontab.sh incident:
# 76 uncommitted lines the next autocommit watcher was positioned to adopt
# under a human's name). THE FLOOR gate 3.2. Owner: realisateur.
#
# SCOPED TO THIS AGENT'S OWN CHANGES. In a shared checkout `git status` cannot
# tell another session's in-progress files from this agent's. Unscoped, this
# gate twice on 2026-08-29 charged an agent with 4 files (154 lines) a live
# session was still writing, leaving it two exits: revert work it did not own,
# or not exit. So the same script runs at SubagentStart (`--baseline`) to
# record what was ALREADY dirty, and judges only the DELTA. Pre-existing dirt
# is CONTEXT: never blocking, never attributed, never something this hook says
# to revert or commit. NO BASELINE IS NOT "IT IS ALL YOURS": missing, stale or
# unreadable warns instead -- losing a block beats losing someone else's work.
#
# CONTRACT. Hook payload as JSON on stdin. Exit 0 lets the subagent stop, 2
# BLOCKS it and feeds stderr back. `--baseline` records and always exits 0 --
# a hook that cannot mark the start must not stop a subagent from starting.
# FAILS LOUD, NOT OPEN: an unreadable payload or an unrecognized closeout-lint
# exit code is exit 1, never 0.
#
# `closeout-lint --strict --repo` is preferred where it exists: it also catches
# unpushed commits and host-only branches, which `git status --porcelain`
# cannot see (2026-07-27). --allow-blind: a linked worktree makes BLIND >= 1 BY
# CONSTRUCTION, and ecosim watches that population instead.
set -uo pipefail

log() { printf 'subagent-closeout: %s\n' "$*" >&2; }

payload="$(cat 2>/dev/null)" || { log "could not read hook payload from stdin"; exit 1; }

# Loop guard: having blocked once this stop, do not block forever. Herestring,
# not a pipe: under pipefail `producer | grep -q` reads FALSE precisely when it
# matched (SIGPIPE, 141, promoted). It bit the capability probe on 2026-08-02.
if grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true' <<<"$payload"; then
  exit 0
fi

# cwd is the SESSION's cwd, not necessarily the tree a subagent worked in.
cwd="$(sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q' <<<"$payload")"
[ -n "$cwd" ] || cwd="$PWD"
[ -d "$cwd" ] || { log "cwd from payload is not a directory: $cwd"; exit 1; }

# The SUBAGENT's own transcript, used below to find trees it wrote to (#363).
agent_transcript="$(sed -n 's/.*"agent_transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q' <<<"$payload")"

command -v git >/dev/null 2>&1 || { log "git not on PATH -- cannot check tree state"; exit 1; }

# --- the baseline: what was already dirty when this agent started -----------
# $CLAUDE_JOB_DIR/tmp is LONG-LIVED ACROSS SESSIONS, so a baseline is keyed by
# session (and agent, when the payload has one) and read only while fresh.
BASELINE_DIR="${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/tmp}"
BASELINE_DIR="${BASELINE_DIR:-${TMPDIR:-/tmp}}/subagent-closeout-baselines"
BASELINE_MAX_AGE_MIN="${SUBAGENT_BASELINE_MAX_AGE_MIN:-1440}"

json_field() { # json_field <name> <payload>
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p;q" <<<"$2"
}

# PATHS, not porcelain lines: " M f" then and "MM f" now is one foreign file.
porcelain_paths() {
  sed -e 's/^...//' | while IFS= read -r pp; do
    case "$pp" in
      *" -> "*) printf '%s\n%s\n' "${pp%% -> *}" "${pp#* -> }" ;;
      *)        printf '%s\n' "$pp" ;;
    esac
  done
}

# --baseline runs the same probe: a finding already there is not this agent's.
LINT="$(command -v closeout-lint 2>/dev/null || true)"
# Capture then match, not `--help | grep -q`: the SIGPIPE note above.
lint_help=""
[ -n "$LINT" ] && lint_help="$("$LINT" --help 2>/dev/null || true)"
LINT_HAS_REPO=0
[ -n "$LINT" ] && [[ "$lint_help" == *"--repo"* ]] && LINT_HAS_REPO=1

lint_findings() { # lint_findings <tree> -- the FLAG/BLIND lines only
  [ "$LINT_HAS_REPO" -eq 1 ] || return 0
  "$LINT" --strict --allow-blind --repo "$1" 2>&1 | grep -E '^[[:space:]]*(FLAG|BLIND) \[' || true
}

baseline_key() { # baseline_key <payload> -- empty when the payload cannot key one
  local sid aid
  sid="$(json_field session_id "$1")"
  aid="$(json_field agent_id "$1")"
  [ -n "$sid" ] || return 0
  printf '%s.%s' "${sid//[^A-Za-z0-9._-]/_}" "${aid//[^A-Za-z0-9._-]/_}"
}

if [ "${1:-}" = "--baseline" ]; then
  key="$(baseline_key "$payload")"
  [ -n "$key" ] || { log "SubagentStart payload carries no session_id -- no baseline recorded"; exit 0; }
  mkdir -p "$BASELINE_DIR" 2>/dev/null || { log "cannot write $BASELINE_DIR -- no baseline recorded"; exit 0; }
  find "$BASELINE_DIR" -maxdepth 1 -type f -mmin +"$BASELINE_MAX_AGE_MIN" -delete 2>/dev/null
  bf="$BASELINE_DIR/$key"
  : > "$bf" || { log "cannot write $bf -- no baseline recorded"; exit 0; }
  if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    {
      printf 'HEAD\t%s\t%s\n' "$cwd" "$(git -C "$cwd" rev-parse HEAD 2>/dev/null || echo unknown)"
      git -C "$cwd" status --porcelain 2>/dev/null | porcelain_paths |
        while IFS= read -r bp; do printf 'DIRTY\t%s\t%s\n' "$cwd" "$bp"; done
      lint_findings "$cwd" |
        while IFS= read -r bl; do printf 'LINT\t%s\t%s\n' "$cwd" "$bl"; done
    } >> "$bf"
  fi
  exit 0
fi

# Concurrent subagents share a session_id when the payload has no agent_id;
# the newest baseline names the most pre-existing dirt, so it accuses least.
BASELINE=""
_sid="$(json_field session_id "$payload")"
_aid="$(json_field agent_id "$payload")"
if [ -n "$_sid" ] && [ -d "$BASELINE_DIR" ]; then
  _sid="${_sid//[^A-Za-z0-9._-]/_}"; _aid="${_aid//[^A-Za-z0-9._-]/_}"
  _exact="$BASELINE_DIR/$_sid.$_aid"
  if [ -n "$_aid" ] && [ -r "$_exact" ] && [ -z "$(find "$_exact" -mmin +"$BASELINE_MAX_AGE_MIN" 2>/dev/null)" ]; then
    BASELINE="$_exact"
  else
    BASELINE="$(find "$BASELINE_DIR" -maxdepth 1 -type f -name "$_sid.*" -mmin -"$BASELINE_MAX_AGE_MIN" \
                 -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  fi
fi

baseline_has_tree() { # a tree the baseline actually probed
  [ -n "$BASELINE" ] && grep -qF "$(printf 'HEAD\t%s\t' "$1")" "$BASELINE"
}
baseline_dirty() {   # the paths that were ALREADY dirty in <tree>
  [ -n "$BASELINE" ] || return 0
  grep -F "$(printf 'DIRTY\t%s\t' "$1")" "$BASELINE" 2>/dev/null | cut -f3-
}
baseline_lint() {    # the findings closeout-lint ALREADY reported for <tree>
  [ -n "$BASELINE" ] || return 0
  grep -F "$(printf 'LINT\t%s\t' "$1")" "$BASELINE" 2>/dev/null | cut -f3-
}

# #363: cwd misses a subagent that cloned or was worktree-isolated elsewhere.
# The FILES are kept too: in a tree no baseline saw, only a path the
# transcript shows this agent writing can be attributed to it.
discover_written_files() {
  local transcript="$1"
  [ -n "$transcript" ] && [ -r "$transcript" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '
    select(.message.content != null) |
    .message.content[]? |
    select(.type == "tool_use") |
    select(.name == "Write" or .name == "Edit" or .name == "NotebookEdit") |
    .input.file_path // empty
  ' "$transcript" 2>/dev/null | sort -u
}

# A PR THIS RUN OPENED -- not one it merely READ (the 2026-08-29 fixture scrape).
discover_opened_prs() {
  local transcript="$1" ids
  [ -n "$transcript" ] && [ -r "$transcript" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  ids="$(jq -r '
    .message.content[]? |
    select(.type == "tool_use" and .name == "Bash") |
    select((.input.command // "") | test("gh[[:space:]].*(pr[[:space:]]+create|POST.*/pulls)")) |
    .id // empty
  ' "$transcript" 2>/dev/null | jq -Rsc 'split("\n") | map(select(. != ""))')"
  [ -n "$ids" ] && [ "$ids" != "[]" ] || return 0
  jq -r --argjson ids "$ids" '
    .message.content[]? |
    select(.type == "tool_result") |
    select(.tool_use_id as $i | ($ids | index($i)) != null) |
    [.content] | flatten | .[] |
    if type == "string" then . else (.text // empty) end
  ' "$transcript" 2>/dev/null |
    grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' | sort -u
}

written_files=()
while IFS= read -r fp; do
  [ -n "$fp" ] && written_files+=("$fp")
done < <(discover_written_files "$agent_transcript")

is_written() { # is_written <abs-path> -- did THIS agent's transcript write it?
  local q="$1" f
  for f in ${written_files[@]+"${written_files[@]}"}; do
    [ "$f" = "$q" ] && return 0
  done
  return 1
}

trees=("$cwd")
for fp in ${written_files[@]+"${written_files[@]}"}; do
  d="$(dirname -- "$fp" 2>/dev/null)" || continue
  root="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || continue
  [ -n "$root" ] || continue
  for seen in "${trees[@]}"; do [ "$seen" = "$root" ] && continue 2; done
  trees+=("$root")
done

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
  echo "For the changes listed as YOURS, do ONE of these:"
  echo "  1. Commit the work you meant to keep, to a BRANCH (never main):"
  echo "       git add <specific paths>   # never 'git add -A'"
  echo "       git commit -F <msgfile>"
  echo "  2. Push it, so the branch exists on origin and not only on this host:"
  echo "       git push -u origin <branch>"
  echo "  3. Revert what you did not mean to keep:  git restore <paths>"
  echo "  4. If a file is deliberately untracked, add it to .gitignore and commit that."
  echo
  echo "NONE of those apply to a path this report did not list as yours. If you do"
  echo "not recognise something it did list -- a concurrent session can start writing"
  echo "after this run began -- leave the file alone and say so in your report. If no"
  echo "permitted commit is open to you, name the paths and stop there: destroying"
  echo "work to get past this hook is the one outcome it exists to prevent."
  echo
  echo "Then report every file you touched, including the ones you reverted."
}

own_report=""; foreign_report=""; unattr_report=""; own_total=0

emit_verdict() { # emit_verdict <blocked-headline>
  if [ "$own_total" -gt 0 ]; then
    {
      echo "BLOCKED: $1"
      if [ "${#trees[@]}" -gt 1 ]; then
        echo "  (${#trees[@]} trees checked -- cwd plus trees this agent's own"
        echo "  transcript shows it wrote to, per #363)"
      fi
      echo
      echo "YOURS -- new since this run started:"
      printf '%s' "$own_report"
      if [ -n "$foreign_report" ]; then
        echo
        echo "NOT YOURS -- already there when this run started. Context only:"
        printf '%s' "$foreign_report"
        echo "  Leave these exactly as they are. They are not part of this gate."
      fi
      if [ -n "$unattr_report" ]; then
        echo
        echo "UNATTRIBUTED -- no baseline for this tree, so ownership is unknown:"
        printf '%s' "$unattr_report"
        echo "  Not attributed to you and not blocking. Do not revert or commit them."
      fi
      advice
    } >&2
    exit 2
  fi

  if [ -n "$foreign_report" ] || [ -n "$unattr_report" ]; then
    {
      echo "subagent-closeout: nothing in these trees is attributable to this run --"
      echo "not blocking. Reported so it is not mistaken for a clean checkout:"
      if [ -n "$foreign_report" ]; then
        echo
        echo "NOT YOURS -- already there when this run started:"
        printf '%s' "$foreign_report"
      fi
      if [ -n "$unattr_report" ]; then
        echo
        echo "UNATTRIBUTED -- no SubagentStart baseline was recorded for this tree, so"
        echo "this hook cannot tell your changes from a concurrent session's:"
        printf '%s' "$unattr_report"
      fi
      echo
      echo "Leave all of the above alone: none of it is yours to commit or revert."
      echo "Mention in your report that you exited with it present."
    } >&2
  fi
  exit 0
}

# Checked only when the tracker can be read: a hook that cannot look must not
# become impassable.
pr_report=""
if command -v gh >/dev/null 2>&1; then
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    slug="${url#https://github.com/}"; num="${slug##*/}"; slug="${slug%/pull/*}"
    meta="$(gh api "repos/$slug/pulls/$num" --jq '"\(.state)\t\(.draft)\t\(.auto_merge != null)\t\(.body // "")"' 2>/dev/null)" || {
      log "could not read $url -- not blocking on a tracker this hook cannot reach"; continue; }
    st="${meta%%$'\t'*}"; rest="${meta#*$'\t'}"; dr="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"; am="${rest%%$'\t'*}"; body="${rest#*$'\t'}"
    [ "$st" = open ] || continue
    if [ "$dr" = true ]; then
      log "note: $url is still a DRAFT -- a draft claims nothing, which is a valid way to stop."
      continue
    fi
    if [ "$am" = true ]; then
      log "note: $url has AUTO-MERGE ARMED -- it lands when its required checks pass. Valid way to stop."
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
    echo "Merging is the middle of the job, not the end of it. Three honest exits:"
    echo "  gh pr merge <n> --repo <slug> --squash --auto --delete-branch"
    echo "      arm auto-merge -- it lands when the required checks pass. PREFER THIS."
    echo "  land it now, if every required check is already green."
    echo "  convert it to a DRAFT -- a draft claims nothing, for work still in flight."
  } >&2
  exit 2
fi

# --- preferred path: reuse the tool, do not reimplement it ------------------
if [ "$LINT_HAS_REPO" -eq 1 ]; then
  for t in "${trees[@]}"; do
    git -C "$t" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    out="$("$LINT" --strict --allow-blind --repo "$t" 2>&1)"
    rc=$?
    case "$rc" in
      0) continue ;;
      1) : ;;
      *)
        log "closeout-lint exited $rc on $t, which this hook does not interpret."
        log "Refusing to report clean on a result it cannot read."
        printf '%s\n' "$out" >&2
        exit 1
        ;;
    esac
    findings="$(printf '%s\n' "$out" | grep -E '^\s*(FLAG|BLIND) \[' || printf '%s\n' "$out")"
    had_base=0; base=""
    baseline_has_tree "$t" && { had_base=1; base="$(baseline_lint "$t")"; }
    own=""; foreign=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if [ "$had_base" -eq 1 ] && printf '%s\n' "$base" | grep -qxF "$line"; then
        foreign+="    $line"$'\n'
      elif [ "$had_base" -eq 1 ]; then
        own+="    $line"$'\n'; own_total=$((own_total + 1))
      else
        unattr_report+="    $line"$'\n'
      fi
    done <<<"$findings"
    [ -n "$own" ]     && own_report+="  tree: $t"$'\n'"$own"
    [ -n "$foreign" ] && foreign_report+="  tree: $t"$'\n'"$foreign"
  done
  emit_verdict "closeout-lint --strict found work THIS RUN did not make durable."
fi

# --- the inline dirty-tree check -------------------------------------------
# NOT a fallback waiting on an install: #511 deleted `closeout-lint` and #264
# its shim installer. #572 was filed on the message that used to tell every
# run to reinstall that dead script.
log "checking the working tree only."
log "  UNPUSHED COMMITS AND HOST-ONLY BRANCHES ARE NOT CHECKED -- by subtraction, not by accident (#511)."
[ -n "$BASELINE" ] || log "  NO BASELINE for this run -- changes this hook cannot attribute are reported, not charged to you."

for t in "${trees[@]}"; do
  git -C "$t" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
  dirty="$(git -C "$t" status --porcelain 2>/dev/null)"
  rc=$?
  if [ $rc -ne 0 ]; then
    log "git status failed in $t (rc=$rc) -- refusing to report clean on a failed probe"
    exit 1
  fi
  [ -z "$dirty" ] && continue

  had_base=0; base=""
  baseline_has_tree "$t" && { had_base=1; base="$(baseline_dirty "$t")"; }
  own=""; foreign=""; unattr=""; own_count=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="$(printf '%s\n' "$line" | porcelain_paths | head -1)"
    if [ "$had_base" -eq 1 ] && printf '%s\n' "$base" | grep -qxF "$path"; then
      foreign+="    $line"$'\n'
    elif [ "$had_base" -eq 1 ] || is_written "$t/$path"; then
      own+="    $line"$'\n'; own_count=$((own_count + 1)); own_total=$((own_total + 1))
    else
      unattr+="    $line"$'\n'
    fi
  done <<<"$dirty"

  [ -n "$own" ]     && own_report+="  tree: $t ($own_count uncommitted change(s))"$'\n'"$own"
  [ -n "$foreign" ] && foreign_report+="  tree: $t"$'\n'"$foreign"
  [ -n "$unattr" ]  && unattr_report+="  tree: $t"$'\n'"$unattr"
done

emit_verdict "you are leaving $own_total uncommitted change(s) of your own."
