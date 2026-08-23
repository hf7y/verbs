#!/usr/bin/env bash
# defere.sh -- file the thing you were about to write a paragraph about.
#
# KIND: verb
#
# TRAP: "no owner" may NOT silently mean Zach. There are three routing
#   states and refusing to choose is a usage error, not a quiet default.
# TRAP: a project that does not resolve against a live `gh repo view` is
#   refused with the --unroutable form PRINTED, never silently redirected.
#   A guessed destination is how a deferral disappears.
#
# usage: `--help`, from CLI_USAGE below. One source.
# exit codes: `--help`, from CLI_EXITS below. One source.

set -uo pipefail

CLI_NAME='defere.sh'
CLI_SUMMARY='file the thing you were about to write a paragraph about'
CLI_USAGE="  defere.sh '<one line>' --project <name>       file on hf7y/<name>
  defere.sh '<one line>' --human '<why>'        needs a person
  defere.sh '<one line>' --unroutable '<why>'   nothing can own it yet
  defere.sh --ledger                            print the DEFERRED block
  defere.sh --forget                            discard the accumulated block
  defere.sh --scan                              what this branch deleted and
                                                something still names
  options: --body <text> --from <project> --repo owner/name --decider @who --dry-run"
CLI_FLAGS='--project --human --unroutable --body --from --repo --decider --dry-run --ledger --forget --scan'
CLI_POSITIONAL=any
CLI_EXITS='  0  filed, or printed under --dry-run / --ledger
  1  could not file -- destination did not resolve, or gh refused
  2  usage error, including refusing to choose a route
  6  BLIND -- gh unavailable; nothing filed and nothing established'
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/cli-guard.sh"
cli_guard "$@"

OWNER="${DEFERE_OWNER:-hf7y}"
# Who is asked when a route needs a person. Not derived from the running
# account: an agent account filing under its own name would be addressing the
# decision to itself, which is the ownerless case with a handle stuck on it.
DECIDER="${DEFERE_DECIDER:-zach}"
WHAT=''; PROJECT=''; HUMAN=''; UNROUTABLE=''; BODY=''; FROM=''; REPO=''
DRY=0; MODE='file'   # quoted: `file` is a mode name, not file(1) -- SC2209

while [ $# -gt 0 ]; do
  case "$1" in
    --project)    PROJECT="${2:-}"; [ -n "$PROJECT" ] || cli_die '--project needs a project name'; shift 2 ;;
    --human)      HUMAN="${2:-}"; [ -n "$HUMAN" ] || cli_die '--human needs a reason a person is required'; shift 2 ;;
    --unroutable) UNROUTABLE="${2:-}"; [ -n "$UNROUTABLE" ] || cli_die '--unroutable needs a reason nothing can own it'; shift 2 ;;
    --body)       BODY="${2:-}"; shift 2 ;;
    --from)       FROM="${2:-}"; shift 2 ;;
    --repo)       REPO="${2:-}"; [ -n "$REPO" ] || cli_die '--repo needs owner/name'; shift 2 ;;
    --decider)    DECIDER="${2:-}"; [ -n "$DECIDER" ] || cli_die '--decider needs a handle'; DECIDER="${DECIDER#@}"; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    --ledger)     MODE=ledger; shift ;;
    --forget)     MODE=forget; shift ;;
    --scan)       MODE=scan; shift ;;
    -*)           cli_die "unknown flag: $1" ;;
    *)            [ -z "$WHAT" ] || cli_die "more than one description given; quote it as one argument: $1"
                  WHAT="$1"; shift ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# THE LEDGER FILE -- per branch, inside .git, so it is never committed and
# never leaks between branches. A session that files six items and then has to
ledger_path() {
  local gd br
  gd="$(git rev-parse --git-dir 2>/dev/null)" || return 1
  br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || br=detached
  printf '%s/defere-ledger.%s' "$gd" "$(printf '%s' "$br" | tr '/' '_')"
}

emit_block() {
  local lp
  lp="$(ledger_path)" || { echo 'defere: not in a git checkout, so there is no branch ledger.' >&2; return 1; }
  printf '<!-- DEFERRED -->\n'
  if [ -s "$lp" ]; then cat "$lp"; else printf -- '- none\n'; fi
  printf '<!-- /DEFERRED -->\n'
}

