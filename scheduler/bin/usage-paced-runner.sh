#!/usr/bin/env bash
# usage-paced-runner.sh -- the pacing dispatcher (replaces the fixed nightly clock).
#
# Driven by a frequent cron tick. On each tick:
#   1. Take a global flock. If a cycle is already running, exit at once -- only
#      ONE tick's worth of dispatching runs at a time, so usage climbs in
#      controlled steps, never two ticks stacking concurrently.
#   2. Ask usage-gate.sh whether there is spare weekly quota. HOLD -> log + exit
#      (cheap: a ~23-token probe). ERROR -> treat as HOLD (fail safe).
#   3. RUN -> pick the NEXT enabled participant (round-robin via a pointer file)
#      and run ONE cycle of it. Then RE-CHECK the gate (live headers reflect the
#      tokens that cycle just spent) and, if still RUN, dispatch the next one in
#      rotation -- up to PACED_MAX_PER_TICK -- before giving the tick back.
#
# Why loop instead of one-and-done: a single dispatch per cron tick caps
# throughput at (participants per hour) regardless of how much slack the gate
# reports, so a lot of quota went unused between ticks even under heavy slack.
# Looping drains whatever slack actually exists, tick by tick, while the gate
# (re-probed each iteration, not assumed) still owns the real stop condition --
# this only removes the artificial one-per-tick ceiling, not the safety logic.
#
# Participants come from a participants conf (name|enabled|command; host mode
# adds an explicit acct field -- #350), chosen PER HOST -- see "which
# participants file" below. Each command is a self-contained wrapper.
#
# Env knobs (forwarded to usage-gate.sh): USAGE_CEILING, USAGE_MIN_SLACK,
# USAGE_PROBE_MODEL. Plus:
#   PACED_CONF        (explicit participants file; otherwise host-resolved)
#   PACED_HOST        (short hostname; overrides which host-scoped conf is picked)
#   USAGE_GATE        (~/.local/bin/usage-gate.sh; beside this script in host
#                      mode, which runs as root so ~ is /root's)
#   NODE_BIN_DIR      (this account's newest ~/.nvm/versions/node/*/bin) the
#                      dir holding `claude`, when discovery guesses wrong
#   PACED_FORCE       (0)  1 = skip the gate AND tempo, run the next participant now (testing)
#   PACED_DRY_RUN     (0)  1 = log WOULD-DISPATCH instead of exec'ing, and skip
#                      the ledger row and run record. Everything upstream
#                      (ROSTER fetch, gate, tempo, account resolution, the
#                      sudo -n -u composition) still runs for real -- only the
#                      final exec is suppressed. The rehearsal for the host-mode
#                      cutover (#358): diff WOULD-DISPATCH against what the
#                      per-account runners actually dispatched.
#   PACED_MAX_PER_TICK (8) hard cap on dispatches in one tick, so one cron
#                      firing cannot monopolize the flock. Rotation continues.
#   GATE_ERROR_STREAK_THRESHOLD (5) consecutive gate rc=2 ticks before a
#                      GATE-ERROR-STREAK line is logged. Why: the gate site.
set -uo pipefail

JOB_NAME="scheduler-paced-runner"

# Resolve symlinks BEFORE taking dirname: this script is normally invoked as
# ~/.local/bin/usage-paced-runner.sh, a symlink into the repo. Plain
# `dirname "${BASH_SOURCE[0]}"` would yield ~/.local/bin and never find the
# repo's schedule/ directory.
SELF_REAL="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)"
[ -n "$SELF_REAL" ] || SELF_REAL="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF_REAL")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." 2>/dev/null && pwd)"
: "${REPO_ROOT:=}"   # empty is fine -- the checks below just fall through

# HOST MODE -- one dispatcher for the machine, instead of one per account.
# Zach, 2026-08-11: "the per-user absurdity should end and become rationalized."
#
# WHAT WAS BROKEN: the lock was $HOME-scoped, so five accounts firing at the
# same `0 */6` took five DIFFERENT lock files and serialised nothing. All five
# probed usage-gate.sh for ACCOUNT-WIDE quota, read the same pre-spend number
# and each decided RUN -- a thundering herd against one budget, with the
# in-tick re-probe blind to the other four spending concurrently.
#
# REJECTED FIX, recorded so it is not re-proposed: stagger each cron minute by
# cksum % 60. That lowers collision PROBABILITY and arbitrates nothing --
# runs reach ~1000s, so two accounts nine minutes apart still overlap.
#
# THE SPLIT: the DECISION is host-level, the EXECUTION stays per-account. This
# is a MODE, not a second dispatcher -- "who dispatches now" as one fact with
# two readers is a shape this estate has paid for repeatedly. Three changes:
#   1. lock and rotation state move to host scope
#   2. the run is wrapped in `sudo -u <account>`
#   3. rotation stops being inert by itself -- the runnability test asks
#      `[ -x "$prog" ]`, false for a peer 0700 home under that peer uid and
#      TRUE under root. scheduler#55 "wholly inert" was about who was asking.
# The gate, freeze-check, verdict handling, MAX_PER_TICK and logging are
# untouched and shared by both modes, which is the point.
[ -r "$SELF_DIR/../lib/run-ledger.sh" ] && . "$SELF_DIR/../lib/run-ledger.sh"

# How many dispatch opportunities a project is held for after recording DONE.
# 0 disables the brake entirely without editing code.
LEDGER_DONE_COOLDOWN="${LEDGER_DONE_COOLDOWN:-3}"
# Base hold after a BLOCKED verdict, multiplied by the number of consecutive
# blockages and doubled again when the reason repeats. 0 disables the backoff.
LEDGER_BLOCKED_HOLD="${LEDGER_BLOCKED_HOLD:-6}"
# MILESTONE GATE (#541, Zach 2026-09-03): dispatch only while the repo has an
# open milestone with an open issue. No milestone = paused; none open = stop.
MILESTONE_GATE="${MILESTONE_GATE:-1}"
# Unreadable list: 1 = hold ("no setpoint is not permission").
MILESTONE_GATE_BLIND_HOLDS="${MILESTONE_GATE_BLIND_HOLDS:-1}"
MILESTONE_GATE_TIMEOUT="${MILESTONE_GATE_TIMEOUT:-15}"
PACED_HOST_MODE="${PACED_HOST_MODE:-0}"
# Rehearse a cutover tick with zero blast radius: log what would be
# dispatched instead of running it, and write neither a ledger row nor a
# run record (the latter falls out for free -- it is scheduler-run, never
# exec'd here, that would have written one). hf7y/scheduler#358.
PACED_DRY_RUN="${PACED_DRY_RUN:-0}"

# acct_of_prog <path> -- which account owns the row whose command is <path>.
# A FUNCTION, not an inline sed, so tests/paced-host-mode-witness.sh can call
# it: the alternative is a regex whose only exercise is production, which is
# how hf7y/scheduler#112's unwitnessed branch got written down as a known gap
# rather than shipped as a claim. Prints nothing and returns 1 when the path
# is not under /home/<acct>/, which the caller must treat as "not mine".
acct_of_prog() {
  local a; a="$(printf '%s' "${1:-}" | sed -n 's#^/home/\([^/]\{1,\}\)/.*#\1#p')"
  [ -n "$a" ] || return 1
  printf '%s' "$a"
}

# --- the roster parser, hoisted above the side-effecting section -------------
# Pure, and defined this early because the pull gate's escalation expands
# "$PACED_HOST": unset under `set -u`, the third consecutive blocked tick aborted
# instead of filing (order pinned by tests/host-mode-preflight-witness.sh).
roster_rows() {
  local line p ah rate state acct build_root
  build_root="${VERB_HOST_BUILD_ROOT:-/usr/local/share/verb-builds}/current/scheduler"
  # `|| [ -n "$line" ]` for the conf loader's reason below: a file with no
  # trailing newline is read one row short. ROSTER is one (hf7y/scheduler#430).
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    IFS='|' read -r p ah rate state <<<"$line"
    p="$(printf '%s' "$p" | tr -d '[:space:]')"
    ah="$(printf '%s' "$ah" | tr -d '[:space:]')"
    state="$(printf '%s' "$state" | tr -d '[:space:]')"
    [ -n "$p" ] || continue
    [ "${ah##*@}" = "$PACED_HOST" ] || continue
    acct="${ah%@*}"
    # enabled is the roster's ONE state field -- the whole point of #79 is that
    # live/parked cannot disagree with a second file. No weight field: #528
    # deleted it (it was already inert here -- #55 -- and unexpressible under
    # ROSTER). acct is now its own field, not read off the path below (#350).
    case "$state" in
      live)   printf '%s|1|%s|%s\n' "$p" "$acct" "$build_root/bin/scheduler-run $p batch" ;;
      parked) printf '%s|0|%s|%s\n' "$p" "$acct" "$build_root/bin/scheduler-run $p batch" ;;
    esac
  done
}

