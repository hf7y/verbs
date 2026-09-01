# run-record.sh -- COMPUTE the verdict at closeout instead of asking for it.
#
# THE PROBLEM (hf7y/scheduler#54, and the 2026-08-06 blowout):
#
# A run that fixed something and a run that merely filed three issues leave
# IDENTICAL records. The only outcome signal above `rc` is bin/verdict.sh, and
# every field in it is typed by the agent about itself -- VERDICT, REASON, the
# closing summary prose. Worse, the file is CONSUMED at dispatch, so even that
# self-report is gone by the time anyone could compare it against what the run
# actually did. Describing is free, indistinguishable from working, and
# strictly cheaper. So agents describe. On 2026-08-06 that produced 42 issues
# across five repos while the thing that actually needed doing was one
# `git merge --ff-only`.
#
# This file does not ask the agent anything. Every field below is read back out
# of git and the GitHub API AFTER `claude -p` has already exited, from state the
# agent had to actually change in order to move. Prose may ACCOMPANY the record
# -- claimed_verdict/claimed_reason carry it, namespaced -- but it can never
# POPULATE it. There is no code path from agent output into a sha, a count, or
# verdict_computed.
#
# WHERE IT IS WRITTEN, and why not in the repo:
#
#   $STATE_ROOT/scheduler-runs/<participant>.jsonl     (append-only, one line
#                                                       per run, never rewritten)
#
# Sibling of bin/verdict.sh's $STATE_ROOT/scheduler-verdict/, keyed the same way
# (rotation participant name) for the same reason. NOT a git-tracked file, and
# run_record_append REFUSES to write one inside the run's own work tree -- that
# refusal is not hypothetical hygiene. On 2026-08-07 vim-arcade's deploys sat
# frozen for 18 hours because lib/sweep-loop-common.sh:601 consumes BLOCKERS.md
# out of its OWN checkout: the engine dirtied the tree it was about to pull
# into, and bin/usage-paced-runner.sh's pull gate correctly refused every tick
# after. An engine that writes into the checkout it manages will eventually
# deadlock against its own guards. So it writes outside, always.
#
# All state is in RR_* globals rather than stdout, so tests/run-record-witness.sh
# can source this file, drive each probe directly, and read the results -- the
# same shape as lib/salvage.sh and append_verdict_closeout() in the engine, and
# for the same reason: a function buried in the run body cannot be witnessed.
set -uo pipefail

RUN_RECORD_SCHEMA="scheduler.run-record/1"

# gh is invoked through this indirection so the witness can hand the probes a
# stub and drive every branch (ok / unavailable / error) without a network.
: "${RR_GH_BIN:=gh}"
: "${RR_GH_TIMEOUT:=20}"

rr_log() { echo "run-record: $*"; }

# --- JSON, by hand -- jq is not guaranteed on a service account -------------
rr_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
  # Strip anything else below 0x20 rather than emitting a raw control byte,
  # which would make the line unparseable and take the whole ledger with it.
  printf '%s' "$s" | tr -d '\000-\037'
}
rr_jstr() { printf '"%s"' "$(rr_json_escape "${1:-}")"; }
# A number, or the literal null when we did not measure it. NEVER 0 for
# "unknown": a debt rule that reads unmeasured as zero opens is a rule that
# passes runs it never looked at.
rr_jnum() {
  case "${1:-}" in
    ''|null) printf 'null' ;;
    *[!0-9-]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

