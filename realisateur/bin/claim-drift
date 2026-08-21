#!/usr/bin/env bash
# claim-drift.sh -- has a pull request grown since it was presented as done?
#
# KIND: verb
#
# RUNNER: operator -- needs a GitHub credential against live PRs; run in a review pass
# GUARD-TEST: bin/tests/claim-drift.test.sh
# GATE: none -- every path calls `gh` against a live PR; the fixture is in its own suite
#
# TRAPS (the rest of this header is in the vault):
# THE FAILURE THIS CLOSES. An agent reports work COMPLETE and points at a pull
# request that is not a draft. More commits land on it. The completion claim
# was true when made and silently false afterwards, and nothing marked the
# moment it went stale.
# WHERE THE CLAIM LIVES, which is the whole trick. A completion claim written
# in prose to a human cannot be checked later by anyone. So the claim is not
# prose: it is the PR's own draft state, which GitHub already records with a
# timestamp and which nobody has to remember to write down.
#   a DRAFT pull request claims nothing        -> it can never drift
#   marking it READY is the commitment point   -> that instant is the anchor
#   a PR OPENED non-draft claims done at its opening
#
# usage: `--help`, from CLI_USAGE below. One source.
# exit codes: `--help`, from CLI_EXITS below. One source.

set -uo pipefail

CLI_NAME='claim-drift.sh'
CLI_SUMMARY='has a pull request grown since it was presented as done?'
CLI_USAGE='  claim-drift.sh <pr-number>...        audit the named PRs
  claim-drift.sh --all                 audit every OPEN pull request
  claim-drift.sh --strict ...          exit 1 on drift, 6 on BLIND
  claim-drift.sh --repo <owner/name>   default: the remote of this checkout'
CLI_FLAGS='--all --strict --repo --convention'
CLI_POSITIONAL=any
CLI_EXITS='  0  audited; no --strict, or --strict and nothing drifted
  1  --strict and at least one PR has grown since it was claimed done
  6  BLIND -- the tracker could not be read. A domain that existed and was
     NOT read is not a pass; 6 is the ecosystem blind code (garde, ausculte,
     closeout-lint) rather than a third invention.'
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/body-grammar.sh"
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/cli-guard.sh"
cli_guard "$@"

