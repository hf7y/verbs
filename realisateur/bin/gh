#!/usr/bin/env bash
# gh-sign.sh -- sign every agent-written GitHub comment/issue AUTOMATICALLY,
# by standing in front of `gh` on PATH.
#
# KIND: verb
#
# TRAPS (the rest of this header is in the vault):
# It appends `<!-- agent: <account>@<host> <ISO8601> -->` to the bodies of
# `issue comment|create|close`, `pr comment|create` and `api` comment writes.
# Both fields are read from the running process, so there is no argument to
# forget -- it replaced a wrapper that had to be called and mostly was not
# (#327). Past STALE_DAYS it stamps `STALE <n>d`, where decision-rot.sh reads
# it, and it does NOT refuse: see FAIL OPEN.
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

# How old a build may be before every body it writes is marked STALE. Not a new
# number: bin/verbs-refresh.sh's STALE_DAYS. 45 = build-verbs.yml's 30-day
# CUT_INTERVAL_DAYS plus half of slack; at 14 it stamped STALE for ~16 of every
# 30 days (realisateur#603). A LITERAL, not a read of status.json: a network
# read in front of every `gh` call is a new failure mode. The env is the seam.
STALE_DAYS="${GH_SIGN_STALE_DAYS:-45}"
BUILD_ROOTS="${GH_SIGN_BUILD_ROOTS:-/usr/local/share/verb-builds ${XDG_DATA_HOME:-$HOME/.local/share}/verb-builds}"

# BUILT-INS ONLY (`-ef`, `printf %(...)T`): this runs in front of every gh call
# including cron's, with a minimal PATH -- id/hostname/date/readlink were "command not
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
  gh issue close <n>        refused when it closes as completed with nothing
                            landed and nothing said -- see close_check below
  gh --check-body <path>    grade a body; `-` reads stdin
  gh --default-after <f>    read a DECISION body's DEFAULT-AFTER: prints
                            "<days><TAB><action>"; 1 = none (blocks forever)
  gh --delivers             emit this branch's DELIVERS block, derived from
                            what it changes and where propagation-set.sh
                            says each of those lands

Installed as one link per host: /usr/local/bin/gh -> the current verb build.
Never edit that copy -- edit realisateur's bin/gh-sign.sh, which is its one
source, and let the nightly cut carry it (hf7y/realisateur#330).
EOF
}

# The real gh: first on PATH that is not this file AND not another copy of it.
# `-ef` catches only the SAME inode and misses a SECOND copy -- a dev checkout
# beside an installed /usr/local/bin/gh -- so the shim picks the other shim: a
# double hop that drains stdin and posts a blank body. Content, not inode.
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
# it; resolving it needs readlink, the external this file cannot
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
# days_from_civil). `date -d` is the external this file may not have; a string
# comparison of build ids cannot answer "how
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
# id is `2026-08-05T0130Z`; anything else is BLIND, not zero.
build_age_days() {
  [ -n "$BUILD_ID" ] || return 1
  case "$BUILD_ID" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) ;;
    *) return 1 ;;
  esac
  # Same no-op as stamp()'s, but it moved the DAY: west of UTC every call
  # between local midnight and 00:00Z aged the build a day short.
  local now
  now="$(TZ=UTC printf '%(%Y %m %d)T' -1)"
  # shellcheck disable=SC2086  # three fields, deliberately split
  set -- $now
  printf '%s' $(( $(days_from_civil "$1" "$2" "$3") \
                - $(days_from_civil "${BUILD_ID:0:4}" "${BUILD_ID:5:2}" "${BUILD_ID:8:2}") ))
}

