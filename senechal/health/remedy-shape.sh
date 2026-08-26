#!/usr/bin/env bash
# senechal: the checkable half of "how to write a remedy".
#
# That was a checklist at the bottom of remedies/README.md until 2026-08-25,
# when that file was deleted -- its opening line ("senechal is an observer and
# does not mutate the live machine on its own") had been superseded for three
# months and was still steering agents into filing instead of fixing. A
# checklist nothing runs is in the same category.
#
# Only the mechanically decidable rows live here. "enable is idempotent",
# "unrelated settings survive", "target values defined once" need judgement or
# execution and are the remedy's own test's job -- which is why the test-
# coverage ratchet below matters more than any of them.
#
#   health/remedy-shape.sh [-q] [--lower]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

REMEDIES="../remedies"
CEILING_FILE="remedy-shape.ceiling"

LOWER=0
for a in "$@"; do [ "$a" = "--lower" ] && LOWER=1; done
parse_common_args "$@"

is_remedy() {  # a remedy is an .sh that is not a test and not the aggregator
  case "$1" in _*|verify-all.sh) return 1 ;; esac
  return 0
}

head_ "every remedy answers enable and verify"
bad_verbs=""
for f in "$REMEDIES"/*.sh; do
  n=$(basename "$f"); is_remedy "$n" || continue
  if ! grep -q 'enable)' "$f" || ! grep -q 'verify)' "$f"; then
    bad_verbs="$bad_verbs $n"
  fi
done
if [ -n "$bad_verbs" ]; then
  fail "no enable/verify dispatch:$bad_verbs"
  note "one file, two verbs -- so they cannot disagree about what correct means"
else
  ok "all answer both verbs"
fi

# verify-all.sh globs ./*.sh and runs each as `<script> verify`, skipping only
# `_*`. An unprefixed test file therefore gets RUN AS A REMEDY against the live
# machine, which is why the prefix is a rule and not a style.
head_ "no test file would be run as a remedy"
loose=""
for f in "$REMEDIES"/test-*.sh; do
  [ -e "$f" ] || continue
  loose="$loose $(basename "$f")"
done
if [ -n "$loose" ]; then
  fail "test file(s) without the _ prefix, which verify-all.sh will run as remedies:$loose"
else
  ok "none"
fi

head_ "no orphan tests"
orphans=""
for f in "$REMEDIES"/_test-*.sh; do
  [ -e "$f" ] || continue
  n=$(basename "$f")
  [ -e "$REMEDIES/${n#_test-}" ] || orphans="$orphans $n"
done
[ -n "$orphans" ] && fail "test(s) whose remedy is gone:$orphans" || ok "none"

head_ "remedy test coverage (ratchet, falls only)"
total=0; untested=0; names=""
for f in "$REMEDIES"/*.sh; do
  n=$(basename "$f"); is_remedy "$n" || continue
  total=$((total + 1))
  if [ ! -e "$REMEDIES/_test-$n" ]; then
    untested=$((untested + 1)); names="$names $n"
  fi
done

if [ ! -f "$CEILING_FILE" ]; then
  skip "$CEILING_FILE missing -- cannot tell whether $untested untested of $total is progress"
  finish_verify
fi
ceiling=$(tr -dc '0-9' < "$CEILING_FILE")
if [ -z "$ceiling" ]; then
  skip "$CEILING_FILE holds no number"
elif [ "$untested" -gt "$ceiling" ]; then
  fail "$untested of $total remedies have no _test- file, above the ceiling of $ceiling"
  note "new remedies need a test:$names"
elif [ "$untested" -lt "$ceiling" ] && [ "$LOWER" = 1 ]; then
  printf '%s\n' "$untested" > "$CEILING_FILE"
  ok "ceiling lowered $ceiling -> $untested"
elif [ "$untested" -lt "$ceiling" ]; then
  warn_ "$untested untested, below the ceiling of $ceiling -- bank it: health/remedy-shape.sh --lower"
else
  ok "$untested of $total untested, at the ceiling"
fi

finish_verify "OK -- remedies are the right shape."
