#!/usr/bin/env bash
# Shared engine for per-project bug-sweep / nightly-batch loop scripts.
#
# A per-project wrapper sets the variables below and then SOURCES this file
# (never executes it): sourcing runs the lock / expiry / heartbeat / clone /
# invoke-claude logic against them. Full wrappers: ../examples/.
# The origin story is vault:scheduler/sweep-loop-common-header-20260826.md.
#
# REQUIRED
#   JOB_NAME    short, unique, matches the wrapper's own filename. Names this
#               job's state dir (~/.local/share/$JOB_NAME) and MUST match the
#               SWEEP_JOB_NAME/BATCH_JOB_NAME field in schedule/<project>.conf
#               -- that is how sync-crontab.sh finds this job's expiry state.
#               TRAP: this script no longer edits crontab; sync-crontab.sh is
#               the only writer, so a schedule has one source.
#   PROJECT_KEY short, unique PER PROJECT, not per job. A project's Tier 1 and
#               Tier 2 wrappers have different JOB_NAMEs and the SAME
#               PROJECT_KEY -- that shared key is how they detect and avoid
#               each other. TRAP: two projects must never share one.
#   REPO_URL    git clone URL (SSH) for the dedicated clone
#   REPO_SUBDIR subdirectory to cd into before invoking claude ("." if the
#               project IS the repo root)
#   PROMPT      the full prompt text passed to `claude -p`
#
# OPTIONAL (defaults in parentheses)
#   TIER               ("unspecified") free-form label, recorded in the
#                      registry marker for logging only -- never a decision.
#   EXPIRY_DAYS        (7)
#   MAX_TURNS          (40) bug-sweep scale; a nightly-batch wants ~200.
#   MODEL              (unset -> no --model flag, so CLI default). Pair with
#                      PRECHECK_CMD: the precheck cuts HOW OFTEN claude runs,
#                      MODEL cuts what each run costs.
#   ALLOWED_TOOLS      ("Bash,Read,Write,Edit,Glob,Grep")
#   NODE_BIN_DIR       (/home/zach/.nvm/versions/node/v25.2.1/bin) wherever
#                      `claude` resolves from. TRAP: cron's PATH is minimal and
#                      will not find it otherwise.
#   BRANCH             ("main") branch this job resets to and pushes against
#   SECRETS_SRC_DIR    (unset) a local dir of non-git secrets, gitignored by
#                      design. Copied into the clone EVERY run, not just on
#                      first clone, so a rotated credential is picked up
#                      without editing the wrapper. Safe before `git reset
#                      --hard`, which never touches untracked files.
#   SECRETS_DEST_SUBDIR (".session-handoff")
#   PRECHECK_CMD       (unset -> always runs) a cheap command, evaluated AFTER
#                      the clone so it can inspect fresh repo state: exit 0 if
#                      there is work, non-zero to skip `claude -p` entirely.
#                      A nightly turn budget is not free on a quiet night.

set -uo pipefail

: "${JOB_NAME:?sweep-loop-common.sh: JOB_NAME must be set before sourcing}"
: "${PROJECT_KEY:?sweep-loop-common.sh: PROJECT_KEY must be set before sourcing}"
: "${REPO_URL:?sweep-loop-common.sh: REPO_URL must be set before sourcing}"
: "${REPO_SUBDIR:=.}"
: "${PROMPT:?sweep-loop-common.sh: PROMPT must be set before sourcing}"
: "${TIER:=unspecified}"
: "${EXPIRY_DAYS:=7}"
: "${MAX_TURNS:=40}"
: "${MODEL:=}"
: "${ALLOWED_TOOLS:=Bash,Read,Write,Edit,Glob,Grep}"
: "${NODE_BIN_DIR:=/home/zach/.nvm/versions/node/v25.2.1/bin}"
# Empty = resolve from origin's own default HEAD after the clone (below),
# NOT the literal string "main". Hardcoding "main" silently half-broke
# every home-assistant run for weeks: baudin's only branch is master, so
# `git checkout main` and `git reset --hard origin/main` both failed --
# unchecked -- the reset-to-origin guarantee quietly did not apply, the
# push check misread the missing ref as an SSH/auth failure, and one run
# summarized itself as "committed, pushed, and in sync" with a commit
# still sitting unpushed. A wrapper may still set BRANCH explicitly
# (aedile's dated aedile-nightly/<date>, scheduler's nightly/<date>);
# this only changes what happens when it says nothing.
: "${BRANCH:=}"
: "${SECRETS_SRC_DIR:=}"
: "${SECRETS_DEST_SUBDIR:=.session-handoff}"
: "${PRECHECK_CMD:=}"
LIB_DIR_EARLY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/salvage.sh
source "$LIB_DIR_EARLY/salvage.sh"
# shellcheck source=lib/run-record.sh
source "$LIB_DIR_EARLY/run-record.sh"
# deadman_renew only. The TRIP check below is still this file's own inline copy
# -- see the note at the expiry block for why that duplication is left standing
# in this change rather than resolved inside it.
# shellcheck source=lib/deadman-switch.sh
source "$LIB_DIR_EARLY/deadman-switch.sh"
STATE_DIR="$HOME/.local/share/${JOB_NAME}"

# --- where the work happens (2026-08-06, Zach: "this should happen today") ---
# The disposable clone at $STATE_DIR/repo is being retired. It was faking an
# isolation that the per-user service accounts already provide for real: on
# monkey each project runs as its own uid with a 0700 home, so there is
# nothing for a second writer to collide with and nothing a human is editing.
# What the clone DID provide was a licence to `git reset --hard` -- and that
# licence ate real work: ecosim's auto-stash held PARADIGM 4 (verdict
# designs), a supervisor history-loss fix and 87 lines of tests, stashed into
# a directory nobody reads and abandoned for days.
#
# The predicate is deliberately narrow, and mechanical rather than a flag
# someone has to remember to set correctly: use the account's own checkout
# only when the account IS the project -- conf's CRON_ACCOUNT, the uid we are
# actually running as, and PROJECT_KEY must all be the same string. That is
# true for ecosim/bibliothecaire/vim-arcade/chezz/crt/baudin on monkey and
# false for everything else, including any job running as `zach`, whose
# PROJECT_REPO_PATH is a HUMAN's working copy and must never be touched by an
# unattended run. Anything that does not match keeps the legacy clone.
# SELFDEV_IN_ACCOUNT=0/1 in the env overrides the auto-detection either way.
: "${SELFDEV_IN_ACCOUNT:=auto}"
if [ "$SELFDEV_IN_ACCOUNT" = "auto" ]; then
  SELFDEV_IN_ACCOUNT=0
  if [ -n "${PROJECT_REPO_PATH:-}" ] &&
     [ -n "${CRON_ACCOUNT:-}" ] &&
     [ "${CRON_ACCOUNT:-}" = "$(id -un)" ] &&
     [ "${CRON_ACCOUNT:-}" = "$PROJECT_KEY" ]; then
    SELFDEV_IN_ACCOUNT=1
  fi