# --- WHAT GIT SAYS HAPPENED ------------------------------------------------
# Args: <before_sha> <after_sha> <remote_sha>   (remote may be empty)
# Sets: RR_COMMITS_ADDED RR_PUSHED RR_FILES_CHANGED RR_INSERTIONS RR_DELETIONS
#
# Runs in the run's work tree. Every value comes from a plumbing command; none
# of them has an argument the agent supplied.
run_record_probe_git() {
  local before="$1" after="$2" remote="${3:-}"
  RR_COMMITS_ADDED=""; RR_PUSHED="null"
  RR_FILES_CHANGED=""; RR_INSERTIONS=""; RR_DELETIONS=""

  # A sha we cannot parse is recorded as unmeasured, not guessed at. This is
  # also the gate that makes "an agent cannot write the sha" mechanical: the
  # only values that ever reach the ledger passed this shape test after being
  # produced by git rev-parse.
  if ! rr_is_sha "$before" || ! rr_is_sha "$after"; then
    rr_log "WARNING: unusable before/after sha ('$before' / '$after') -- git fields recorded as null"
    return 1
  fi

  RR_COMMITS_ADDED="$(git rev-list --count "$before..$after" 2>/dev/null)"
  [ -n "$RR_COMMITS_ADDED" ] || RR_COMMITS_ADDED=""

  if [ "$before" = "$after" ]; then
    # No commits: "pushed" is not false, it is not applicable. false would read
    # as an unpushed-commit failure in every consumer.
    RR_PUSHED="null"
  elif [ -n "$remote" ] && [ "$after" = "$remote" ]; then
    RR_PUSHED="true"
  else
    RR_PUSHED="false"
  fi

  local shortstat
  shortstat="$(git diff --shortstat "$before" "$after" 2>/dev/null)"
  RR_FILES_CHANGED="$(printf '%s' "$shortstat" | grep -oE '[0-9]+ files? changed' | grep -oE '^[0-9]+')"
  RR_INSERTIONS="$(printf '%s' "$shortstat" | grep -oE '[0-9]+ insertions?' | grep -oE '^[0-9]+')"
  RR_DELETIONS="$(printf '%s' "$shortstat" | grep -oE '[0-9]+ deletions?' | grep -oE '^[0-9]+')"
  # git omits the clause entirely when a count is zero; absent means zero here,
  # and we only got this far because both shas parsed.
  : "${RR_FILES_CHANGED:=0}" "${RR_INSERTIONS:=0}" "${RR_DELETIONS:=0}"
  return 0
}

rr_is_sha() { [[ "${1:-}" =~ ^[0-9a-f]{7,40}$ ]]; }

# Reasons accumulate as a newline-separated list; run_record_line renders them
# as a JSON array. A verdict with no reason is a verdict nobody can check.
rr_add_reason() { RR_REASONS="${RR_REASONS:-}${RR_REASONS:+$'\n'}$1"; }

# owner/name from origin, for gh -R. Empty if origin is not a GitHub remote.
#
# Self-dev accounts point origin at a per-repo SSH host alias
# (git@github-<project>:owner/repo.git, see ~/.ssh/config), not literal
# github.com -- a literal *github.com* match against that alias always
# failed, so every self-dev run recorded gh:"unavailable" regardless of
# whether gh actually worked. Match any github.com or github-* host and
# pull the trailing owner/repo off the URL generically.
run_record_repo_slug() {
  local url; url="$(git remote get-url origin 2>/dev/null)" || return 1
  case "$url" in
    *github.com*|*github-*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$url" | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##'
}

# --- WHAT GITHUB SAYS HAPPENED ---------------------------------------------
# Args: <owner/repo> <since ISO8601>
# Sets: RR_ISSUES_OPENED RR_ISSUES_CLOSED RR_PRS_OPENED RR_PRS_MERGED RR_GH
#
# SCOPE, stated plainly because run_record_compute_verdict's NET-closed check
# is built on it:
#   opened  -- author:@me, i.e. attributable to the account this run ran as.
#   closed  -- everything closed in the window, whoever closed it. GitHub
#              search has no closed-by: qualifier, so this cannot be narrowed.
# That asymmetry makes the count LENIENT (a human closing something in the
# same window credits the run) and never harsh.
#
# gh missing, unauthenticated, or erroring is RR_GH != ok and NULL counts --
# never zero. Unmeasured must read as unmeasured, not as a real zero; that is
# the same asymmetry as bin/verdict.sh's "absence of a verdict is never
# GAVE-UP".
run_record_probe_gh() {
  local slug="$1" since="$2"
  RR_ISSUES_OPENED=""; RR_ISSUES_CLOSED=""; RR_PRS_OPENED=""; RR_PRS_MERGED=""
  RR_GH="unavailable"

  if [ -z "$slug" ]; then
    rr_log "gh probe skipped -- origin is not a GitHub remote; issue/PR counts recorded as null"
    return 1
  fi
  if ! command -v "$RR_GH_BIN" >/dev/null 2>&1; then
    rr_log "WARNING: '$RR_GH_BIN' not on PATH -- issue/PR counts recorded as null"
    return 1
  fi

  local n
  n="$(rr_gh_count issue "$slug" all "created:>=$since author:@me")" || { RR_GH="error"; return 1; }
  RR_ISSUES_OPENED="$n"
  n="$(rr_gh_count issue "$slug" closed "closed:>=$since")"          || { RR_GH="error"; return 1; }
  RR_ISSUES_CLOSED="$n"
  n="$(rr_gh_count pr "$slug" all "created:>=$since author:@me")"    || { RR_GH="error"; return 1; }
  RR_PRS_OPENED="$n"
  n="$(rr_gh_count pr "$slug" merged "merged:>=$since")"             || { RR_GH="error"; return 1; }
  RR_PRS_MERGED="$n"

  RR_GH="ok"
  return 0
}

