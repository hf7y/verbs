#!/usr/bin/env bash
# gh-sign.sh -- sign every agent-written GitHub comment/issue AUTOMATICALLY,
# by standing in front of `gh` on PATH.
#
# KIND: verb
#
# TRAPS (the rest of this header is in the vault):
# It appends `<!-- agent: <account>@<host> <ISO8601> -->` to the bodies of
# `issue comment|create|close`, `pr comment|create`, and `api` comment
# writes, passing everything else through untouched. Both fields
# are read from the running process, so there is no argument to forget -- it
# replaced a wrapper that had to be called and mostly was not (#327).
# AND IT KNOWS HOW OLD IT IS: past STALE_DAYS it stamps `STALE <n>d` into the
# body, where decision-rot.sh reads it. It does NOT refuse: see FAIL OPEN.
#
# usage: `usage()` below. `gh --help` reaches it only where there is no real gh.

set -uo pipefail

# Both halves load-bearing: CLAUDECODE alone unsigns cron's gh calls, a TTY
# alone signs an agent holding one.
human_at_keyboard() {
  [ -z "${CLAUDECODE:-}" ] && [ -z "${CLAUDE_CODE_ENTRYPOINT:-}" ] || return 1
  [ -t 0 ] || [ -t 1 ] || return 1
  return 0
}

MARKER='<!-- agent:'

# How old a build may be before every body it writes is marked STALE. Not a
# new number: bin/verbs-refresh.sh's STALE_DAYS.
#
STALE_DAYS=14
BUILD_ROOTS="${GH_SIGN_BUILD_ROOTS:-/usr/local/share/verb-builds ${XDG_DATA_HOME:-$HOME/.local/share}/verb-builds}"

# BUILT-INS ONLY (`-ef`, `printf %(...)T`): this runs in front of every gh
# call including cron's, with a minimal PATH. Shelling out to
# id/hostname/date/readlink made all four "command not
stamp() {
  local who
  who="$(id -un 2>/dev/null)" || who="${USER:-${LOGNAME:-?}}"
  TZ=UTC printf '%s %s@%s %(%Y-%m-%dT%H:%M:%SZ)T %s -->\n' \
    "$MARKER" "$who" "${HOSTNAME%%.*}" -1 "$(origin)"
}

# Named commands, not "update your verbs": the accounts have no checkout.
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
  gh --delivers             emit this branch's DELIVERS block, derived from
                            what it changes and where propagation-set.sh
                            says each of those lands

Installed as one link per host: /usr/local/bin/gh -> the current verb build.
Never edit that copy -- edit realisateur's bin/gh-sign.sh, which is its one
source, and let the nightly cut carry it (hf7y/realisateur#330).
EOF
}

# The real gh: first on PATH that is not this file AND not another copy of
# it. `-ef` alone only catches the SAME inode (the /usr/local/bin/gh link
# back to this exact build); it misses a SECOND copy -- a dev checkout run
# as `bash bin/gh-sign.sh` while /usr/local/bin/gh is a distinct installed
# copy of the same script. `-ef` then says "different file" and this shim
# picks the other shim as "real gh": a double hop whose second layer reads
# an already-`cat`-drained stdin and posts a blank body. The content check
# catches any copy, byte-identical or not.
real_gh() {
  local d c
  IFS=: read -ra _p <<< "$PATH"
  for d in "${_p[@]}"; do
    c="$d/gh"
    [ -x "$c" ] || continue
    [ "$c" -ef "${BASH_SOURCE[0]}" ] && continue
    grep -qaF '# gh-sign.sh -- sign every agent-written GitHub' "$c" 2>/dev/null && continue
    printf '%s\n' "$c"
    return 0
  done
  return 1
}

# --- which copy is this, and when was it cut? -------------------------------
# Invoked as the link, ${BASH_SOURCE[0]} names no build and has no lib/ beside
# it. Resolving it needs readlink, the external this file cannot
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