# roster_state_for <project> <host> -- print live/parked for that project@host
# row in schedule/ROSTER; return 1 if ROSTER is absent/unreadable or names no
# row for it. A FUNCTION, not inlined, for the same reason roster_rows is:
# tests/paced-roster-authority-witness.sh calls it directly.
roster_state_for() {
  local proj="$1" host="$2" f line p ah rate state
  f="${SCHEDULER_ROSTER_FILE:-$REPO_ROOT/schedule/ROSTER}"
  [ -r "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    IFS='|' read -r p ah rate state <<<"$line"
    p="$(printf '%s' "$p" | tr -d '[:space:]')"
    ah="$(printf '%s' "$ah" | tr -d '[:space:]')"
    state="$(printf '%s' "$state" | tr -d '[:space:]')"
    [ "$p" = "$proj" ] || continue
    [ "${ah##*@}" = "$host" ] || continue
    printf '%s' "$state"
    return 0
  done < "$f"
  return 1
}

# participant_enabled <name> <host> -- is this row live?
# schedule/ROSTER decides, and it is the ONLY thing that decides (#282, #364).
# It is not handed the conf's enabled column, so it cannot consult one -- a
# value never passed in is not a second opinion. That column merely OUTRANKED
# ROSTER, which is how `crt|1|` and `secretaire|1|` kept dispatching against a
# standing `parked` (2026-08-25). A ROSTER miss is a logged refusal now.
# _paced.<host>.conf is still the rotation SOURCE; deleting it is #364.
participant_enabled() {
  local name="$1" host="$2" rstate
  if rstate="$(roster_state_for "$name" "$host")"; then
    [ "$rstate" = "live" ]
    return
  fi
  log "SKIP $name -- schedule/ROSTER names no $name@$host row, and ROSTER is the only arming surface"
  return 1
}

PACED_HOST="${PACED_HOST:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)}"

# --- --check: the host-mode arming preflight (hf7y/scheduler#364) ------------
# IT CLEARS SUDO_USER ON PURPOSE. gh_as borrows $SUDO_USER's credential when root
# has none, so `sudo PACED_HOST_MODE=1 ...` reads as the human and passes, while
# the armed row reads as root -- no /root/.config/gh, no GH_TOKEN (monkey,
# 2026-08-30) -- gets BLIND, and exits 2 every tick. Whether root gets one: #364.
if [ "${1:-}" = --check ]; then
  echo "usage-paced-runner --check -- host-mode arming preflight for $PACED_HOST"
  if [ "$PACED_HOST_MODE" != 1 ]; then
    echo "  REFUSE   PACED_HOST_MODE is not 1; this preflight describes host mode only." >&2
    exit 2
  fi
  if [ "$(id -u)" -ne 0 ]; then
    echo "  REFUSE   not root -- host mode needs root, so an armed tick would exit 2." >&2
    exit 2
  fi
  echo "  root     OK"
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    echo "  identity ignoring SUDO_USER=$SUDO_USER -- the armed cron row will not have it"
  fi
  unset SUDO_USER
  . "$SELF_DIR/../lib/dose-common.sh" 2>/dev/null || {
    echo "  REFUSE   lib/dose-common.sh is not beside this script." >&2; exit 2; }
  if ! _r="$(fetch_roster 2>&1)"; then
    echo "  roster   BLIND as root -- an armed tick would refuse and dispatch nothing:" >&2
    printf '           %s\n' "$_r" >&2
    exit 2
  fi
  _rows="$(printf '%s\n' "$_r" | roster_rows)"
  _n="$(printf '%s\n' "$_rows" | grep -c . || true)"
  if [ "$_n" -eq 0 ]; then
    echo "  roster   OK, but it names no project on $PACED_HOST -- an armed tick would refuse." >&2
    exit 2
  fi
  _live="$(printf '%s\n' "$_rows" | awk -F'|' '$2 == 1' | grep -c . || true)"
  echo "  roster   OK -- $_n row(s) for $PACED_HOST, read as root over gh"
  echo "  rotation $_live live, $(( _n - _live )) parked"
  if [ "$_live" -eq 0 ]; then
    echo "  tick 1   dispatches NOTHING -- logs 'no enabled participants ... nothing to dispatch'"
  else
    echo "  tick 1   may dispatch up to PACED_MAX_PER_TICK=${PACED_MAX_PER_TICK:-8} of $_live live row(s)"
  fi
  if [ -d "$REPO_ROOT/.git" ] && ! git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
    echo "  checkout WARN -- git cannot read $REPO_ROOT as $(id -un) (usually 'dubious ownership')."
    echo "           No parked row reaches the schedule/-clean gate, but the first LIVE one"
    echo "           would, and it would log REFUSE instead of dispatching."
  fi
  exit 0
fi
if [ "$PACED_HOST_MODE" = 1 ]; then
  # Refuse rather than silently degrade: host mode without root cannot sudo to
  # the accounts, so every dispatch would fail one at a time and the tick would
  # look like five broken projects instead of one misconfigured runner.
  if [ "$(id -u)" -ne 0 ]; then
    echo "usage-paced-runner: PACED_HOST_MODE=1 needs root (it dispatches AS each account via sudo). Refusing." >&2
    exit 2
  fi
  STATE_DIR="${PACED_HOST_STATE:-/var/lib/$JOB_NAME}"
  LOCK="${PACED_HOST_LOCK:-/run/lock/$JOB_NAME.lock}"
  mkdir -p "$STATE_DIR" "$(dirname "$LOCK")" 2>/dev/null || true
else
  STATE_DIR="$HOME/.local/share/$JOB_NAME"
  LOCK="$STATE_DIR/run.lock"
fi
LOG="$STATE_DIR/run.log"
PTR="$STATE_DIR/rotation.idx"
GATE_ERROR_STREAK_FILE="$STATE_DIR/gate-error-streak.state"
GATE_ERROR_STREAK_THRESHOLD="${GATE_ERROR_STREAK_THRESHOLD:-5}"

# --- sprint (hf7y/scheduler#292): a bounded, recorded bypass of the PACE hold.
# Per-account IS per-project ("EVERY RUNNER RUNS ONLY ITSELF", rotation filter
# below). Not under schedule/: git-clean-gated, so it would REFUSE its own tick.
SPRINT_FILE="$STATE_DIR/sprint"
SPRINT_UNTIL=""

# sprint_active -- the WALL CLOCK decides, never the file's mere presence.
sprint_active() {
  SPRINT_UNTIL=""
  local until_s until_e now_e
  [ -r "$SPRINT_FILE" ] || return 1
  until_s="$(cat "$SPRINT_FILE" 2>/dev/null)"
  [ -n "$until_s" ] || return 1
  until_e="$(date -d "$until_s" +%s 2>/dev/null)" || return 1
  [ -n "$until_e" ] || return 1
  now_e="$(date +%s)"
  [ "$now_e" -lt "$until_e" ] || return 1
  SPRINT_UNTIL="$until_s"
  return 0
}

# gate_hold_is_pace_only -- EVERY window must read `on-pace`. THE CEILING IS NOT
# SPRINTABLE (#292), nor a `rejected` window: safety, not preference.
gate_hold_is_pace_only() {
  local reasons r
  reasons="$(printf '%s\n' "$1" | grep -E '^hold_reasons=' | head -1)"
  reasons="${reasons#hold_reasons=}"
  [ -n "$reasons" ] || return 1
  local IFS=';'
  for r in $reasons; do
    [ -n "$r" ] || continue
    case "${r#*:}" in on-pace) ;; *) return 1 ;; esac
  done
  return 0
}

# Host mode runs as root (it refuses otherwise, above), so `$HOME/.local/bin`
# there is /root's and names nothing -- it reached the real gate only by
# FAILING the -x test, which is resolution by accident. Say it instead.
# Account mode keeps its two-step order byte for byte: 18 accounts use it.
if [ "$PACED_HOST_MODE" = 1 ]; then
  USAGE_GATE="${USAGE_GATE:-$SELF_DIR/usage-gate.sh}"
else
  USAGE_GATE="${USAGE_GATE:-$HOME/.local/bin/usage-gate.sh}"
  [ -x "$USAGE_GATE" ] || USAGE_GATE="$SELF_DIR/usage-gate.sh"
fi

# node_bin_dir -- THIS account's `claude` dir, discovered. A FUNCTION for the
# same reason acct_of_prog is one: tests/paced-node-bin-witness.sh calls it.
#
# It replaces a literal /home/zach/.nvm/.../v25.2.1/bin -- one person's home,
# one node version -- tried FIRST by every account on every host. Monkey, the
# only host that dispatches, does not use it: every cron-shaped PATH this repo
# builds to reach `claude` there (bin/provision-selfdev-user.sh:174,
# bin/setup-selfdev-project.sh:124, this file's own sudo line) names
# /usr/local/bin and ~/.local/bin and no node dir. The literal stays LAST, as
# mandark's fallback, so that host resolves exactly as it did.
node_bin_dir() {
  local newest
  newest="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)"
  printf '%s' "${newest:-/home/zach/.nvm/versions/node/v25.2.1/bin}"
}
NODE_BIN_DIR="${NODE_BIN_DIR:-$(node_bin_dir)}"

