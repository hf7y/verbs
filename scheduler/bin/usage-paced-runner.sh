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
# Participants come from a participants conf (name|enabled|command), chosen
# PER HOST -- see "which participants file" below. Each participant command is
# a self-contained wrapper with its own lock + logging.
#
# Env knobs (forwarded to usage-gate.sh): USAGE_CEILING, USAGE_MIN_SLACK,
# USAGE_PROBE_MODEL. Plus:
#   PACED_CONF        (explicit participants file; otherwise host-resolved)
#   PACED_HOST        (short hostname; overrides which host-scoped conf is picked)
#   USAGE_GATE        (~/.local/bin/usage-gate.sh)
#   PACED_FORCE       (0)  1 = skip the gate and run the next participant now (testing)
#   PACED_MAX_PER_TICK (8) hard cap on dispatches in one tick, so a single cron
#                      firing can't monopolize the flock indefinitely if the
#                      gate keeps reporting RUN (e.g. a probe stuck reporting
#                      stale slack). The next tick simply continues rotation.
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

# ###########################################################################
# HOST MODE -- one dispatcher for the machine, instead of one per account.
# ###########################################################################
#
# Zach, 2026-08-11: "now that we've moved to /usr/lib and other host level
# things, the per-user absurdity should end and become rationalized."
#
# THE PREMISE THAT JUSTIFIED PER-ACCOUNT DISPATCH IS GONE, and it was retired
# deliberately the same day rather than eroding. The five self-dev accounts on
# monkey now share one build root, one /usr/local/bin, one pin and one release
# clock in root's crontab (hf7y/realisateur#179). Dispatch was the only half of
# the machine still modelling accounts as islands.
#
# WHAT WAS ACTUALLY BROKEN. This file's own header says "Take a global flock",
# and that was true on mandark where one unix user ran every project. Here the
# lock is $HOME-scoped, so five accounts firing at the same `0 */6` took five
# DIFFERENT lock files and serialised nothing. All five then probed
# usage-gate.sh for ACCOUNT-WIDE quota, read the same pre-spend number, and
# each decided RUN from it -- a thundering herd against one budget, with the
# in-tick re-probe unable to see the other four spending concurrently.
#
# THE REJECTED FIX, recorded so it is not re-proposed: stagger each account's
# cron minute by cksum % 60. That lowers collision PROBABILITY and arbitrates
# nothing -- two accounts nine minutes apart still overlap on a run, and
# measured durations reach ~1000s. Randomising spawn time is not arbitration.
#
# THE SPLIT. The DECISION is host-level; the EXECUTION stays per-account. Only
# three things change, which is why this is a mode and not a second
# dispatcher -- a second implementation of "who dispatches now" would be one
# fact with two readers, and this estate has paid for that shape repeatedly:
#
#   1. the lock and rotation state move to host scope (below)
#   2. the run is wrapped in `sudo -u <account>` (see the dispatch site)
#   3. rotation stops being inert BY ITSELF -- the runnability test further
#      down asks `[ -x "$prog" ]`, which is false for a peer's 0700 home under
#      that peer's uid and TRUE under root. Nothing there needed changing;
#      hf7y/scheduler#55's "weight and rotation index are wholly inert" was a
#      consequence of who was asking, not of the code.
#
# Everything else -- the gate, freeze-check, verdict handling, MAX_PER_TICK,
# the logging -- is untouched and shared by both modes, which is the point.
PACED_HOST_MODE="${PACED_HOST_MODE:-0}"

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

USAGE_GATE="${USAGE_GATE:-$HOME/.local/bin/usage-gate.sh}"
[ -x "$USAGE_GATE" ] || USAGE_GATE="$SELF_DIR/usage-gate.sh"
NODE_BIN_DIR="${NODE_BIN_DIR:-/home/zach/.nvm/versions/node/v25.2.1/bin}"

# mandark reaches `claude` through nvm; dexter has a native binary in
# ~/.local/bin and no nvm at all. Prepend the node dir only when it exists,
# and always APPEND ~/.local/bin (cron's default PATH omits it) -- appending
# can add a resolution but can never shadow one that already worked.
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

