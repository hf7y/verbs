#!/usr/bin/env bash
# tempo.sh -- may this participant dispatch NOW, at the pace its backlog
# justifies? The thermostat's setpoint, hf7y/scheduler#147 (#66 §3).
#
# RUNNER: tests/tempo-witness.sh
#
# ---------------------------------------------------------------------------
# WHAT IT IS FOR, AND WHY IT IS NOT usage-gate.sh
#
# usage-gate.sh answers "is the QUOTA at risk" -- a resource guard, one number
# for the whole account, identical for every project. This answers "is this
# project's pace right for the work it actually has" -- a tempo regulator, per
# project. realisateur#46 is the standing argument that these are two jobs
# under one name and must not share an exit code; this is the second one,
# split out rather than folded in, with its own vocabulary in the log so
# "held for quota" and "held for pace" are never the same string.
#
# ---------------------------------------------------------------------------
# THE ARITHMETIC, so a reader can redo it rather than trust it
#
#   actionable = open issues MINUS those labelled as waiting on a human
#   want_min   = clamp( BASE_MIN * PIVOT / max(1, actionable), MIN_MIN, MAX_MIN )
#
# One term. A project with PIVOT issues of real work runs at BASE_MIN; twice
# the work runs twice as often; and the interval is clamped at both ends so
# neither an empty tracker nor a flooded one can produce an absurd pace.
#
# THE INVERSION #147 CALLS "the whole design" IS THE SUBTRACTION, and nothing
# else. An issue an agent filed for a human to settle does not raise the rate,
# because it is not work the dispatcher can do -- so a tracker that is mostly
# such issues has a near-zero actionable count and lands at MAX_MIN, dispatched
# once a day. Getting this backwards is a runaway, which is why the blocked
# set is subtracted before the division rather than penalised after it: there
# is one place to be wrong instead of two.
#
# NO SECOND PENALTY TERM, deliberately. An earlier draft multiplied the
# interval up again by the blocked count. On today's realisateur (42
# actionable, 21 blocked) that produced 94 min -- slower than the 30 min a
# human had just set by hand for the same tracker -- i.e. the penalty
# out-argued the measurement it was supposed to refine. Exclusion already
# expresses "this does not count as backlog"; multiplying as well says "and it
# is evidence against running", which is a different and unproven claim.
#
# ---------------------------------------------------------------------------
# WHY THE SENSOR IS LABELS AND NOT AUTHORSHIP
#
# #147 specifies the split as WHO FILED IT, resolved by a provenance label the
# filing verbs stamp. Measured before building this, 2026-08-16: every actor
# in the estate is `hf7y`, and the one stamp that does exist -- the
# `<!-- agent: ... -->` marker realisateur's gh shim appends -- reaches 3 of
# realisateur's 63 open issues, because the shim shipped this month and the
# tracker did not. A sensor with 5% coverage that defaults the other 95% to
# "a human asked for this" fails in the dispatch-MORE direction, which is the
# one #147 names as the runaway.
#
# `needs-human` / `deferred` are already applied, by agents, across the
# estate -- 21 of realisateur's 63 today. They measure the property the
# setpoint actually wants (can the dispatcher act on this?) rather than a
# proxy for it (who typed it?), they are live rather than 5% covered, and they
# are wrong in the safe direction: an unlabelled blocked issue reads as work,
# which at worst wastes one dispatch that will label it.
#
# When the marker's coverage catches up, add it to TEMPO_BLOCKED_LABELS'
# argument rather than replacing this: they answer the same question.
#
# ---------------------------------------------------------------------------
# WHAT IT REFUSES TO DO
#
# BLIND IS A HOLD, NOT A RUN. If the tracker cannot be read there is no
# setpoint, and a regulator with no setpoint must not wave dispatch through --
# #147's own guardrail, and the same polarity usage-gate.sh already uses for
# ERROR. Exit 2, and the caller holds. This is the one place tempo can stop a
# project that has real work, so it says exactly which read failed.
#
# IT DOES NOT APPEND A LEDGER ROW WHEN IT HOLDS, and that is a deliberate
# difference from the DONE cooldown and the BLOCKED backoff sitting next to it
# in usage-paced-runner.sh -- not an omission. Those two count ROWS, so they
# must record their own skips or the count never advances and the hold becomes
# permanent. This counts MINUTES off the wall clock, so it elapses whether or
# not anything is written; and writing anyway would inflate the row counts
# those two brakes read, quietly shortening every cooldown in proportion to
# how often tempo held. `bin/tempo.sh <project>` reproduces any decision on
# demand, and the runner logs every hold.
set -uo pipefail

