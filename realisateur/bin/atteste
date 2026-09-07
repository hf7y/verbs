#!/usr/bin/env bash
# atteste.sh -- does what a body CLAIMS to deliver actually exist? (#791, #803)
# RUNNER: .github/workflows/atteste.yml -- daily; REPORTING-ONLY, red on GAP only
# GUARD-TEST: bin/tests/atteste.test.sh -- offline behind --body and ATTESTE_GH
# GATE: none -- it reads the GitHub API, which this suite's sandbox denies.
#
# Every other guard here checks a claim's FORM; this one goes and looks. An
# entry it cannot check is BLIND, never a pass. #803 has the measurements.
set -uo pipefail

CLI_NAME='atteste.sh'
CLI_SUMMARY='does what this issue, PR or body claims to DELIVER actually exist?'
CLI_USAGE='  atteste.sh <owner/repo#n|url>...  grade the DELIVERS entries of each
                                   against GitHub: a merged PR at its merge
                                   commit, an open PR at its head, an issue at
                                   the default branch. A PR is also graded
                                   against the DELIVERS of every issue it
                                   closes -- its own block can be a subset.
  atteste.sh --body <file>         grade a body against THIS working tree
                                   before you file it ("-" reads stdin)
  DELETED, GONE or RETIRED in an entry inverts it: being there is the GAP.'
CLI_FLAGS='--body'
CLI_POSITIONAL=subject
CLI_EXITS='  0  every entry that could be checked was SATISFIED, and at least one was
  4  GAP: a typed claim names something that is not there
  6  BLIND: an entry could not be checked and none was a GAP. NEVER clean.'
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$HERE/lib/cli-guard.sh"
cli_guard "$@"
. "$HERE/lib/body-grammar.sh"
. "$HERE/lib/host-check.sh"

GH="${ATTESTE_GH:-gh}"
KINDS='host path clock tag secret unit port repo'

CLOSING_Q='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){closingIssuesReferences(first:20){nodes{number repository{nameWithOwner}}}}}}'  # GraphQL-only: REST has no equivalent field

# `on <word>` is a HOST only when the word is a name: "on this repo's default
# branch" is 13 of 240 path: entries.
NOT_A_HOST=' this the a an every all each its any both either other same '

# Markdown and sentence punctuation: 37 claims read MISSING on that alone.
clean() {
  local v="${1//\`/}"
  v="${v%%,*}"
  while :; do case "$v" in *[.,\;:\)\"\']) v="${v%?}" ;; *) break ;; esac; done
  printf '%s' "$v"
}

# repo_path <repo> <ref> <path> -- 0 exists, 1 absent, 2 COULD NOT TELL. The
# third is the point: `gh api` fails the same for "no file" and "GitHub down".
repo_path() {
  local repo="$1" ref="$2" p="$3" q='' out rc
  [ -n "$ref" ] && [ "$ref" != - ] && q="?ref=$ref"
  out="$("$GH" api "repos/$repo/contents/$p$q" 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] && return 0
  case "$out" in
    *'HTTP 404'*|*'Not Found'*)
      # A repo this token cannot SEE 404s exactly like an absent file.
      "$GH" api "repos/$repo" >/dev/null 2>&1 || return 2
      return 1 ;;
  esac
  return 2
}

# A PR's changed files, "status<TAB>filename". `path:` says WHERE, never
# WHETHER, so only the diff separates "delivered X" from "deleted X".
PRFILES=''

satisfied=0; gaps=0; blind=0; claimed=0
say() { printf '  %-9s %s\n' "$1" "$2"; }
sat()  { satisfied=$((satisfied + 1)); say SATISFIED "$1"; }
gap()  { gaps=$((gaps + 1));           say GAP "$1"; }
dark() { blind=$((blind + 1));         say BLIND "$1"; }

