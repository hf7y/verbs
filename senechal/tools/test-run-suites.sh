#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
SUT="$PWD/run-suites.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; echo "       $2"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want '$2', got '$3'"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3'" ;; esac; }
hasnot() { case "$2" in *"$3"*) bad "$1" "should not contain '$3'" ;; *) ok "$1" ;; esac; }

pass_suite() { printf '#!/usr/bin/env bash\nexit 0\n' > "$T/$1"; chmod +x "$T/$1"; }
fail_suite() { printf '#!/usr/bin/env bash\nexit 1\n' > "$T/$1"; chmod +x "$T/$1"; }
qfile() { printf '%s\n' "$@" > "$T/q.tsv"; }
run() { OUT="$(cd "$T" && RUN_SUITES_QUARANTINE="$T/q.tsv" bash "$SUT" "$@" 2>&1)"; RC=$?; }

echo "-- A. baseline: no quarantine involved"
pass_suite ok1.sh
run ok1.sh
is  "A1 a passing suite exits 0"                   0 "$RC"
fail_suite bad1.sh
qfile ''
run bad1.sh
is  "A2 a failing, non-quarantined suite exits 1"  1 "$RC"
has "A2 and names it FAILED"                       "$OUT" "FAILED:"

echo "-- B. quarantine forgives a suite that EXISTS and fails"
qfile "$(printf 'bad1.sh\thf7y/senechal#1\tsome reason')"
run bad1.sh
is  "B1 exits 0 -- quarantined failures do not gate" 0 "$RC"
has "B1 and says QUARANTINED"                      "$OUT" "QUARANTINED"

echo "-- C. a quarantine entry that passes is announced stale, not forgiven silently"
qfile "$(printf 'ok1.sh\thf7y/senechal#1\tstale now')"
run ok1.sh
is  "C1 a quarantined PASS still exits 0"          0 "$RC"
has "C1 and flags the entry as stale"              "$OUT" "quarantine entry is stale"

echo "-- D. #464: deletion is not forgiveness"
qfile "$(printf 'gone.sh\thf7y/senechal#464\tdeleted suite')"
run gone.sh
is  "D1 a quarantined but MISSING suite exits 1"   1 "$RC"
has "D1 and says it does not exist"                "$OUT" "does not exist"
hasnot "D1 and is not reported QUARANTINED"        "$OUT" "QUARANTINED"
has "D1 and is named in FAILED"                    "$OUT" "gone.sh"

echo "-- E. quarantine matching survives a ./ prefix mismatch"
qfile "$(printf './bad1.sh\thf7y/senechal#1\tsome reason')"
run bad1.sh
is  "E1 quarantine entry with ./ matches a bare caller path" 0 "$RC"
qfile "$(printf 'bad1.sh\thf7y/senechal#1\tsome reason')"
run ./bad1.sh
is  "E2 a bare quarantine entry matches a ./ caller path"    0 "$RC"

echo "-- F. BLIND: no suite paths given"
OUT="$(bash "$SUT" 2>&1)"; RC=$?
is  "F1 no arguments exits 6"                      6 "$RC"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