case "$MODE" in
  ledger) emit_block; exit $? ;;
  forget)
    lp="$(ledger_path)" || exit 1
    rm -f "$lp"; echo "defere: branch ledger discarded ($lp)"; exit 0 ;;
  scan)
    # WHY THIS EXISTS. The DEFERRED block is answered honestly 34% of the time
    # and DELIVERS 0.7%, with the SAME grammar and the same enforcement. The
    # difference is that this verb emits the text you paste and DELIVERS does
    # not. So the way to raise a ledger's honesty is never a stricter check --
    # it is to make the true answer cheaper than `- none`.
    #
    # This branch deleted files. Anything that still NAMES one of them is work
    # this branch left behind, and it is findable rather than remembered.
    # hf7y/realisateur#511 shipped three of these under `- none`: a registry
    # whose audit was gone, a conf naming a deleted script, and a carry with no
    # detector. Nobody was lazy; the honest answer just cost more than the lie.
    #
    # A LINE THAT SAYS THE THING IS GONE IS A RETRACTION, NOT A DANGLE, and is
    # skipped. This estate propagates mechanism well and retracts claims badly
    # -- an alarm outlived its own fix by 30 hours, a dashboard still reports a
    # mechanism retired in #180. Retraction is the scarce behaviour here, so a
    # scan that scolded someone for writing "deleted 2026-08-22" would be
    # taxing the one thing it wants more of.
    base="$(git merge-base HEAD "${DEFERE_BASE:-origin/main}" 2>/dev/null)" \
      || { echo "defere: BLIND -- no merge-base with ${DEFERE_BASE:-origin/main}; cannot tell what this branch deleted." >&2; exit 6; }
    # COMPARE TO THE WORKING TREE, NOT HEAD. This is the mandated pre-PR check
    # (#523), and the moment it exists to catch is BEFORE the deletion is
    # committed. "$base"...HEAD only sees committed deletions, so a staged
    # `git rm` reported "deletes nothing" right up until `git commit` -- silent
    # at the one moment it was meant to be run (#534). Dropping the range for a
    # single ref makes git diff compare that ref to the index+worktree, which
    # is exactly "what this branch has done so far, including what's not
    # committed yet".
    gone="$(git diff --name-only --diff-filter=D "$base" 2>/dev/null)"
    [ -n "$gone" ] || { echo 'defere --scan: this branch deletes nothing, so it can dangle nothing.'; exit 0; }
    found=0
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      b="$(basename "$path")"
      # A MANIFEST LINE IS NOT A DEPENDENCY. A line whose whole content is the
      # deleted path is a record OF the deletion (DELETION-LIST.txt is nothing
      # else); a line that says anything more is a file still talking about
      # something that is gone. One rule separates them, and it kept registry
      # rows surfacing -- `path<TAB>owner` has a second field, which is how
      # this found four stale rows in ownership-set.sh, itself deleted in #514.
      #
      # Search the worktree, not HEAD: on an uncommitted deletion the
      # retraction prose lives only on disk, same as the deletion itself.
      hits=""
      while IFS=':' read -r hfile hlineno hline; do
        [ -n "${hfile:-}" ] || continue
        [ "$hfile" != "$path" ] || continue
        trimmed="$(printf '%s' "$hline" | sed 's/^[ \t]*//;s/[ \t]*$//')"
        [ "$trimmed" != "$path" ] || continue
        # A RETRACTION IS OFTEN A PARAGRAPH, NOT A LINE (#534): prose
        # narrating a deletion across several lines can put the keyword
        # ("deleted", "retired"...) a line or two away from the line naming
        # the file, so checking only the matched line missed it. Read a small
        # window around the match instead.
        lo=$((hlineno - 2)); [ "$lo" -ge 1 ] || lo=1
        ctx="$(sed -n "${lo},$((hlineno + 2))p" -- "$hfile" 2>/dev/null)"
        printf '%s\n' "$ctx" | grep -qiE 'deleted|removed|retired|gone with|no longer|gone\b|gone,' && continue
        hits="${hits}${hits:+
}${hfile}:${hlineno}:${hline}"
      done <<< "$(git grep -n -F -- "$b" -- . 2>/dev/null)"
      [ -n "$hits" ] || continue
      hits="$(printf '%s\n' "$hits" | head -4)"
      found=$((found+1))
      printf '\n  DANGLING  %s\n' "$path"
      printf '%s\n' "$hits" | sed 's/^/            /'
      printf "            defere '%s is referenced by %s but was deleted in this branch' --project %s\n" \
        "$b" "$(printf '%s' "$hits" | head -1 | cut -d: -f1)" "${FROM:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo unknown)")}"
    done <<< "$gone"
    if [ "$found" -eq 0 ]; then
      echo 'defere --scan: every file this branch deleted is named nowhere else.'
      exit 0
    fi
    printf '\n%s dangling reference(s). Each line above is a deferral this branch owes;\nrun the command under it, then `defere --ledger` for the block.\n' "$found"
    exit 1 ;;
esac

# ---------------------------------------------------------------------------
# THE ROUTE -- exactly one, chosen explicitly.
# ---------------------------------------------------------------------------
[ -n "$WHAT" ] || cli_die "nothing to file: give the one-line description as the first argument"

nroute=0
[ -n "$PROJECT" ] && nroute=$((nroute+1))
[ -n "$HUMAN" ] && nroute=$((nroute+1))
[ -n "$UNROUTABLE" ] && nroute=$((nroute+1))
if [ "$nroute" -eq 0 ]; then
  cli_die "no route chosen. There is no default owner, on purpose -- an unroutable item silently assigned to a person is indistinguishable from one that genuinely needs them. Pick: --project <name> | --human '<why a person>' | --unroutable '<why nothing can own it>'"
fi
[ "$nroute" -eq 1 ] || cli_die 'choose exactly one of --project / --human / --unroutable'