# `build <id>` / `build <id> STALE <n>d` / `unbuilt`, for the stamp and
# --self-check: one reader, so the two cannot disagree about freshness.
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
# GH_SIGN_LIB overrides a layout that predicts: a path, not a policy.
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
  --default-after)
    # ONE HOME FOR THE GRAMMAR, reachable by the verb every account has on
    # PATH. scheduler reads DEFAULT-AFTER at dispatch and must not carry a
    # second copy of the parser -- copies produced eleven byte-identical
    # corrupted files and a source 36 lines behind them.
    #
    #   gh --default-after <file|->   prints "<days><TAB><action>"
    #     0  a well-formed default;  1  none, so it BLOCKS FOREVER, a valid
    #     answer and not an error;  6  BLIND, never mistake this for 1
    [ "$grammar_ok" -eq 1 ] || { printf 'gh-sign: BLIND -- no grammar library at %s\n' "$GRAMMAR" >&2; exit 6; }
    if [ "${2:--}" = - ]; then _b="$(cat)"; else _b="$(cat -- "$2")" || exit 6; fi
    grammar_default_after "$_b" || exit 1
    exit 0 ;;
  --delivers)
    # THE ACTUATOR THE DELIVERS LEDGER NEVER HAD. Measured 2026-08-22: DEFERRED
    # is answered honestly 41 of 120 times (34%); DELIVERS, same grammar and
    # same body, 2 of 292 (0.7%) -- `defere` emits the line you paste, this
    # ledger made you hand-write `path:/x on host`. So: derive it from what the
    # branch changed (bin/lib/propagation-set.sh). `- none` stays honest.
    _base="$(git merge-base HEAD "${GH_SIGN_BASE:-origin/main}" 2>/dev/null)" \
      || { printf 'gh-sign: BLIND -- no merge-base with %s; cannot tell what this branch changes.\n' "${GH_SIGN_BASE:-origin/main}" >&2; exit 6; }
    _ps="${GH_SIGN_LIB:-${SELF%/*}/lib}/propagation-set.sh"
    [ -r "$_ps" ] || { printf 'gh-sign: BLIND -- no propagation-set.sh at %s, so nothing can say where a file lands.\n' "$_ps" >&2; exit 6; }
    # shellcheck source=lib/propagation-set.sh
    . "$_ps"
    _host="${GH_SIGN_HOST:-monkey}"
    # A LOCAL-CLASS FILE CAN STILL LAND ON A HOST. prop_host_tools() rides
    # ausculte's probes to /usr/local/libexec/selfdev BY NAME while prop_channel
    # calls them `local` -- deliberately. Reading only the class answered
    # `- none` for three files that deploy: ausculte-cadence.sh,
    # dexter-liveness.sh, decision-rot.sh. Space-delimited so a name matches
    # whole, same idiom as $_seen below.
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
    # A branch that ships nothing is not a finding: non-zero on emptiness
    # alone would train people to skip running it.
    exit 0 ;;
  --self-check)
    # Exit 1 on a stale build: the machine-readable half of the demand, so
    # something on a clock need not grep the warning out of an agent's stderr.
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
  # A verb must introduce itself even where the real gh is absent:
  # cut-verb-build.sh probes `--help` on every command and refuses the whole
  # cut on a bad exit. Any other argv is still 127 -- a caller asking for a
  # GitHub write on a host with no gh has not had it done.
  case "${1:-}" in
    -h|--help|'') usage; exit 0 ;;
  esac
  echo 'gh-sign: no real gh on PATH' >&2
  exit 127
}

# Only these carry a body an agent writes for another agent to read; a PR body
# is where a cross-repo handoff lands.
signable=0
case "${1:-} ${2:-}" in
  'issue comment'|'issue create'|'issue close'|'pr comment'|'pr create') signable=1 ;;
esac