# Prepend the node dir only when it exists, and always APPEND ~/.local/bin
# (cron's default PATH omits it) -- appending can add a resolution but can
# never shadow one that already worked.
[ -d "$NODE_BIN_DIR" ] && export PATH="$NODE_BIN_DIR:$PATH"
export PATH="$PATH:$HOME/.local/bin"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

mkdir -p "$STATE_DIR"

exec 200>"$LOCK"
if ! flock -n 200; then
  # a cycle is already in progress -- serialize, don't stack
  exit 0
fi
[ -f "$LOG" ] && { tail -n 4000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }

log() { echo "$(date -Is) $*" >> "$LOG"; }

# THE MISS IS LOUD NOW. `[ -d ]` above says nothing when false, so a host that
# could not reach `claude` logged what one that could logged: nothing. To the
# log, not stderr -- cron mails stderr to nobody. NOT a refusal: the gate
# probes with curl and python3 (never `claude`), host mode replaces PATH for
# the dispatch anyway, and the engine re-prepends its own NODE_BIN_DIR, so
# exiting would darken hosts that work today over a PATH this process
# does not own.
command -v claude >/dev/null 2>&1 || log "NODE-BIN MISS -- no \`claude\` on PATH after resolution (NODE_BIN_DIR=$NODE_BIN_DIR, $([ -d "$NODE_BIN_DIR" ] && echo present || echo ABSENT)). Not refusing: pacing does not need it. But a dispatch that reaches \`claude -p\` from this environment produces nothing."

# >>> pull gate
# --- pull before dispatch (2026-07-24) ---------------------------------------
# This repo is shared RUNNING CODE across two hosts: mandark and dexter each
# execute it out of their own checkout on a */5 tick, so a commit pushed from
# one has no effect on the other until that checkout updates. Runs inside the
# flock and BEFORE the participants-file resolution, so a freshly pulled
# host-scoped conf takes effect the same tick it lands.
#
# TRAP: fail-loud-not-block. A pull that cannot happen cleanly is logged and
#   the tick proceeds on whatever is checked out -- one stale tick beats a
#   dispatcher that stops ticking on a conflict only a human can resolve.
#   --ff-only refuses to fabricate a merge commit unattended.
# DECISION 2026-07-28 (Zach, explicit): an UNTRACKED file does not block the
#   pull -- the gate is `--untracked-files=no`. A fast-forward cannot clobber
#   a file it does not mention, git refuses the ff if it would, and the old
#   gate let one stray scratch file freeze deployed code indefinitely behind a
#   */5 log line nobody reads.
#   REVISIT IF: a blind alley is ever traced back to not knowing about an
#   untracked file on a dispatcher host.
PULL_STATE="$STATE_DIR/pull-block.state"
PULL_ESCALATE_AFTER="${PACED_PULL_ESCALATE_AFTER:-3}"
PULL_FILE_TIMEOUT="${PACED_PULL_FILE_TIMEOUT:-60}"

# file_to_realisateur <what> <text> -- escalate OUTSIDE this checkout. Both
# escalations use it; it sits inside the pull-gate markers because
# tests/pull-escalation-witness.sh lifts that block whole.
#
# TRAP: AN ESCALATION MUST NOT LIVE INSIDE WHAT IT REPORTS ON. This resolved
# "$REPO_ROOT/bin/scheduler" FIRST, so a frozen checkout -- the one condition
# it exists to report -- was also the condition that disabled it (2026-08-30:
# scheduler@monkey on `bashified`, no bin/scheduler, logged "FILED FAILED --
# scheduler command not found" and went dark). PATH first now, the checkout
# still after it, covering #276's bare cron PATH. `gh` LAST and it is the half
# that carries this: `scheduler` is not in the verb build (only `dose` is), so
# no PATH lookup finds a host-wide one, while `gh` is a verb on every account.
# Not a new channel -- `scheduler -i` is itself a gh issue create on that repo
# (bin/scheduler:1304), minus the checkout it reads REPO_URL from. No --label:
# `idea` does not exist on hf7y/realisateur and a missing named label makes gh
# record NOTHING (bin/scheduler:854).
file_to_realisateur() {
  local what="$1" text="$2" bin title bf
  bin="$(command -v scheduler 2>/dev/null || true)"
  [ -n "$bin" ] || { [ -x "$REPO_ROOT/bin/scheduler" ] && bin="$REPO_ROOT/bin/scheduler"; }
  if [ -n "$bin" ] && timeout "$PULL_FILE_TIMEOUT" "$bin" -i realisateur "$text" >/dev/null 2>&1; then
    log "FILED $what to realisateur's inbox"
    return 0
  fi
  # Title indexes (GitHub rejects one over 256), body records. --body-file,
  # not --body: this text carries backticks and $(.
  title="$(printf '%s\n' "$text" | head -1 | cut -c1-200)"
  bf="$(mktemp)"; printf '%s\n' "$text" > "$bf"
  if timeout "$PULL_FILE_TIMEOUT" gh issue create --repo hf7y/realisateur \
       --title "$title" --body-file "$bf" >/dev/null 2>&1; then
    rm -f "$bf"
    log "FILED $what to realisateur as a GitHub issue (no usable \`scheduler\`${bin:+ -- $bin failed}; filed with \`gh\` from outside the checkout)"
    return 0
  fi
  rm -f "$bf"
  log "FILED FAILED -- could not file $what to realisateur${bin:+ via $bin} and \`gh issue create\` also failed; it exists in this log only"
  return 1
}

# Records that this tick's pull did NOT advance, and escalates once the same
# cause has repeated PULL_ESCALATE_AFTER ticks running. State is "<n> <reason>
# <filed>"; a change of reason restarts the count, so an unrelated blip cannot
# inherit an older cause's escalation.
pull_blocked() {  # $1 = short reason key   $2 = the line to log
  local reason="$1" line="$2" n=1 filed=0 prev_n=0 prev_reason="" prev_filed=0
  if [ -f "$PULL_STATE" ]; then
    read -r prev_n prev_reason prev_filed < "$PULL_STATE" 2>/dev/null || true
  fi
  case "$prev_n" in ''|*[!0-9]*) prev_n=0 ;; esac
  case "$prev_filed" in ''|*[!0-9]*) prev_filed=0 ;; esac
  if [ "$prev_reason" = "$reason" ]; then n=$((prev_n + 1)); filed="$prev_filed"; fi
  log "$line [consecutive blocked ticks: $n]"
  printf '%s %s %s\n' "$n" "$reason" "$filed" > "$PULL_STATE"
  if [ "$n" -ge "$PULL_ESCALATE_AFTER" ]; then
    log "PULL FROZEN -- $REPO_ROOT has not advanced for $n consecutive tick(s) (cause: $reason). Deployed code on this host is STALE and a merged fix cannot reach it. NOT auto-resolved: a dirty tree here can hold the only copy of a record (hf7y/scheduler#61, #75)."
    if [ "$filed" = "0" ]; then
      if file_to_realisateur "the pull freeze" "PULL FROZEN on $PACED_HOST as $(id -un): $REPO_ROOT has not pulled for $n consecutive dispatcher ticks (cause: $reason). Deployed scheduler code there is stale -- merged fixes cannot reach that account until a human clears it. Evidence: $LOG"; then
        filed=1
        printf '%s %s %s\n' "$n" "$reason" "$filed" > "$PULL_STATE"
      fi
    fi
  fi
}

# The clone is current. Silent in the normal case -- this runs every 5 minutes
# -- but a freeze that ends says so, once.
pull_advanced() {
  local prev_n=0 prev_reason=""
  if [ -f "$PULL_STATE" ]; then
    read -r prev_n prev_reason _ < "$PULL_STATE" 2>/dev/null || true
    log "PULL RECOVERED -- advancing again after $prev_n consecutive blocked tick(s) (cause was: $prev_reason)"
    rm -f "$PULL_STATE"
  fi
}