# One counted search. Prints an integer, or returns non-zero (an errored probe
# must be distinguishable from a genuine zero -- that distinction IS the point
# of the whole file).
rr_gh_count() {
  local kind="$1" slug="$2" state="$3" search="$4" out
  out="$(timeout "$RR_GH_TIMEOUT" "$RR_GH_BIN" "$kind" list -R "$slug" \
          --state "$state" --search "$search" --limit 200 --json number 2>/dev/null)" || {
    rr_log "WARNING: gh $kind list failed for $slug ($search)"
    return 1
  }
  # --json number gives [] or [{"number":N},...]. Counting the key is enough
  # and needs no jq.
  case "$out" in
    '[]') printf '0'; return 0 ;;
    '['*) printf '%s' "$out" | grep -o '"number"' | wc -l | tr -d ' ' ; return 0 ;;
    *) rr_log "WARNING: unparseable gh output for $kind/$slug"; return 1 ;;
  esac
}

# --- THE VERDICT, COMPUTED -------------------------------------------------
# Sets: RR_VERDICT (WORKED|WORKED-CUTOFF|IDLE|FAILED) RR_REASONS (newline-separated)
#
# Reads only RR_* values set by the probes above and the wrapper's own rc.
# There is deliberately no parameter through which prose could reach this.
run_record_compute_verdict() {
  local rc="${1:-0}"
  RR_VERDICT=""; RR_REASONS=""
  local failed=0

  if [ "$rc" != "0" ]; then
    rr_add_reason "the run itself exited rc=$rc"; failed=1
  fi
  if [ "${RR_PUSHED:-null}" = "false" ]; then
    rr_add_reason "commits were made and NOT pushed -- work that reached no consumer"; failed=1
  fi

  if [ "${RR_PUSHED:-null}" = "true" ] && [ "${RR_COMMITS_ADDED:-0}" != "0" ]; then
    rr_add_reason "pushed ${RR_COMMITS_ADDED} commit(s)"; RR_VERDICT="WORKED"
  fi
  if [ -n "${RR_PRS_MERGED:-}" ] && [ "${RR_PRS_MERGED}" -gt 0 ] 2>/dev/null; then
    rr_add_reason "merged ${RR_PRS_MERGED} PR(s)"; RR_VERDICT="WORKED"
  fi
  # NET closed, not closed. Caught by tests/run-record-witness.sh case 4 while
  # this was being written: counting gross closures lets a run open three
  # issues, close those same three, and score WORKED -- the exact
  # describing-is-free loop this file exists to break, reconstituted inside the
  # thing meant to detect it. The backlog has to be SMALLER than it was.
  if [ -n "${RR_ISSUES_CLOSED:-}" ] && [ -n "${RR_ISSUES_OPENED:-}" ] \
     && [ "$(( RR_ISSUES_CLOSED - RR_ISSUES_OPENED ))" -gt 0 ] 2>/dev/null; then
    rr_add_reason "closed $(( RR_ISSUES_CLOSED - RR_ISSUES_OPENED )) more issue(s) than it opened (${RR_ISSUES_CLOSED} closed, ${RR_ISSUES_OPENED} opened)"
    RR_VERDICT="WORKED"
  fi

  if [ -z "$RR_VERDICT" ]; then
    # Nothing observable AND something went wrong -> FAILED, as before.
    if [ "$failed" = "1" ]; then
      RR_VERDICT="FAILED"
    else
      RR_VERDICT="IDLE"
      rr_add_reason "nothing observable changed: no pushed commit, no merged PR, no closed issue"
    fi
  elif [ "$failed" = "1" ]; then
    # Shipped something, then failed. Not clean, but not nothing.
    RR_VERDICT="WORKED-CUTOFF"
  fi
  return 0
}