fi
if [ "$SELFDEV_IN_ACCOUNT" = "1" ]; then
  REPO="$PROJECT_REPO_PATH"
else
  REPO="$STATE_DIR/repo"
fi

LOG="$STATE_DIR/sweep.log"
LOCK="$STATE_DIR/sweep.lock"
EXPIRES_AT_FILE="$STATE_DIR/expires_at"
HEARTBEAT_FILE="$STATE_DIR/last_heartbeat"
# hf7y/scheduler#31 item 2 -- see write_ceiling_breadcrumb/read_ceiling_breadcrumb
# below. Lives in STATE_DIR (survives between runs, unlike the disposable clone).
CEILING_BREADCRUMB_FILE="$STATE_DIR/ceiling_breadcrumb.txt"

# Cross-job, cross-tier registry -- one directory shared by EVERY project's
# EVERY job, not per-job like STATE_DIR above. $LOCK (above) only stops
# THIS SAME SCRIPT from double-running if one invocation runs long; it
# does nothing to stop a project's bug-sweep and nightly-batch (different
# scripts, different JOB_NAMEs) from firing at the same time and both
# doing `git reset --hard` + commit + push against the SAME repo --
# whichever pushes second silently clobbers or conflicts with the other.
# Keying this second lock by PROJECT_KEY instead of JOB_NAME is what makes
# every tier/job for one project contend for the same slot.
REGISTRY_DIR="$HOME/.local/share/scheduler-registry"
REGISTRY_LOCK="$REGISTRY_DIR/${PROJECT_KEY}.lock"
REGISTRY_MARKER="$REGISTRY_DIR/${PROJECT_KEY}.active"

export PATH="${NODE_BIN_DIR}:$PATH"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

mkdir -p "$STATE_DIR" "$REGISTRY_DIR"

# Every notification in this engine goes through here (q-756f82, closed
# 2026-07-28). `notify-send ... 2>/dev/null || true` guards a notify-send
# that FAILS; it does nothing about one that NEVER RETURNS, and those are
# different. Found live 2026-07-28 in lib/deadman-switch.sh:82 under
# svc-vaporwave: the dbus socket at $XDG_RUNTIME_DIR/bus exists but nothing
# is listening, so notify-send blocked forever and hung the run that
# sourced it. This engine exports DBUS_SESSION_BUS_ADDRESS unconditionally
# (line 177) for EVERY job, cron or not, so it points at that same socket
# on any account without a live desktop session -- the cron path is not
# immune, it just hasn't drawn the short straw yet. A wedged notify-send
# here is worse than there: this one holds $LOCK and the registry marker,
# so it blocks the project's other tier too.
#
# The notification is best-effort garnish and must never wedge the job it
# decorates -- but a dropped one is not allowed to be silent either, so
# the timeout case (rc 124) says so in the log.
notify() {
  local rc=0
  timeout 5 notify-send "$@" 2>/dev/null || rc=$?
  if [ "$rc" = "124" ]; then
    echo "$(date -Is) WARNING: notify-send timed out after 5s (dbus socket present but unanswered, or a hung notification daemon) -- notification DROPPED: $*" >> "$LOG"
  fi
  return 0
}

# claude_failure_detail() -- say WHY claude -p failed, when the cause is
# recognizable from its own output, instead of every non-zero exit reading as
# the same generic FAILED. Takes the path to a captured claude -p transcript
# (stdout+stderr combined, as the engine tees it); echoes a STATUS_DETAIL
# suffix (leading space, parenthesized) or nothing if unrecognized.
#
# Two causes named today:
#   auth     "Not logged in" etc -- has a specific human fix (refresh the CLI
#            login) and is NOT a quota/turn cutoff. Pages loudly.
#   ceiling  "Reached max turns (N)" -- the run was cut off with a turn
#            budget exhausted, not broken. hf7y/scheduler#31: this collapsed
#            into the same generic FAILED as every other cause, so a run that
#            landed two real commits and ran out of room looked identical in
#            the log to one that crashed outright. Does NOT page -- hitting a
#            turn ceiling is an expected, unremarkable outcome (see
#            bin/verdict.sh's header: absence of a verdict is NEVER "gave
#            up", it is NOT-DONE, re-dispatch, metabolism unchanged), it is
#            only unnamed today.
#
# Pure function: reads the file, writes nothing, no side effects. Same shape
# as notify() above and for the same reason -- tests/
# claude-failure-detail-witness.sh lifts this out of the engine and drives it
# directly, which it cannot do to code buried in the run body.
claude_failure_detail() {
  local out="$1"
  if grep -qiE 'not logged in|please run /login|invalid api key|oauth token.*(expired|revoked)|authentication[_ ]?error' "$out" 2>/dev/null; then
    echo " (auth: not logged in)"
  elif grep -qiE 'reached max turns' "$out" 2>/dev/null; then
    echo " (ceiling: max turns reached)"
  fi
}

# write_ceiling_breadcrumb() / read_ceiling_breadcrumb() -- hf7y/scheduler#31
# item 2, the second half of the ceiling-cutoff work (item 1, #166, only made
# the cutoff distinguishable in the log/ledger; this is the part that changes
# what the NEXT dispatch sees).
#
# A run cut off by --max-turns already gets its pushed commits back for free:
# the next dispatch clones/fetches origin, which already has them (see
# salvage_then_restore above). What it does NOT get back is CONTEXT -- the
# next dispatch receives the exact same conf brief from scratch, with no
# sense that this is a continuation of something already in progress rather
# than a fresh start. chezz's #31 case: two real commits landed, then the run
# was cut off, and the following tick had no way to know "Bump pawn spawn
# allowance" was step one of a larger change already underway.
#
# write_ceiling_breadcrumb runs at the end of a run (after push status is
# known); read_ceiling_breadcrumb runs near the top of the NEXT run, before
# the claude invocation, alongside the existing FEEDBACK_BLOCK/BLOCKERS_BLOCK
# prepending below. Same shape as those and as claude_failure_detail() above
# -- globals in/out rather than a return value, so tests/
# ceiling-breadcrumb-witness.sh can lift them out of the engine and drive
# them directly without running a real job.
#
# Does NOT change dispatch behaviour: a cutoff run is still NOT-DONE, still
# re-dispatched next tick. This only restores context for that re-dispatch.
#
# Globals in: STATUS_DETAIL, BEFORE_SHA, AFTER_SHA, CLAUDE_OUT, MAX_TURNS,
# CEILING_BREADCRUMB_FILE. No-op (and no file left behind) unless
# STATUS_DETAIL names a ceiling cutoff -- an unrelated FAILED run must not
# leave a stale breadcrumb for the next dispatch to misread as "resume this".
write_ceiling_breadcrumb() {
  case "${STATUS_DETAIL:-}" in
    *"ceiling: max turns reached"*) ;;
    *) return 0 ;;
  esac
  {
    echo "Cut off $(date -Is) by --max-turns ($MAX_TURNS)."
    if [ "$AFTER_SHA" != "$BEFORE_SHA" ]; then
      echo "Commits made this run (${BEFORE_SHA:0:12}..${AFTER_SHA:0:12}):"
      git log --oneline "$BEFORE_SHA..$AFTER_SHA"
    else
      echo "No commits made this run before the cutoff."
    fi
    echo
    echo "Tail of the transcript at cutoff:"
    tail -n 40 "$CLAUDE_OUT" 2>/dev/null
  } > "$CEILING_BREADCRUMB_FILE"
  echo "ceiling breadcrumb written -- $CEILING_BREADCRUMB_FILE (consumed by the next run's prompt)"
}