# `gh api` IS THE SAME WRITE BY ANOTHER ROUTE: a comment posted that way came
# out UNSTAMPED and decision-rot read it as Zach's (2026-08-21).
api_comment=0
if [ "${1:-}" = api ]; then
  for _a in "$@"; do
    case "$_a" in
      */issues/*/comments|*/pulls/*/comments|*/issues/comments/*) api_comment=1 ;;
    esac
  done
  [ "$api_comment" -eq 1 ] && signable=1
fi
# A human's write passes through whole, unsigned AND ungraded: the grammar is
# a contract between agents, not a rule about how its author may talk.
if [ "$signable" -ne 1 ] || human_at_keyboard; then exec "$GH" "$@"; fi

# Announced HERE, not on every call: four lines in front of every `gh pr view`
# is how a warning stops being read.
case "$(origin)" in *STALE*) demand_refresh ;; esac

# CLOSED HAVING LANDED NOTHING -- 317 of 936 agent-filed closed issues, 33.9%,
# the largest class this estate has measured and NOTHING ANYWHERE LOOKED
# (#752; #294 named it in 2026-08-15 and its point 1 was never built).
# NOT A BAN -- most closes owe no diff. Four honest ways past it, and #778
# carries the measurement behind each: `--reason "not planned"`, a `#N` or a
# commit in the comment, a typed `path:` claim, a `DECISION:` body. Replayed
# over 1,348 real closes it refuses 49, 10 of the 968 since the stamp exists;
# 7 of those 8 in-scope say in their own words that nothing was done.
# FAIL OPEN ON EVERYTHING -- no grammar, no number, no API, no answer, no
# refusal. Refusing closes when GitHub is slow wedges 18 accounts.
close_check() {
  local comment="$1" i skip=0 sel='' reason='' out url rest o r n body landed
  local -a view=()

  [ "$grammar_ok" -eq 1 ] || return 0

  for ((i = 2; i < ${#args[@]}; i++)); do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "${args[$i]}" in
      -r|--reason)   reason="${args[$((i + 1))]:-}"; skip=1 ;;
      --reason=*)    reason="${args[$i]#--reason=}" ;;
      -R|--repo)     view=(--repo "${args[$((i + 1))]:-}"); skip=1 ;;
      --repo=*)      view=(--repo "${args[$i]#--repo=}") ;;
      -c|--comment)  skip=1 ;;
      --comment=*)   comment="${args[$i]#--comment=}" ;;
      -*)            ;;
      *)             [ -n "$sel" ] || sel="${args[$i]}" ;;
    esac
  done

  # NOT_PLANNED today, DUPLICATE next, without an edit here: only a COMPLETED
  # close claims something was done.
  case "${reason,,}" in ''|completed) ;; *) return 0 ;; esac

  grammar_landing_ref "$comment" >/dev/null && return 0
  [ -n "$sel" ] || return 0

  # `gh issue view` resolves the repo exactly as `gh issue close` just did, so
  # this never reimplements that; one call also answers what line 1 declares.
  out="$("$GH" issue view "$sel" "${view[@]}" --json url,body --jq '.url, .body' 2>/dev/null)" || return 0
  url="${out%%$'\n'*}"
  body="${out#*$'\n'}"
  case "$url" in *://*/*/*/issues/[0-9]*) ;; *) return 0 ;; esac

  [ "$(grammar_declaration "$body")" = decision ] && return 0   # closes on an answer

  n="${url##*/}"; rest="${url%/issues/*}"
  r="${rest##*/}"; rest="${rest%/*}"; o="${rest##*/}"
  landed="$("$GH" api "repos/$o/$r/issues/$n/timeline?per_page=100" --paginate --jq \
    '.[] | select(.commit_id != null or (.event == "cross-referenced" and .source.issue.pull_request.merged_at != null)) | "landed"' \
    2>/dev/null)" || return 0
  [ -n "$landed" ] && return 0

  printf 'gh-sign: REFUSED -- closing %s/%s#%s as completed, and nothing says what landed.\n' "$o" "$r" "$n" >&2
  printf 'gh-sign: No merged pull request and no commit reference it, and this close names\n' >&2
  printf 'gh-sign: nothing a check could go and look at. Nothing was closed.\n\n' >&2
  printf '  +-- ANY ONE OF THESE CLOSES IT --------------------------------\n' >&2
  printf '  | gh issue close %s --reason "not planned"\n' "$sel" >&2
  printf '  | gh issue close %s --comment "closed by %s/%s#<n>"\n' "$sel" "$o" "$r" >&2
  printf '  | gh issue close %s --comment "landed as path:/usr/local/bin/<verb> on <host>"\n' "$sel" >&2
  printf '  +--------------------------------------------------------------\n\n' >&2
  printf 'gh-sign: 317 of 936 agent-filed closed issues closed with nothing landed and\n' >&2
  printf 'gh-sign: nothing said -- 33.9%%, the largest class measured (hf7y/realisateur#752).\n' >&2
  exit 7
}