# grade <entry> <default-repo> <ref> <mode>
# mode: gh = look in <default-repo> at <ref>; tree = look in $ROOT on disk.
grade() {
  local entry="$1" drepo="$2" ref="$3" mode="$4"
  local words=() w i k v e_path='' e_repo='' e_other='' host='' found=0 gone=0 gonew
  local IFS=$' \t\n'
  read -ra words <<<"$entry"

  # ABSENCE PROVES A RETIREMENT (#872, #878). Not `.`: it splits retired.md.
  gonew=" ${entry^^} "; gonew="${gonew//[,;:()\`]/ }"
  case "$gonew" in *' DELETED '*|*' GONE '*|*' RETIRED '*) gone=1 ;; esac

  case "${entry,,}" in none|none.|'none '*) return 0 ;; esac
  claimed=$((claimed + 1))

  for ((i = 0; i < ${#words[@]}; i++)); do
    w="${words[i]}"; w="${w#\`}"
    for k in $KINDS; do
      case "$w" in
        "$k":?*) v="$(clean "${w#"$k":}")" ;;
        "$k":)   v="$(clean "${words[i + 1]:-}")" ;;
        *)       continue ;;
      esac
      found=1
      case "$k" in
        path) [ -n "$e_path" ] || e_path="$v" ;;
        repo) [ -n "$e_repo" ] || e_repo="$v" ;;
        *)    [ -n "$e_other" ] || e_other="$k:$v" ;;
      esac
    done
    if [ "$w" = on ] && [ -z "$host" ]; then
      v="$(clean "${words[i + 1]:-}")"
      case "$NOT_A_HOST" in *" ${v,,} "*) ;; *) [ -n "$v" ] && host="$v" ;; esac
    fi
  done

  if [ "$found" -eq 0 ]; then
    dark "UNTYPED -- names no <kind>:<value>, so there is nothing to look for: ${entry:0:60}"
    return 0
  fi

  if [ -z "$e_path" ]; then
    if [ -n "$e_other" ]; then
      dark "${e_other} needs the host it names, and ${e_other%%:*}: is under 1% of all entries measured -- no predicate was written for it"
    elif [ "$gone" -eq 1 ] && [ -n "$e_repo" ]; then
      case "$e_repo" in
        */*) if "$GH" api "repos/$e_repo" >/dev/null 2>&1
             then gap "repo:$e_repo is claimed GONE and the API still answers for it"
             else sat "repo:$e_repo does not answer -- gone, as claimed"; fi ;;
        *)   dark "repo:$e_repo is not an owner/repo, so nothing was asked" ;;
      esac
    else
      dark "repo:${e_repo:-?} alone -- a repo that already exists proves no delivery. Name the path, unit or clock inside it."
    fi
    return 0
  fi

  # A path with a leading / or ~, or one declared `on <host>`, is a HOST path.
  case "$e_path" in
    /*|'~'/*)
      if [ -z "$host" ]; then
        dark "path:$e_path names an absolute path and no host, so no machine was asked"
      elif on_target_host "$host"; then
        if [ -e "${e_path/#\~/$HOME}" ]; then
          if [ "$gone" -eq 1 ]; then gap "path:$e_path is claimed GONE and still exists on $host"
          else sat "path:$e_path exists on $host"; fi
        elif [ "$gone" -eq 1 ]; then sat "path:$e_path is gone from $host, as claimed"
        else gap "path:$e_path is absent on $host, and this run IS $host"; fi
      else
        dark "path:$e_path on $host -- this run is not $host, so nothing looked"
      fi
      return 0 ;;
  esac
  if [ -n "$host" ]; then
    dark "path:$e_path on $host -- a host path written relative; only $host can answer it"
    return 0
  fi
  case "$e_path" in
    *:*) dark "path:$e_path is a git ref, not a path in one tree -- not resolved from here"; return 0 ;;
    */)  e_path="${e_path%/}" ;;
  esac

  if [ "$mode" = tree ]; then
    if [ -e "$ROOT/$e_path" ]; then
      if [ "$gone" -eq 1 ]; then gap "path:$e_path is claimed GONE and is still in this tree"
      else sat "path:$e_path is in this tree"; fi
    elif [ "$gone" -eq 1 ]; then sat "path:$e_path is gone from this tree, as claimed"
    else gap "path:$e_path is NOT in this tree ($ROOT)"; fi
    return 0
  fi

  local repo="${e_repo:-$drepo}"
  case "$repo" in */*) ;; *) dark "path:$e_path -- '$repo' is not an owner/repo, so no tree was searched"; return 0 ;; esac
  # A REF BELONGS TO ONE REPO: this subject's merge sha does not exist in
  # another, so the API 404s the REF. 4 of the first 8 gaps were that bug.
  [ "$repo" = "$drepo" ] || ref=''
  repo_path "$repo" "$ref" "$e_path"
  case $? in
    0) if [ "$gone" -eq 1 ]
       then gap "path:$e_path is claimed GONE and is still in $repo at ${ref:--default-}"
       else sat "path:$e_path is in $repo at ${ref:--default-}"; fi ;;
    1) [ "$gone" -eq 1 ] && { sat "path:$e_path is gone from $repo, as claimed"; return 0; }
       # `path:` ALONE CANNOT SAY WHICH: all 5 gaps over 110 PRs were paths the
       # PR DELETED and did not say so. Ask the diff before a gap.
       case "$PRFILES" in
         *"removed	$e_path"$'\n'*)
           sat "path:$e_path was RETIRED by this change and is gone from $repo"; return 0 ;;
       esac
       # A DOMAIN IS NOT A DIRECTORY: #611 delivers `hf7y.com/monkey/x.json`,
       # a page. A leading dot spares `.github`; the slash spares `gardien.py`.
       case "$e_path" in
         .*) gap "path:$e_path is NOT in $repo at ${ref:--default-}" ;;
         *.*/*) dark "path:$e_path -- '${e_path%%/*}' reads as a domain or another namespace, not a directory in $repo" ;;
         *) gap "path:$e_path is NOT in $repo at ${ref:--default-}" ;;
       esac ;;
    *) dark "path:$e_path in $repo -- the contents API could not be read, so this is not a miss" ;;
  esac
}