# --- pull before dispatch (2026-07-24) ---------------------------------------
# This repo is shared RUNNING CODE across two hosts now, not just shared
# config -- mandark and dexter each execute this script and lib/*.sh straight
# out of their own checkout on a */5 cron tick, with no human in the loop.
# A commit pushed from one host has zero effect on the other's behavior until
# that checkout is updated. Runs inside the flock (one pull per host per tick,
# never overlapping with a dispatch already in flight) and BEFORE the
# participants-file resolution below, so a freshly pulled host-scoped conf
# (e.g. a brand new schedule/_paced.<host>.conf) takes effect the same tick
# it lands, not one tick later.
#
# Fail-loud-not-block, same philosophy as the usage gate's ERROR->HOLD: a
# pull that can't happen cleanly (dirty tree, diverged history, no network)
# is logged loudly and the tick proceeds on whatever is already checked
# out -- one stale tick beats a dispatcher that stops ticking entirely
# because of a merge conflict only a human can resolve. --ff-only refuses to
# fabricate a merge commit unattended; a real divergence (this host has local
# commits origin doesn't) is left exactly as found, for a human/session pull
# to sort out, same as the mandark/dexter divergence QUESTIONS.md already
# flagged the same day this was built.
#
# DECISION 2026-07-28 (Zach, explicit): an UNTRACKED file does not block the
# pull. The gate is `--untracked-files=no` -- only TRACKED modifications hold
# the tick back. Rationale: an untracked file cannot be clobbered by a
# fast-forward that doesn't mention it, git itself refuses the ff if it WOULD
# clobber one (handled in the else branch below), and the old gate meant a
# single stray scratch file silently froze deployed code on a host at whatever
# commit it happened to be at -- indefinitely, with only a */5 log line nobody
# reads. That is a bigger hazard than the one it guarded against.
# REVISIT TRIGGER: if a real blind alley is ever traced back to not knowing
# about an untracked file on a dispatcher host -- e.g. debugging behavior that
# turns out to come from an uncommitted script sitting beside the tracked one
# -- this decision is the thing to reopen. File it here and flip the gate back
# to a bare `status --porcelain`.
#
# ESCALATION (2026-08-11, #61/#70). "Fail loud" was only half true: every
# non-advancing branch below logged ONE line, at the same volume, every tick,
# forever. A one-off blip and a permanent freeze were the same log line, so
# there was no observation that distinguished them and nothing that ever
# raised its voice. Measured: vim-arcade's clone sat behind origin/main from
# 2026-08-06 to at least 2026-08-11 -- five days, ~1400 identical `PULL skip`
# lines -- while PR #59, merged specifically to fix that account's brief, could
# not reach it. The line was there the whole time. Nobody reads a line that
# says the same thing on a healthy host and a frozen one.
#
# So a repeat is now counted, and a run of PACED_PULL_ESCALATE_AFTER ticks with
# the SAME cause is a finding: it logs PULL FROZEN and files once into
# realisateur's inbox through the same door the GAVE-UP brake uses further
# down. Recovery is announced too (PULL RECOVERED), because "it started working
# again" is exactly as unobservable as the freeze was.
#
# WHAT IT DELIBERATELY DOES NOT DO IS RESOLVE THE TREE. `git restore` or a
# stash here would have destroyed a real record: the dirty diff on vim-arcade
# is a machine-append from a 2026-08-08 run marking a BLOCKERS entry consumed,
# verified absent from origin/main (#75). Committing on `main` in that clone is
# worse still -- HEAD stops being an ancestor of origin/main and this block
# then logs `PULL WARNING -- diverged` on every tick forever. The self-healing
# is upstream of here and already landed in this change: bin/collect-feedback.sh
# no longer writes the tracked file at all, so the engine stops creating the
# condition. What remains is the class of dirty tree a HUMAN made, and that is
# a finding to raise, not a diff to discard.
# >>> pull gate
PULL_STATE="$STATE_DIR/pull-block.state"
PULL_ESCALATE_AFTER="${PACED_PULL_ESCALATE_AFTER:-3}"

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
  if [ "$n" -ge "$PULL_ESCALATE_AFTER" ]; then
    log "PULL FROZEN -- $REPO_ROOT has not advanced for $n consecutive tick(s) (cause: $reason). Deployed code on this host is STALE and a merged fix cannot reach it. NOT auto-resolved: a dirty tree here can hold the only copy of a record (hf7y/scheduler#61, #75)."
    if [ "$filed" = "0" ] && command -v scheduler >/dev/null 2>&1; then
      if scheduler -i realisateur "PULL FROZEN on $PACED_HOST as $(id -un): $REPO_ROOT has not pulled for $n consecutive dispatcher ticks (cause: $reason). Deployed scheduler code there is stale -- merged fixes cannot reach that account until a human clears it. Evidence: $LOG" >/dev/null 2>&1; then
        filed=1
        log "FILED the pull freeze to realisateur's inbox"
      else
        log "FILED FAILED -- could not file the pull freeze to realisateur; it exists in this log only"
      fi
    fi
  fi
  printf '%s %s %s\n' "$n" "$reason" "$filed" > "$PULL_STATE"
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
  if [ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    pull_blocked dirty-tracked "PULL skip -- $REPO_ROOT has uncommitted changes to TRACKED files"
  elif ! timeout 20 git -C "$REPO_ROOT" fetch --quiet origin main 2>>"$LOG"; then
    pull_blocked fetch-failed "PULL skip -- fetch failed or timed out (network/auth?)"
  elif git -C "$REPO_ROOT" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
    pull_advanced  # already up to date (or ahead) -- nothing to log every 5 minutes
  elif git -C "$REPO_ROOT" merge --ff-only origin/main --quiet 2>>"$LOG"; then
    pull_advanced
    log "PULL fast-forwarded to $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  elif git -C "$REPO_ROOT" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    # A fast-forward WAS possible by ancestry, so the merge refused for a
    # working-tree reason -- almost always "untracked working tree files would
    # be overwritten by merge". Name that specifically: it is the one case the
    # untracked-files decision above deliberately lets reach git, and a
    # "diverged" message here would be a lie that costs an hour to unpick.
    pull_blocked untracked-collision "PULL BLOCKED -- ff-only refused despite clean ancestry; an untracked file in $REPO_ROOT likely collides with an incoming tracked file (see merge error above). Code here is STALE until a human moves it."
  else
    pull_blocked diverged "PULL WARNING -- $REPO_ROOT diverged from origin/main, code here may be stale (needs a human/session merge, not auto-resolved)"
  fi
fi
# <<< pull gate

# --- which participants file? (host-scoped, 2026-07-24) ---------------------
# Two hosts now run this dispatcher out of ONE git-tracked repo (mandark and
# dexter -- see DESIGN-NOTES.md "multi-machine parallelism"). A single shared
# schedule/_paced.conf can't express that: the hosts pin different projects,
# and that file already has an AUTOMATED writer (weight-audit.sh rewrites
# weights and commits them), so aiming both hosts at one file means two
# machines rewriting the same lines. So each host MAY own its own file:
#
#   schedule/_paced.<short-hostname>.conf   this host's rotation, if present
#   schedule/_paced.conf                    shared/default, used otherwise
#
# A host only ever writes its OWN file, so two hosts cannot fight over one set
# of lines by construction -- they're different paths, not different edits to
# one path. A host with no host-scoped file reads _paced.conf exactly as
# before, which is what mandark still does today: this change is a no-op there
# until someone adds a _paced.mandark.conf.
#   List registered hosts:  ls schedule/_paced.*.conf
#
# This block is deliberately INLINE rather than sourced from
# lib/paced-conf.sh, which holds the same rule for bin/scheduler: this script
# is the live */5 dispatcher for the whole ecosystem and resolves its conf
# before it has established anything it could safely source from, so a
# `source` here is a new way for all dispatch to die at once. The agreement
# between the two copies is MECHANIZED instead -- tests/paced-conf-witness.sh
# extracts this block by the two markers below and asserts it resolves
# identically to the library for the same inputs. If you move or rename the
# markers, that witness fails loud rather than silently testing nothing.
# >>> paced conf resolution
# ###########################################################################
# HOST MODE READS THE ROSTER, NOT A CHECKOUT
# ###########################################################################
#
# The last thing tying dispatch to a clone is not code, it is CONFIG: the
# participants list. Everything else the dispatch path needs has been carried
# onto `bashified` and travels in the verb build, but PACED_CONF resolves to
# $REPO_ROOT/schedule/_paced.<host>.conf -- a file that only exists inside a
# checkout, with a hardcoded /home/zach fallback below it (the same shape as
# hf7y/scheduler#99).
#
# Zach, 2026-08-11: "scheduler should not need to exist as a check out on
# monkey for the verbs to work" -- and the reason it matters is isolation. If
# the dispatcher runs out of the same clone self-dev scheduler is editing, one
# bad self-dev run takes down the thing that dispatches every other project.
#
# schedule/ROSTER already is the single source of who is live (#79), and
# lib/dose-common.sh already fetches it from GitHub with no clone. So in host
# mode the participants are MATERIALISED from the roster into the very same
# `name|enabled|weight|command` rows this file already parses. The parser, the
# rotation, the gate and every refusal below are untouched -- only where the
# rows come from changes.
#
# ACCOUNT MODE IS UNCHANGED. It still reads _paced.<host>.conf from its own
# checkout, so nothing about today's five armed accounts moves until the
# cutover is a deliberate act.
roster_rows() {
  local line p ah rate state acct
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    IFS='|' read -r p ah rate state <<<"$line"
    p="$(printf '%s' "$p" | tr -d '[:space:]')"
    ah="$(printf '%s' "$ah" | tr -d '[:space:]')"
    state="$(printf '%s' "$state" | tr -d '[:space:]')"
    [ -n "$p" ] || continue
    [ "${ah##*@}" = "$PACED_HOST" ] || continue
    acct="${ah%@*}"
    # enabled is the roster's ONE state field -- the whole point of #79 is that
    # live/parked cannot disagree with a second file. weight is emitted as 1
    # because it is inert (#55) and this is a translation, not a revival.
    case "$state" in
      live)   printf '%s|1|1|/home/%s/Documents/Projects/scheduler/bin/scheduler-run %s batch\n' "$p" "$acct" "$p" ;;
      parked) printf '%s|0|1|/home/%s/Documents/Projects/scheduler/bin/scheduler-run %s batch\n' "$p" "$acct" "$p" ;;
    esac
  done
}