# Globals in/out: PROMPT (rewritten if a breadcrumb is found), CEILING_BREADCRUMB_FILE
# in. CONSUMES (deletes) the file unconditionally once read, same as
# BLOCKERS.md's --consume above -- a breadcrumb re-read on every future run
# would look like an infinite loop of "resume" instructions long after the
# task actually moved on.
read_ceiling_breadcrumb() {
  [ -f "$CEILING_BREADCRUMB_FILE" ] || return 0
  local block
  block="$(cat "$CEILING_BREADCRUMB_FILE")"
  rm -f "$CEILING_BREADCRUMB_FILE"
  [ -n "$block" ] || return 0
  echo "found a ceiling-cutoff breadcrumb from the previous run -- prepending to prompt, consumed"
  PROMPT="The previous run of this job was cut off by --max-turns mid-task (hf7y/scheduler#31) -- this is a CONTINUATION, not a fresh start. What it had gotten to:

$block

---

$PROMPT"
}

read_resume_hint() {
  [ -n "${SCHEDULER_RESUME_PR:-}" ] && [ -n "${SCHEDULER_RESUME_REPO:-}" ] || return 0
  echo "dispatcher found an open PR left by a no-verdict run -- prepending a resume instruction"
  PROMPT="The previous run of this job ended with no verdict, and the dispatcher found open pull request #$SCHEDULER_RESUME_PR on $SCHEDULER_RESUME_REPO still carrying a failing check. Before picking anything new, go finish or fix that PR first.

---

$PROMPT"
  unset SCHEDULER_RESUME_PR SCHEDULER_RESUME_REPO
}