if ! have gh; then
  echo "defere: BLIND -- gh is not on PATH. Nothing was filed, and nothing has been established about where this work went." >&2
  echo "        Do NOT write this into a PR body as an ownerless line: lib/body-grammar.sh" >&2
  echo "        refuses one, because that is the shape that shipped hf7y/realisateur#327" >&2
  echo "        as a no-op. Re-run this where gh works, then cite the issue number." >&2
  exit 6
fi

if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || REPO=''
fi
# The calling project's NAME comes from the remote, not from the directory:
# this repository is routinely worked from a git worktree under
# .claude/worktrees/agent-<hex>, and a deferral stamped "from
# agent-a77f87cd21106fde6" names nothing anyone can act on.
if [ -z "$FROM" ]; then
  if [ -n "$REPO" ]; then FROM="${REPO##*/}"
  else FROM="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo unknown)")"
  fi
fi

TITLE=''; DEST=''; LABEL=''; LEDGER_KIND=''
if [ -n "$PROJECT" ]; then
  DEST="$OWNER/$PROJECT"
  LABEL='deferred'
  TITLE="$WHAT"
  LEDGER_KIND=project
  # PROBED, NOT ASSUMED.
  if ! gh repo view "$DEST" --json name -q .name >/dev/null 2>&1; then
    cat >&2 <<EOF
defere: '$PROJECT' does not resolve to a repository ($DEST is not readable from here).
        NOT redirecting this to a person -- a guessed destination is worse than an
        admitted gap. Either name the right project, or say so out loud:

          defere '$WHAT' --unroutable 'no repo resolves for <owner>; the ownership map has a hole here'
EOF
    exit 1
  fi
elif [ -n "$HUMAN" ]; then
  DEST="${REPO:-$OWNER/$FROM}"
  LABEL='needs-human'
  TITLE="$WHAT"
  BODY="${BODY:+$BODY

}Why this needs a person: $HUMAN"
  LEDGER_KIND=human
else
  DEST="${REPO:-$OWNER/$FROM}"
  LABEL='unroutable'
  TITLE="$WHAT"
  BODY="${BODY:+$BODY

}Why nothing can own this yet: $UNROUTABLE

UNROUTABLE is its own state. It is not a soft way of assigning this to a
person, and it must not be triaged into one without the ownership gap it
records being closed or named."
  LEDGER_KIND=unroutable
fi

# The issue this files must satisfy the same grammar bin/gh-sign.sh enforces
# on `issue create` -- otherwise the front door emits bodies the front door
# refuses. Each route implies its own declaration:
#   --project      routed and owned; nothing to weigh -> NO-DECISION
case "$LEDGER_KIND" in
  project) DECLARE="NO-DECISION: @$DECIDER -- routed to $DEST and owned there; nothing here needs a call" ;;
  *)       DECLARE="DECISION: @$DECIDER -- $WHAT" ;;
esac

FULLBODY="$DECLARE

$BODY

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

---
Deferred from **$FROM**${REPO:+ (}${REPO}${REPO:+)} by \`defere\` on $(date -u +%Y-%m-%d).
Filed because the work was left behind deliberately and a paragraph is not a queue.
See realisateur \`bin/lib/body-grammar.sh\` for why this exists."

if [ "$DRY" -eq 1 ]; then
  printf 'defere: DRY RUN -- nothing filed.\n\n'
  printf '  repo:   %s\n  label:  %s\n  title:  %s\n\n  body:\n' "$DEST" "$LABEL" "$TITLE"
  printf '%s\n' "$FULLBODY" | sed 's/^/    /'
  exit 0
fi

# A missing label must not lose the issue. `gh issue create` fails outright on
# an unknown label, so create it first and ignore an already-exists error --
# the alternative is an issue that silently never gets filed, which is the
# original failure wearing a different hat.
gh label create "$LABEL" --repo "$DEST" --color ededed \
   --description 'work deferred from another run; see body' >/dev/null 2>&1 || true

URL="$(gh issue create --repo "$DEST" --title "$TITLE" --body "$FULLBODY" --label "$LABEL" 2>&1)" || {
  printf 'defere: gh refused to file on %s:\n%s\n' "$DEST" "$URL" >&2
  printf '        NOTHING was filed. There is no ownerless line to fall back on --\n' >&2
  printf '        lib/body-grammar.sh refuses one. Fix the destination and re-run.\n' >&2
  exit 1
}
URL="$(printf '%s' "$URL" | grep -oE 'https://[^ ]+' | tail -1)"
NUM="${URL##*/}"

case "$LEDGER_KIND" in
  project) LINE="- $DEST#$NUM -- $WHAT" ;;
  human)   LINE="- $DEST#$NUM -- $WHAT (needs a person: $HUMAN)" ;;
  *)       LINE="- $DEST#$NUM -- UNROUTABLE: $WHAT ($UNROUTABLE)" ;;
esac

if lp="$(ledger_path)"; then
  printf '%s\n' "$LINE" >> "$lp"
fi

printf 'defere: filed %s  [%s]\n' "$URL" "$LABEL"
printf '        ledger line (already accumulated; `defere --ledger` prints the block):\n'
printf '%s\n' "$LINE"
exit 0