CLI_NAME='tempo.sh'

usage() {
  cat <<'EOF'
tempo.sh -- may this participant dispatch now, at the pace its backlog justifies?

usage: tempo.sh <project> [--quiet]

  <project>   a name with a schedule/<project>.conf (its REPO_URL names the tracker)
  --quiet     print the verdict word only

Prints one verdict line and exits:
  0  RUN    -- enough time has passed for this backlog
  1  HOLD   -- too soon; it resumes on its own, nothing is stuck
  2  BLIND  -- the tracker could not be read. NEVER treated as RUN
  3  usage

Knobs, resolved env > schedule/_tempo.<host>.conf > schedule/_tempo.conf > default:
  TEMPO_ENABLED         1        0 makes every answer RUN, and says so
  TEMPO_BASE_MIN        120      interval at the pivot backlog
  TEMPO_PIVOT_ISSUES    12       the backlog that maps to BASE_MIN
  TEMPO_MIN_MIN         20       never faster than this
  TEMPO_MAX_MIN         1440     never slower than this
  TEMPO_BLOCKED_LABELS  needs-human,deferred,blocked,question
  TEMPO_CACHE_MIN       30       how long a tracker count may be reused

This utility cannot spend money. It has no --summon flag.
EOF
}

QUIET=0; PROJECT=""
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --quiet|-q) QUIET=1 ;;
    --summon) echo "$CLI_NAME: this utility cannot spend; there is no --summon" >&2; exit 3 ;;
    -*) echo "$CLI_NAME: unknown flag $a" >&2; usage >&2; exit 3 ;;
    *) PROJECT="$a" ;;
  esac
done
[ -n "$PROJECT" ] || { usage >&2; exit 3; }

emit() {
  local verdict="$1"; shift
  if [ "$QUIET" = 1 ]; then printf '%s\n' "$verdict"; else printf 'verdict=%s %s\n' "$verdict" "$*"; fi
}
blind() { emit BLIND "project=$PROJECT reason=$1"; exit 2; }

SELF_REAL="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)" || SELF_REAL="${BASH_SOURCE[0]}"
[ -n "$SELF_REAL" ] || SELF_REAL="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF_REAL")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
CONF_DIR="${TEMPO_CONF_DIR:-$REPO_ROOT/schedule}"
HOST="${PACED_HOST:-$(hostname -s 2>/dev/null || echo unknown)}"

# --- knobs -----------------------------------------------------------------
# Parsed, not sourced, and by the same rule usage-gate.sh states for
# schedule/_usage.conf: these files hold scalar knobs only, and sourcing one
# into this script would let a stray line clobber the verdict. The resolver is
# a second implementation of that one rather than a shared library ON PURPOSE
# -- usage-gate.sh is installed as a COPY at ~/.local/bin (bin/deploy-drift-check.sh
# is the record of that), so a lib it sourced would simply not be there.
CONF_FILES=()
[ -f "$CONF_DIR/_tempo.conf" ] && CONF_FILES+=("$CONF_DIR/_tempo.conf")
[ -f "$CONF_DIR/_tempo.$HOST.conf" ] && CONF_FILES+=("$CONF_DIR/_tempo.$HOST.conf")

