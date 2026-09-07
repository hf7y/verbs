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
  if ! grep -qE '^[[:space:]]*enable\)' "$f" || ! grep -qE '^[[:space:]]*verify\)' "$f"; then
    bad_verbs="$bad_verbs $n"
  fi
done
if [ -n "$bad_verbs" ]; then
  fail "no enable/verify dispatch:$bad_verbs"
  note "one file, two verbs -- so they cannot disagree about what correct means"
else
  ok "all answer both verbs"
fi

# ENABLE THAT CANNOT BE UNDONE, both found 2026-08-27: postfix-delegate
# dispatched no disable though its engine defined one, and lid-inhibit's said
# "delete them by hand". A remedy owns removing what it installs (#466).
head_ "what enable installs, disable removes"
no_dispatch=""; no_removal=""
for f in "$REMEDIES"/*.sh; do
  n=$(basename "$f"); is_remedy "$n" || continue
  grep -qE 'toggle-kinds\.sh|timer-kind\.sh|install_file|ssh-keygen|\$SUDO_CMD[[:space:]]+(install|tee|cp|ln)|sudo[[:space:]]+(install|tee|cp)' "$f" || continue
  if ! grep -qE '^[[:space:]]*disable\)' "$f"; then
    no_dispatch="$no_dispatch $n"
    continue
  fi
  # Installs its own files (rather than delegating to an engine that removes
  # them) -- then its disable has to say rm somewhere.
  grep -q 'install_file' "$f" || continue
  awk '/^(do_)?disable_?\(\)/,/^}/' "$f" \
    | grep -qE 'rm -f|_timer_remove_file' || no_removal="$no_removal $n"
done
if [ -n "$no_dispatch" ]; then
  fail "installs durable artifacts, dispatches no disable:$no_dispatch"
else
  ok "every installer answers disable"
fi
if [ -n "$no_removal" ]; then
  fail "disable removes nothing it installed:$no_removal"
else
  ok "every hand-rolled installer's disable removes its own files"
fi

head_ "durable installs are declared, and hand-rolled disable removes exactly them"
no_installs_decl=""; install_drift=""
for f in "$REMEDIES"/*.sh; do
  n=$(basename "$f"); is_remedy "$n" || continue
  grep -qE 'toggle-kinds\.sh|timer-kind\.sh|install_file|ssh-keygen|\$SUDO_CMD[[:space:]]+(install|tee|cp|ln)|sudo[[:space:]]+(install|tee|cp)' "$f" || continue
  if ! grep -qE '^INSTALLS=\(' "$f"; then
    no_installs_decl="$no_installs_decl $n"
    continue
  fi
  grep -qE '^\. lib/(timer-kind|toggle-kinds)\.sh$' "$f" && continue
  disable_body="$(awk '/^(do_)?disable_?\(\)/,/^}/' "$f")"
  mapfile -t toks < <(grep -E '^INSTALLS=\(' "$f" | grep -oE '"[^"]*"')
  for tok in "${toks[@]}"; do
    path="${tok#\"}"; path="${path%\"}"
    [ -n "$path" ] || continue
    printf '%s\n' "$disable_body" | grep -qF -- "$path" || install_drift="$install_drift $n:$path"
  done
done
if [ -n "$no_installs_decl" ]; then
  fail "writes durable state, no 'INSTALLS=(...)' line:$no_installs_decl"
else
  ok "all declare"
fi
if [ -n "$install_drift" ]; then
  fail "declared install never referenced in disable:$install_drift"
else
  ok "every hand-rolled disable references every declared install"
fi

# verify-all.sh globs ./*.sh and runs each as `<script> verify`, skipping only
# `_*`. An unprefixed test file therefore gets RUN AS A REMEDY against the live
# machine, which is why the prefix is a rule and not a style.
head_ "no test file would be run as a remedy"
# ANY spelling of "test", not just the test-*.sh prefix: the sibling
# directories name tests health/test-X.sh, test/X-test.sh and
# tools/test-X.py, so remedies/X-test.sh is a shape someone writes by
# habit -- and verify-all.sh would run it, and auto-apply-remedies.sh
# would enable it unattended on merge.
loose=""
for f in "$REMEDIES"/*test*.sh; do
  [ -e "$f" ] || continue
  n=$(basename "$f")
  case "$n" in _test-*) continue ;; esac
  loose="$loose $n"
done
if [ -n "$loose" ]; then
  fail "test file(s) without the _ prefix, which verify-all.sh will run as remedies:$loose"
else
  ok "none"
fi

# Read by tools/auto-apply-remedies.sh (#481) -- undeclared reads as privileged.
head_ "every remedy declares whether enable holds privilege"
undeclared=""
for f in "$REMEDIES"/*.sh; do
  n=$(basename "$f"); is_remedy "$n" || continue
  grep -qE '^PRIVILEGED=(yes|no)$' "$f" || undeclared="$undeclared $n"
done
[ -n "$undeclared" ] && fail "no 'PRIVILEGED=yes|no' line:$undeclared" || ok "all declare"

head_ "every remedy declares which host(s) it runs on"
no_hosts=""
for f in "$REMEDIES"/*.sh; do
  n=$(basename "$f"); is_remedy "$n" || continue
  grep -qE '^HOSTS=\([^)]+\)$' "$f" || no_hosts="$no_hosts $n"
done
[ -n "$no_hosts" ] && fail "no 'HOSTS=(...)' line:$no_hosts" || ok "all declare"

head_ "every remedy declares how (if at all) it reaches its subject remotely (#637)"
no_reaches=""
for f in "$REMEDIES"/*.sh; do
  n=$(basename "$f"); is_remedy "$n" || continue
  grep -qE '^REACHES=\([^)]*\)$' "$f" || no_reaches="$no_reaches $n"
done
[ -n "$no_reaches" ] && fail "no 'REACHES=(...)' line (use REACHES=() for none):$no_reaches" || ok "all declare"

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
  # -s, not -e: an empty _test- file would clear the ratchet forever.
  if [ ! -s "$REMEDIES/_test-$n" ]; then
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
  warn_ "$untested of $total untested ($(( (total - untested) * 100 / total ))% covered), below the ceiling of $ceiling -- bank it: health/remedy-shape.sh --lower"
else
  ok "$untested of $total untested ($(( (total - untested) * 100 / total ))% covered), at the ceiling"
fi

finish_verify "OK -- remedies are the right shape."