# --- APPEND ----------------------------------------------------------------
# Args: <ledger path> <json line>
# The ONLY writer. Append-only: no consumer ever rewrites a line, so a record
# is evidence rather than a status field.
run_record_append() {
  local path="$1" line="$2" dir
  [ -n "$path" ] || { rr_log "FATAL: no ledger path"; return 1; }

  # THE REFUSAL. The engine writing into the checkout it manages is what froze
  # vim-arcade's deploys for 18 hours on 2026-08-07 (BLOCKERS.md consumed in
  # its own tree, tripping the pull gate at bin/usage-paced-runner.sh). Refuse
  # rather than trust that the caller passed a sane path.
  if git -C "$(dirname "$path")" rev-parse --show-toplevel >/dev/null 2>&1; then
    rr_log "FATAL: refusing to write the run ledger inside a git work tree ($path). The engine must never dirty the checkout it manages."
    return 1
  fi

  dir="$(dirname "$path")"
  mkdir -p "$dir" || { rr_log "FATAL: cannot create $dir"; return 1; }
  printf '%s\n' "$line" >> "$path" || { rr_log "FATAL: cannot append to $path"; return 1; }
  return 0
}

# --- EMIT ------------------------------------------------------------------
# Renders one JSONL line from RR_* plus the identity args. Prose arrives here
# ONLY as claimed_verdict/claimed_reason, both escaped, both namespaced, and
# neither read by anything above.
run_record_line() {
  local run_id="$1" job="$2" participant="$3" tier="$4" slug="$5" branch="$6" \
        started="$7" ended="$8" elapsed="$9" rc="${10}" status="${11}" \
        before="${12}" after="${13}" remote="${14}" \
        claimed_v="${15:-}" claimed_r="${16:-}"

  printf '{'
  printf '"schema":%s,'          "$(rr_jstr "$RUN_RECORD_SCHEMA")"
  printf '"run_id":%s,'          "$(rr_jstr "$run_id")"
  printf '"job":%s,'             "$(rr_jstr "$job")"
  printf '"participant":%s,'     "$(rr_jstr "$participant")"
  printf '"tier":%s,'            "$(rr_jstr "$tier")"
  printf '"host":%s,'            "$(rr_jstr "$(hostname 2>/dev/null)")"
  printf '"account":%s,'         "$(rr_jstr "$(id -un 2>/dev/null)")"
  printf '"repo":%s,'            "$(rr_jstr "$slug")"
  printf '"branch":%s,'          "$(rr_jstr "$branch")"
  printf '"started_at":%s,'      "$(rr_jstr "$started")"
  printf '"ended_at":%s,'        "$(rr_jstr "$ended")"
  printf '"elapsed_s":%s,'       "$(rr_jnum "$elapsed")"
  printf '"rc":%s,'              "$(rr_jnum "$rc")"
  printf '"status":%s,'          "$(rr_jstr "$status")"
  printf '"before_sha":%s,'      "$(rr_jstr "$before")"
  printf '"after_sha":%s,'       "$(rr_jstr "$after")"
  printf '"remote_sha":%s,'      "$(rr_jstr "$remote")"
  printf '"commits_added":%s,'   "$(rr_jnum "${RR_COMMITS_ADDED:-}")"
  printf '"pushed":%s,'          "${RR_PUSHED:-null}"
  printf '"files_changed":%s,'   "$(rr_jnum "${RR_FILES_CHANGED:-}")"
  printf '"insertions":%s,'      "$(rr_jnum "${RR_INSERTIONS:-}")"
  printf '"deletions":%s,'       "$(rr_jnum "${RR_DELETIONS:-}")"
  printf '"issues_opened":%s,'   "$(rr_jnum "${RR_ISSUES_OPENED:-}")"
  printf '"issues_closed":%s,'   "$(rr_jnum "${RR_ISSUES_CLOSED:-}")"
  printf '"prs_opened":%s,'      "$(rr_jnum "${RR_PRS_OPENED:-}")"
  printf '"prs_merged":%s,'      "$(rr_jnum "${RR_PRS_MERGED:-}")"
  printf '"gh":%s,'              "$(rr_jstr "${RR_GH:-unavailable}")"
  printf '"gh_scope":%s,'        "$(rr_jstr 'opened=author:@me; closed=window, any actor')"
  printf '"verdict_computed":%s,' "$(rr_jstr "${RR_VERDICT:-}")"
  printf '"verdict_reasons":['
  local first=1 r
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    printf '%s' "$(rr_jstr "$r")"
  done <<< "${RR_REASONS:-}"
  printf '],'
  # PROSE LIVES HERE AND ONLY HERE. Namespaced "claimed_" so no consumer can
  # mistake it for an observation, and written last so a reader hits the
  # computed fields first.
  printf '"claimed_verdict":%s,' "$(rr_jstr "${claimed_v:-none}")"
  printf '"claimed_reason":%s'   "$(rr_jstr "${claimed_r:0:500}")"
  printf '}'
}