# THE CANONICAL TEXT. One place, printed on demand.
#
# Why a flag and not a paragraph in a brief: on 2026-08-07 this convention was
# retyped from memory into eight agent briefs by one coordinator, who then
print_convention() {
  cat <<'CONV'
PULL REQUEST CONVENTION -- canonical. Reference this; do not paraphrase it.

  COMPLETION axis (mechanized here, enforced by this script):
    a DRAFT pull request claims nothing        -> it can never drift
    marking it READY is the commitment point   -> that instant anchors the claim
    a PR OPENED non-draft claims done at its opening
    Growth after "done" is legal. Growth while STILL claiming done is not:
    convert back to draft while you work, mark ready again when finished.

  ATTENTION axis (decided 2026-08-08; enforced here and by branch protection):
    NO decision -> ready, then merge it. This is the default and should be
                   the common case; nobody reads it.
                     with a required check:  gh pr merge --squash --auto
                     without one:            gh pr merge --squash
                   `--auto` on a repo with NO required check does not queue --
                   it merges instantly and leaves autoMergeRequest null, so the
                   caller cannot tell it happened (#288, 7 silent merges). Use
                   it only where a check exists to queue behind.
    A decision  -> a DRAFT, and the FIRST non-empty line is:
                     DECISION: <the one call the human must make>
                   Draft, not ready-with-auto-merge-off: GitHub refuses to
                   auto-merge a draft, so the server enforces the hold. #319
                   carried a correct DECISION line and was auto-merged 38
                   minutes later anyway. An open PR is never a hold.
                   Optionally NO-DECISION: <why> when auto-merge is unavailable
                   but no judgement is needed.
    A DRAFT is exempt from both: it claims nothing, so it asks nothing.

  Why PRs at all, when nobody reads most of them: the PR is what runs CI
  against the MERGE RESULT. Four PRs on 2026-08-07 merged with zero textual
  conflicts and broke each other's repository-wide invariants; `main` went red
  twice. Dropping the PR would drop that gate. What was removed is the WAITING,
  not the gate.

  THE MECHANISM, live on hf7y/realisateur since 2026-08-08 -- cited so this
  text cannot quietly become aspirational:
    allow_auto_merge=true, delete_branch_on_merge=true
    branch protection on main: required checks `suites` and `markdown-cost`
    strict=false          -- deliberately NOT "require branches up to date":
                             that forces every open PR to re-sync whenever main
                             moves, the loop that broke #95/#96/#98 repeatedly.
    enforce_admins=true    -- self-dev accounts run tools this repo ships, so
                             a bad merge here breaks all of them at once. A
                             required check an admin can route around on a bad
                             day is not a gate, it is a suggestion.
    no required reviews   -- the point. Green is sufficient; nobody has to look.

  Why the first line: the stated failure mode is "if it's a PR not a draft,
  I'm just going to merge it without reading". A ready PR whose ask is buried
  in prose cannot be triaged without opening it.

  OVERCAUTIOUS (non-blocking): the mirror failure -- a DECISION line on a diff
  that touched no existing file's behavior. Before reaching for DECISION, ask:
  does this diff change what any ALREADY-RUNNING thing does?

  THE CHEAPER QUESTION, AND THE ONE THE SCRIPT CANNOT ASK FOR YOU. Before
  writing DECISION: did the user already ask for exactly this, and is there
  evidence it does what was asked? That is not readable from a diff, only
  from the conversation, by the one party who was in it.

  The classification is the AUTHOR's, declared. No guard can read intent.
  This script does NOT re-implement the green gate -- branch protection owns
  that.
CONV
}

REPO=''
ALL=0
STRICT=0
PRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --convention) print_convention; exit 0 ;;
    --repo)   REPO="${2:-}"; [ -n "$REPO" ] || cli_die '--repo needs owner/name'; shift 2 ;;
    --all)    ALL=1; shift ;;
    --strict) STRICT=1; shift ;;
    *)        case "$1" in
                ''|*[!0-9]*) cli_die "not a pull request number: $1" ;;
              esac
              PRS+=("$1"); shift ;;
  esac
done

# A run that examines nothing is not a clean run. Saying "no drift" about an
# empty set is the found-nothing / nothing-is-wrong conflation this repository
# keeps paying for, so it is a usage error rather than a green exit.
if [ "$ALL" -eq 0 ] && [ "${#PRS[@]}" -eq 0 ]; then
  cli_die 'nothing to audit: give one or more PR numbers, or --all'
fi

drifted=0; current=0; unclaimed=0; settled=0; blind=0; undecided=0; overcautious=0; notdraft=0

# Whether the body declares itself at all -- one line over the shared
# grammar_declaration(), which bin/gh-sign.sh enforces at the write. This file
# used to carry TWO functions that differed only in return shape, each with
declares_itself() { [ "$(grammar_declaration "$1")" != none ]; }

# THE OVERCAUTIOUS CHECK. UNDECIDED (below) catches a ready PR that asks for
# nothing while silently wanting attention. This is the mirror failure: a
# ready PR that raises a DECISION nobody needs to make. Both are the same
is_additive_only_diff() {
  local file='' is_new=0 adds=0 dels=0 saw_file=0
  judge() {
    [ "$saw_file" -eq 0 ] && return 0
    [ "$is_new" -eq 1 ] && return 0
    case "$file" in
      *.md) [ "$dels" -ge "$adds" ] && return 0 ;;
    esac
    return 1
  }
  while IFS= read -r line; do
    case "$line" in
      'diff --git '*)
        if [ "$saw_file" -eq 1 ]; then judge || return 1; fi
        file="${line#diff --git a/}"; file="${file%% b/*}"
        is_new=0; adds=0; dels=0; saw_file=1
        ;;
      'new file mode'*) is_new=1 ;;
      '+++'*) : ;;
      '---'*) : ;;
      '+'*) adds=$((adds+1)) ;;
      '-'*) dels=$((dels+1)) ;;
    esac
  done <<<"$1"
  [ "$saw_file" -eq 1 ] && { judge || return 1; }
  return 0
}

note_blind() { blind=$((blind+1)); printf '  #%-4s BLIND     %s\n' "$1" "$2"; }

