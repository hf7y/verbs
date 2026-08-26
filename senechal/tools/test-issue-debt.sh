#!/usr/bin/env bash
# tools/test-issue-debt.sh -- the suite for tools/issue-debt.sh. Exit 0 = pass.
#
# `gh` is stubbed by a fake on PATH, so no case touches GitHub and the counts
# are chosen rather than observed. The property under test is the ratchet:
# it must fall, must never rise on its own, and must never call a count it
# could not take a pass.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
SUT="$PWD/issue-debt.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; echo "       $2"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want '$2', got '$3'"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3'" ;; esac; }

mkdir -p "$T/bin"
fakegh() {                       # <count>|fail -- stub `gh issue list ... -q length`
  if [ "$1" = fail ]; then printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/gh"
  else printf '#!/usr/bin/env bash\necho %s\n' "$1" > "$T/bin/gh"; fi
  chmod +x "$T/bin/gh"
}
ceiling() { printf '%s\n# comment\n' "$1" > "$T/ceiling"; }
run() { OUT="$(PATH="$T/bin:$PATH" ISSUE_DEBT_CEILING_FILE="$T/ceiling" bash "$SUT" "$@" 2>&1)"; RC=$?; }

echo "-- A. the rule"
ceiling 58; fakegh 58; run
is  "A1 at the ceiling passes"                     0 "$RC"
ceiling 58; fakegh 59; run
is  "A2 one over the ceiling FAILS"                1 "$RC"
has "A2 and says how far over"                     "$OUT" "1 over the ceiling"
ceiling 58; fakegh 40; run
is  "A3 under the ceiling is a WARN, not a pass"   3 "$RC"
has "A3 because unrecorded debt can be re-borrowed" "$OUT" "re-borrowed"

echo "-- B. the ratchet falls, and only falls"
ceiling 58; fakegh 40; run --lower
is  "B1 --lower under the ceiling succeeds"        0 "$RC"
is  "B1 and the ceiling is now the count"          40 "$(head -1 "$T/ceiling")"
has "B1 and it says so"                            "$OUT" "58 -> 40"
fakegh 40; run
is  "B2 the lowered ceiling is now enforced"       0 "$RC"
fakegh 41; run
is  "B2 and one over the NEW ceiling fails"        1 "$RC"

ceiling 40; fakegh 90; run --lower
is  "B3 --lower with a HIGHER count does not raise" 1 "$RC"
is  "B3 the ceiling is untouched"                  40 "$(head -1 "$T/ceiling")"

echo "-- C. the file keeps explaining itself after a rewrite"
ceiling 58; fakegh 30; run --lower
has "C1 --lower rewrites the comment block too"    "$(cat "$T/ceiling")" "never raised by any script"

echo "-- D. could-not-look is never a pass"
ceiling 58; fakegh fail; run
is  "D1 gh failing exits 2, not 0"                 2 "$RC"
# PATH must be JUST the stub dir: leaving the real PATH appended finds the
# real gh, which answers truthfully and makes this case pass for the wrong
# reason -- it did exactly that on first run.
# A PATH with the coreutils the script needs and NO gh. Stripping PATH to
# just the stub dir instead makes the script die 127 on `grep`, which would
# pass a "not 0" assertion for entirely the wrong reason.
mkdir -p "$T/nogh"
for u in grep tr head cat mv sed bash; do ln -sf "$(command -v $u)" "$T/nogh/$u"; done
ceiling 58
OUT="$(PATH="$T/nogh" ISSUE_DEBT_CEILING_FILE="$T/ceiling" bash "$SUT" 2>&1)"; RC=$?
is  "D2 no gh at all exits 2"                      2 "$RC"
fakegh 58; rm -f "$T/ceiling"; run
is  "D3 a missing ceiling file exits 2"            2 "$RC"
fakegh 58; printf 'soon\n' > "$T/ceiling"; run
is  "D4 a non-numeric ceiling exits 2"             2 "$RC"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