# --- THE CLOSEOUT, wired -----------------------------------------------------
# Called by lib/sweep-loop-common.sh once, after `claude -p` has exited and
# after AFTER_SHA/REMOTE_SHA have been read. Reads engine globals; writes the
# ledger; echoes a human-readable summary into the run log.
#
# Deliberately returns 1 when the computed verdict is FAILED, so the caller can
# fold it into RUN_RC -- a computed FAILED that does not change the run's exit
# status is another self-report.
run_record_closeout() {
  local ledger="${RUN_LEDGER_FILE:-${STATE_ROOT:-$HOME/.local/share}/scheduler-runs/${PROJECT_KEY}.jsonl}"
  local slug started ended claimed_v claimed_r vfile

  slug="$(run_record_repo_slug || true)"
  started="$(date -Is -d "@$START_TS" 2>/dev/null || date -Is)"
  ended="$(date -Is)"

  run_record_probe_git "$BEFORE_SHA" "$AFTER_SHA" "${REMOTE_SHA:-}" || true
  run_record_probe_gh "$slug" "$started" || true
  run_record_compute_verdict "${RUN_RC:-0}"

  # The agent's own words, if it left any. Read AFTER everything above is
  # already computed, so there is no ordering by which it could influence one.
  vfile="${STATE_ROOT:-$HOME/.local/share}/scheduler-verdict/${PROJECT_KEY}"
  if [ -f "$vfile" ]; then
    claimed_v="$(grep -m1 '^VERDICT=' "$vfile" | cut -d= -f2-)"
    claimed_r="$(grep -m1 '^REASON='  "$vfile" | cut -d= -f2-)"
  fi

  local line
  line="$(run_record_line \
    "${JOB_NAME}-${START_TS}" "$JOB_NAME" "$PROJECT_KEY" "${TIER:-unspecified}" \
    "$slug" "${BRANCH:-}" "$started" "$ended" "$(( $(date +%s) - START_TS ))" \
    "${RUN_RC:-0}" "${STATUS:-}${STATUS_DETAIL:-}" "$BEFORE_SHA" "$AFTER_SHA" "${REMOTE_SHA:-}" \
    "${claimed_v:-}" "${claimed_r:-}")"

  if run_record_append "$ledger" "$line"; then
    echo "run record: $ledger"
  else
    echo "WARNING: run record NOT written -- the verdict below was computed but is not durable"
  fi

  echo "COMPUTED VERDICT: ${RR_VERDICT} -- $(printf '%s' "${RR_REASONS:-}" | tr '\n' ';' )"
  if [ "$RR_VERDICT" = "FAILED" ]; then
    echo "!!! COMPUTED VERDICT FAILED for $PROJECT_KEY. This is derived from git and the GitHub API after the run, not from anything the run said about itself."
    return 1
  fi
  return 0
}
