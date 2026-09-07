#!/usr/bin/env bash
set -uo pipefail  # tools/test-common.sh -- suite for deployed_source_sha(). 0 = pass.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; echo "       $2"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want '$2', got '$3'"; }

run() {   # <deployed-root-or-empty> -> stdout of deployed_source_sha()
  SENECHAL_DEPLOYED_ROOT="$1" SENECHAL_SKIP_CONFIG_CHECK=1 \
    bash -c ". '$REPO/lib/common.sh'; deployed_source_sha"
}

echo "-- A. no deployed build at all"
is "A1 empty when SENECHAL_DEPLOYED_ROOT names nothing" "" "$(run "$T/nope")"

echo "-- B. a build root with no manifest.tsv beside it"
mkdir -p "$T/b1/senechal"
is "B1 empty when the manifest is missing" "" "$(run "$T/b1/senechal")"

echo "-- C. a manifest, but no senechal row"
mkdir -p "$T/c1/senechal"
printf '# verb build\nother\tinstalle\tdeadbee\thttps://example/other.git\n' > "$T/c1/manifest.tsv"
is "C1 empty when senechal has no row" "" "$(run "$T/c1/senechal")"

echo "-- D. the real shape: manifest.tsv is a SIBLING of the project root"
mkdir -p "$T/d1/senechal"
printf '# verb build 2026-09-01T030800Z\n# NOT-A-VERB\tsenechal\tsome-script.sh\tcommentary, not a row\nrealisateur\tnotify-senechal\taaaaaaa\thttps://example/realisateur.git\nsenechal\tinstalle\t7ff910d53c1d3b33360f2e0a12ec4e9991e7e2f6\thttps://github.com/hf7y/senechal.git\n' \
  > "$T/d1/manifest.tsv"
is "D1 reads the sha from the senechal row" \
  "7ff910d53c1d3b33360f2e0a12ec4e9991e7e2f6" "$(run "$T/d1/senechal")"

echo "-- E. multiple senechal rows (one per verb) agree; the first wins"
mkdir -p "$T/e1/senechal"
printf 'senechal\tinstalle\tcafef00d\thttps://github.com/hf7y/senechal.git\nsenechal\tanotherverb\tcafef00d\thttps://github.com/hf7y/senechal.git\n' \
  > "$T/e1/manifest.tsv"
is "E1 the first matching row's sha is returned" "cafef00d" "$(run "$T/e1/senechal")"

echo
echo "test-common.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