if [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT/.git" ]; then
  # #596: root here would leave root-owned refs in an account-owned checkout.
  _pull_owner="$(stat -c '%U' "$REPO_ROOT" 2>/dev/null || echo root)"
  if [ "$(id -u)" = 0 ] && [ "$_pull_owner" != root ]; then
    _pull_git=(sudo -n -u "$_pull_owner" -H git -C "$REPO_ROOT")
  else
    _pull_git=(git -C "$REPO_ROOT")
  fi
  if [ -n "$("${_pull_git[@]}" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    pull_blocked dirty-tracked "PULL skip -- $REPO_ROOT has uncommitted changes to TRACKED files"
  elif ! timeout 20 "${_pull_git[@]}" fetch --quiet origin main 2>>"$LOG"; then
    pull_blocked fetch-failed "PULL skip -- fetch failed or timed out (network/auth?)"
  elif "${_pull_git[@]}" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
    pull_advanced  # already up to date (or ahead) -- nothing to log every 5 minutes
  elif "${_pull_git[@]}" merge --ff-only origin/main --quiet 2>>"$LOG"; then
    pull_advanced
    log "PULL fast-forwarded to $("${_pull_git[@]}" rev-parse --short HEAD)"
  elif "${_pull_git[@]}" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    # TRAP: a fast-forward WAS possible by ancestry, so the merge refused for a working-tree reason -- almost always an untracked file colliding. Name it: a "diverged" message here is a lie that costs an hour.
    pull_blocked untracked-collision "PULL BLOCKED -- ff-only refused despite clean ancestry; an untracked file in $REPO_ROOT likely collides with an incoming tracked file (see merge error above). Code here is STALE until a human moves it."
  else
    pull_blocked diverged "PULL WARNING -- $REPO_ROOT diverged from origin/main, code here may be stale (needs a human/session merge, not auto-resolved)"
  fi
fi
# <<< pull gate

# >>> paced conf resolution
# --- which participants file? (host-scoped, 2026-07-24) ---------------------
# Two hosts, one tracked repo, different pinned projects, so each host MAY own
#   schedule/_paced.<short-hostname>.conf   this host, if present
#   schedule/_paced.conf                    shared/default otherwise
# A host writes only its OWN file, so two cannot fight by construction.
if [ -n "${PACED_CONF:-}" ]; then
  PACED_CONF_SRC="explicit PACED_CONF"
elif [ "$PACED_HOST_MODE" = 1 ]; then
  # Materialise the roster into the rows this file already parses, so nothing
  # downstream changes. A tempfile rather than a here-doc because every reader
  # below takes a PATH, and giving them one keeps this a source change instead
  # of a parser change.
  #
  # FAIL CLOSED. fetch_roster separates BLIND (could not look) from GAP (looked,
  # not there); either way host mode has no participants and must NOT silently
  # fall through to a checkout's conf -- falling back would resurrect the exact
  # clone dependency this branch exists to remove, and would do it invisibly,
  # on the one path where nobody is watching.
  . "$SELF_DIR/../lib/dose-common.sh" 2>/dev/null || {
    echo "usage-paced-runner: host mode needs lib/dose-common.sh beside this script and it is not there. Refusing." >&2; exit 2; }
  _roster="$(fetch_roster)" || { echo "usage-paced-runner: host mode could not read schedule/ROSTER as $(id -un) (SUDO_USER=${SUDO_USER:-unset}). Refusing to dispatch rather than fall back to a checkout. An armed cron row runs as root with SUDO_USER unset; run this script with --check as root to measure that identity before arming." >&2; exit 2; }
  PACED_CONF="$(mktemp)"; SCHEDULER_ROSTER_FILE="$(mktemp)"
  trap 'rm -f "$PACED_CONF" "$SCHEDULER_ROSTER_FILE"' EXIT
  # BOTH READS COME FROM THE FETCHED BYTES (hf7y/scheduler#412). The rotation
  # was already fetched; the per-project live/parked question was not, because
  # roster_state_for (:280) defaults to $REPO_ROOT/schedule/ROSTER -- the
  # checkout this mode exists to do without. A stale local `live` then beat a
  # fetched `parked`, so a pushed `dose --park` did not stop a host-mode
  # dispatch.
  #
  # A SECOND TEMPFILE, not PACED_CONF, and the distinction is load-bearing:
  # PACED_CONF holds roster_rows' CONF-shaped translation (name|enabled|cmd),
  # while roster_state_for parses the roster's OWN shape (project |
  # account@host | rate | state). Pointing it at PACED_CONF would make every
  # row unmatchable, so roster_state_for would return 1 for everything and the
  # whole host would go dark (before #364, worse: it fell back to the conf
  # column) -- the failure this fix exists to remove, wearing the fix's clothes.
  #
  # Exported rather than assigned because it IS the environment default
  # roster_state_for reads. Host mode is the only writer: account mode leaves
  # it unset and keeps reading REPO_ROOT, unchanged.
  printf '%s\n' "$_roster" > "$SCHEDULER_ROSTER_FILE"
  export SCHEDULER_ROSTER_FILE
  printf '%s\n' "$_roster" | roster_rows > "$PACED_CONF"
  [ -s "$PACED_CONF" ] || { echo "usage-paced-runner: schedule/ROSTER names no project on $PACED_HOST. Refusing -- an empty rotation is indistinguishable from a parse failure." >&2; exit 2; }
  PACED_CONF_SRC="schedule/ROSTER via gh ($(grep -c . "$PACED_CONF") row(s), no checkout)"
elif [ -f "$REPO_ROOT/schedule/_paced.$PACED_HOST.conf" ]; then
  PACED_CONF="$REPO_ROOT/schedule/_paced.$PACED_HOST.conf"
  PACED_CONF_SRC="host-scoped for $PACED_HOST"
elif [ -f "$REPO_ROOT/schedule/_paced.conf" ]; then
  PACED_CONF="$REPO_ROOT/schedule/_paced.conf"
  PACED_CONF_SRC="shared (no _paced.$PACED_HOST.conf)"
else
  echo "usage-paced-runner: no schedule/_paced.$PACED_HOST.conf and no schedule/_paced.conf under $REPO_ROOT. Refusing." >&2
  exit 2
fi
# <<< paced conf resolution

# --- load enabled participants -------------------------------------------------
# Format: name|enabled|command (host mode: ...|acct|command, #350; PACED_HOST_MODE
# says which). Used to carry an optional weight as a third field, repeating a
# participant N times in the rotation pool below -- deleted by #528 (host mode
# had already made it unexpressible: roster_rows emitted weight 1, #55).
names=(); cmds=(); accts=()
if [ ! -f "$PACED_CONF" ]; then
  log "FATAL no participants conf at $PACED_CONF [$PACED_CONF_SRC] host=$PACED_HOST"
  exit 1
fi
# `|| [ -n "$name" ]` because schedule/_paced.monkey.conf ends with no trailing
# newline: a bare `read` saw 17 of its 18 rows and dropped the last silently.
while IFS='|' read -r name enabled field3 field4 || [ -n "$name" ]; do
  case "$name" in ''|\#*) continue ;; esac
  name="${name// /}"
  participant_enabled "$name" "$PACED_HOST" || continue
  if [ "$PACED_HOST_MODE" = 1 ]; then
    acct="$field3"; cmd="$field4"
  else
    acct=""; cmd="$field3"
  fi
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"
  names+=("$name"); cmds+=("$cmd"); accts+=("$acct")
done < "$PACED_CONF"

# --- EVERY RUNNER RUNS ONLY ITSELF (2026-08-19) -----------------------------
# Zach's call, and a decision on record long before this edit: an account
# dispatches its own project, full stop. The rotation is filtered HERE, at
# load, instead of being walked row by row and skipped at dispatch time.
#
# What this replaces. One uid cannot execute another uid's scheduler-run, so
# on monkey each of 15 accounts walked a 15-slot roster of which exactly one
# row was ever executable under its uid. The 14 foreign rows were discovered
# one at a time, each costing a stat(2), a pointer write and a SKIP line.
# Measured 2026-08-19: ecosim 1329 ticks, 1096 of them skips of other
# accounts' work; nine-speakers 571 ticks and not one dispatch of its own.
#
# The two counters below (dispatched/examined) and the SKIP branch inside the
# loop existed ONLY to make that walk terminate. With no foreign rows left in
# the pool there is nothing to walk past, so the walk, its bound and its log
# line all go. `examined` stays as the loop's termination guarantee for the
# EXPIRED/FROZEN paths, which are decisions about rows this account owns.
own_names=(); own_cmds=(); own_accts=()
for ((_i=0; _i<${#names[@]}; _i++)); do
  _prog="${cmds[$_i]%% *}"
  if [ -x "$_prog" ] || command -v "$_prog" >/dev/null 2>&1; then
    own_names+=("${names[$_i]}"); own_cmds+=("${cmds[$_i]}"); own_accts+=("${accts[$_i]}")
  fi
done
_foreign=$(( ${#names[@]} - ${#own_names[@]} ))
names=("${own_names[@]}"); cmds=("${own_cmds[@]}"); accts=("${own_accts[@]}")

n="${#names[@]}"
if [ "$n" -eq 0 ]; then
  # Distinct from the empty-conf case below: rows exist, none is ours. That
  # is a provisioning fault (this account is in no roster row it can run),
  # not an idle tick, so say which.
  if [ "$_foreign" -gt 0 ]; then
    log "no runnable participant in $PACED_CONF [$PACED_CONF_SRC] host=$PACED_HOST -- $_foreign row(s) belong to other accounts and none to this one"
    exit 0
  fi
fi
if [ "$n" -eq 0 ]; then
  # Loud on purpose: on a freshly-registered host this is the difference
  # between "correctly idle" and "silently pointed at the wrong file".
  log "no enabled participants in $PACED_CONF [$PACED_CONF_SRC] host=$PACED_HOST -- nothing to dispatch"
  exit 0
fi

# Log the resolved rotation only when it CHANGES, not every tick (a tick fires
# every 5 min; the RUN/HOLD line is already per-tick). A host silently moving
# between participants files -- e.g. its host-scoped conf being added, renamed
# or deleted underneath it -- is exactly the drift that would otherwise be
# invisible, so make the transition itself the log event.
ROTATION_SIG="$STATE_DIR/rotation.sig"
sig="host=$PACED_HOST conf=$PACED_CONF [$PACED_CONF_SRC] slots=$n :: ${names[*]}"
if [ "$sig" != "$(cat "$ROTATION_SIG" 2>/dev/null || true)" ]; then
  log "ROTATION $sig"
  printf '%s' "$sig" > "$ROTATION_SIG"
fi

MAX_PER_TICK="${PACED_MAX_PER_TICK:-8}"

# --- validate conf is committed before dispatch (2026-07-27) ----------------
# FOCUS.md's "Consolidation roadmap" item 1 gate: "the paced runner
# dispatches from a committed/validated copy of _paced*.conf". This check
# refuses to dispatch a participant whose conf is dirty relative to HEAD
# (verified) -- see bin/schedule-clean-check.sh for the gate itself (#471,
# extracted out of the retired bin/sync-crontab.sh so this stays the one
# definition of the rule).
if [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT/.git" ]; then
  if ! "$SELF_DIR/schedule-clean-check.sh" 2>/dev/null; then
    log "REFUSE -- schedule/ is dirty relative to HEAD (run git commit in the repo to proceed)"
    exit 2
  fi
fi

# --- dispatch loop --------------------------------------------------------
# Each iteration re-checks the gate against LIVE headers, so this stops when
# the account is genuinely on-pace/at-ceiling, not after a fixed count.
# MAX_PER_TICK is a runaway backstop, not the normal stop reason.
#
# TWO counters since 2026-08-05, and the distinction is the whole fix:
#   dispatched -- rows this account actually RAN (or decided about: expired,
#                 frozen). Bounded by MAX_PER_TICK. The quota-facing number.
#   examined   -- rows this account LOOKED AT. Bounded by $n, the rotation
#                 length, so the loop terminates after one full lap no matter
#                 how many rows turn out to belong to somebody else.
# repo_slug_of <project> -- owner/name from REPO_URL. ONE copy, two callers.
repo_slug_of() {
  local conf="$REPO_ROOT/schedule/${1:?}.conf" url
  url="$(grep -E '^REPO_URL=' "$conf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
  sed -E 's#^https://github\.com/##; s#\.git$##' <<<"$url"
}

# milestone_gate_probe <slug> -> "<count>\t<next>", or NOTHING if it could
# not ask. <count> is open milestones having an open issue; <next> is the
# title named by a `NEXT: <title>` line in an open milestone's description,
# or empty if none declares one (#582 -- GitHub milestones have no successor
# field, so this is the whole chain-declaration contract: written into the
# CURRENT milestone's description, by a human or a run, same as any other
# milestoned content per #575's ruling on authorship).
#
# Empty is BLIND and must NEVER read as count=0: that would stop all
# nineteen accounts on one outage, logged as deliberate. ONE call answers
# both questions, so a chained project costs no second probe.
milestone_gate_probe() {
  timeout "${MILESTONE_GATE_TIMEOUT:-15}" gh api "repos/${1:?}/milestones?state=open" \
    --jq '. as $ms
      | ([$ms[] | select(.open_issues > 0)] | length) as $count
      | ([$ms[].description // "" | capture("(?m)^NEXT:[ \t]*(?<t>.+)$")? | .t] | .[0] // "") as $next
      | [$count, $next] | @tsv' 2>/dev/null
}

milestone_self_fed() {  # <slug> -> 1 iff every actionable issue's last body line stamps an account other than zach, 0 if any doesn't, empty if unreadable (#575)
  timeout "${MILESTONE_GATE_TIMEOUT:-15}" gh api "repos/${1:?}/issues?state=open&per_page=100" --paginate \
    --jq '[.[] | select(.milestone != null and .milestone.state == "open" and .milestone.open_issues > 0)
               | (.body // "") | split("\n") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))
               | (if length == 0 then "" else .[-1] end) as $last
               | ($last | capture("^<!--\\s*agent:\\s*(?<who>[^@]+)@")?) as $c
               | if $c == null then "human" else $c.who end]
          | if length == 0 then empty
            elif any(. == "human" or . == "zach") then "0"
            else "1" end' 2>/dev/null
}

derive_no_verdict_reason() {  # $1 = project name   $2 = dispatch start (epoch seconds)
  local name="$1" since="$2" repo pr
  repo="$(repo_slug_of "$name")"
  if [ -z "$repo" ]; then
    echo "DERIVED-SILENT: no-verdict, and $name.conf names no REPO_URL to check for a live PR"
    return
  fi
  pr="$(timeout "${PACED_DERIVE_TIMEOUT:-15}" gh pr list -R "$repo" --state open \
        --json number,updatedAt,statusCheckRollup \
        --jq '[.[] | select((.updatedAt|fromdateiso8601) >= '"$since"') | select([.statusCheckRollup[]? | (.conclusion // .state // "")] | any(. == "FAILURE"))] | .[0].number // empty' \
        2>/dev/null)" || pr=""
  if [ -n "$pr" ]; then
    echo "DERIVED-CONTINUE: open PR #$pr on $repo has a failing check -- next dispatch should finish it, not start fresh"
  else
    echo "DERIVED-SILENT: no open PR on $repo, updated since this run started, with a failing check -- nothing to point at"
  fi
}

rr_last_verdict() {  # <project> <home> [acct] -> run-record.sh's git/gh verdict for the run just finished, or empty (#347)
  local name="${1:?}" home="${2:?}" acct="${3:-}" f line
  f="$home/.local/share/scheduler-runs/$name.jsonl"
  if [ -n "$acct" ]; then
    line="$(sudo -n -u "$acct" tail -n1 "$f" 2>/dev/null)"
  else
    line="$(tail -n1 "$f" 2>/dev/null)"
  fi
  [ -n "$line" ] || { printf ''; return 0; }
  printf '%s' "$line" | grep -o '"verdict_computed":"[^"]*"' | head -1 | sed -E 's/^"verdict_computed":"(.*)"$/\1/'
}

typed_ledger_outcome() {  # <project> <outcome> <home> [acct] -> outcome, upgraded to rr_last_verdict's WORKED-CUTOFF when NOT-DONE and that applies
  local name="${1:?}" outcome="${2:-NOT-DONE}" home="${3:?}" acct="${4:-}"
  if [ "$outcome" != "NOT-DONE" ]; then printf '%s' "$outcome"; return 0; fi
  local rr; rr="$(rr_last_verdict "$name" "$home" "$acct")"
  if [ "$rr" = "WORKED-CUTOFF" ]; then printf 'WORKED-CUTOFF'; else printf '%s' "$outcome"; fi
}

resume_hint_for_project() {
  local name="${1:?}" last_outcome last_reason
  declare -F ledger_last >/dev/null 2>&1 || return 0
  last_outcome="$(ledger_last "$name" 2>/dev/null || true)"
  case "$last_outcome" in  # WORKED-CUTOFF is a typed NOT-DONE (#347); both take this path
    NOT-DONE|WORKED-CUTOFF) ;;
    *) return 0 ;;
  esac
  last_reason="$(ledger_reason "$name" "$last_outcome" 1 2>/dev/null || true)"
  if [[ "$last_reason" =~ ^DERIVED-CONTINUE:\ open\ PR\ \#([0-9]+)\ on\ ([^[:space:]]+)\  ]]; then
    printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
}
dispatched=0
examined=0
while [ "$dispatched" -lt "$MAX_PER_TICK" ] && [ "$examined" -lt "$n" ]; do
  # pick next enabled participant (round-robin) -- PEEK ONLY. The pointer is
  # not committed until this row is known to be one this account can decide
  # about, so a HOLD verdict below still leaves the rotation exactly where it
  # was, unchanged from when the gate probe stood at the top of this loop.
  last=-1; [ -f "$PTR" ] && last="$(cat "$PTR" 2>/dev/null || echo -1)"
  case "$last" in ''|*[!0-9-]*) last=-1 ;; esac
  idx=$(( (last + 1) % n ))

  name="${names[$idx]}"; cmd="${cmds[$idx]}"; row_acct="${accts[$idx]:-}"

  # The runnability TEST that used to stand here (2026-08-06, "RUNNABILITY
  # BEFORE THE PROBE") moved to load time -- see "EVERY RUNNER RUNS ONLY
  # ITSELF" above. Every row still in the pool is one this account can run,
  # so there is no foreign row left to detect, skip or log.
  #
  # `prog` STAYS. It is not test scaffolding: the dead-man switch derives the
  # job's state directory from it a few lines below, and so does the GAVE-UP
  # brake at the bottom of this loop. Deleting it along with the test left
  # job_state="$HOME/.local/share/" -- so a project that reported IMPOSSIBLE
  # would have been stamped in the wrong place and re-dispatched forever,
  # while still logging METABOLISM as though it had braked.
  prog="${cmd%% *}"

  if [ "${PACED_FORCE:-0}" = "1" ]; then
    log "PACED_FORCE=1 -- skipping usage gate"
  else
    verdict="$("$USAGE_GATE" 2>/dev/null)"; rc=$?
    summary="$(printf '%s\n' "$verdict" | grep -E '^verdict=|^# ' | tr '\n' ' ')"
    # #191: rc=2 (ERROR -- probe failed/unparseable) is deliberately treated
    # as HOLD below, same as rc=1 -- that fail-safe is not changed here. What
    # was missing is a voice: a broken probe and a busy quota logged
    # identically, so a multi-day ERROR streak was indistinguishable from
    # ordinary pacing without grepping run.log for "rc=2" by hand. rc=0 or
    # rc=1 both mean the gate itself is working, so either resets the streak.
    if [ "$rc" -eq 2 ]; then
      streak=$(( $(cat "$GATE_ERROR_STREAK_FILE" 2>/dev/null || echo 0) + 1 ))
      echo "$streak" > "$GATE_ERROR_STREAK_FILE"
      if [ $((streak % GATE_ERROR_STREAK_THRESHOLD)) -eq 0 ]; then
        log "GATE-ERROR-STREAK n=$streak -- usage gate has returned rc=2 (probe failed/unparseable) for $streak consecutive ticks; this is a broken probe, not a busy quota"
      fi
    else
      rm -f "$GATE_ERROR_STREAK_FILE"
    fi
    if [ "$rc" -ne 0 ]; then
      # rc=1 required: rc=2 is a FAILED PROBE, which says nothing about pace.
      if [ "$rc" -eq 1 ] && sprint_active && gate_hold_is_pace_only "$verdict"; then
        log "SPRINT (expires $SPRINT_UNTIL) -- pace bypassed; $summary"
      else
        log "HOLD (gate rc=$rc) $summary"
        break
      fi
    else
      log "RUN  $summary"
    fi
  fi

  # Committed HERE, once, before any branch below can `continue`. Every exit
  # path from this point is therefore bounded by the rotation length -- which
  # is what makes it safe for the not-runnable branch to stop touching
  # `dispatched`. Put this inside a branch instead and one `continue` without
  # it becomes an infinite loop that re-probes the gate forever.
  echo "$idx" > "$PTR"
  examined=$((examined + 1))

  # Dead-man-switch awareness (2026-07-26): an expired participant used to
  # consume a dispatch slot and record as a normal DISPATCH/DONE pair. The
  # state dir is derived from the wrapper name by the <job>-loop.sh convention;
  # a command not matching it has no expires_at there and dispatches as before
  # -- FAIL-OPEN. Belt-and-braces with sweep-loop-common.sh's pre-clone check:
  # this saves the slot, that one saves the clone. Counts toward MAX_PER_TICK.
  job_state="$HOME/.local/share/$(basename "$prog" | sed 's/-loop\.sh$//')"
  if [ -f "$job_state/expires_at" ]; then
    expires_at="$(cat "$job_state/expires_at" 2>/dev/null)"
    if [ -n "$expires_at" ] && [[ "$(date -Is)" > "$expires_at" ]]; then
      log "SKIP $name -- EXPIRED $expires_at (dead-man switch; renew: rm $job_state/expires_at, next run re-stamps now+EXPIRY_DAYS)"
      dispatched=$((dispatched + 1))
      continue
    fi
  fi

  # Migration abort handle (2026-07-29, M1(a)). Checked HERE, per-participant
  # at dispatch time, not once at the top of the tick: a freeze that lands
  # mid-tick must stop the remaining participants, not just the next tick.
  # freeze-check exits 1 (frozen) or 2 (unreadable = frozen); both refuse.
  #
  # CONTINUE, not BREAK: the freeze supports per-project EXEMPT lines, so a
  # refused participant must not stop the loop before an exempt one later in
  # the rotation is reached. Breaking here would silently make exemptions
  # depend on rotation order -- the orchestrator would be exempt on paper and
  # unreachable in practice. Slot is consumed, matching the SKIP paths above,
  # so a frozen rotation ends its tick rather than spinning.
  if ! "$SELF_DIR/freeze-check.sh" "$name" 2>>"$LOG"; then
    log "FROZEN -- refusing to dispatch $name (see schedule/FREEZE; release: git rm it)"
    dispatched=$((dispatched + 1))
    continue
  fi

  # DONE COOLDOWN. Checked HERE, per-participant and BEFORE the gate probe, for
  # the same reason the runnability test moved above the probe: a row we are
  # not going to dispatch must not buy a live quota probe first.
  #
  # Slot IS consumed, matching FROZEN above: having decided about this row, the
  # tick has done its job. Not consuming it would let a cooling-down project
  # spin the rotation looking for someone else to run, which is a different
  # behaviour from the one being asked for.
  if declare -F ledger_since >/dev/null 2>&1 && [ "${LEDGER_DONE_COOLDOWN:-3}" -gt 0 ]; then
    _since="$(ledger_since "$name" DONE 2>/dev/null || echo 999999)"
    if [ "${_since:-999999}" -lt "${LEDGER_DONE_COOLDOWN:-3}" ]; then
      # THE SKIP IS RECORDED. Without this row the count never advances and the
      # hold is permanent -- a stop wearing a cooldown's name. Recording it also
      # makes the brake visible in the same ledger as the dispatches it
      # replaced, so "why did this project go quiet" is one file, not a guess.
      ledger_append "$name" "${TIER:-batch}" - COOLDOWN "held: $((LEDGER_DONE_COOLDOWN - _since)) more opportunit(ies) after DONE" 2>/dev/null || true
      log "COOLDOWN $name -- DONE $_since opportunit(ies) ago; holding until ${LEDGER_DONE_COOLDOWN}. It resumes on its own; nothing is stuck."
      dispatched=$((dispatched + 1))
      unset _since
      continue
    fi
    unset _since
  fi

  # BLOCKED BACKOFF. Same shape as the DONE cooldown and for the same reason it
  # must record its skips -- but the hold LENGTH is not constant: it grows with
  # the number of consecutive blockages and doubles again when the reason has
  # not changed. Recomputed here from the ledger rather than stashed anywhere,
  # so there is exactly one place the backoff is defined and no second copy to
  # drift.
  if declare -F ledger_since >/dev/null 2>&1 && [ "${LEDGER_BLOCKED_HOLD:-6}" -gt 0 ]; then
    _bsince="$(ledger_since "$name" BLOCKED 2>/dev/null || echo 999999)"
    if [ "${_bsince:-999999}" -lt 999999 ]; then
      _brun="$(ledger_run "$name" BLOCKED BLOCKED-HOLD 2>/dev/null || echo 1)"
      [ "${_brun:-0}" -lt 1 ] && _brun=1
      _bwant=$(( ${LEDGER_BLOCKED_HOLD:-6} * _brun ))
      _r1="$(ledger_reason "$name" BLOCKED 1 2>/dev/null || true)"
      _r2="$(ledger_reason "$name" BLOCKED 2 2>/dev/null || true)"
      [ -n "$_r1" ] && [ "$_r1" = "$_r2" ] && _bwant=$(( _bwant * 2 ))
      if [ "$_bsince" -lt "$_bwant" ]; then
        ledger_append "$name" "${TIER:-batch}" - BLOCKED-HOLD "waiting: $_bsince/$_bwant after blockage #$_brun" 2>/dev/null || true
        log "BLOCKED-HOLD $name -- $_bsince/$_bwant opportunit(ies) since it reported BLOCKED${_r1:+ ($_r1)}. Backing off, not giving up."
        dispatched=$((dispatched + 1))
        unset _bsince _brun _bwant _r1 _r2
        continue
      fi
      unset _brun _bwant _r1 _r2
    fi
    unset _bsince
  fi

  # NOT A ROSTER WRITE: `state` is the human's field (#291). A finished project
  # is live and idle; a new milestone resumes it. Slot consumed, like COOLDOWN.
  if [ "${MILESTONE_GATE:-1}" -ne 0 ]; then
    _mslug="$(repo_slug_of "$name")"
    _mprobe=""
    [ -n "$_mslug" ] && _mprobe="$(milestone_gate_probe "$_mslug")"
    if [ -z "$_mprobe" ]; then
      if [ -n "$_mslug" ]; then
        _mwhy="could not read the milestone list for $_mslug"
      else
        _mwhy="schedule/$name.conf names no REPO_URL"
      fi
      if [ "${MILESTONE_GATE_BLIND_HOLDS:-1}" -ne 0 ]; then
        ledger_append "$name" "${TIER:-batch}" - MILESTONE-BLIND "$_mwhy" 2>/dev/null || true
        log "MILESTONE-BLIND $name -- $_mwhy. Holding: a predicate that could not run is not permission. MILESTONE_GATE_BLIND_HOLDS=0 to dispatch anyway."
        dispatched=$((dispatched + 1))
        unset _mslug _mprobe _mwhy
        continue
      fi
      log "MILESTONE-BLIND $name -- $_mwhy; MILESTONE_GATE_BLIND_HOLDS=0, so dispatching without the gate's answer."
    else
      _mcount="${_mprobe%%$'\t'*}"
      _mnext="${_mprobe#*$'\t'}"
      case "$_mcount" in ''|*[!0-9]*) _mcount=0 ;; esac  # a malformed probe must hold, never pass through as actionable
      if [ "$_mcount" -eq 0 ]; then
        if [ -n "$_mnext" ]; then
          ledger_append "$name" "${TIER:-batch}" - MILESTONE-CHAIN-HELD "chained to '$_mnext' on $_mslug, which has no open issue yet" 2>/dev/null || true
          log "MILESTONE-CHAIN-HELD $name -- $_mslug names '$_mnext' as its successor, but it has no open issue yet. Holding, not done: populate '$_mnext' and it resumes on its own."
        else
          ledger_append "$name" "${TIER:-batch}" - MILESTONE-HELD "no open milestone with an open issue on $_mslug" 2>/dev/null || true
          log "MILESTONE-HELD $name -- $_mslug has no open milestone with an open issue and none names a successor. Nothing to work toward; give it one and it resumes on its own. The roster row is untouched and still live."
        fi
        dispatched=$((dispatched + 1))
        unset _mslug _mprobe _mcount _mnext _mwhy
        continue
      else
        if [ "$(ledger_run "$name" MILESTONE-DONE MILESTONE-HELD 2>/dev/null || echo 0)" -gt 0 ]; then
          log "MILESTONE-DISAGREE $name -- last verdict was MILESTONE-DONE but $_mslug still has $_mcount open milestone(s) with open issues. Dispatching anyway; the predicate is the authority."
        fi
        _mfed="$(milestone_self_fed "$_mslug" 2>/dev/null)"
        if [ "$_mfed" = "1" ]; then
          ledger_append "$name" "${TIER:-batch}" - MILESTONE-SELF-FED "$_mslug's actionable milestone(s) hold only agent-filed issues, no human's" 2>/dev/null || true
          log "MILESTONE-SELF-FED $name -- $_mslug's actionable milestone(s) hold only agent-filed issues. Dispatching anyway."
        fi
        unset _mfed
      fi
    fi
    unset _mslug _mprobe _mcount _mnext _mwhy
  fi

  # TEMPO. The setpoint, hf7y/scheduler#147 (#66 §3): dispatch this project at
  # the pace its actionable backlog justifies, not at whatever pace the cron
  # line happens to ask. The crontab rate becomes a CEILING on how often we may
  # ask; bin/tempo.sh decides how many of those asks become dispatches.
  #
  # Checked HERE, alongside the other two brakes, and NOT earlier. It would be
  # cheaper before the gate probe -- tests/paced-probe-order-witness.sh is the
  # standing argument that a row we will not dispatch should not buy a live
  # probe first, and a tempo hold does buy one. That cost is accepted on
  # purpose: the rotation pointer is committed a few lines above the gate
  # block, and every `continue` before that point is an infinite loop that
  # re-probes forever (the comment on the commit says so). One probe per held
  # tick is the price of not moving the pointer commit, which is load-bearing
  # for a different reason. Slot IS consumed, matching every other
  # decided-about row.
  #
  # ITS OWN VOCABULARY, NOT THE GATE'S. "held for quota" and "held for pace"
  # are different facts with different fixes, and realisateur#46 is the standing
  # argument that folding them into one exit code is how the ecosystem lost
  # track of which one was switched off. TEMPO/TEMPO-BLIND never appear in a
  # gate line and HOLD (gate rc=) never appears here.
  #
  # NO LEDGER ROW ON A HOLD, deliberately -- see bin/tempo.sh's header. The two
  # brakes above count rows and must record their skips to elapse; tempo counts
  # minutes and would only be inflating the counts they read.
  #
  # FAIL CLOSED ON A MISSING tempo.sh, same as freeze-check.sh above: a
  # regulator that cannot be found is not a regulator that said yes. A checkout
  # new enough to run this line is new enough to carry the script.
  # There is exactly ONE standing off switch and it is TEMPO_ENABLED, read by
  # tempo.sh from schedule/_tempo.conf (or env). A second bypass here would be
  # a knob that outranks the file someone just edited -- hf7y/scheduler#119's
  # shape, and the mistake _runner.conf's RUNNER_ENV already made with
  # USAGE_CEILING. PACED_FORCE is not that: it is this script's existing
  # one-shot "run the next participant NOW" for testing, already documented at
  # the top and already skipping the quota gate. Pace is the other half of the
  # same decision, so it skips both or the flag means two things.
  if [ "${PACED_FORCE:-0}" = "1" ]; then
    log "PACED_FORCE=1 -- skipping tempo"
  # Pace is one decision with two brakes; releasing only the gate buys nothing.
  elif sprint_active; then
    log "SPRINT (expires $SPRINT_UNTIL) -- tempo bypassed"
  # STATE_DIR IS PASSED, NOT INHERITED. It is a plain assignment above, not an
  # export, and it MOVES between $HOME/.local/share and /var/lib depending on
  # host mode -- so a tempo.sh left to resolve its own default would read the
  # per-account ledger while the host-mode dispatcher writes the host one, and
  # answer confidently off a file nothing is appending to.
  elif ! _tline="$(STATE_DIR="$STATE_DIR" "$SELF_DIR/tempo.sh" "$name" 2>&1)"; then
    case "$_tline" in
      *verdict=BLIND*) log "TEMPO-BLIND $name -- ${_tline#verdict=BLIND }. Holding: no setpoint is not permission." ;;
      *verdict=HOLD*)  log "TEMPO $name -- ${_tline#verdict=HOLD }. Too soon for this backlog; it resumes on its own." ;;
      *)               log "TEMPO-BLIND $name -- tempo.sh gave no verdict (${_tline:-no output}). Holding." ;;
    esac
    dispatched=$((dispatched + 1))
    unset _tline
    continue
  else
    log "TEMPO $name -- ${_tline#verdict=RUN }"
    unset _tline
  fi

  # Consume any prior verdict BEFORE dispatching, so this run's outcome can
  # never be read off the last run's file. Same lesson as expires_at: a stale
  # stamp that reads as current is worse than no stamp.
  "$SELF_DIR/verdict.sh" clear "$name" >/dev/null 2>&1 || true

  _resume_pr="" _resume_repo=""
  if declare -F resume_hint_for_project >/dev/null 2>&1; then
    read -r _resume_pr _resume_repo <<<"$(resume_hint_for_project "$name")"
  fi
  export SCHEDULER_RESUME_PR="$_resume_pr" SCHEDULER_RESUME_REPO="$_resume_repo"

  # HOST MODE: run AS the account that owns the row. The account now comes
  # from roster_rows()' own field (#350), not the command's path -- the
  # command names the served build, identical for every account.
  # acct_of_prog() stays as a fallback for an old-shaped, hand-set PACED_CONF.
  #
  # A LOGIN-SHAPED PATH IS NOT OPTIONAL. `sudo -u x cmd` is not a login shell,
  # so Ubuntu's .profile never runs and ~/.local/bin is absent -- the omission
  # that once made land-selfdev.sh report "installe is not on PATH" from the
  # script that had just linked it (realisateur MONKEY.md 8.1). /usr/local/bin
  # is included because that is where this host's verbs now live.
  if [ "$PACED_HOST_MODE" = 1 ]; then
    acct="${row_acct:-$(acct_of_prog "$prog" || true)}"
    acct_home="$(getent passwd "$acct" 2>/dev/null | cut -d: -f6)"
    if [ -z "$acct" ] || [ -z "$acct_home" ]; then
      log "SKIP $name -- host mode cannot tell which account owns '$prog' (no explicit field and no /home/<acct>/ prefix, or no such account). NOT dispatched."
      dispatched=$((dispatched + 1))
      continue
    fi
    cmd="sudo -n -u $acct -H env HOME=$acct_home USER=$acct LOGNAME=$acct PATH=$acct_home/.local/bin:/usr/local/bin:/usr/bin:/bin SCHEDULER_RESUME_PR=$_resume_pr SCHEDULER_RESUME_REPO=$_resume_repo $cmd"
  fi

  # Rehearsal: everything above (ROSTER, gate, tempo, account resolution, the
  # sudo composition) already ran for real. Only the exec, the ledger row and
  # the run record (implicit -- scheduler-run is what writes one, and it is
  # never invoked here) are suppressed. #358.
  if [ "$PACED_DRY_RUN" = 1 ]; then
    log "WOULD-DISPATCH [$idx/$n] $name -> $cmd (host=$PACED_HOST conf=$PACED_CONF [$PACED_CONF_SRC] mode=$([ "$PACED_HOST_MODE" = 1 ] && echo host || echo account))"
    unset _resume_pr _resume_repo
    dispatched=$((dispatched + 1))
    continue
  fi

  # conf= is an mktemp path in host mode; [$PACED_CONF_SRC] is the only part that names a surface.
  log "DISPATCH [$idx/$n] $name -> $cmd (host=$PACED_HOST conf=$PACED_CONF [$PACED_CONF_SRC] mode=$([ "$PACED_HOST_MODE" = 1 ] && echo host || echo account))"
  start=$(date +%s)
  # shellcheck disable=SC2086
  if $cmd; then rc=0; else rc=$?; fi

  # NOT-DONE vs GAVE-UP. `rc` alone cannot tell them apart -- rc=1 is both
  # "hit --max-turns with work left" and "concluded it cannot be done", and
  # those want opposite responses. See bin/verdict.sh's header for the full
  # argument; the rule is that ABSENCE of a verdict is never GAVE-UP.
  outcome="$("$SELF_DIR/verdict.sh" classify "$name" "$rc" 2>/dev/null)"; vrc=$?
  log "DONE $name rc=$rc outcome=${outcome:-NOT-DONE} ($(( $(date +%s) - start ))s)"

  # Say when a verdict was never written, distinctly from CONTINUE. Both
  # classify as NOT-DONE and both re-dispatch, so this changes NOTHING about
  # control flow -- it only stops the two being indistinguishable in the log.
  #
  # WHY IT MATTERS: an agent whose brief asks for a verdict and never writes
  # one is a real condition, and the first live run of this mechanism
  # (2026-07-29, scheduler on dexter) was exactly that -- max-turns with no
  # verdict. Silence is deliberately NOT a brake, which is the whole asymmetry
  # in bin/verdict.sh, so the only way silence becomes visible is by being
  # named. Otherwise "the agent never reports" and "the agent said keep going"
  # read identically forever.
  # Asked via `verdict.sh get` (exit 1 == no verdict recorded) rather than by
  # rebuilding the state path here -- one owner of that layout, not two.
  _no_verdict=0
  _derived=""
  if ! "$SELF_DIR/verdict.sh" get "$name" >/dev/null 2>&1; then
    _derived="$(derive_no_verdict_reason "$name" "$start" 2>/dev/null)"
    log "NO-VERDICT $name -- ran with no verdict written (its brief asks for one). ${_derived:-no derivation available.} Treated as NOT-DONE and re-dispatched; metabolism untouched."
    _no_verdict=1
  fi

  # RECORD IT, before anything can consume it. verdict.sh clears the verdict at
  # the NEXT dispatch, so this line is the only thing that will still exist by
  # then -- and repetition is only observable because of it (#54).
  #
  # #261: a blank reason column read as "quietly fine" -- indistinguishable
  # from an account genuinely holding no news. The NO-VERDICT case above
  # already knows why the column would be blank, so it fills it rather than
  # leaving the row to say nothing.
  if declare -F ledger_append >/dev/null 2>&1; then
    if [ "$_no_verdict" -eq 1 ]; then
      _lreason="${_derived:-no-verdict: ran with no verdict written}"
    else
      _lreason="$("$SELF_DIR/verdict.sh" get "$name" 2>/dev/null | grep -m1 '^REASON=' | cut -d= -f2- || true)"
    fi
    _rr_home="$HOME"  # type the silence (#347): see typed_ledger_outcome
    [ "$PACED_HOST_MODE" = 1 ] && _rr_home="$acct_home"
    _ledger_outcome="$(typed_ledger_outcome "$name" "${outcome:-NOT-DONE}" "$_rr_home" "${acct:-}")"
    if [ "$_ledger_outcome" != "${outcome:-NOT-DONE}" ]; then
      log "CUTOFF-TYPED $name -- run-record.sh found real progress before the ceiling; ledger row typed WORKED-CUTOFF instead of generic NOT-DONE"
    fi
    ledger_append "$name" "${TIER:-batch}" "$rc" "$_ledger_outcome" "${_lreason:-}" \
      || log "LEDGER $name -- could not append to the run ledger; repetition is unobservable for this run"
    unset _lreason _rr_home _ledger_outcome
  fi
  unset _no_verdict _derived

  # DONE BRAKES (scheduler#54) -- the vrc -eq 0 branch that never existed.
  # `vrc` was computed for as long as this file has existed and only `-eq 3`
  # was ever read. Measured 2026-08-06: DONE recorded nine times across four
  # accounts in one day, stopping nothing; bibliothecaire said DONE on six
  # consecutive runs and was re-dispatched every time. Every brief tells the
  # agent DONE means "stop dispatching" -- a contract the code did not honour,
  # which is worse than not asking: the agent spends turns producing a signal
  # that is discarded.
  #
  # A COOLDOWN, NOT A SWITCH, and that is the thermostat part. DONE goes stale
  # the moment new work arrives, and a project that cannot restart without a
  # human is a brake with no thaw. So DONE lowers the FREQUENCY.
  if [ "$vrc" -eq 4 ]; then
    _breason="$("$SELF_DIR/verdict.sh" get "$name" 2>/dev/null | grep -m1 '^REASON=' | cut -d= -f2-)"
    _brun=1; _bsame=""
    if declare -F ledger_run >/dev/null 2>&1; then
      _brun="$(ledger_run "$name" BLOCKED BLOCKED-HOLD 2>/dev/null || echo 1)"
      [ "${_brun:-0}" -lt 1 ] && _brun=1
      _bprev="$(ledger_reason "$name" BLOCKED 2>/dev/null || true)"
      [ -n "${_bprev:-}" ] && [ "$_bprev" = "$_breason" ] && _bsame=yes
    fi
    _bhold=$(( ${LEDGER_BLOCKED_HOLD:-6} * _brun ))
    [ -n "$_bsame" ] && _bhold=$(( _bhold * 2 ))
    log "BLOCKED $name -- ${_breason:-no reason recorded} (blockage #$_brun${_bsame:+, SAME reason as last time}); lengthening: held ${_bhold} opportunit(ies). Not IMPOSSIBLE -- it will try again by itself."
    unset _breason _bprev _bsame _bhold _brun
  fi

  if [ "$vrc" -eq 3 ]; then
    # GAVE-UP: the agent itself said IMPOSSIBLE, with a reason. This is the
    # ONLY path that reduces metabolism -- reached by an explicit claim, never
    # by silence. Braking reuses the EXISTING dead-man switch rather than
    # adding a second parallel mechanism: stamp expires_at in the past and
    # this same runner's expiry check (above) stops dispatching it next tick,
    # logs why, and prints the one-command renewal.
    vreason="$("$SELF_DIR/verdict.sh" get "$name" 2>/dev/null | grep -m1 '^REASON=' | cut -d= -f2-)"
    log "GAVE-UP $name -- ${vreason:-no reason recorded}"
    if [ -n "${job_state:-}" ] && mkdir -p "$job_state" 2>/dev/null; then
      date -Is > "$job_state/expires_at"
      log "METABOLISM $name -- dead-man switch stamped expired at $job_state/expires_at (renew: rm it)"
    else
      log "METABOLISM $name -- COULD NOT stamp expires_at (job_state=${job_state:-<unset>}); it will keep dispatching"
    fi
    # File it where a human and realisateur both read. A brake nobody is told
    # about is an outage that looks like calm. It had the pull freeze's defect
    # byte for byte, so it shares the fix rather than a second copy of it.
    file_to_realisateur "$name's give-up" "GAVE-UP: $name declared IMPOSSIBLE on $PACED_HOST -- ${vreason:-no reason recorded}. Metabolism reduced (expires_at stamped). Renew: rm ${job_state:-<unset>}/expires_at"
  fi

  unset _resume_pr _resume_repo
  dispatched=$((dispatched + 1))
done

if [ "$dispatched" -ge "$MAX_PER_TICK" ]; then
  log "PACED_MAX_PER_TICK ($MAX_PER_TICK) reached -- yielding tick, rotation continues next tick"
elif [ "$examined" -ge "$n" ]; then
  # A full lap with nothing dispatched is REPORTED, not silent. On a host
  # where every row belongs to another account this is the normal, correct
  # outcome; on a host where one row should have run it is the finding. Either
  # way the log has to be able to tell "looked at everything and ran nothing"
  # apart from "cron never fired", which an empty log cannot.
  log "ROTATION EXHAUSTED -- examined all $n row(s), dispatched $dispatched"
fi
exit 0