LEGACY_PACED_CONF="/home/zach/Documents/Projects/scheduler/schedule/_paced.conf"
PACED_HOST="${PACED_HOST:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)}"
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
  _roster="$(fetch_roster)" || { echo "usage-paced-runner: host mode could not read schedule/ROSTER. Refusing to dispatch rather than fall back to a checkout." >&2; exit 2; }
  PACED_CONF="$(mktemp)"; trap 'rm -f "$PACED_CONF"' EXIT
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
  # Last resort: a copied-not-symlinked install whose repo we can't locate.
  PACED_CONF="$LEGACY_PACED_CONF"
  PACED_CONF_SRC="legacy absolute path (repo not found from $SELF_DIR)"
fi
# <<< paced conf resolution

# --- load enabled participants -------------------------------------------------
# Format: name|enabled|command, with an OPTIONAL weight inserted as a third
# field (name|enabled|weight|command) -- realisateur is expected to set this,
# scheduler only enforces it mechanically (see docs/priority-weight.md).
# Weight is a positive integer >=1; omitted/invalid defaults to 1. A weight-N
# participant gets N turns in the rotation for every 1 turn a weight-1
# participant gets (implemented by literally repeating it N times in the
# rotation pool below), so ties still resolve by plain round-robin order.
names=(); cmds=()
if [ ! -f "$PACED_CONF" ]; then
  log "FATAL no participants conf at $PACED_CONF [$PACED_CONF_SRC] host=$PACED_HOST"
  exit 1