# Days since 1970-01-01 from a civil date, arithmetic only (Hinnant's
# days_from_civil). `date -d` is the external this file may not have, and a
# string comparison of build ids cannot answer "how
days_from_civil() {
  local y=$((10#$1)) m=$((10#$2)) d=$((10#$3)) era yoe doy doe
  y=$(( y - (m <= 2) ))
  era=$(( (y >= 0 ? y : y - 399) / 400 ))
  yoe=$(( y - era * 400 ))
  doy=$(( (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1 ))
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  printf '%s' $(( era * 146097 + doe - 719468 ))
}

# Age of this build in days; returns 1 with no build id to date from. A build
# id is `2026-08-05T0130Z` (install-verb-build.sh's layout);
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
    # Asked to look and found something: 1. It creates nothing to refuse.
    [ "$_n" -eq 0 ] && { echo 'gh-sign: body is well-formed'; exit 0; }
    exit 1 ;;
  --delivers)
    # THE ACTUATOR THE DELIVERS LEDGER NEVER HAD.
    #
    # Measured 2026-08-22: DEFERRED is answered honestly 41 of 120 times (34%);
    # DELIVERS, with the SAME grammar, the SAME enforcement and the same block
    # in the same body, 2 of 292 (0.7%). Fifty times worse, and the only
    # difference is that `defere` emits the line you paste and this ledger made
    # you hand-write `path:/x on host` and then audited you for it.
    #
    # So the fix is not a stricter check. It is this: derive the answer from
    # what the branch actually changed, using the dev/prod contract that
    # already decides where every file lands (bin/lib/propagation-set.sh), and
    # print the block. `- none` stays the honest answer for a branch that
    # ships nothing outward -- it just stops being the ONLY cheap one.
    _base="$(git merge-base HEAD "${GH_SIGN_BASE:-origin/main}" 2>/dev/null)" \
      || { printf 'gh-sign: BLIND -- no merge-base with %s; cannot tell what this branch changes.\n' "${GH_SIGN_BASE:-origin/main}" >&2; exit 6; }
    _ps="${GH_SIGN_LIB:-${SELF%/*}/lib}/propagation-set.sh"
    [ -r "$_ps" ] || { printf 'gh-sign: BLIND -- no propagation-set.sh at %s, so nothing can say where a file lands.\n' "$_ps" >&2; exit 6; }
    # shellcheck source=lib/propagation-set.sh
    . "$_ps"
    _host="${GH_SIGN_HOST:-monkey}"
    # A LOCAL-CLASS FILE CAN STILL LAND ON A HOST. prop_host_tools() rides
    # ausculte's probes to /usr/local/libexec/selfdev BY NAME, while
    # prop_channel goes on calling them `local` -- deliberately, per
    # propagation-set.sh: "or it is BLIND about them on a host". Reading only
    # the class made this actuator answer `- none` for three files that
    # demonstrably deploy: ausculte-cadence.sh, dexter-liveness.sh,
    # decision-rot.sh. Space-delimited so a name matches whole, same idiom as
    # $_seen below.
    _ht=' '
    while IFS= read -r _t; do [ -n "$_t" ] && _ht="$_ht$_t "; done <<EOF
$(prop_host_tools 2>/dev/null)
EOF
    printf '<!-- DELIVERS -->\n'
    _n=0; _seen=''
    while IFS= read -r _f; do
      [ -n "$_f" ] || continue
      _b="${_f##*/}"
      case " $_seen " in *" $_b "*) continue ;; esac
      _seen="$_seen $_b"
      _ch="$(prop_channel "$_b" 2>/dev/null)" || continue
      case "$_ch" in
        payload)    # The verb name is NOT the basename: gh-sign.sh installs as `gh`.
                    # bin/lib/carries.tsv is the one table that maps carried
                    # path to source, so it answers this instead of a guess.
                    _v="$(awk -F'\t' -v s="bin/$_b" '$2==s{n=$1; sub(/^bin\//,"",n); print n; exit}' \
                          "${GH_SIGN_LIB:-${SELF%/*}/lib}/carries.tsv" 2>/dev/null)"
                    [ -n "$_v" ] || _v="${_b%.sh}"
                    printf -- '- path:/usr/local/bin/%s on %s\n' "$_v" "$_host"; _n=$((_n+1)) ;;
        bootstrap|provision)
                    printf -- '- path:/usr/local/libexec/selfdev/%s on %s\n' "$_b" "$_host"; _n=$((_n+1)) ;;
        local)      case "$_ht" in
                      *" $_b "*) printf -- '- path:/usr/local/libexec/selfdev/%s on %s\n' "$_b" "$_host"; _n=$((_n+1)) ;;
                    esac ;;
      esac
    done <<EOF
$(git diff --name-only "$_base" 2>/dev/null; git diff --name-only --cached "$_base" 2>/dev/null)
EOF
    [ "$_n" -gt 0 ] || printf -- '- none\n'
    printf '<!-- /DELIVERS -->\n'
    # A branch that ships nothing is not a finding, so this is never non-zero
    # on emptiness alone -- that would train people to skip running it.
    exit 0 ;;
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

# `gh api` IS THE SAME WRITE BY ANOTHER ROUTE and was not covered: a comment
# posted that way came out UNSTAMPED, indistinguishable from a human's --
# decision-rot's KNOWN GAP, which on 2026-08-21 read such comments as Zach's.
api_comment=0
if [ "${1:-}" = api ]; then
  for _a in "$@"; do
    case "$_a" in
      */issues/*/comments|*/pulls/*/comments|*/issues/comments/*) api_comment=1 ;;
    esac
  done
  [ "$api_comment" -eq 1 ] && signable=1
fi
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
# `gh api` spells it body=<text>/body=@<file> in ONE word: -F is a field here.
if [ "$api_comment" -eq 1 ]; then
  found=0
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
      body=@*)  kind=api_path; bi=$i; idx=$i; found=1 ;;
      body=*)   kind=api_inline; bi=$i; idx=$i; found=1 ;;
    esac
  done
fi
if [ "$found" -ne 1 ] || [ "$bi" -ge "${#args[@]}" ]; then exec "$GH" "$@"; fi

if [ "$kind" = api_inline ]; then
  body="${args[$bi]#body=}"
elif [ "$kind" = api_path ]; then
  _f="${args[$bi]#body=@}"
  [ "$_f" = '-' ] && body="$(cat)" || { body="$(cat -- "$_f" 2>/dev/null)" || exec "$GH" "$@"; }
elif [ "$kind" = inline ]; then
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
        # WON'T DO: the shim declined to create it.
        exit 7
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
case "$kind" in
  api_inline|api_path)
    # NOT `| exec`: that is a SUBSHELL, and the parent invoked gh twice.
    args[$bi]='body=@-'
    printf '%s' "$signed" | "$GH" "${args[@]}"
    exit $? ;;
esac
case "${args[$idx]}" in
  --comment|-c)
    args[$bi]="$signed"
    exec "$GH" "${args[@]}" ;;
esac
args[$idx]='--body-file'
args[$bi]='-'
printf '%s' "$signed" | "$GH" "${args[@]}"