# --- subjects ---------------------------------------------------------------
MODE=gh; BODYFILE=''; subjects=()
while [ $# -gt 0 ]; do
  case "$1" in
    --body) MODE=tree; BODYFILE="${2:-}"; [ -n "$BODYFILE" ] || cli_die "--body needs a file ('-' for stdin)"; shift ;;
    -*) cli_die "unknown flag: $1" ;;
    *) subjects+=("$1") ;;
  esac
  shift
done

echo "== atteste -- what these bodies say they deliver, looked up =="

if [ "$MODE" = tree ]; then
  [ "${#subjects[@]}" -eq 0 ] || cli_die "--body grades one body; it takes no subjects"
  ROOT="${ATTESTE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
  [ -n "$ROOT" ] && [ -d "$ROOT" ] || {
    printf '%s: BLIND -- no working tree to look in (set ATTESTE_ROOT). Nothing was checked.\n' "$CLI_NAME" >&2; exit 6; }
  if [ "$BODYFILE" = - ]; then body="$(cat)"; else body="$(cat -- "$BODYFILE")" || {
    printf '%s: BLIND -- cannot read %s. Nothing was checked.\n' "$CLI_NAME" "$BODYFILE" >&2; exit 6; }; fi
  printf -- '-- %s, against %s\n' "$BODYFILE" "$ROOT"
  if entries="$(grammar_delivers "$body")"; then
    while IFS= read -r e; do [ -n "$e" ] && grade "$e" '' '' tree; done <<<"$entries"
  else
    dark 'no DELIVERS block at all -- body-grammar.sh would refuse this body at the write'
  fi