# The two tools this reads the world with. Their absence is BLIND, not clean --
# a guard that reports success when its own instrument is missing is the
# exit-0 no-op BUILD-DISCIPLINE.md exists to prevent.
have() { command -v "$1" >/dev/null 2>&1; }

if [ -z "$REPO" ]; then
  if have gh; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || REPO=''
  fi
fi

printf 'claim-drift: %s\n\n' "${REPO:-(unknown repo)}"

if ! have gh || ! have jq; then
  missing=''
  have gh || missing="$missing gh"
  have jq || missing="$missing jq"
  printf '  BLIND: cannot read the tracker --%s not on PATH.\n' "$missing"
  printf '         This is not "no claim has drifted". Nothing was examined.\n\n'
  [ "$STRICT" -eq 1 ] && exit 6
  exit 0
fi

if [ "$ALL" -eq 1 ]; then
  list="$(gh pr list --repo "$REPO" --state open --limit 100 --json number 2>/dev/null)" || list=''
  if [ -z "$list" ]; then
    printf '  BLIND: could not list open pull requests for %s.\n\n' "$REPO"
    [ "$STRICT" -eq 1 ] && exit 6
    exit 0
  fi
  while read -r n; do [ -n "$n" ] && PRS+=("$n"); done < <(printf '%s' "$list" | jq -r '.[].number' 2>/dev/null)
fi

