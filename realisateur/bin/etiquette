#!/usr/bin/env bash
# etiquette.sh -- the estate's issue-label grammar, read at the point of use,
# and the reconciler that makes a repo match it.
#
# KIND: verb
# RUNNER: no -- a SURVEY, run in a triage pass or ahead of /ideate and /cloture
# GUARD-TEST: bin/tests/etiquette.test.sh
# GATE: none -- reads live issue trackers; writes only with --apply
# THE TEXT LIVES IN bin/lib/labels.tsv, NOT HERE (#397): a grammar copied into
# 24 repos is 24 grammars. `needs-human` is DERIVED -- grammar_declaration()
# reads line 1, issue_answered() reads the comments. Typed, it was wrong 3 of 3.
#
# TRAP: line 1 declaring NEITHER is UNDECLARED, never "no decision".
# TRAP: a label absent from labels.tsv is left alone -- a floor, not a
#   whitelist; deleting one erases a repo's own taxonomy.
set -uo pipefail

CLI_NAME='etiquette'
CLI_SUMMARY='the estate label grammar, and whether a repo follows it'
CLI_USAGE='  etiquette                        print the grammar every repo follows
  etiquette --path                 print the file the grammar is read from
  etiquette <owner>/<repo>         report how that repo departs from it
  etiquette <owner>/<repo> --apply provision the labels and reconcile the derived one'
CLI_FLAGS='--apply --path'
CLI_POSITIONAL='[<owner>/<repo>]'
CLI_EXITS='  0  the repo carries the declared labels and every derived one matches its body
  1  findings: a declared label is missing, a derived one disagrees, or a body declares nothing
  2  usage error
  6  BLIND -- the grammar or the issue list could not be read. Never 0.'
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/cli-guard.sh"
cli_guard "$@"
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/body-grammar.sh"
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/answered.sh"

APPLY=0
REPO=''
PATH_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --path)  PATH_ONLY=1 ;;
    -*) printf '%s: unknown argument: %s\n' "$CLI_NAME" "$1" >&2; exit 2 ;;
    *)  [ -n "$REPO" ] && { printf '%s: one repo at a time\n' "$CLI_NAME" >&2; exit 2; }
        REPO="$1" ;;
  esac
  shift
done

# Self-locating THROUGH THE SYMLINK: without readlink -f the grammar is sought
# beside the NAME it was called by (the trap discipline.sh documents).
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
GRAMMAR_FILE="${ETIQUETTE_GRAMMAR:-$HERE/bin/lib/labels.tsv}"

say() { printf '%s\n' "$*"; }
row() { printf '  %-11s %-6s %s\n' "$1" "#$2" "${3:-}"; }

[ "$PATH_ONLY" = 1 ] && { printf '%s\n' "$GRAMMAR_FILE"; exit 0; }

# A GRAMMAR THAT IS NOT THERE IS BLIND, NOT AN EMPTY ONE: reporting a repo
# compliant with rules that failed to load is the exit-0 no-op.
[ -r "$GRAMMAR_FILE" ] || {
  printf '%s: BLIND -- no label grammar at %s\n' "$CLI_NAME" "$GRAMMAR_FILE" >&2
  printf '%s: that is "I could not read the rules", not "there are no rules".\n' "$CLI_NAME" >&2
  exit 6
}
mapfile -t GRAMMAR < <(grep -v '^#' "$GRAMMAR_FILE" | grep -v '^[[:space:]]*$')
[ "${#GRAMMAR[@]}" -gt 0 ] || {
  printf '%s: BLIND -- %s holds no label rows.\n' "$CLI_NAME" "$GRAMMAR_FILE" >&2
  exit 6
}

g_field() { printf '%s' "$1" | cut -f"$2"; }

if [ -z "$REPO" ]; then
  say "etiquette -- the estate's issue-label grammar"
  say "  one home: $GRAMMAR_FILE"
  say "  read live, never copied into a repo. \`etiquette <owner>/<repo>\` grades one."
  say ""
  for g in "${GRAMMAR[@]}"; do
    printf '  %-14s %-18s %s\n' "$(g_field "$g" 1)" "$(g_field "$g" 3)" "$(g_field "$g" 4)"
  done
  say ""
  say "SOURCE column: derived:decision is written by --apply from line 1 of the body"
  say "and must never be typed; written:<verb> belongs to that verb alone."
  exit 0
fi

LABEL=''
for g in "${GRAMMAR[@]}"; do
  [ "$(g_field "$g" 3)" = 'derived:decision' ] && { LABEL="$(g_field "$g" 1)"; break; }
done
[ -n "$LABEL" ] || {
  printf '%s: BLIND -- %s declares no derived:decision label, so there is nothing to reconcile.\n' \
    "$CLI_NAME" "$GRAMMAR_FILE" >&2
  exit 6
}

# --- 1. does the repo carry the declared labels? ------------------------
have="$(gh label list --repo "$REPO" --limit 200 --json name,description --jq '.[]|[.name,.description]|@tsv' 2>&1)" || {
  printf '%s: BLIND -- could not read %s label list: %s\n' "$CLI_NAME" "$REPO" "$have" >&2
  exit 6
}

