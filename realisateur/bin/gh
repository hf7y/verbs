#!/usr/bin/env bash
# KIND: verb
# gh-sign.sh -- sign every agent-written GitHub comment/issue AUTOMATICALLY,
# by standing in front of `gh` on PATH.
#
# It appends `<!-- agent: <account>@<host> <ISO8601> -->` to the bodies of
# `issue comment|create|close` and `pr comment|create`, and passes everything
# else through untouched. Both fields are read from the running process, so
# there is no argument for a caller to get wrong or forget. It replaced
# bin/gh-comment.sh, a wrapper that had to be called and never was: 20 of 403
# comments across five repos were stamped. Why the GitHub App cannot own this
# half of attribution, and the measurement: hf7y/realisateur#327.
#
# It also REFUSES an `issue create` / `pr create` whose body breaks
# lib/body-grammar.sh. claim-drift.yml and deferral-ledger.yml grade the same
# text afterwards and are not required checks on main, so the write is the
# only place the rule bites.
#
# FAIL OPEN ON MACHINERY, CLOSED ON GRAMMAR. No real gh, an unreadable
# --body-file, an unrecognised subcommand, a missing grammar library: exec the
# real gh with the ORIGINAL argv. A body that breaks a rule the shim could
# read is the one case it stops.
#
# usage: `usage()` below. One source; `gh --help` reaches it only on a host
# with no real gh, because everywhere else --help belongs to the real gh.
#
# HOW IT REACHES A PATH, AND WHY THERE IS EXACTLY ONE COPY (#330)
# ---------------------------------------------------------------
# It ships as a VERB. realisateur's `bashified` branch carries bin/gh and
# man/gh.1, the nightly cut puts it in the build manifest, and the host-scoped
# tick links /usr/local/bin/gh into whichever build the host pin names --
# /usr/local/bin being the one directory that precedes /usr/bin under cron and
# is writable by
# provisioning (measured on #330; a per-account ~/.local/bin shim is inert
# because usage-paced-runner.sh APPENDS that directory deliberately).
#
# Zach, 2026-08-16, on the alternative: "it cannot be several copies, one per
# repo that will drift inevitably; this needs to be one single, stable location
# where policy changes automatically reach." So the policy has one home -- this
# file on `main` -- and every replica is mechanical: the carry onto `bashified`
# is `bin/carry-drift.sh --carry` and byte-identity is a CI guard, the build is
# cut from that branch, and the link is moved by the tick. Nothing is retyped
# anywhere, so nothing can drift without a red check.
#
# AND IT KNOWS HOW OLD IT IS. Propagation can stop -- the cutter can fail, the
# tick can be unarmed, a pin can freeze -- and a shim that enforces a policy is
# WORSE than none when it is silently enforcing last month's. So it finds its
# own build id, dates itself from it, and past STALE_DAYS it says so on stderr
# at every write AND stamps `STALE <n>d` into every body it signs. That mark is
# in the artifact, where a human and decision-rot.sh both read it, rather than
# in a log nobody opens. It does NOT refuse the write: see FAIL OPEN above --
# an unsigned comment is the status quo, a dropped one is not, and the same
# argument holds for a stale one.
#
#   gh-sign.sh <any gh argv>        sign if it is a body-carrying write, then exec gh
#   gh-sign.sh --self-check         prove the shim resolves a real gh that is not itself
#   gh-sign.sh --stamp              print the stamp this host/account would append
#   gh-sign.sh --check-body <path>  grade a body against the grammar; `-` reads stdin
#
# MANDARK IS EXCLUDED, deliberately and permanently: an unsigned comment from
# Zach's own machine is the signal decision-rot.sh reads.
set -uo pipefail

MARKER='<!-- agent:'

# How old a build may be before every body it writes is marked STALE. 14 is
# not a new number: it is bin/verbs-refresh.sh's STALE_DAYS, the estate's
# existing answer to "how long may a verb build go unrefreshed", against a
# cutter that runs nightly and a tick that adopts within 26 hours.
#
# There is no environment override, on purpose. A documented override turns a
# guard into a toll booth -- Zach, 2026-08-15, in hf7y/realisateur#321. The
# build root IS overridable: that is a path, not a policy, and the suite needs
# it.
STALE_DAYS=14
BUILD_ROOTS="${GH_SIGN_BUILD_ROOTS:-/usr/local/share/verb-builds ${XDG_DATA_HOME:-$HOME/.local/share}/verb-builds}"