for n in "${PRS[@]}"; do
  pr="$(gh pr view "$n" --repo "$REPO" \
        --json number,title,url,state,isDraft,createdAt,headRefOid,commits,body,autoMergeRequest 2>/dev/null)" || pr=''
  if [ -z "$pr" ]; then
    note_blind "$n" "could not read the pull request."
    continue
  fi
  state="$(printf '%s' "$pr" | jq -r '.state // ""')"
  isdraft="$(printf '%s' "$pr" | jq -r '.isDraft // false')"
  created="$(printf '%s' "$pr" | jq -r '.createdAt // ""')"
  head="$(printf '%s' "$pr" | jq -r '.headRefOid // ""')"
  if [ -z "$state" ] || [ -z "$created" ]; then
    note_blind "$n" "the pull request payload was unreadable."
    continue
  fi

  # A merged or closed PR's head cannot move again, so whatever was claimed
  # about it is settled -- true or false, it is no longer going stale.
  if [ "$state" != OPEN ]; then
    settled=$((settled+1))
    printf '  #%-4s SETTLED   %s at %s -- head is immutable now.\n' "$n" "$(printf '%s' "$state" | tr 'A-Z' 'a-z')" "${head:0:8}"
    continue
  fi

  if [ "$isdraft" = true ]; then
    unclaimed=$((unclaimed+1))
    printf '  #%-4s UNCLAIMED draft -- it claims nothing, so it cannot drift.\n' "$n"
    continue
  fi

  # THE ATTENTION AXIS. A ready PR either lands unattended or asks for a call.
  # Auto-merge IS the no-decision declaration -- it is a live GitHub state, not
  # a sentence someone wrote, so it cannot be stale. Only a PR that is ready,
  # not auto-merging, and silent about why is asking for attention without
  # saying what for.
  automerge="$(printf '%s' "$pr" | jq -r '.autoMergeRequest // "" | if . == "" then "" else "on" end')"
  body="$(printf '%s' "$pr" | jq -r '.body // ""')"
  if [ "$automerge" != on ] && ! declares_itself "$body"; then
    undecided=$((undecided+1))
    printf '  #%-4s UNDECIDED ready, not auto-merging, and its first line does not say why.\n' "$n"
    printf '                  Either `gh pr merge %s --squash` (add --auto only if this\n' "$n"
    printf '                  repo has a required check), or open the body with\n'
    printf '                  See: claim-drift --convention\n'
  fi

  # THE MIRROR CHECK: a DECISION nobody needs to make. See is_additive_only_diff
  # above for exactly what "nobody needs to make" means here and why it stops
  # at a FLAG rather than a verdict.
  if [ "$(grammar_declaration "$body")" = decision ]; then
    # Zach, 2026-08-15, after #319 was auto-merged past its own DECISION line:
    # "a decision should be a draft PR." A DECISION: on a ready PR is a
    # convention with nothing behind it -- `gh pr merge --auto` lands it the
    # moment its checks go green, and a green check answers "do the tests
    # pass", not "has a human agreed". GitHub refuses to auto-merge a draft,
    # so draft is the same rule enforced by the server instead of by prose.
    notdraft=$((notdraft+1))
    printf '  #%-4s NOT-DRAFT declares DECISION: while ready. Auto-merge can land this\n' "$n"
    printf '                  the instant its checks go green, past the line asking for a\n'
    printf '                  human (#288, #319). Convert it to a draft -- GitHub refuses\n'
    printf '                  to auto-merge one -- or drop the DECISION line.\n'
    printf '                  See: claim-drift --convention\n'
    prdiff="$(gh pr diff "$n" --repo "$REPO" 2>/dev/null)" || prdiff=''
    if [ -n "$prdiff" ] && is_additive_only_diff "$prdiff"; then
      overcautious=$((overcautious+1))
      printf '  #%-4s OVERCAUTIOUS DECISION line, but every changed file is new or a\n' "$n"
      printf '                  shrinking .md edit -- nothing existing was touched. Re-check\n'
      printf '                  whether this really needs the human'"'"'s call, or downgrade to\n'
      printf '                  plain ready + auto-merge (no decision) or a NO-DECISION line.\n'
      printf '                  See: claim-drift --convention\n'
    fi
  fi

  # THE ANCHOR. Last time this PR was presented as finished.
  tl="$(gh api "repos/$REPO/issues/$n/timeline" --paginate 2>/dev/null)" || tl=''
  if [ -z "$tl" ]; then
    note_blind "$n" "could not read the pull request timeline."
    continue
  fi
  anchor="$(printf '%s' "$tl" \
    | jq -r -s 'add // [] | map(select(.event=="ready_for_review") | .created_at) | last // ""' 2>/dev/null)"
  if [ -n "$anchor" ]; then
    why="marked ready for review"
  else
    # No ready_for_review event at all: the PR was opened non-draft, and
    # opening it that way IS the claim. This branch is the incident.
    anchor="$created"
    why="opened non-draft"
  fi

  after="$(printf '%s' "$pr" | jq -r --arg a "$anchor" '[.commits[] | select(.committedDate > $a)] | length')"
  claim_sha="$(printf '%s' "$pr" | jq -r --arg a "$anchor" \
      '[.commits[] | select(.committedDate <= $a)] | last | .oid // ""')"
  [ -n "$claim_sha" ] || claim_sha='(no commit at claim time)'

  if [ "${after:-0}" -eq 0 ]; then
    current=$((current+1))
    printf '  #%-4s CURRENT   claimed %s (%s); head %s unchanged since.\n' \
      "$n" "$anchor" "$why" "${head:0:8}"
    printf '                  cite this: %s#%s at %s\n' "$REPO" "$n" "${claim_sha:0:12}"
  else
    drifted=$((drifted+1))
    printf '  #%-4s DRIFTED   claimed %s (%s)\n' "$n" "$anchor" "$why"
    printf '                  claim sha %s  ->  head %s   (%s commit(s) since)\n' \
      "${claim_sha:0:12}" "${head:0:8}" "$after"
    printf '                  FLAG: this PR was presented as done and has grown since.\n'
    printf '                  Not forbidden -- but the claim is stale. Convert it back\n'
    printf '                  to draft while you work, or mark it ready again to\n'
    printf '                  re-commit to what is now on the branch.\n'
  fi
done

printf '\n%d drifted, %d undecided, %d not-draft, %d overcautious, %d current, %d unclaimed, %d settled, %d blind.\n' \
  "$drifted" "$undecided" "$notdraft" "$overcautious" "$current" "$unclaimed" "$settled" "$blind"

if [ "$STRICT" -eq 1 ]; then
  [ "$blind" -gt 0 ] && exit 6
  # overcautious never gates: it's a suggestion to reduce friction, and a
  # mechanism that BLOCKS on "you asked for review when you maybe didn't need
  # to" would just add the friction it exists to catch, one level up.
  [ "$drifted" -gt 0 ] || [ "$undecided" -gt 0 ] || [ "$notdraft" -gt 0 ] && exit 1
fi
exit 0
