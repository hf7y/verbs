#!/usr/bin/env bash
# issue-debt.sh -- the open-issue count is a ratchet. It only falls.
#
# GUARD: is senechal's inbox growing?
# RUNNER: health/estate-health.sh (read-only form)
# GUARD-TEST: tools/test-issue-debt.sh
#
# WHY THIS EXISTS. tools/issue-janitor.py closes receipts it can read
# character for character, and correctly refuses everything else -- so on
# 2026-08-15 it examined 58 open issues and recognised none. hf7y/senechal#303
# made that report as could-not-look instead of as a pass, which stopped the
# backlog reading as clean. It did not stop the backlog GROWING.
#
# Counting is not the same as bounding. A number nobody compares to a previous
# number is a fact, not a guard: 58 open issues looks identical to 40 or to 90
# unless something remembers which way it moved.
#
# WHAT THIS IS. One committed number -- the ceiling -- and one rule: the count
# may never exceed it. Paying debt down lowers the ceiling permanently. There
# is no hand-raise: this script never writes a larger number, so raising the
# ceiling means editing a tracked file, in a diff, where someone sees it. That
# is deliberately the same shape as realisateur's markdown-cost ratchet
# ("the ratchet only falls, and there is no hand-raise", hf7y/realisateur#322).
#
# WHAT IT DOES NOT DO. It contains no judgment about any individual issue and
# closes nothing -- issue-janitor.py owns closing, and its refusal to guess is
# not weakened here. This only answers "is the pile bigger than last time".
#
# THE ONE BUG IT MUST NOT HAVE. A count that could not be taken must never
# read as a count of zero. Every unreachable path exits 2.
set -uo pipefail

CLI_NAME='issue-debt.sh'
CLI_SUMMARY='the open-issue count is a ratchet -- it only falls'
CLI_USAGE='  issue-debt.sh              report against the ceiling; write nothing
  issue-debt.sh --lower      lower the ceiling to the current count'
CLI_FLAGS='  --lower       record a paid-down debt (never raises)
  --repo OWNER/NAME'
CLI_EXITS='  0  at or under the ceiling
  1  OVER the ceiling -- the inbox grew
  2  could not look -- no gh, not authenticated, or no ceiling file
  3  under the ceiling and the ceiling has not been lowered yet'
CLI_POSITIONAL=none
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
cli_guard "$@"

RC_PASS=0; RC_FAIL=1; RC_INCOMPLETE=2; RC_WARN=3
quit() { local rc="$1"; shift; printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit "$rc"; }

CEILING_FILE="${ISSUE_DEBT_CEILING_FILE:-$(dirname "${BASH_SOURCE[0]}")/issue-debt.ceiling}"
REPO='hf7y/senechal'
LOWER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lower) LOWER=1; shift ;;
    --repo)  REPO="${2:-}"; shift 2 ;;
    *) quit "$RC_INCOMPLETE" "unknown argument '$1' -- see --help" ;;
  esac
done

[ -f "$CEILING_FILE" ] || quit "$RC_INCOMPLETE" "no ceiling file at $CEILING_FILE"
CEILING="$(grep -vE '^\s*(#|$)' "$CEILING_FILE" | head -1 | tr -d '[:space:]')"
case "$CEILING" in ''|*[!0-9]*) quit "$RC_INCOMPLETE" "ceiling file holds '$CEILING', not a number" ;; esac

command -v gh >/dev/null 2>&1 || quit "$RC_INCOMPLETE" "gh is not on PATH"
COUNT="$(gh issue list --repo "$REPO" --state open --limit 1000 --json number -q length 2>/dev/null)" \
  || quit "$RC_INCOMPLETE" "cannot count open issues on $REPO"
case "$COUNT" in ''|*[!0-9]*) quit "$RC_INCOMPLETE" "gh returned '$COUNT', not a count" ;; esac

printf 'issue-debt -- %s: %d open, ceiling %d\n' "$REPO" "$COUNT" "$CEILING"

if [ "$COUNT" -gt "$CEILING" ]; then
  printf '  FLAG [issue-debt] %d over the ceiling. The inbox grew.\n' "$((COUNT - CEILING))"
  printf '        Close %d, or raise the ceiling in %s -- which is a tracked\n' \
    "$((COUNT - CEILING))" "${CEILING_FILE#"$PWD"/}"
  printf '        file, so raising it is a reviewable act and not a silent one.\n'
  exit "$RC_FAIL"
fi

if [ "$COUNT" -lt "$CEILING" ]; then
  if [ "$LOWER" -eq 1 ]; then
    printf '%d\n' "$COUNT" > "$CEILING_FILE.tmp"
    cat >> "$CEILING_FILE.tmp" <<EOF
# senechal's open-issue ceiling. The count may never exceed this number.
# Lowered by tools/issue-debt.sh --lower; never raised by any script.
# Raising it means editing this file in a reviewable diff.
EOF
    mv "$CEILING_FILE.tmp" "$CEILING_FILE"
    printf '  ratchet lowered: %d -> %d. Commit %s.\n' \
      "$CEILING" "$COUNT" "${CEILING_FILE#"$PWD"/}"
    exit "$RC_PASS"
  fi
  printf '  %d under the ceiling, and the ceiling still says %d.\n' "$((CEILING - COUNT))" "$CEILING"
  printf '        Run `%s --lower` and commit it, or the debt you paid can\n' "$CLI_NAME"
  printf '        be re-borrowed silently.\n'
  exit "$RC_WARN"
fi

printf '  at the ceiling.\n'
exit "$RC_PASS"