# THE VERDICT CLOSEOUT -- appended to every batch brief, BY THE ENGINE, because the contract is the RUNNER's and the runner is shared. Until 2026-08-06 the only thing asking for a verdict was one paragraph in ONE conf, so bibliothecaire wrote verdicts and nobody else ever had -- and usage-paced-runner logged NO-VERDICT every tick and re-dispatched forever, the exact "retries forever, no braking" failure verdict.sh exists to end. Here, the next account armed is correct BY DEFAULT, and it works whether a conf spells its brief inline or as a bare slash command resolved in the project's own repo.
# TRAP: BATCH TIER ONLY. The verdict file is keyed on the ROTATION PARTICIPANT name and the runner consumes it at dispatch, so a sweep-tier run writing the same key between paced ticks hands the batch run someone else's verdict.
# A conf that already names verdict.sh keeps its own wording: bibliothecaire's is strictly more specific than this generic one.
own_repo_slug() {
  local slug=""
  case "$REPO_URL" in
    *github.com[:/]*)
      slug="${REPO_URL%.git}"; slug="${slug##*github.com[:/]}"
      case "$slug" in
        ?*/?*) case "${slug#*/}" in */*) slug="" ;; esac ;;
        *) slug="" ;;
      esac ;;
  esac
  [ -n "$slug" ] || return 1
  printf '%s\n' "$slug"
}

# apply_decision_defaults -- act on a decision nobody answered.
#
# WHY. Measured across hf7y 2026-08-22: 36 open `needs-human` issues. Each one
# subtracts from its repo's `actionable` count in bin/tempo.sh, so an
# unanswered question is also a BRAKE ON THE REPO THAT ASKED IT. #262 named the
# consequence exactly: the only brake in the whole loop was a person's
# attention, "which is why the estate could not be left alone".
#
# So a DECISION body may say what happens if nobody answers
# (realisateur#536):
#
#     DEFAULT-AFTER 14d: <the reversible thing to do>
#
# Past the window, this comments the default on the issue, drops `needs-human`,
# and labels it `defaulted`. It does NOT do the work -- the owning account
# picks the issue up as ordinary backlog on a later tick, and Zach can reverse
# it by saying so, because the issue stays OPEN.
#
# A DECISION WITH NO DEFAULT-AFTER IS LEFT ALONE, FOREVER, ON PURPOSE. That is
# the correct outcome for an irreversible call. `gh --default-after` exits 1
# for that case and 6 when it could not read the grammar; those must not be
# confused, so only exit 0 acts.
#
# OWN REPO ONLY, and never fatal -- same rules as reconcile_own_labels above.
# Globals in: REPO_URL. tests/decision-default-witness.sh drives it directly.
apply_decision_defaults() {
  local slug now issues n num body days action age created
  command -v gh >/dev/null 2>&1 || { echo "defaults: SKIPPED -- no gh on PATH"; return 0; }
  slug="$(own_repo_slug)" || { echo "defaults: SKIPPED -- no GitHub owner/repo in REPO_URL '$REPO_URL'"; return 0; }

  issues="$(gh issue list -R "$slug" --state open --label needs-human \
              --limit 100 --json number,createdAt --jq '.[]|"\(.number) \(.createdAt)"' 2>/dev/null)" || {
    echo "defaults: BLIND -- could not list $slug's needs-human issues; none applied"; return 0; }
  [ -n "$issues" ] || return 0

  now="$(date -u +%s)"
  n=0
  while read -r num created; do
    [ -n "$num" ] || continue
    body="$(gh issue view "$num" -R "$slug" --json body --jq .body 2>/dev/null)" || continue
    # exit 0 ONLY. 1 = blocks forever by design; 6 = could not read.
    read -r days action <<<"$(printf '%s' "$body" | gh --default-after - 2>/dev/null | tr '\t' ' ')" || continue
    case "$days" in ''|*[!0-9]*) continue ;; esac
    created="$(date -u -d "$created" +%s 2>/dev/null)" || continue
    age=$(( (now - created) / 86400 ))
    [ "$age" -ge "$days" ] || continue
    gh issue comment "$num" -R "$slug" --body "No answer in ${days}d, so this proceeds on the default it declared:

> $action

**Reversible, and the issue stays open.** Say the word and it goes back. If the
default was wrong, that is worth knowing -- the window is a guess, not a policy.

Applied by the dispatch that reads this tracker (realisateur#536), because an
unanswered decision also brakes this repo: \`needs-human\` is subtracted from
\`actionable\` before bin/tempo.sh divides." >/dev/null 2>&1 || continue
    # TWO CALLS, NOT ONE. `gh issue edit --remove-label X --add-label Y` is a
    # single request: if Y does not exist in that repo, GitHub rejects the
    # whole thing and X SURVIVES -- so the brake this exists to release would
    # stay on, silently, on exactly the repos that never got the label
    # provisioned. Dropping needs-human is the load-bearing half; do it first
    # and alone. (`defaulted` is declared in realisateur's bin/lib/labels.tsv
    # and provisioned by `etiquette --apply`, which reconcile_own_labels runs
    # immediately above -- but a repo can still be one tick behind.)
    gh issue edit "$num" -R "$slug" --remove-label needs-human >/dev/null 2>&1 || true
    gh issue edit "$num" -R "$slug" --add-label defaulted      >/dev/null 2>&1 || true
    echo "  defaults: #$num proceeded on its ${days}d default after ${age}d"
    n=$((n + 1))
  done <<<"$issues"
  [ "$n" -eq 0 ] || echo "defaults: $n decision(s) proceeded on their declared default"
  return 0
}

reconcile_own_labels() {
  local slug out rc
  if ! command -v etiquette >/dev/null 2>&1; then
    echo "labels: SKIPPED -- \`etiquette\` is not on PATH, so this project's labels were NOT reconciled. It ships in realisateur's verb build."
    return 0
  fi
  slug="$(own_repo_slug)" || {
    echo "labels: SKIPPED -- REPO_URL '$REPO_URL' names no GitHub owner/repo (a local or bare remote has no tracker to reconcile)"
    return 0
  }
  out="$(etiquette "$slug" --apply 2>&1)"; rc=$?
  # rc 1 is ORDINARY: it means findings, and an UNDECLARED body is a finding
  # this cannot fix. rc 6 is the one that matters -- it could not look.
  if [ "$rc" = 6 ]; then
    echo "labels: BLIND -- etiquette could not read $slug; labels NOT reconciled this run"
    return 0
  fi
  printf '%s\n' "$out" | grep -E 'label\(s\) reconciled|^ +[-+]label' || true
  return 0
}

append_verdict_closeout() {
  case "${TIER:-}" in
    nightly-batch|batch) ;;
    *) return 0 ;;
  esac
  if printf '%s' "$PROMPT" | grep -q 'verdict\.sh'; then
    echo "verdict closeout: skipped -- this conf's own prompt already names verdict.sh"
    return 0
  fi
  # Fail LOUD rather than pasting a path to a command that is not there: a
  # brief that asks for an impossible step is worse than one that asks for
  # nothing, and the runner would then report the resulting NO-VERDICT as the
  # agent's fault.
  if [ ! -x "${VERDICT_BIN:-}" ]; then
    echo "WARNING: verdict closeout NOT appended -- '${VERDICT_BIN:-<unset>}' is missing or not executable. This run will log NO-VERDICT and be re-dispatched."
    return 0
  fi
  PROMPT="$PROMPT

---

BEFORE YOU STOP, RECORD A VERDICT. This is not bookkeeping: it is the only way
the scheduler can tell a run that finished from a run that was cut off, and the
only signal that can ever stop this job being dispatched again.

  $VERDICT_BIN set $PROJECT_KEY <VERDICT> \"<one line, what you actually did>\"

  CONTINUE   there is ACTIONABLE work left -- something you could pick up on
             the next run without anyone else doing anything first.
  DONE       nothing actionable right now. THIS INCLUDES a backlog whose only
             remaining items are BLOCKED WAITING ON A HUMAN, and a backlog you
             have genuinely drained. Recording CONTINUE there gets you
             re-dispatched every tick to re-read something nobody has touched,
             which spends real quota to learn nothing. Do not invent work to
             justify CONTINUE.
  IMPOSSIBLE a real dead end, with the probe that proves it -- not merely out
             of turns. This one brakes the whole ecosystem, so it requires a
             reason and the command refuses it without one.

If you ran out of room mid-task, write NOTHING: silence already classifies as
NOT-DONE, which is the correct reading of a truncated run.

DO NOT END YOUR TURN ON A PROMISE TO CHECK BACK LATER. \"I'll merge once CI
passes\" or \"waiting for X, will follow up\" with no further tool calls is
not a pause -- it is the end of this run. There is no later moment inside
THIS session: the next dispatch starts a fresh session with no memory of
what you were waiting on. If you are waiting on something external (CI, a
human, another run), check it now if the tool to check is available, and
if it genuinely is not ready yet, record BLOCKED naming what you are
waiting on (or CONTINUE if other actionable work remains) -- never end
silently on an intention to look later."
  echo "verdict closeout: appended to the brief (participant $PROJECT_KEY, via $VERDICT_BIN)"
}

exec 200>"$LOCK"
if ! flock -n 200; then
  echo "$(date -Is) already running, skipping" >> "$LOG"
  exit 0
fi

exec 201>"$REGISTRY_LOCK"
if ! flock -n 201; then
  OTHER="$(cat "$REGISTRY_MARKER" 2>/dev/null || echo 'unknown job')"
  echo "$(date -Is) project '$PROJECT_KEY' already has an active job ($OTHER) -- skipping this run to avoid a concurrent-push conflict" >> "$LOG"
  exit 0
fi
# ---- job vs. HUMAN --------------------------------------------------------
# The two flocks above are job-vs-job. This is the other half: is a person
# editing this project right now? $REGISTRY_DIR/<PROJECT_KEY>.interactive is
# written by realisateur/bin/session-marker.sh (a Claude session started under
# this project's repo) and by bin/scheduler's front door (you opened one of
# this project's .md files through `scheduler -q/-f/-r`). Same directory as
# .active on purpose -- one place answers "is anything writing to this project
# right now."
#
# LIVENESS IS A PID PROBE, never the file's existence. Neither writer can
# guarantee a clean release (SessionEnd is not guaranteed on crash; an editor
# can be SIGKILLed), so trusting the file alone would wedge this project's
# batch permanently and SILENTLY -- introducing a silent-failure path in order
# to fix a race, which is the trade this repo exists to refuse.
#
# STARVATION CAP, non-negotiable: "defer whenever a human is present" means a
# long session starves this project's batch forever. After
# INTERACTIVE_DEFER_MAX consecutive deferrals, proceed anyway and say so
# LOUDLY. Warn-then-continue is a real failure pattern; silent indefinite
# deferral is a worse one. The cap is the lesser evil and is visible either
# way. Set INTERACTIVE_DEFER_MAX per job via RUNNER_ENV or the project's own
# schedule/<key>.conf; 3 consecutive misses is roughly "you have been editing
# across three of this project's turns."
INTERACTIVE_MARKER="$REGISTRY_DIR/${PROJECT_KEY}.interactive"
# Records WHEN the current deferral streak began, not how many times we asked.
# (Retires interactive_deferrals, a counter of dispatch attempts -- see
# registry_should_defer's header for why attempts measured nothing.)
DEFER_STREAK_FILE="$STATE_DIR/interactive_defer_since"
[ -f "$STATE_DIR/interactive_deferrals" ] && rm -f "$STATE_DIR/interactive_deferrals"

# The probe/cap policy itself now lives in lib/registry-lock.sh so the
# scheduler's own dev cycle obeys the same rule (2026-07-27) -- it had no
# registry participation at all and used a dirty-tree heuristic instead.
# Behaviour here is unchanged; only the decision moved. This file keeps the
# LOG WORDING, because the exit-code vocabulary (4 = deferred) and the
# ===-delimited run record are this job engine's contract, not the policy's.
# shellcheck source=lib/registry-lock.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry-lock.sh"

if registry_should_defer "$PROJECT_KEY" "$DEFER_STREAK_FILE" "${PROJECT_REPO_PATH:-}"; then
  HUMAN_PID="$REGISTRY_DEFER_PID"
  HUMAN_SINCE="$REGISTRY_DEFER_SINCE"
  NOW_IS="$(date -Is)"
  # A real ===-delimited run record, same reasoning as the expiry block
  # below: a bare prose line is invisible to `scheduler status`, which
  # would then re-report the PREVIOUS run as this project's current state
  # and hide the fact that it has been standing down.
  {
    echo "=== $NOW_IS ==="
    echo "deferred -- '$PROJECT_KEY' is being worked in right now (pid $HUMAN_PID, since ${HUMAN_SINCE:-unknown}); no work attempted (no clone, no claude)."
    echo "reason: $REGISTRY_DEFER_REASON (watching ${REGISTRY_DEFER_DIR:-?}). Standing down for as long as that stays true; backstop at ${REGISTRY_DEFER_MAX_HOURS}h continuous, currently ${REGISTRY_DEFER_STREAK_MIN}m. Marker: $INTERACTIVE_MARKER"
    echo "=== skipped (repo active, ${REGISTRY_DEFER_STREAK_MIN}m into a deferral streak) $NOW_IS (0s) ==="
  } >> "$LOG"
  # Exit 4: distinct from success (0), fatal (1) and expired (3), so
  # usage-paced-runner.sh's `rc=` line tells deferred from worked without
  # parsing this log. The rotation simply comes back next tick.
  exit 4
fi

# Proceeding. registry_should_defer() returns 1 both when nobody is there and
# when the starvation cap fired -- REGISTRY_DEFER_CAPPED distinguishes them,
# and the capped case must never be quiet.
if [ "${REGISTRY_DEFER_CAPPED:-0}" = "1" ]; then
  # Only the BACKSTOP is loud. Proceeding because the repo went quiet is the
  # ordinary path and says nothing -- notifying on it is what trains a person
  # to ignore the notification that matters.
  echo "$(date -Is) WARNING: proceeding despite an ACTIVE repo on '$PROJECT_KEY' (pid $REGISTRY_DEFER_PID, since ${REGISTRY_DEFER_SINCE:-unknown}) -- $REGISTRY_DEFER_REASON. This run may write files you have open; your editor's next save reconciles via the vimrc 3-way merge." >> "$LOG"
  notify -u critical "$JOB_NAME: running while you work" "$PROJECT_KEY has deferred continuously for ${REGISTRY_DEFER_STREAK_MIN}m (backstop ${REGISTRY_DEFER_MAX_HOURS}h) and is now running anyway. Close the editor or expect a merge on save."
fi

echo "{\"job\":\"$JOB_NAME\",\"tier\":\"$TIER\",\"started_at\":\"$(date -Is)\",\"pid\":$$}" > "$REGISTRY_MARKER"
trap 'rm -f "$REGISTRY_MARKER"' EXIT

if [ -f "$LOG" ]; then
  tail -n 4000 "$LOG" > "$LOG.tmp"
  mv "$LOG.tmp" "$LOG"
fi

# Expiry (dead-man switch) is checked BEFORE the clone/secrets work, not
# after (moved 2026-07-26): an expired job used to clone the repo and copy
# secrets in first, then no-op -- burning network/disk for a run that was
# never going to do anything. The check needs nothing but the stamp file.
# DUPLICATION, NAMED RATHER THAN QUIETLY KEPT. lib/deadman-switch.sh exists to
# be THE one implementation of this switch -- its header argues the case at
# length, having been extracted in 2026-07 after a hand-pasted copy lost four
# behaviours in a day. It is also, as of 2026-08-11, SOURCED BY NOTHING: the
# copy it was written to retire is the block below, and the block below is what
# actually runs on every self-dev account. The extraction happened; the
# replacement never did.
#
# This change sources that lib for deadman_renew and leaves the trip check
# here, on purpose. Swapping the trip path too is a behaviour change to the
# engine every project is downstream of (its notify path differs, and
# .scheduler/QUESTIONS.md q-756f82 records an unexplained notify-send hang that
# is still open), and mixing it into the polarity fix would make one reviewable
# thing into two unreviewable ones. It is the PR's stated open question.
if [ ! -f "$EXPIRES_AT_FILE" ]; then
  date -d "+${EXPIRY_DAYS} days" -Is > "$EXPIRES_AT_FILE"
fi
EXPIRES_AT=$(cat "$EXPIRES_AT_FILE")
NOW_IS=$(date -Is)

if [[ "$NOW_IS" > "$EXPIRES_AT" ]]; then
  MSG="Auto-disabled: dead-man switch tripped ($EXPIRES_AT). Renew: rm $EXPIRES_AT_FILE -- next run re-stamps now+${EXPIRY_DAYS}d. Bumping EXPIRY_DAYS alone does NOT renew (the stamp is only written when the file is missing)."
  notify "$JOB_NAME" "$MSG"
  # A real ===-delimited run record, not one bare prose line (changed
  # 2026-07-26, FOCUS.md EXPIRY_DAYS finding 2: expiry used to be a clean
  # exit 0 with a log line nothing surfaced -- invisible everywhere but
  # this file). The start/completion pair is what `scheduler status`
  # slices a "last run" from, and "skipped" is a completion status it
  # already recognizes -- so an expired job now SHOWS expiry as its last
  # run instead of the view re-reporting the previous real run as current.
  {
    echo "=== $NOW_IS ==="
    echo "expired -- dead-man switch tripped; no work attempted (no clone, no claude). $MSG"
    echo "note: bin/sync-crontab.sh prunes this job's crontab line on its next --apply run; this script never touches crontab itself"
    echo "=== skipped (expired $EXPIRES_AT) $NOW_IS (0s) ==="
  } >> "$LOG"
  # Exit 3, not 0: distinct from success and from a fatal error (1), so a
  # dispatcher (usage-paced-runner.sh logs rc= per dispatch) can tell
  # "expired" from "worked" without parsing this log. Nothing keys on the
  # old exit 0 -- cron ignores exit codes and the paced runner only logs rc.
  exit 3
fi

# Dedicated clone, never the user's real working copy -- reset --hard
# below would destroy uncommitted work if pointed at a real checkout.
#
# The clone result is CHECKED (2026-07-24, dexter bring-up). It used to be
# unchecked, and with `set -uo pipefail` (no -e) a failed clone did not stop
# the run: $REPO never got created, the `cd "$REPO/$REPO_SUBDIR"` below
# silently failed too, and everything after it -- git checkout/fetch/reset
# --hard AND the `claude -p` call with Write/Edit/Bash -- ran in whatever
# directory cron happened to start in ($HOME). Found while pinning crt to
# dexter, where crt's REPO_URL (a bare repo local to mandark) genuinely is
# unreachable, making this the first host that would actually hit it.
if [ ! -d "$REPO/.git" ]; then
  if ! git clone "$REPO_URL" "$REPO" >> "$LOG" 2>&1; then
    echo "$(date -Is) FATAL clone failed: '$REPO_URL' -> '$REPO' (git output above) -- aborting before any git or claude work" >> "$LOG"
    notify -u critical "$JOB_NAME" "clone failed for $REPO_URL -- job aborted, see $LOG"
    exit 1
  fi
fi

if [ -n "$SECRETS_SRC_DIR" ]; then
  mkdir -p "$REPO/$SECRETS_DEST_SUBDIR"
  cp -f "$SECRETS_SRC_DIR"/* "$REPO/$SECRETS_DEST_SUBDIR/" 2>/dev/null || true
fi

NOW_EPOCH=$(date +%s)
LAST_HEARTBEAT_EPOCH=0
if [ -f "$HEARTBEAT_FILE" ]; then
  LAST_HEARTBEAT_EPOCH=$(cat "$HEARTBEAT_FILE")
fi
SECONDS_SINCE=$((NOW_EPOCH - LAST_HEARTBEAT_EPOCH))

if [ "$SECONDS_SINCE" -ge 86400 ]; then
  notify "$JOB_NAME" "Still running. Expires $EXPIRES_AT."
  echo "$NOW_EPOCH" > "$HEARTBEAT_FILE"
fi

{
  START_TS=$(date +%s)
  echo "=== $(date -Is) ==="
  # Belt-and-braces with the clone check above: never let a failed cd leave
  # the reset --hard / claude call running against the cron working directory.
  if ! cd "$REPO/$REPO_SUBDIR"; then
    echo "FATAL cannot cd '$REPO/$REPO_SUBDIR' -- aborting before any git or claude work"
    notify -u critical "$JOB_NAME" "cannot enter $REPO/$REPO_SUBDIR -- job aborted, see $LOG"
    exit 1
  fi
  echo "workspace: $REPO ($([ "$SELFDEV_IN_ACCOUNT" = "1" ] && echo "account checkout, salvage-then-restore" || echo "dedicated clone"))"
  # Resolve BRANCH from the remote's own default HEAD when the wrapper
  # didn't name one. Local read (the clone already recorded it), no
  # network; ls-remote is the fallback, and only then the old "main"
  # guess -- now announced in the log rather than assumed.
  if [ -z "$BRANCH" ]; then
    BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
    if [ -z "$BRANCH" ]; then
      BRANCH="$(git ls-remote --symref origin HEAD 2>/dev/null | awk '$1=="ref:"{sub("refs/heads/","",$2); print $2; exit}')"
    fi
    if [ -z "$BRANCH" ]; then
      BRANCH="main"
      echo "WARNING: could not resolve origin's default branch -- falling back to '$BRANCH'"
    else
      echo "BRANCH unset by the wrapper -- resolved from origin's default HEAD: $BRANCH"
    fi
  fi
  # CHECKED, all three (2026-07-25). These were unchecked and `set -uo
  # pipefail` has no -e, so a bad branch name or an unreachable origin
  # let the run continue against whatever the clone happened to have
  # checked out -- i.e. the disposable-clone-reset-to-origin guarantee
  # every other part of this design assumes was silently void. Aborting
  # is correct: the next scheduled cycle retries, whereas a run on an
  # unknown base can commit and push real work onto the wrong thing.
  # Fetch FIRST, before touching the working tree: everything below decides
  # what to preserve by comparing against origin/$BRANCH, and comparing
  # against a stale remote ref would mislabel already-pushed commits as
  # unpushed work (or, worse, the reverse).
  if ! git fetch origin --quiet; then
    echo "FATAL git fetch origin failed -- aborting rather than running against a stale base"
    notify -u critical "$JOB_NAME" "fetch failed -- job aborted, see $LOG"
    exit 1
  fi

  # --- salvage, then restore (2026-08-06; replaces stash + reset --hard) ---
  # See lib/salvage.sh for why local preservation was the bug. CHECKED, and
  # the check is the point: `set -uo pipefail` has no -e, so an unchecked
  # failure here would let the run continue on an unknown base and push real
  # work onto the wrong thing. A non-zero return means NOTHING was discarded.
  # A salvage branch gets PUSHED. The secrets the engine copies into
  # $SECRETS_DEST_SUBDIR now survive between runs (the workspace is no longer
  # thrown away), so without this they would look like uncommitted work and
  # be published. Excluded from detection as well as from the commit.
  SALVAGE_EXCLUDE="${SECRETS_DEST_SUBDIR:-}"
  if ! salvage_then_restore "$BRANCH" "$JOB_NAME"; then
    echo "FATAL $SALVAGE_ERROR -- aborting before any claude work"
    notify -u critical "$JOB_NAME" "$SALVAGE_ERROR -- run aborted, see $LOG"
    exit 1
  fi
  if [ -n "$SALVAGE_REF" ]; then
    notify -u critical "$JOB_NAME" "previous run left work behind -- pushed to origin/$SALVAGE_REF for review${SALVAGE_ISSUE_URL:+ ($SALVAGE_ISSUE_URL)}"
  fi
  BEFORE_SHA=$(git rev-parse HEAD)
  echo "start commit: $BEFORE_SHA"

  # Release the brake the human already released, before this run reads its
  # own backlog. See reconcile_own_labels() above for why a stale label
  # lengthens this project's dispatch interval.
  reconcile_own_labels
  apply_decision_defaults

  LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Verdict closeout FIRST, while $PROMPT is still exactly the conf's own
  # brief and nothing else. Caught by the first real dispatch, 2026-08-06:
  # run this after the feedback blocks below and its "does this conf already
  # ask for a verdict?" test reads THEM instead. vim-arcade's BLOCKERS.md
  # section happens to contain the word verdict.sh, so the engine logged
  # "skipped -- this conf's own prompt already names verdict.sh" and appended
  # nothing, on the exact participant this was written to fix. A guard whose
  # input is the composed prompt is answering a different question than the
  # one it was asked. Ordering after this: feedback, then the conf's brief,
  # then the closeout -- which is the right reading order anyway.
  VERDICT_BIN="$(cd "$LIB_DIR/.." && pwd)/bin/verdict.sh"
  append_verdict_closeout

  # Pick up any %%TAG inline comments the human left in the previous
  # report (see docs/feedback-tags.md) and put them first in this run's
  # prompt. LATEST.md gets overwritten by this same run below, so a tag
  # naturally clears itself once acted on -- no separate "mark as read".
  FEEDBACK_FILE="$HOME/reports/$PROJECT_KEY/LATEST.md"
  if [ -f "$FEEDBACK_FILE" ]; then
    FEEDBACK_BLOCK="$("$LIB_DIR/../bin/collect-feedback.sh" "$FEEDBACK_FILE" 2>/dev/null || true)"
    if [ -n "$FEEDBACK_BLOCK" ]; then
      echo "found inline feedback tags in $FEEDBACK_FILE -- prepending to prompt"
      PROMPT="Human feedback on the previous report, left inline in $FEEDBACK_FILE -- act on this FIRST, before anything else:

$FEEDBACK_BLOCK

---

$PROMPT"
    fi
  fi

  # The cross-project BLOCKERS.md channel that used to be prepended here is
  # RETIRED: #66 (2026-08-07) moved human-owned action items to GitHub
  # issues, and hf7y/realisateur#293 deleted the file. `collect-feedback.sh
  # --consume` retires with it (#193). The per-report %%TAG channel above is
  # unaffected -- it reads ~/reports/<proj>/LATEST.md, which is not retired.

  # Resume breadcrumb from a previous ceiling cutoff, if the last run left
  # one -- see write_ceiling_breadcrumb/read_ceiling_breadcrumb above.
  # Deliberately AFTER the feedback prepending above (reading order:
  # human feedback first, then "you're continuing a cut-off task", then the
  # conf's own brief) and unconditional on TIER, unlike append_verdict_closeout
  # -- a bug-sweep tier can hit --max-turns exactly the same way batch does.
  read_ceiling_breadcrumb

  read_resume_hint

  # claude's own output is tee'd to a per-run capture file (as well as
  # flowing into $LOG via the enclosing block redirect) so that a FAILED
  # run can be diagnosed against exactly THIS run's output -- $LOG
  # accumulates across runs, so grepping it would match stale text from
  # an earlier failure. pipefail is set above, so the pipeline's status
  # is still claude's own exit code.
  CLAUDE_OUT="$STATE_DIR/claude-last-run.out"
  STATUS_DETAIL=""
  if [ -n "$PRECHECK_CMD" ] && [ -z "${FEEDBACK_BLOCK:-}" ] && ! eval "$PRECHECK_CMD"; then
    echo "precheck said nothing to do -- skipping claude invocation this run"
    STATUS="skipped (precheck)"
  elif claude -p "$PROMPT" --allowedTools "$ALLOWED_TOOLS" --max-turns "$MAX_TURNS" ${MODEL:+--model "$MODEL"} 2>&1 | tee "$CLAUDE_OUT"; then
    STATUS="done"
  else
    STATUS="FAILED"
    # STATUS itself stays the exact string "FAILED" -- the push-reason and
    # exit-code blocks below compare it with = -- the detail rides in
    # STATUS_DETAIL and is appended to the final === line (and, since
    # hf7y/scheduler#31, into the durable run record's status field too --
    # see the run_record_line call below).
    STATUS_DETAIL="$(claude_failure_detail "$CLAUDE_OUT")"
    case "$STATUS_DETAIL" in
      " (auth: not logged in)")
        echo "CRITICAL: claude authentication failure -- this account's CLI credentials have lapsed (\"Not logged in\"), NOT a quota/turn cutoff. Fix: run any interactive claude session as OS user $(id -un) to refresh the login, then this job recovers on its own next scheduled run."
        notify -u critical "$JOB_NAME: claude NOT LOGGED IN" "CLI credentials lapsed for OS user $(id -un) -- run any interactive claude session to refresh. See $LOG"
        ;;
      " (ceiling: max turns reached)")
        echo "claude hit --max-turns ($MAX_TURNS) before finishing -- cut off, not broken. Any commits made before the cutoff are still evaluated below (pushed/not-pushed); this is NOT-DONE per bin/verdict.sh, re-dispatched next tick with metabolism unchanged. hf7y/scheduler#31."
        ;;
    esac
  fi

  # Objective, tool-verified facts about what actually happened -- not
  # relying solely on the agent's own summary prose being accurate or
  # consistently formatted (this check originated in chezz's own script,
  # independently, before this library existed). Compares local HEAD
  # against the *remote's* HEAD (not just "did local HEAD move"), so a
  # commit made locally but never actually pushed (e.g. an SSH/auth
  # failure mid-run) shows up as a distinct WARNING instead of silently
  # reading as "pushed".
  AFTER_SHA=$(git rev-parse HEAD)
  # COMPARE AGAINST THE BRANCH WE ARE ACTUALLY ON (2026-08-19), not $BRANCH.
  # $BRANCH is the job's configured branch -- effectively always "main". But
  # main is PROTECTED on every hf7y repo, so the mandated workflow is branch,
  # push, open a PR, and a correct run therefore ENDS on a feature branch.
  # Comparing its HEAD to origin/main could only ever say "not pushed": wtul
  # and bibliothecaire both sat on clean, fully-pushed feature branches on
  # 2026-08-19 and both were recorded FAILED, with this file's own diagnostic
  # printing "a plain push would succeed right now (dry-run OK)" underneath.
  HEAD_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$BRANCH")"
  [ "$HEAD_BRANCH" = "HEAD" ] && HEAD_BRANCH="$BRANCH"   # detached: fall back
  REMOTE_SHA=$(git ls-remote origin -h "refs/heads/$HEAD_BRANCH" | cut -f1)
  ELAPSED=$(( $(date +%s) - START_TS ))

  if [ "$AFTER_SHA" = "$BEFORE_SHA" ]; then
    echo "pushed: no -- no new commits this run"
  elif [ "$AFTER_SHA" = "$REMOTE_SHA" ]; then
    echo "pushed: yes -- $BEFORE_SHA -> $AFTER_SHA"
    git log --oneline "$BEFORE_SHA..$AFTER_SHA"
  else
    # Nonzero, not just a log line (2026-07-25). This branch is the exact
    # state home-assistant sat in for weeks while `usage-paced-runner.sh`
    # recorded `rc=0` and the run's own summary claimed it had pushed. The
    # runner logs whatever rc it gets and neither retries nor escalates, so
    # returning 1 here costs nothing and is the difference between a
    # failure that is visible in run.log and one that isn't.
    RUN_RC=1
    echo "WARNING: local commit made but NOT pushed to origin/$HEAD_BRANCH (local=$AFTER_SHA remote=$REMOTE_SHA)"
    # WHY, not just THAT -- distinguish the recurring causes instead of
    # leaving every unpushed commit looking like the same generic no-op
    # (this is the "stale/incomplete-push visibility" stability-milestone
    # item). All read-only: --dry-run never mutates the remote, so it's
    # safe to run here even though the same `claude -p` invocation above
    # may have already attempted and failed its own push.
    if [ "$STATUS" = "FAILED" ] && [ -n "${STATUS_DETAIL:-}" ]; then
      echo "push reason: claude -p failed with a recognized cause -- ${STATUS_DETAIL# } (see the CRITICAL line above), not a push failure per se"
    elif [ "$STATUS" = "FAILED" ]; then
      echo "push reason: claude -p itself exited non-zero (see above) -- most likely cut off (turn/spend limit) before it reached a push step, not a push failure per se"
    elif [ -z "$REMOTE_SHA" ]; then
      echo "push reason: could not read origin/$HEAD_BRANCH at all (git ls-remote returned nothing) -- looks like an SSH/auth/network failure reaching origin, not a push rejection"
    elif git merge-base --is-ancestor "$REMOTE_SHA" "$AFTER_SHA" 2>/dev/null; then
      DRY_RUN_OUT="$(git push --dry-run origin "HEAD:$HEAD_BRANCH" 2>&1)"
      if [ $? -eq 0 ]; then
        echo "push reason: a plain push would succeed right now (dry-run OK) -- claude's own run likely never attempted git push at all this cycle, not a credential/conflict failure"
      else
        echo "push reason: dry-run push failed -- $(echo "$DRY_RUN_OUT" | grep -m1 -v '^$')"
      fi
    else
      echo "push reason: origin/$HEAD_BRANCH has commit(s) local doesn't (diverged) -- would need a merge/rebase before push, not a credential issue"
    fi
  fi

  # Resume breadcrumb for the NEXT run, if this one was cut off by
  # --max-turns -- see write_ceiling_breadcrumb above. No-op for every other
  # STATUS/STATUS_DETAIL. Placed after push status is known (the breadcrumb
  # names the commit range).
  write_ceiling_breadcrumb

  if [ "$STATUS" = "FAILED" ]; then
    RUN_RC=1
    notify -u critical "$JOB_NAME FAILED" "See log: $LOG"
  fi

  # --- THE COMPUTED VERDICT (lib/run-record.sh) -----------------------------
  # Everything above this line that describes the run's outcome is either `rc`
  # or the agent's own prose. bin/verdict.sh asks the agent; its answer is
  # consumed at the NEXT dispatch, so nothing durable ever recorded what a run
  # actually did. A run that fixed something and a run that filed three issues
  # left identical records, and filing is cheaper -- see hf7y/scheduler#54 and
  # the 2026-08-06 blowout (42 issues, five repos, one needed `git merge
  # --ff-only`).
  #
  # So derive it. run_record_closeout re-reads git and the GitHub API AFTER
  # `claude -p` has exited and appends one JSONL line per run to
  # $STATE_ROOT/scheduler-runs/<participant>.jsonl -- outside this checkout, on
  # purpose (that lib's header has the 18-hour vim-arcade freeze this avoids).
  # The agent's prose rides along in claimed_verdict/claimed_reason and
  # populates nothing.
  #
  # cd first: nothing above is guaranteed to leave us in the work tree the
  # shas were taken from.
  cd "$REPO/$REPO_SUBDIR" || echo "WARNING: cannot re-enter $REPO/$REPO_SUBDIR for the run record"
  # A computed FAILED that does not change the run's exit status is just
  # another self-report, so it folds into RUN_RC -- which is what lands in
  # usage-paced-runner.sh's `DONE <name> rc=N`.
  if ! run_record_closeout; then
    RUN_RC=1
    notify -u critical "$JOB_NAME COMPUTED-FAILED" "verdict computed from git/gh, not self-reported. See $LOG"
  fi

  # ALIVE. Reaching this line means the engine ran end to end, which is the
  # only thing a dead-man switch can honestly measure -- see deadman_renew's
  # header for why this is not conditioned on STATUS. Before this call the
  # stamp was written once, on the first run, and never again, so every job
  # died EXPIRY_DAYS after its FIRST run no matter how well it was working.
  #
  # Deliberately NOT guarded by `if [ "$STATUS" != FAILED ]`: a job failing
  # loudly every night is not silent, and killing it a week later removes the
  # noise rather than the fault.
  if deadman_renew; then
    echo "dead-man switch renewed -- next expiry $(cat "$EXPIRES_AT_FILE" 2>/dev/null)"
  else
    echo "WARNING: dead-man switch NOT renewed (deadman_renew failed); this job will expire on its existing stamp"
  fi

  echo "=== $STATUS${STATUS_DETAIL:-} $(date -Is) (${ELAPSED}s) ==="
} >> "$LOG" 2>&1

# The job's exit status is the runner's ONLY machine-readable verdict --
# it is what lands in usage-paced-runner.sh's `DONE <name> rc=N` line.
# Before 2026-07-25 that was whatever the last command in the block
# happened to return (usually notify-send, i.e. 0), so a FAILED claude
# run and an unpushed commit both reported success. The brace group above
# is a group, not a subshell, so RUN_RC set inside it is visible here.
exit "${RUN_RC:-0}"
