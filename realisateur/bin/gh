#!/usr/bin/env bash
# gh-sign.sh -- sign every agent-written GitHub comment/issue AUTOMATICALLY,
# by standing in front of `gh` on PATH.
#
# KIND: verb
#
# TRAPS (the rest of this header is in the vault):
# It appends `<!-- agent: <account>@<host> <ISO8601> -->` to the bodies of
# `issue comment|create|close` and `pr comment|create`, passing everything else
# through untouched. Both fields are read from the running process, so there is
# no argument to get wrong or forget -- it replaced bin/gh-comment.sh, a
# wrapper that had to be called and never was (20 of 403 comments stamped;
# measurement and the GitHub App question: hf7y/realisateur#327).
# AND IT KNOWS HOW OLD IT IS. Propagation can stop, and a shim silently
# enforcing last month's policy is worse than none -- so past STALE_DAYS it
# says so on stderr at every write AND stamps `STALE <n>d` into the body, in
# the artifact where decision-rot.sh reads it rather than a log nobody opens.
# It does NOT refuse: see FAIL OPEN above.
#
# usage: `usage()` below. `gh --help` reaches it only where there is no real gh.

set -uo pipefail

# Both halves are load-bearing. CLAUDECODE alone unsigns every cron script
# calling gh outside an agent, where signing already worked; a TTY alone signs
# an agent that happens to hold one.
human_at_keyboard() {
  [ -z "${CLAUDECODE:-}" ] && [ -z "${CLAUDE_CODE_ENTRYPOINT:-}" ] || return 1
  [ -t 0 ] || [ -t 1 ] || return 1
  return 0
}

MARKER='<!-- agent:'

# How old a build may be before every body it writes is marked STALE. Not a
# new number: bin/verbs-refresh.sh's STALE_DAYS, against a nightly cutter and
# a tick that adopts within 26 hours.
#
#   [rest: vault:realisateur/guard-archaeology-20260817.md]
STALE_DAYS=14
BUILD_ROOTS="${GH_SIGN_BUILD_ROOTS:-/usr/local/share/verb-builds ${XDG_DATA_HOME:-$HOME/.local/share}/verb-builds}"

# BUILT-INS ONLY (`-ef`, `printf %(...)T`): this runs in front of every gh call
# including cron's, with a minimal PATH. An early version shelled out to
# id/hostname/date/readlink; under a stripped PATH all four were "command not
#   [rest: vault:realisateur/guard-archaeology-20260817.md]
stamp() {
  local who
  who="$(id -un 2>/dev/null)" || who="${USER:-${LOGNAME:-?}}"
  TZ=UTC printf '%s %s@%s %(%Y-%m-%dT%H:%M:%SZ)T %s -->\n' \
    "$MARKER" "$who" "${HOSTNAME%%.*}" -1 "$(origin)"
}

# Named commands, not "update your verbs": these accounts have no realisateur
# checkout, and a refusal nobody can act on is a refusal nobody acts on.
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
# Invoked as /usr/local/bin/gh, ${BASH_SOURCE[0]} is the LINK: no build named,
# no lib/ beside it. Resolving it needs readlink, the external this file cannot
#   [rest: vault:realisateur/guard-archaeology-20260817.md]
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
#   [rest: vault:realisateur/guard-archaeology-20260817.md]
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
  # Same no-op as in stamp(), but it moved the DAY: west of UTC every call
  # between local midnight and 00:00Z aged the build one day short.
  local now
  now="$(TZ=UTC printf '%(%Y %m %d)T' -1)"
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
# A human's write passes through whole: unsigned AND ungraded. The grammar is
# a contract between agents, not a rule about how its author may talk.
if [ "$signable" -ne 1 ] || human_at_keyboard; then exec "$GH" "$@"; fi

# Announced HERE, not on every call: the policy only acts on a write, and four
# lines in front of every `gh pr view` is how a warning stops being read.
case "$(origin)" in *STALE*) demand_refresh ;; esac

# Read the body out of argv, whichever spelling. No body at all opens $EDITOR.
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
# refusing one loses the reply. No bypass flag; an override is a toll booth.
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

# Already signed -- by a re-run, or a body composed from one. Signing twice
# pushes the first stamp off the last line, where it reads as body text.
last="$(printf '%s\n' "$body" | grep -v '^[[:space:]]*$' | tail -1)"
case "$last" in
  "$MARKER"*) exec "$GH" "$@" ;;
esac

signed="$(printf '%s\n\n%s' "$body" "$(stamp)")"

# `issue close` has no --comment-file spelling, so it stays in argv. The rest
# go back on STDIN: a body can exceed ARG_MAX and contain anything, and
# `--body-file -` is the one spelling with neither limit.
case "${args[$idx]}" in
  --comment|-c)
    args[$bi]="$signed"
    exec "$GH" "${args[@]}" ;;
esac
args[$idx]='--body-file'
args[$bi]='-'
printf '%s' "$signed" | "$GH" "${args[@]}"