# BUILT-INS ONLY (`-ef`, `printf %(...)T`): this runs in front of every gh call
# including cron's, with a minimal PATH. An early version shelled out to
# id/hostname/date/readlink; under a stripped PATH all four were "command not
# found", which degraded the stamp to `?@?` AND made the shim fail to recognise
# ITSELF as the gh it had found. `id -un` first and $USER only as fallback:
# $USER is inherited and can be set by the caller.
#
# The trailing field is which COPY of the policy wrote this, and how old it
# was -- `build 2026-08-16T0130Z`, or `... STALE 46d`, or `unbuilt`. Without
# it a body proves who wrote it and says nothing about what rules were in
# force, which is the question every one of these stamps gets read to answer.
stamp() {
  local TZ=UTC who
  who="$(id -un 2>/dev/null)" || who="${USER:-${LOGNAME:-?}}"
  printf '%s %s@%s %(%Y-%m-%dT%H:%M:%SZ)T %s -->\n' \
    "$MARKER" "$who" "${HOSTNAME%%.*}" -1 "$(origin)"
}

# The demand. Named commands, not "update your verbs": the accounts that will
# read this have no realisateur checkout, and a refusal that cannot be acted
# on is a refusal nobody acts on.
demand_refresh() {
  printf 'gh-sign: STALE -- this copy is %s, %s days old (limit %s). The policy it\n' \
    "$BUILD_ID" "$(build_age_days)" "$STALE_DAYS" >&2
  printf 'gh-sign: enforces is that far behind main, and every body it signs now says so.\n' >&2
  printf 'gh-sign: Move the channel:  selfdev-release-tick.sh --apply   (a host on a clock)\n' >&2
  printf 'gh-sign:                    verbs-refresh.sh --apply          (a workstation without one)\n' >&2
}

