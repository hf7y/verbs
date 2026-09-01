#!/usr/bin/env bash
set -uo pipefail  # stop-residue-gate.sh: Stop guard one scope up from SubagentStop (#681 SS1), same CONTRACT as hooks/subagent-closeout.sh; #681's unfiled-finding half is completion_claims() + stated_defects(), refiled as #752; SCOPED TO THIS SESSION'S OWN CHANGES (#773) as #764 scoped the twin -- same contract, different anchor, because a main session has no SubagentStart, so the baseline is taken at SessionStart and spans the session. NO BASELINE IS NOT "IT IS ALL YOURS": it warns, since losing a block beats destroying what another session is still writing

log() { printf 'stop-residue-gate: %s\n' "$*" >&2; }

payload="$(cat 2>/dev/null)" || { log "could not read hook payload from stdin"; exit 1; }

if grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true' <<<"$payload"; then  # herestring: pipefail+SIGPIPE misreports a piped `grep -q` (subagent-closeout.sh)
  exit 0
fi

cwd="$(sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q' <<<"$payload")"
[ -n "$cwd" ] || cwd="$PWD"
[ -d "$cwd" ] || { log "cwd from payload is not a directory: $cwd"; exit 1; }

BASELINE_DIR="${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/tmp}"  # what was already dirty when this SESSION started. Keyed by session and read only while fresh ($CLAUDE_JOB_DIR/tmp is LONG-LIVED ACROSS SESSIONS), in its OWN dir: the twin's baselines mark a different moment and must not be read as this one
BASELINE_DIR="${BASELINE_DIR:-${TMPDIR:-/tmp}}/stop-residue-baselines"
BASELINE_MAX_AGE_MIN="${STOP_RESIDUE_BASELINE_MAX_AGE_MIN:-1440}"

json_field() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p;q" <<<"$2"; }

porcelain_paths() {  # PATHS, not porcelain lines: " M f" then and "MM f" now is one foreign file
  sed -e 's/^...//' | while IFS= read -r pp; do
    case "$pp" in
      *" -> "*) printf '%s\n%s\n' "${pp%% -> *}" "${pp#* -> }" ;;
      *)        printf '%s\n' "$pp" ;;
    esac
  done
}

session_id="$(json_field session_id "$payload")"
BASELINE_FILE="${session_id:+$BASELINE_DIR/${session_id//[^A-Za-z0-9._-]/_}}"

if [ "${1:-}" = "--baseline" ]; then  # SessionStart. Records and ALWAYS exits 0 -- a hook that cannot mark the start must not stop a session from starting
  [ -n "$BASELINE_FILE" ] || { log "SessionStart payload carries no session_id -- no baseline recorded"; exit 0; }
  command -v git >/dev/null 2>&1 || { log "git not on PATH -- no baseline recorded"; exit 0; }
  mkdir -p "$BASELINE_DIR" 2>/dev/null || { log "cannot write $BASELINE_DIR -- no baseline recorded"; exit 0; }
  find "$BASELINE_DIR" -maxdepth 1 -type f -mmin +"$BASELINE_MAX_AGE_MIN" -delete 2>/dev/null
  [ -e "$BASELINE_FILE" ] && exit 0  # FIRST CAPTURE WINS: resume and compact re-fire SessionStart, and a second mark would relabel this session's own work as pre-existing
  : > "$BASELINE_FILE" || { log "cannot write $BASELINE_FILE -- no baseline recorded"; exit 0; }
  if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    {
      printf 'HEAD\t%s\t%s\n' "$cwd" "$(git -C "$cwd" rev-parse HEAD 2>/dev/null || echo unknown)"
      git -C "$cwd" status --porcelain 2>/dev/null | porcelain_paths |
        while IFS= read -r bp; do printf 'DIRTY\t%s\t%s\n' "$cwd" "$bp"; done
    } >> "$BASELINE_FILE"
  fi
  exit 0
fi

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

