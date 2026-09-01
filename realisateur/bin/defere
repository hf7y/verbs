#!/usr/bin/env bash
# defere.sh -- file the thing you were about to write a paragraph about.
#
# KIND: verb
# TRAP: "no owner" may NOT silently mean Zach -- refusing to choose among the
#   three routes is a usage error, and an unresolvable project is refused with
#   the --unroutable form PRINTED. A guessed destination loses the deferral.

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
  defere.sh --scan --all                        every script path named in the
                                                tree that does not exist
  options: --body <text> --from <project> --repo owner/name --decider @who --dry-run
           --default-after '<n>d: <action>'   required by --human/--unroutable"
CLI_FLAGS='--project --human --unroutable --body --from --repo --decider --default-after --dry-run --ledger --forget --scan --all'
CLI_POSITIONAL=any
CLI_EXITS='  0  filed, or printed under --dry-run / --ledger
  1  could not file -- destination did not resolve, or gh refused
  2  usage error, including refusing to choose a route
  6  BLIND -- gh unavailable; nothing filed and nothing established'
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/cli-guard.sh"
cli_guard "$@"

. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/estate-set.sh"
OWNER="${DEFERE_OWNER:-$GH_ESTATE_OWNER}"
# Who is asked when a route needs a person. Not derived from the running
# account: an agent account filing under its own name would be addressing the
# decision to itself, which is the ownerless case with a handle stuck on it.
DECIDER="${DEFERE_DECIDER:-hf7y}"
WHAT=''; PROJECT=''; HUMAN=''; UNROUTABLE=''; BODY=''; FROM=''; REPO=''; DEFAULT_AFTER=''
ALL=0
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
    --default-after) DEFAULT_AFTER="${2:-}"; [ -n "$DEFAULT_AFTER" ] || cli_die "--default-after needs '<n>d: <action>'"; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    --ledger)     MODE=ledger; shift ;;
    --forget)     MODE=forget; shift ;;
    --scan)       MODE=scan; shift ;;
    --all)        ALL=1; shift ;;
    -*)           cli_die "unknown flag: $1" ;;
    *)            [ -z "$WHAT" ] || cli_die "more than one description given; quote it as one argument: $1"
                  WHAT="$1"; shift ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }

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
    # Anything still NAMING a file this branch deleted is work left behind.
    # A LINE SAYING THE THING IS GONE IS A RETRACTION, NOT A DANGLE: skipped,
    # because retraction is the scarce behaviour here (#534; pinned in tests).
    # --all (#579): A NAMED SCRIPT PATH THAT DOES NOT EXIST IS A FINDING.
    # Exempt, as a RECORD is not a CLAIM: archive/, bin/tests/ fixtures,
    # not-a-verb.tsv, .prose-ratchet (hf7y/etalon#10).
    if [ "$ALL" -eq 1 ]; then
      found=0
      while IFS=: read -r hfile hlineno hpath; do
        [ -n "${hpath:-}" ] || continue
        # THIS repo's bin/: leading char keeps other repos' out (5 false).
        hpath="bin/${hpath#*bin/}"
        [ -e "$hpath" ] && continue
        # A line that IS the path, or narrates the deletion, is a record.
        line="$(sed -n "${hlineno}p" -- "$hfile" 2>/dev/null)"
        trimmed="$(printf '%s' "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')"
        [ "$trimmed" = "$hpath" ] && continue
        lo=$((hlineno - 2)); [ "$lo" -ge 1 ] || lo=1
        sed -n "${lo},$((hlineno + 2))p" -- "$hfile" 2>/dev/null \
          | grep -qiE 'deleted|removed|retire[sd]?|retiring|gone with|no longer|gone\b|gone,|used to|went with' && continue
        found=$((found+1))
        printf '\n  NAMES-NOTHING  %s:%s\n' "$hfile" "$hlineno"
        printf '                 %s does not exist\n' "$hpath"
        printf '                 %s\n' "${trimmed:0:96}"
      done <<< "$(git grep -n -oE '(^|[^/[:alnum:]._-])(realisateur/)?bin/[a-z0-9_-]+\.(sh|py)' \
                    -- . ':!archive/' ':!bin/tests/' ':!bin/lib/not-a-verb.tsv' \
                       ':!.prose-ratchet' 2>/dev/null)"
      if [ "$found" -eq 0 ]; then
        echo 'defere --scan --all: every script path named in this tree exists.'
        exit 0
      fi
      printf '\n%s sentence(s) name a script that is not here. DELETE THE SENTENCE --\n' "$found"
      printf 'do not repoint it at a replacement, which recreates the rot with a fresh\n'
      printf 'name. Keep the FACT it was carrying, drop the NAME.\n'
      exit 1
    fi

    base="$(git merge-base HEAD "${DEFERE_BASE:-origin/main}" 2>/dev/null)" \
      || { echo "defere: BLIND -- no merge-base with ${DEFERE_BASE:-origin/main}; cannot tell what this branch deleted." >&2; exit 6; }
    # WORKING TREE, NOT HEAD: a single ref (no range) diffs against
    # index+worktree, so a staged `git rm` is seen BEFORE the commit -- the
    # moment this check exists for (#523, #534).
    gone="$(git diff --name-only --diff-filter=D "$base" 2>/dev/null)"
    [ -n "$gone" ] || { echo 'defere --scan: this branch deletes nothing, so it can dangle nothing.'; exit 0; }
    found=0
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      b="$(basename "$path")"
      # A MANIFEST LINE IS NOT A DEPENDENCY: a line whose WHOLE content is the
      # path records the deletion; anything more still talks about it. Search
      # the worktree -- on an uncommitted deletion the prose is only on disk.
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
# refuses. This comment once claimed that while the body carried no DELIVERS
# block, so gh-sign refused EVERY filing (#568); a guard test binds it now.
# DELIVERS is `- none`: filing an issue takes effect nowhere outside the repo.
#
# Each route implies its own declaration:
#   --project      routed and owned; nothing to weigh -> NO-DECISION
#   --human/--unroutable  asks a person -> DECISION, so #680 requires a
#     DEFAULT-AFTER. Not invented here: a fabricated default is the same block
#     by omission, wearing a timer.
case "$LEDGER_KIND" in
  project) DECLARE="NO-DECISION: @$DECIDER -- routed to $DEST and owned there; nothing here needs a call" ;;
  *)       case "$DEFAULT_AFTER" in
             [0-9]*d:?*) : ;;
             '') cli_die "a DECISION needs --default-after '<n>d: <action>' (#680). To block forever, say so: --default-after '0d: block -- irreversible, no default'" ;;
             *)  cli_die "--default-after must read '<n>d: <action>', got: $DEFAULT_AFTER" ;;
           esac
           DECLARE="DECISION: @$DECIDER -- $WHAT
DEFAULT-AFTER $DEFAULT_AFTER" ;;
esac

FULLBODY="$DECLARE

$BODY

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->

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