say "etiquette -- $REPO against $GRAMMAR_FILE"
say ""
label_findings=0; provisioned=0
for g in "${GRAMMAR[@]}"; do
  name="$(g_field "$g" 1)"; color="$(g_field "$g" 2)"; meaning="$(g_field "$g" 4)"
  # GitHub caps a description at 100 chars; the full meaning stays in the one
  # home and this is a pointer to it.
  desc="${meaning:0:96}"
  if printf '%s\n' "$have" | cut -f1 | grep -qxF "$name"; then
    continue
  fi
  label_findings=$((label_findings + 1))
  printf '  %-11s %s\n' "MISSING" "label \`$name\` is declared by the grammar and this repo does not have it"
  if [ "$APPLY" -eq 1 ]; then
    if gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" >/dev/null 2>&1; then
      provisioned=$((provisioned + 1)); printf '  %-11s %s\n' "  +label" "created \`$name\`"
    else
      printf '  %-11s %s\n' "  FAILED" "could not create \`$name\` -- not counting it as provisioned"
    fi
  fi
done
[ "$label_findings" -eq 0 ] && say "  ok          every declared label exists here"
say ""

# --- 2. does each open issue's derived label match its body? ------------
# [] means both "missing repo" and "empty one" -- only the exit code separates
# "nothing waiting" from "could not look".
json="$(gh issue list --repo "$REPO" --state open --limit 200 \
        --json number,title,body,labels 2>&1)" || {
  printf '%s: BLIND -- could not read %s: %s\n' "$CLI_NAME" "$REPO" "$json" >&2
  printf '%s: that is "I could not look", not "nothing needs a human".\n' "$CLI_NAME" >&2
  exit 6
}

findings=0; matched=0; changed=0; BLIND_READS=0
while IFS=$'\t' read -r num has_label title; do
  [ -n "$num" ] || continue
  body="$(printf '%s' "$json" | jq -r --argjson n "$num" '.[]|select(.number==$n)|.body')"
  want='' ; answered=0 ; noted=0
  case "$(grammar_declaration "$body")" in
    # An answered decision is an agent's work: left labelled it brakes dispatch.
    decision)
      want=yes
      # UNCOUNTED and BLIND keep the label -- clearing would be forgery --
      # but are REPORTED (#553): only one non-answer is a silence.
      issue_answered "$REPO" "$num"
      case $? in
        0) want=no; answered=1 ;;
        2) findings=$((findings + 1)); noted=1
           row UNCOUNTED "$num" "$ANSWERED_WHY -- ${title:0:46}" ;;
        6) findings=$((findings + 1)); noted=1; BLIND_READS=$((BLIND_READS + 1))
           row BLIND "$num" "$ANSWERED_WHY -- ${title:0:46}" ;;
      esac ;;
    no-decision) want=no ;;
    none)
      findings=$((findings + 1))
      row UNDECLARED "$num" "line 1 declares neither DECISION: nor NO-DECISION: -- ${title:0:52}"
      continue ;;
  esac
  [ "$has_label" = "$want" ] && { [ "$noted" -eq 1 ] || matched=$((matched + 1)); continue; }
  findings=$((findings + 1))
  if [ "$want" = yes ]; then
    row MISSING "$num" "declares DECISION: but is not labelled $LABEL -- ${title:0:52}"
    [ "$APPLY" -eq 1 ] && gh issue edit "$num" --repo "$REPO" --add-label "$LABEL" >/dev/null \
      && { changed=$((changed + 1)); row "  +label" "$num" "$LABEL added"; }
  else
    if [ "$answered" = 1 ]; then
      row ANSWERED "$num" "declares DECISION: and has been answered -- ${title:0:52}"
    else
      row STALE "$num" "labelled $LABEL but declares NO-DECISION: -- ${title:0:52}"
    fi
    [ "$APPLY" -eq 1 ] && gh issue edit "$num" --repo "$REPO" --remove-label "$LABEL" >/dev/null \
      && { changed=$((changed + 1)); row "  -label" "$num" "$LABEL removed"; }
  fi
done < <(printf '%s' "$json" | jq -r --arg l "$LABEL" \
  '.[] | [.number, (if any(.labels[]; .name==$l) then "yes" else "no" end), .title] | @tsv')

say ""
say "$matched issue(s) agree, $findings issue finding(s), $label_findings label finding(s);"
say "$changed label(s) reconciled, $provisioned label(s) provisioned."
[ $((findings + label_findings)) -gt 0 ] && [ "$APPLY" -eq 0 ] && \
  say 'Re-run with --apply. An UNDECLARED body is NOT fixed by a label -- edit line 1.'
# A BLIND read is neither a finding --apply can fix nor a clean run.
if [ "$BLIND_READS" -gt 0 ]; then
  printf '%s: BLIND -- %s issue(s) could not be read, so the report above is INCOMPLETE.\n' \
    "$CLI_NAME" "$BLIND_READS" >&2
  exit 6
fi
[ $((findings + label_findings)) -eq 0 ] || exit 1
exit 0