# knob <KEY> <default> -- sets KNOB_VAL and KNOB_SRC. NOT a printing function
# called through $(...): a subshell cannot report which file a value came from,
# and reporting that is the point (usage-gate.sh's verdict line carries the
# same `knobs=ceiling:_usage.conf` field so a reader can tell a set value from
# a default without going looking).
KNOB_VAL=""; KNOB_SRC=""
knob() {
  local key="$1" def="$2" f line v
  KNOB_VAL=""; KNOB_SRC="default"
  if [ -n "${!key:-}" ]; then KNOB_VAL="${!key}"; KNOB_SRC="env"; return; fi
  for f in ${CONF_FILES+"${CONF_FILES[@]}"}; do
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$f" 2>/dev/null | tail -n1)"
    [ -n "$line" ] || continue
    v="${line#*=}"; v="${v%%#*}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    [ -n "$v" ] && { KNOB_VAL="$v"; KNOB_SRC="$(basename "$f")"; }
  done
  [ -n "$KNOB_VAL" ] || KNOB_VAL="$def"
}
want_int() {                                # want_int <KEY> <value> <lo> <hi>
  case "$2" in ''|*[!0-9]*) blind "invalid_$1=$2 (want an integer $3-$4)" ;; esac
  [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] || blind "invalid_$1=$2 (out of range $3-$4)"
}

knob TEMPO_ENABLED 1;        ENABLED="$KNOB_VAL"
knob TEMPO_BASE_MIN 120;     BASE_MIN="$KNOB_VAL"; BASE_SRC="$KNOB_SRC"
knob TEMPO_PIVOT_ISSUES 12;  PIVOT="$KNOB_VAL";    PIVOT_SRC="$KNOB_SRC"
knob TEMPO_MIN_MIN 20;       MIN_MIN="$KNOB_VAL"
knob TEMPO_MAX_MIN 1440;     MAX_MIN="$KNOB_VAL"
knob TEMPO_CACHE_MIN 30;     CACHE_MIN="$KNOB_VAL"
knob TEMPO_BLOCKED_LABELS 'needs-human,deferred,blocked,question'
BLOCKED_LABELS="$KNOB_VAL"

if [ "$ENABLED" = "0" ]; then
  emit RUN "project=$PROJECT reason=tempo_disabled knobs=enabled:0"
  exit 0
fi

want_int TEMPO_BASE_MIN "$BASE_MIN" 1 10080
want_int TEMPO_PIVOT_ISSUES "$PIVOT" 1 10000
want_int TEMPO_MIN_MIN "$MIN_MIN" 1 10080
want_int TEMPO_MAX_MIN "$MAX_MIN" 1 10080
want_int TEMPO_CACHE_MIN "$CACHE_MIN" 0 10080
[ "$MIN_MIN" -le "$MAX_MIN" ] || blind "TEMPO_MIN_MIN=$MIN_MIN exceeds TEMPO_MAX_MIN=$MAX_MIN"

# --- which tracker ---------------------------------------------------------
# From schedule/<project>.conf's REPO_URL, the same field every other consumer
# of that file reads, so there is no second place a project's tracker is named.
SLUG="${TEMPO_REPO:-}"
if [ -z "$SLUG" ]; then
  conf="$CONF_DIR/$PROJECT.conf"
  [ -r "$conf" ] || blind "no readable $conf -- cannot tell which tracker '$PROJECT' has"
  url="$(grep -E '^[[:space:]]*REPO_URL[[:space:]]*=' "$conf" | tail -n1 | sed -E 's/^[^=]*=//; s/^"//; s/"$//')"
  [ -n "$url" ] || blind "$conf sets no REPO_URL"
  case "$url" in
    *github.com*|*github-*) SLUG="$(printf '%s' "$url" | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##')" ;;
    *) blind "REPO_URL in $conf is not a GitHub remote ($url) -- no tracker to read" ;;
  esac
fi

# --- the ledger clock ------------------------------------------------------
# Sourced rather than re-derived: lib/run-ledger.sh owns where the ledger
# lives, and it moves between $HOME and /var/lib depending on dispatch mode.
# A second copy of that path here is exactly the drift hf7y/scheduler#119 is.
# shellcheck source=../lib/run-ledger.sh
. "$REPO_ROOT/lib/run-ledger.sh" 2>/dev/null \
  || blind "cannot source $REPO_ROOT/lib/run-ledger.sh -- no clock to measure against"
declare -F ledger_age_min >/dev/null 2>&1 \
  || blind "lib/run-ledger.sh has no ledger_age_min -- this build predates the thermostat"

# HOLD ROWS ARE NOT DISPATCHES. The cooldown and the backoff each write a row
# when they hold, so counting "minutes since the last row" would restart this
# clock every time a NEIGHBOURING brake fired -- a project held for DONE would
# look freshly dispatched to tempo forever.
SINCE_MIN="$(ledger_age_min "$PROJECT" COOLDOWN BLOCKED-HOLD 2>/dev/null || echo 999999)"