fi
while IFS='|' read -r name enabled rest; do
  case "$name" in ''|\#*) continue ;; esac          # skip blank / comment lines
  [ "${enabled// /}" = "1" ] || continue
  name="${name// /}"
  rest="${rest#"${rest%%[![:space:]]*}"}"   # trim leading whitespace
  weight=1
  case "$rest" in
    [0-9]*'|'*)
      maybe_weight="${rest%%|*}"
      if [[ "$maybe_weight" =~ ^[0-9]+$ ]] && [ "$maybe_weight" -ge 1 ]; then
        weight="$maybe_weight"
        rest="${rest#*|}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
      fi
      ;;
  esac
  cmd="$rest"
  for ((_w=0; _w<weight; _w++)); do
    names+=("$name"); cmds+=("$cmd")
  done
done < "$PACED_CONF"

n="${#names[@]}"
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
# dispatches from a committed/validated copy of _paced*.conf". The gate has
# two named halves: sync-crontab.sh --apply refuses a dirty schedule/
# (committed), and this check refuses to dispatch a participant whose conf
# is dirty relative to HEAD (verified). Reuse the same --check-clean gate so
# the rule has one definition.
if [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT/.git" ]; then
  if ! "$SELF_DIR/sync-crontab.sh" --check-clean 2>/dev/null; then
    log "REFUSE -- schedule/ is dirty relative to HEAD (run git commit in the repo to proceed)"
    exit 2
  fi
fi

# --- dispatch loop --------------------------------------------------------
# Each iteration re-checks the gate against LIVE headers -- the previous
# cycle's spend has already landed by the time we re-probe -- so this stops
# as soon as the account is genuinely on-pace/at-ceiling, not after a fixed
# count. MAX_PER_TICK is just a runaway backstop, not the normal stop reason.
#
# TWO counters, since 2026-08-05, and the distinction is the whole fix.
#
#   dispatched -- rows this account actually RAN (or decided about: expired,
#                 frozen). Bounded by MAX_PER_TICK. This is the quota-facing
#                 number and its meaning is unchanged.
#   examined   -- rows this account LOOKED AT. Bounded by $n, the rotation
#                 length, so the loop terminates after one full lap no matter
#                 how many rows turn out to belong to somebody else.
#
# WHY. A row whose command lives under another account's $HOME is not
# runnable HERE, and used to consume a dispatch slot. On monkey four accounts
# share one _paced.monkey.conf with four rows, so at PACED_MAX_PER_TICK=1
# three of every four accounts spent their entire tick logging a SKIP for a
# row they were never able to run. Measured at the 00:00 UTC tick, 2026-08-05:
#
#   [ecosim]         SKIP vim-arcade -- command not runnable  -> tick yielded
#   [vim-arcade]     SKIP ecosim     -- command not runnable  -> tick yielded
#   [bibliothecaire] DONE bibliothecaire rc=0 (182s)
#
# Effective throughput was ~1/N of capacity, and it got WORSE with every row
# added -- so arming a fifth project slowed the four already running. That is
# backwards for a rotation whose purpose is to add participants.
#
# WHY NOT SIMPLY STOP COUNTING THE SKIP. Because the counting was load-bearing
# for TERMINATION, which the EXPIRED branch below says out loud: "so an
# all-expired rotation still terminates the tick loop." With no counter at all
# a rotation containing no runnable row would spin forever, re-probing the
# usage gate each lap. `examined` is that guarantee, made explicit and
# separated from the quota budget it was overloaded onto.
#
# COST: none, since 2026-08-06. Walking past a foreign row briefly cost one
# extra usage-gate probe (~23 Haiku tokens), because the runnability test sat
# AFTER the gate: the account paid a live probe against the SHARED account
# quota to learn the row was not its own. The test now runs first (see
# "RUNNABILITY BEFORE THE PROBE" below) and a foreign row costs a stat(2).
# Measured on monkey at the 18:00Z tick 2026-08-06: 9 probes host-wide (3
# accounts x 3 roster rows) to make 3 dispatch decisions. Now 3.
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

  name="${names[$idx]}"; cmd="${cmds[$idx]}"

  # --- RUNNABILITY BEFORE THE PROBE (2026-08-06) ---------------------------
  # "Is this row even mine?" is a local filesystem question -- one stat(2) --
  # and until today it was asked AFTER the usage gate had already spent a live
  # API probe against the account-wide quota. One uid cannot execute another
  # uid's scheduler-run, so on monkey every account walked a 3-row roster of
  # which exactly one row was executable under its uid, and bought a probe for
  # each. 3 accounts x 3 rows = 9 probes to make 3 dispatch decisions.
  #
  # Order is the ENTIRE change. No branch below sees a different input, the
  # rotation pointer advances over the same rows in the same sequence, and the
  # gate still owns every real stop condition. Only the probes that could not
  # have changed any outcome stop being bought.
  #
  # resolve the command's program (first token) to check it exists
  prog="${cmd%% *}"
  if [ ! -x "$prog" ] && ! command -v "$prog" >/dev/null 2>&1; then
    # NOT counted against MAX_PER_TICK, unlike the EXPIRED and FROZEN skips
    # below. Those are decisions about a row this account OWNS -- having made
    # one, the tick has done its job. This one means "that row is somebody
    # else's", which is not a decision and must not spend the budget.
    # `examined` is what stops the loop, so it MUST be incremented on this
    # path: it is now the only bound on a rotation of entirely foreign rows,
    # and without it this `continue` is an infinite loop.
    echo "$idx" > "$PTR"
    examined=$((examined + 1))
    log "SKIP $name -- command not runnable here: $cmd"
    continue
  fi

  if [ "${PACED_FORCE:-0}" = "1" ]; then
    log "PACED_FORCE=1 -- skipping usage gate"
  else
    verdict="$("$USAGE_GATE" 2>/dev/null)"; rc=$?
    summary="$(printf '%s\n' "$verdict" | grep -E '^verdict=|^# ' | tr '\n' ' ')"
    if [ "$rc" -ne 0 ]; then
      log "HOLD (gate rc=$rc) $summary"
      break
    fi
    log "RUN  $summary"
  fi

  # Committed HERE, once, before any branch below can `continue`. Every exit
  # path from this point is therefore bounded by the rotation length -- which
  # is what makes it safe for the not-runnable branch to stop touching
  # `dispatched`. Put this inside a branch instead and one `continue` without
  # it becomes an infinite loop that re-probes the gate forever.
  echo "$idx" > "$PTR"
  examined=$((examined + 1))

  # Dead-man-switch awareness (2026-07-26, FOCUS.md EXPIRY_DAYS finding 2):
  # an expired participant used to consume a full dispatch slot and record
  # as a normal DISPATCH/DONE pair -- this runner had no expires_at
  # awareness at all, so expired jobs no-op'd visibly only in their own
  # sweep.log. The job's state dir is derived from the wrapper filename by
  # the same <job>-loop.sh convention the wrappers themselves use
  # (chezz-nightly-batch-loop.sh -> ~/.local/share/chezz-nightly-batch);
  # a command that doesn't match the convention (scheduler-dev-cycle.sh)
  # has no expires_at at the derived path and dispatches exactly as
  # before -- fail-open, never fail-blocked. Belt-and-braces with
  # lib/sweep-loop-common.sh's own pre-clone check (which exits 3): this
  # skip saves the dispatch slot, that one saves the clone if a job
  # expires between here and its own check, or arrives via cron instead.
  # Counts toward MAX_PER_TICK like the not-runnable SKIP above, so an
  # all-expired rotation still terminates the tick loop.
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

  # Consume any prior verdict BEFORE dispatching, so this run's outcome can
  # never be read off the last run's file. Same lesson as expires_at: a stale
  # stamp that reads as current is worse than no stamp.
  "$SELF_DIR/verdict.sh" clear "$name" >/dev/null 2>&1 || true

  # HOST MODE: run AS the account that owns the row. The account is read off
  # the command's own path (/home/<acct>/...), which is the authority for who
  # runs it -- that path IS the thing being executed, so deriving the uid from
  # anywhere else would let the two disagree.
  #
  # A LOGIN-SHAPED PATH IS NOT OPTIONAL. `sudo -u x cmd` is not a login shell,
  # so Ubuntu's .profile never runs and ~/.local/bin is absent -- the omission
  # that once made land-selfdev.sh report "installe is not on PATH" from the
  # script that had just linked it (realisateur MONKEY.md 8.1). /usr/local/bin
  # is included because that is where this host's verbs now live.
  if [ "$PACED_HOST_MODE" = 1 ]; then
    acct="$(acct_of_prog "$prog" || true)"
    acct_home="$(getent passwd "$acct" 2>/dev/null | cut -d: -f6)"
    if [ -z "$acct" ] || [ -z "$acct_home" ]; then
      log "SKIP $name -- host mode cannot tell which account owns '$prog' (no /home/<acct>/ prefix, or no such account). NOT dispatched."
      dispatched=$((dispatched + 1))
      continue
    fi
    cmd="sudo -n -u $acct -H env HOME=$acct_home USER=$acct LOGNAME=$acct PATH=$acct_home/.local/bin:/usr/local/bin:/usr/bin:/bin $cmd"
  fi

  log "DISPATCH [$idx/$n] $name -> $cmd (host=$PACED_HOST conf=$PACED_CONF mode=$([ "$PACED_HOST_MODE" = 1 ] && echo host || echo account))"
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
  if ! "$SELF_DIR/verdict.sh" get "$name" >/dev/null 2>&1; then
    log "NO-VERDICT $name -- ran with no verdict written (its brief asks for one). Treated as NOT-DONE and re-dispatched; metabolism untouched."
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
    # about is an outage that looks like calm.
    if command -v scheduler >/dev/null 2>&1; then
      if scheduler -i realisateur "GAVE-UP: $name declared IMPOSSIBLE on $PACED_HOST -- ${vreason:-no reason recorded}. Metabolism reduced (expires_at stamped). Renew: rm ${job_state:-<unset>}/expires_at" >/dev/null 2>&1; then
        log "FILED $name's give-up to realisateur's inbox"
      else
        log "FILED FAILED -- could not file $name's give-up to realisateur; it exists in this log only"
      fi
    fi
  fi

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