else
  [ "${#subjects[@]}" -gt 0 ] || cli_die "name at least one owner/repo#n or issue/pull URL"
  for s in "${subjects[@]}"; do
    o=''; r=''; n=''
    case "$s" in
      *://*/*/*/issues/[0-9]*|*://*/*/*/pull/[0-9]*)
        n="${s##*/}"; rest="${s%/*}"; rest="${rest%/*}"
        r="${rest##*/}"; o="${rest%/*}"; o="${o##*/}" ;;
      */*'#'[0-9]*)
        n="${s##*#}"; rest="${s%%#*}"; r="${rest##*/}"; o="${rest%/*}" ;;
    esac
    case "$n" in ''|*[!0-9]*) o='' ;; esac
    [ -n "$o" ] && [ -n "$r" ] || { dark "$s is not owner/repo#n or an issue/pull URL, so nothing was fetched"; continue; }

    if ! out="$("$GH" api "repos/$o/$r/issues/$n" --jq '(.pull_request.url // "-"), .body' 2>/dev/null)"; then
      dark "$o/$r#$n could not be read from GitHub, so its claims were NOT checked"; continue
    fi
    ispr="${out%%$'\n'*}"; body="${out#*$'\n'}"

    ref=''; what='issue, graded at the default branch'
    if [ "$ispr" != - ]; then
      if pr="$("$GH" api "repos/$o/$r/pulls/$n" --jq '(if .merged then "merged" else "open" end), (.merge_commit_sha // "-"), (.head.sha // "-")' 2>/dev/null)"; then
        st="$(printf '%s' "$pr" | sed -n 1p); "; st="${st%; }"
        mc="$(printf '%s' "$pr" | sed -n 2p)"; hs="$(printf '%s' "$pr" | sed -n 3p)"
        # MERGE COMMIT, NOT HEAD: #675 delivered BUILD-DISCIPLINE.md, #684
        # purged it; at HEAD that true claim would read as a lie.
        if [ "$st" = merged ]; then ref="$mc"; what="merged PR, graded at merge commit ${mc:0:8}"
        else ref="$hs"; what="unmerged PR, graded at its head ${hs:0:8}"; fi
      else
        what='PR whose state could not be read; graded at the default branch'
      fi
    fi
    PRFILES=''
    if [ "$ispr" != - ]; then
      PRFILES="$("$GH" api "repos/$o/$r/pulls/$n/files?per_page=100" --paginate \
        --jq '.[] | .status + "\t" + .filename' 2>/dev/null)"$'\n'
    fi
    printf -- '-- %s/%s#%s (%s)\n' "$o" "$r" "$n" "$what"
    if entries="$(grammar_delivers "$body")"; then
      while IFS= read -r e; do [ -n "$e" ] && grade "$e" "$o/$r" "$ref" gh; done <<<"$entries"
    else
      dark "$o/$r#$n carries no DELIVERS block, so it claims nothing a check could follow"
    fi

    if [ "$ispr" != - ]; then  # #872: a PR's block can be a SUBSET of what it closes (scheduler#454/#456 graded clean, 2 of 3 unreached) -- grade the closed issues' claims too, at the same ref
      closing="$("$GH" api graphql -f query="$CLOSING_Q" -F owner="$o" -F repo="$r" -F number="$n" \
        --jq '.data.repository.pullRequest.closingIssuesReferences.nodes[] | .repository.nameWithOwner + "#" + (.number|tostring)' 2>/dev/null)"
      while IFS= read -r cs; do
        [ -n "$cs" ] || continue
        case "$cs" in
          */*'#'[0-9]*) cn="${cs##*#}"; crest="${cs%%#*}"; cr="${crest##*/}"; co="${crest%/*}" ;;
          *) dark "$cs -- closingIssuesReferences returned something unparseable"; continue ;;
        esac
        if cbody="$("$GH" api "repos/$co/$cr/issues/$cn" --jq .body 2>/dev/null)"; then
          iref="$ref"; [ "$co/$cr" = "$o/$r" ] || iref=''  # a ref belongs to one repo, same as any cross-repo path:
          printf -- '-- closes %s/%s#%s\n' "$co" "$cr" "$cn"
          if centries="$(grammar_delivers "$cbody")"; then
            while IFS= read -r ce; do [ -n "$ce" ] && grade "$ce" "$co/$cr" "$iref" gh; done <<<"$centries"
          else
            dark "$co/$cr#$cn (closed by this PR) carries no DELIVERS block"
          fi
        else
          dark "$co/$cr#$cn (closed by this PR) could not be read from GitHub, so its claims were NOT checked"
        fi
      done <<<"$closing"
    fi
  done
fi

echo
printf 'checked %d claim(s): %d satisfied, %d gap(s), %d blind.\n' "$claimed" "$satisfied" "$gaps" "$blind"
if [ "$gaps" -gt 0 ]; then
  echo 'GAP -- a body names a delivery that is not there. Named above.'
  exit 4
fi
if [ "$blind" -gt 0 ] || [ "$satisfied" -eq 0 ]; then
  echo 'BLIND -- something could not be looked up. This is NOT "the claims hold".'
  exit 6
fi
echo 'Every claim that could be checked holds.'
exit 0