# --- the tracker -----------------------------------------------------------
# Cached, because at a fine ask-rate most ticks are holds and a hold must not
# buy a network round-trip -- the same rule that puts the DONE cooldown ahead
# of the live quota probe in usage-paced-runner.sh. The cache stores the
# reading and its epoch; a cache it cannot parse is a miss, never a zero.
CACHE_DIR="${STATE_DIR:-$HOME/.local/share/scheduler-paced-runner}"
CACHE="$CACHE_DIR/tempo-$PROJECT.count"
NOW="$(date +%s)"
OPEN=""; BLOCKED=""; SOURCE="live"

if [ "$CACHE_MIN" -gt 0 ] && [ -r "$CACHE" ]; then
  IFS=$'\t' read -r c_at c_open c_blocked < "$CACHE" 2>/dev/null || true
  case "${c_at:-x}${c_open:-x}${c_blocked:-x}" in
    *[!0-9]*) : ;;
    *) if [ $(( (NOW - c_at) / 60 )) -lt "$CACHE_MIN" ] && [ "$c_at" -le "$NOW" ]; then
         OPEN="$c_open"; BLOCKED="$c_blocked"; SOURCE="cache"
       fi ;;
  esac
fi

if [ -z "$OPEN" ]; then
  command -v gh >/dev/null 2>&1 || blind "gh is not on PATH -- cannot read $SLUG"
  # ONE call, counting both numbers in the filter: total open, and those
  # carrying any blocked label. `gh issue list` excludes pull requests already.
  # gh's --jq takes no --arg, so the label list is interpolated as a string
  # literal and split inside the filter -- which is also why TEMPO_BLOCKED_LABELS
  # is validated as a plain comma list below before it reaches here.
  case "$BLOCKED_LABELS" in
    *['"'\\\$\`]*) blind "TEMPO_BLOCKED_LABELS carries a quote or shell metacharacter: $BLOCKED_LABELS" ;;
  esac
  raw="$(gh issue list --repo "$SLUG" --state open --limit 300 --json number,labels \
           --jq "[ length, ([ .[] | select( [.labels[].name] as \$l | (\"$BLOCKED_LABELS\"|split(\",\")) | any(. as \$b | \$l | index(\$b)) ) ] | length) ] | @tsv" 2>/dev/null)" \
    || blind "gh could not read $SLUG's open issues"
  [ -n "$raw" ] || blind "gh returned nothing for $SLUG -- an unreadable tracker is not an empty one"
  IFS=$'\t' read -r OPEN BLOCKED <<<"$raw"
  case "${OPEN:-x}${BLOCKED:-x}" in
    *[!0-9]*) blind "could not parse a count out of gh's answer for $SLUG" ;;
  esac
  if [ "$CACHE_MIN" -gt 0 ] && mkdir -p "$CACHE_DIR" 2>/dev/null; then
    printf '%s\t%s\t%s\n' "$NOW" "$OPEN" "$BLOCKED" > "$CACHE" 2>/dev/null || true
  fi
fi

ACTIONABLE=$(( OPEN - BLOCKED ))
[ "$ACTIONABLE" -lt 0 ] && ACTIONABLE=0

# want = BASE * PIVOT / max(1, actionable), rounded, then clamped.
DIV=$ACTIONABLE; [ "$DIV" -lt 1 ] && DIV=1
WANT=$(( (BASE_MIN * PIVOT + DIV / 2) / DIV ))
[ "$WANT" -lt "$MIN_MIN" ] && WANT="$MIN_MIN"
[ "$WANT" -gt "$MAX_MIN" ] && WANT="$MAX_MIN"

FACTS="project=$PROJECT repo=$SLUG open=$OPEN blocked=$BLOCKED actionable=$ACTIONABLE"
FACTS="$FACTS want_min=$WANT since_min=$SINCE_MIN counts=$SOURCE"
FACTS="$FACTS knobs=base:$BASE_SRC,pivot:$PIVOT_SRC"

if [ "$SINCE_MIN" -ge "$WANT" ]; then
  emit RUN "$FACTS"
  exit 0
fi
emit HOLD "$FACTS"
exit 1