# Read the body out of argv, whichever spelling; no body at all opens $EDITOR.
body=''; found=0; idx=0; bi=0; kind=''
args=("$@")
# `issue close` spells it --comment, everything else --body: the same thing to
# a reader of the thread, so both get signed.
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --body|-b|--comment|-c) kind=inline; bi=$((i + 1)); idx=$i; found=1 ;;
    --body-file|-F)         kind=path;   bi=$((i + 1)); idx=$i; found=1 ;;
  esac
done
# `gh api` spells it body=<text>/body=@<file> in ONE word: -F is a field here.
bflag=-1
if [ "$api_comment" -eq 1 ]; then
  found=0
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
      body=@*)  kind=api_path; bi=$i; idx=$i; found=1; bflag=$((i - 1)) ;;
      body=*)   kind=api_inline; bi=$i; idx=$i; found=1; bflag=$((i - 1)) ;;
    esac
  done
fi
# Graded BEFORE the no-body bail-out: a close with no --comment at all is the
# very case the guard is for, and used to exit here unseen.
if [ "$found" -ne 1 ] || [ "$bi" -ge "${#args[@]}" ]; then
  case "${1:-} ${2:-}" in 'issue close') close_check '' ;; esac
  exec "$GH" "$@"
fi

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

# Comments are exempt; no bypass flag, an override is a toll booth.
case "${1:-} ${2:-}" in
  'issue create'|'pr create')
    if [ "$grammar_ok" -eq 1 ]; then
      if findings="$(grammar_check "$body")"; then :; else
        # DOOR FIRST, FINDING LAST, EXAMPLE FENCED BETWEEN: the other order
        # meant `tail` saw the example and never the finding (#627).
        printf 'gh-sign: REFUSED -- this %s body breaks the grammar in %s.\n' "$1 $2" "$GRAMMAR" >&2
        printf 'gh-sign: `defere` composes a valid body; `gh-sign.sh --check-body <file>` re-runs this check.\n' >&2
        printf 'gh-sign: nothing was created.\n\n' >&2
        printf '  +-- EXAMPLE BODY -- an illustration, NOT state of any repo ---\n' >&2
        grammar_template | while IFS= read -r _t; do printf '  | %s\n' "$_t" >&2; done
        printf '  +------------------------------------------------------------\n\n' >&2
        printf 'gh-sign: what is wrong with YOUR body:\n' >&2
        while IFS= read -r _f; do printf '  %s\n' "$_f" >&2; done <<<"$findings"
          exit 7
      fi
    else
      printf 'gh-sign: BLIND -- no grammar library at %s; body not checked.\n' "$GRAMMAR" >&2
    fi ;;
  'issue close') close_check "$body" ;;
esac

# Already signed. Signing twice pushes the first stamp off the last line.
last="$(printf '%s\n' "$body" | grep -v '^[[:space:]]*$' | tail -1)"
case "$last" in
  "$MARKER"*) exec "$GH" "$@" ;;
esac

signed="$(printf '%s\n\n%s' "$body" "$(stamp)")"

# `issue close` has no --comment-file spelling, so it stays in argv. The rest
# go on STDIN: `--body-file -` is the one spelling with no ARG_MAX limit.
case "$kind" in
  api_inline|api_path)
    # `-f/--raw-field` has no `@file`/`@-` magic -- only `-F/--field` does.
    # Rewriting to `body=@-` behind a bare `-f` sends the literal `@-` as the
    # body: a comment posted, its content silently replaced. Upgrade the flag.
    if [ "$bflag" -ge 0 ]; then
      case "${args[$bflag]}" in
        -f)          args[$bflag]='-F' ;;
        --raw-field) args[$bflag]='--field' ;;
      esac
    fi
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