usage() {
  cat <<'EOF'
gh-sign -- the shim that stands in front of `gh` and signs what an agent writes.

  gh <any gh argv>          passed to the real gh; body-carrying writes are
                            signed first, and `issue create` / `pr create`
                            bodies are graded against lib/body-grammar.sh
  gh --self-check           which real gh, which build, how old, which grammar
  gh --stamp                the stamp this host and account would append
  gh --check-body <path>    grade a body; `-` reads stdin

Installed as one link per host: /usr/local/bin/gh -> the current verb build.
Never edit that copy -- edit realisateur's bin/gh-sign.sh, which is its one
source, and let the nightly cut carry it (hf7y/realisateur#330).
EOF
}

# The real gh: the first one on PATH that is not this file. `-ef` compares
# device+inode THROUGH symlinks, so /usr/local/bin/gh -> .../gh-sign.sh is
# recognised as this script and skipped rather than re-executed forever.
real_gh() {
  local d c
  IFS=: read -ra _p <<< "$PATH"
  for d in "${_p[@]}"; do
    c="$d/gh"
    [ -x "$c" ] || continue
    [ "$c" -ef "${BASH_SOURCE[0]}" ] && continue
    printf '%s\n' "$c"
    return 0
  done
  return 1
}

# --- which copy is this, and when was it cut? -------------------------------
# Invoked as /usr/local/bin/gh, ${BASH_SOURCE[0]} is the LINK: it names no
# build and has no lib/ beside it. Resolving it needs readlink, which is
# exactly the external this file cannot rely on -- so it does not resolve the
# link, it RECOGNISES itself among the builds, with the same `-ef` inode test
# real_gh() already uses to avoid re-executing itself. Builtins only: a glob,
# `-ef`, and parameter expansion.
#
# This is NOT a second reader of the host pin, and must not become one: it
# never asks which build the host is ON (prop_build_trailer() owns that
# question), only which build this FILE is IN, which the pin cannot answer for
# a copy that is no longer linked.
#
# Sets SELF (the real file) and BUILD_ID (the dated build directory holding
# it), or leaves BUILD_ID empty -- which means this copy is not running from a
# build at all: a checkout, or a hand-placed file. That is reported, never
# guessed at, and never treated as fresh.
SELF="${BASH_SOURCE[0]}"
BUILD_ID=''
locate_self() {
  local r c rest
  for r in $BUILD_ROOTS; do
    for c in "$r"/*/*/bin/gh; do
      [ -f "$c" ] || continue
      [ "$c" -ef "${BASH_SOURCE[0]}" ] || continue
      SELF="$c"; rest="${c#"$r"/}"; BUILD_ID="${rest%%/*}"; return 0
    done
  done
  return 1
}
locate_self || :

# Days since 1970-01-01 from a civil date, in arithmetic only (Howard
# Hinnant's days_from_civil). `date -d` is the obvious way and is the external
# this file may not have; a string comparison of build ids cannot answer "how
# many days", which is the only question worth asking of a channel that is
# supposed to move nightly. `10#` because a build id spells August as `08`,
# and $(( 08 )) is an octal error, not eight.
days_from_civil() {
  local y=$((10#$1)) m=$((10#$2)) d=$((10#$3)) era yoe doy doe
  y=$(( y - (m <= 2) ))
  era=$(( (y >= 0 ? y : y - 399) / 400 ))
  yoe=$(( y - era * 400 ))
  doy=$(( (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1 ))
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  printf '%s' $(( era * 146097 + doe - 719468 ))
}

# Prints the age of this build in days; returns 1 when there is no build id to
# date from. A build id is `2026-08-05T0130Z` (install-verb-build.sh's layout);
# anything else is unreadable, which is BLIND and not zero.
build_age_days() {
  [ -n "$BUILD_ID" ] || return 1
  case "$BUILD_ID" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) ;;
    *) return 1 ;;
  esac
  local TZ=UTC now
  now="$(printf '%(%Y %m %d)T' -1)"
  # shellcheck disable=SC2086  # three fields, deliberately split
  set -- $now
  printf '%s' $(( $(days_from_civil "$1" "$2" "$3") \
                - $(days_from_civil "${BUILD_ID:0:4}" "${BUILD_ID:5:2}" "${BUILD_ID:8:2}") ))
}

# `build <id>` / `build <id> STALE <n>d` / `unbuilt`, for the stamp and for
# --self-check. One reader, so the two can never disagree about freshness.
origin() {
  local age
  [ -n "$BUILD_ID" ] || { printf 'unbuilt'; return 0; }
  age="$(build_age_days)" || { printf 'build %s' "$BUILD_ID"; return 0; }
  if [ "$age" -gt "$STALE_DAYS" ]; then
    printf 'build %s STALE %sd' "$BUILD_ID" "$age"
  else
    printf 'build %s' "$BUILD_ID"
  fi
}

# lib/ sits beside the REAL file, which is why locate_self runs first.
# GH_SIGN_LIB stays as an override for a layout neither branch of that
# predicts; it is a path, not a policy.
GRAMMAR="${GH_SIGN_LIB:-${SELF%/*}/lib}/body-grammar.sh"
grammar_ok=0
# shellcheck source=lib/body-grammar.sh
[ -r "$GRAMMAR" ] && . "$GRAMMAR" && grammar_ok=1

case "${1:-}" in
  --stamp)      stamp; exit 0 ;;
  --check-body)
    [ "$grammar_ok" -eq 1 ] || { printf 'gh-sign: BLIND -- no grammar library at %s\n' "$GRAMMAR" >&2; exit 6; }
    if [ "${2:--}" = - ]; then _b="$(cat)"; else _b="$(cat -- "$2")" || exit 6; fi
    grammar_check "$_b"; _n=$?
    [ "$_n" -eq 0 ] && { echo 'gh-sign: body is well-formed'; exit 0; }
    exit 3 ;;
  --self-check)
    # Exit 1 on a stale build. This is the machine-readable half of the demand
    # -- something that runs on a clock can ask this and get an exit code,
    # rather than grepping the warning out of an agent's stderr.
    if gh_bin="$(real_gh)"; then
      printf 'gh-sign: real gh -> %s\ngh-sign: stamp   -> %s\n' "$gh_bin" "$(stamp)"
      printf 'gh-sign: copy    -> %s (%s)\n' "$SELF" "$(origin)"
      [ "$grammar_ok" -eq 1 ] \
        && printf 'gh-sign: grammar -> %s\n' "$GRAMMAR" \
        || printf 'gh-sign: grammar -> BLIND, none at %s -- creates go unchecked\n' "$GRAMMAR"
      case "$(origin)" in *STALE*) demand_refresh; exit 1 ;; esac
      exit 0
    fi
    echo 'gh-sign: BLIND -- no gh on PATH other than this shim. Every call falls through unsigned.' >&2
    exit 6 ;;