completion_claims() { # <this turn's assistant text> -> one tagged line per act the turn CLAIMS; P=done, F=promised (#752, #681 2.1)
  awk '
    { s = tolower($0); gsub(/\047/, "", s); sub(/^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+/, "", s)
      if (s ~ /(^|[.!?] )i( ?ve| have)? (just |now )?(filed|committed|pushed|merged|landed|fixed|patched|deleted|removed)([ ,.]|$)/ ||
          s ~ /(^|[.!?] )i( ?ve| have)? (just |now )?(opened|created|raised)[^.!?]*(issue|pull request|pr[ .,]|#[0-9])/ ||
          s ~ /(^|[.!?] )(filed|landed) (it |this )?as #[0-9]/)
        print "P" substr($0, 1, 140)
      else if (s ~ /(^|[.!?] )i( ?ll| will) (also |then |next |now )?(file|open|commit|push|create|fix|land|delete|remove)([ ,.]|$)/)
        print "F" substr($0, 1, 140) }
  '
}

stated_defects() { # <this turn's assistant text> -> one line per sentence asserting a NAMED artifact is broken (#752 option 2, #681 2.1)
  awk '
    /^[[:space:]]*```/ { fence = !fence; next }                       # a fenced block is quoted material, not an assertion
    fence { next }
    /^[[:space:]]*>/ { next }                                        # so is a blockquote
    /^[[:space:]]*[-*][[:space:]]*\[[ xX]\]/ { next }                 # a checklist line reports work done, it does not assert a defect
    { line = $0; gsub(/\*?"[^"]*"\*?/, " ", line)                    # an inline quotation is someone else s words
      n = split(line, sent, /[.!?] +/)
      for (i = 1; i <= n; i++) {
        s = tolower(sent[i]); gsub(/\047/, "", s)
        if (s !~ /`[a-z0-9_./-]+\.(sh|py|tsv|conf|yml|yaml|json|jq|awk|md)(:[0-9]+)?`/) continue   # must name the artifact it accuses
        if (s ~ /(nothing|no one|nobody) (is|was|are|were)/) continue                              # "nothing is broken" is the opposite claim
        if (s ~ /(is|are|was|were|remains|remain|stays|stay) (still )?(wrong|false|stale|dead|broken|inert|a no-?op|a noop|vacuous|out of date|not true|never true)/ ||
            s ~ /never (fires|fired|runs|ran|looks|looked|checks|checked|reads|read|evaluates|evaluated|executed)/ ||
            s ~ /(does|do) not exist|no longer exists/ ||
            s ~ /nothing (reads|calls|checks|enforces|evaluates|holds|watches)/)
          { print substr(sent[i], 1, 140); next }
      }
    }
  '
}

ACT_RE='^(Write|Edit|NotebookEdit)$|git +commit|git +push|gh +(issue|pr) +(create|comment)|gh +api.*(issues|pulls)|notify-senechal'

cited_already() { # <flagged text> <transcript> -- true when it names an artifact this transcript has already seen
  local cite seen                                    # gh issue create prints a URL, not #N, so the number is the identity
  cite="$(grep -oE '#[0-9]+|/(issues|pull)/[0-9]+' <<<"$1" | grep -oE '[0-9]+' | sed -n 1p)"
  [ -n "$cite" ] || return 1
  seen="$(grep -vF '"type":"assistant"' "$2" | grep -cE "[#/]$cite([^0-9]|\$)")"
  [ "${seen:-0}" -gt 0 ]
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

  turn_acts="$(jq -rs '
    . as $all |
    ([range(0; length) | select($all[.].type == "user" and ($all[.] | has("toolUseResult") | not))] | last) as $b |
    if $b == null then empty else
      $all[($b + 1):][] | select(.type == "assistant") | (.message.content // [])[] | select(.type == "tool_use") |
      if .name == "Bash" then (.input.command // "") else .name end
    end
  ' "$transcript" 2>/dev/null)" || turn_acts=""
  claim_report=""
  defect_report=""
  if ! grep -qE "$ACT_RE" <<<"$turn_acts"; then
    while IFS= read -r claim; do
      case "$claim" in P*) cited_already "$claim" "$transcript" && continue ;; esac  # a done-claim naming an artifact this transcript has already seen is a citation, not a fresh claim
      claim_report+="  ${claim#?}"$'\n'
    done < <(completion_claims <<<"$turn_text")
    while IFS= read -r found; do
      cited_already "$found" "$transcript" && continue
      defect_report+="  $found"$'\n'
    done < <(stated_defects <<<"$turn_text")
  fi
  if [ -n "$claim_report" ]; then
    {
      echo "BLOCKED: this turn states an act that its own tool calls do not show."
      echo
      printf '%s' "$claim_report"
      echo
      echo "Fix it in the turn you found it; file only what you cannot reach. Do the act"
      echo "NOW -- Edit, git commit, gh issue create, gh pr create -- or cite the artifact"
      echo "that already carries it (#N, or a URL this transcript has seen). A finding"
      echo "stated in a reply and left there dies with the transcript."
    } >&2
    exit 2
  fi
  if [ -n "$defect_report" ]; then
    {
      echo "BLOCKED: this turn states that something is broken and files nothing."
      echo
      printf '%s' "$defect_report"
      echo
      echo "Fix it in the turn you found it; file only what you cannot reach. Do the act"
      echo "NOW -- Edit, git commit, gh issue create -- or cite the artifact that already"
      echo "carries it (#N, or a URL this transcript has seen). This is the residue #681"
      echo "measured: a defect named in prose, with no owner, dies with the transcript."
    } >&2
    exit 2
  fi
fi

command -v git >/dev/null 2>&1 || { log "git not on PATH -- cannot check tree state"; exit 1; }

BASELINE=""
if [ -n "$BASELINE_FILE" ] && [ -r "$BASELINE_FILE" ] \
   && [ -z "$(find "$BASELINE_FILE" -mmin +"$BASELINE_MAX_AGE_MIN" 2>/dev/null)" ]; then
  BASELINE="$BASELINE_FILE"
fi
baseline_has_tree() { # a tree the baseline actually probed
  [ -n "$BASELINE" ] && grep -qF "$(printf 'HEAD\t%s\t' "$1")" "$BASELINE"
}
baseline_dirty() {   # the paths ALREADY dirty in <tree> when this session started
  [ -n "$BASELINE" ] || return 0
  grep -F "$(printf 'DIRTY\t%s\t' "$1")" "$BASELINE" 2>/dev/null | cut -f3-
}

discover_written_files() {  # #363: cwd misses a turn worktree-isolated elsewhere. The FILES are kept too -- in a tree no baseline saw, only a path this transcript shows being written is attributable to this session
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

written_files=()
while IFS= read -r fp; do
  [ -n "$fp" ] && written_files+=("$fp")
done < <(discover_written_files "$transcript")

is_written() { # is_written <abs-path> -- did this session's transcript write it?
  local q="$1" f
  for f in ${written_files[@]+"${written_files[@]}"}; do
    [ "$f" = "$q" ] && return 0
  done
  return 1
}

discover_opened_prs() {
  local transcript="$1"
  [ -n "$transcript" ] && [ -r "$transcript" ] || return 0
  grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' "$transcript" 2>/dev/null | sort -u
}

trees=("$cwd")
for fp in ${written_files[@]+"${written_files[@]}"}; do
  d="$(dirname -- "$fp" 2>/dev/null)" || continue
  root="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || continue
  [ -n "$root" ] || continue
  for seen in "${trees[@]}"; do [ "$seen" = "$root" ] && continue 2; done
  trees+=("$root")
done

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
  echo "For the changes listed as YOURS, do ONE of these:"
  echo "  1. Commit the work you meant to keep, to a BRANCH (never main):"
  echo "       git add <specific paths>   # never 'git add -A'"
  echo "       git commit -F <msgfile>"
  echo "  2. Push it, so the branch exists on origin and not only on this host:"
  echo "       git push -u origin <branch>"
  echo "  3. Revert what you did not mean to keep:  git restore <paths>"
  echo "  4. If a file is deliberately untracked, add it to .gitignore and commit that."
  echo
  echo "NONE of those apply to a path this report did not list as YOURS. Those files"
  echo "are not yours: leave them exactly as they are, say so in your reply, and stop."
  echo "If no permitted commit is open to you, name the paths and stop there too --"
  echo "destroying work to get past this hook is the one outcome it exists to prevent."
}

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
  done < <(discover_opened_prs "$transcript")
fi
if [ -n "$pr_report" ]; then
  {
    echo "BLOCKED: this turn opened a pull request that is still open."
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

own_report=""; foreign_report=""; unattr_report=""; own_total=0
[ -n "$BASELINE" ] || log "NO BASELINE for this session -- changes this hook cannot attribute are reported, not charged to you."

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

if [ "$own_total" -gt 0 ]; then
  {
    echo "BLOCKED: you are leaving $own_total uncommitted change(s) of your own."
    echo
    echo "YOURS -- new since this session started:"
    printf '%s' "$own_report"
    if [ -n "$foreign_report" ]; then
      echo
      echo "NOT YOURS -- already there when this session started. Context only:"
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
    echo "stop-residue-gate: nothing in these trees is attributable to this session --"
    echo "not blocking. Reported so it is not mistaken for a clean checkout:"
    if [ -n "$foreign_report" ]; then
      echo
      echo "NOT YOURS -- already there when this session started:"
      printf '%s' "$foreign_report"
    fi
    if [ -n "$unattr_report" ]; then
      echo
      echo "UNATTRIBUTED -- no SessionStart baseline was recorded for this tree, so this"
      echo "hook cannot tell your changes from a concurrent session's:"
      printf '%s' "$unattr_report"
    fi
    echo
    echo "Leave all of the above alone: none of it is yours to commit or revert."
    echo "Mention in your reply that you stopped with it present."
  } >&2
fi
exit 0