esac

GH="$(real_gh)" || {
  # A verb must be able to introduce itself even where the real gh is absent:
  # cut-verb-build.sh probes `--help` on every command in a build and refuses
  # the whole cut on a bad exit, so a runner without gh would otherwise fail
  # 33 verbs over this one. Any other argv is still 127 -- a caller asking for
  # a GitHub write on a host with no gh has not had it done.
  case "${1:-}" in
    -h|--help|'') usage; exit 0 ;;
  esac
  echo 'gh-sign: no real gh on PATH' >&2
  exit 127
}

# Only these carry a body an agent writes for another agent to read. `pr
# create` is included: a PR body is where a cross-repo handoff usually lands.
signable=0
case "${1:-} ${2:-}" in
  'issue comment'|'issue create'|'issue close'|'pr comment'|'pr create') signable=1 ;;
esac
[ "$signable" -eq 1 ] || exec "$GH" "$@"

# Announced HERE and not on every call: a stale channel is a fact about the
# policy, and the policy only acts on a write. Warning on `gh pr view` too
# would put four lines in front of every read an agent makes, which is how a
# warning stops being read.
case "$(origin)" in *STALE*) demand_refresh ;; esac

# Read the body out of argv, whichever spelling was used. An argv with no body
# at all opens $EDITOR interactively -- a human path, left alone.
body=''; found=0; idx=0; bi=0; kind=''
args=("$@")
# `issue close` spells it --comment; everything else spells it --body. Both
# are the same thing to a reader of the thread, so both get signed.
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --body|-b|--comment|-c) kind=inline; bi=$((i + 1)); idx=$i; found=1 ;;
    --body-file|-F)         kind=path;   bi=$((i + 1)); idx=$i; found=1 ;;
  esac
done
if [ "$found" -ne 1 ] || [ "$bi" -ge "${#args[@]}" ]; then exec "$GH" "$@"; fi

if [ "$kind" = inline ]; then
  body="${args[$bi]}"
elif [ "${args[$bi]}" = '-' ]; then
  body="$(cat)"
else
  body="$(cat -- "${args[$bi]}" 2>/dev/null)" || exec "$GH" "$@"
fi

# Comments are exempt: a DEFERRED block does not belong in a thread reply, and
# refusing one loses the reply. No bypass flag: a documented override turns a
# guard into a toll booth.
case "${1:-} ${2:-}" in
  'issue create'|'pr create')
    if [ "$grammar_ok" -eq 1 ]; then
      if findings="$(grammar_check "$body")"; then :; else
        printf 'gh-sign: REFUSED -- this %s body breaks the grammar in %s:\n' "$1 $2" "$GRAMMAR" >&2
        while IFS= read -r _f; do printf '  %s\n' "$_f" >&2; done <<<"$findings"
        printf 'gh-sign: nothing was created. `gh-sign.sh --check-body <file>` re-runs this check.\n\n' >&2
        grammar_template >&2
        exit 3
      fi
    else
      printf 'gh-sign: BLIND -- no grammar library at %s; body not checked.\n' "$GRAMMAR" >&2
    fi ;;
esac

# Already signed -- by a re-run, or by a body composed from one. Signing twice
# would push the first stamp off the last line and make the marker read as
# body text.
last="$(printf '%s\n' "$body" | grep -v '^[[:space:]]*$' | tail -1)"
case "$last" in
  "$MARKER"*) exec "$GH" "$@" ;;
esac

signed="$(printf '%s\n\n%s' "$body" "$(stamp)")"

# `issue close` has no --comment-file spelling, so that one stays in argv.
# Everything else is handed back on STDIN: a body can exceed ARG_MAX and can
# contain anything, and `--body-file -` is the one spelling with neither
# limit. It also normalises -b/-F/--body/--body-file to a single shape.
case "${args[$idx]}" in
  --comment|-c)
    args[$bi]="$signed"
    exec "$GH" "${args[@]}" ;;
esac
args[$idx]='--body-file'
args[$bi]='-'
printf '%s' "$signed" | "$GH" "${args[@]}"
