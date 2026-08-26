#!/usr/bin/env bash
# The failure this reproduces: `door` absent -> every typed filing rejected.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo '{"watch": []}' > "$tmp/cfg.json"

# Fake gh: prints whatever label set the case under test wants.
mk_gh() { printf '#!/bin/sh\n[ "$1" = label ] || exit 1\nprintf "%%s\\n" %s\n' "$1" > "$tmp/gh"; chmod +x "$tmp/gh"; }
run() { PATH="$tmp:$PATH" SENECHAL_CONFIG="$tmp/cfg.json" bash "$HERE/front-door-labels.sh" -q 2>&1; }
t() { local want=$1 desc=$2 out; out=$(run); local rc=$?
  if [ "$rc" = "$want" ]; then echo "ok   $desc"
  else echo "FAIL $desc (rc=$rc want $want)"; echo "$out" | sed 's/^/     /'; fails=$((fails+1)); fi; }

mk_gh "door idea"; t 0 "both labels present"
mk_gh "idea";      t 1 "door missing -- the 2026-08-16 outage"
mk_gh "door";      t 1 "idea missing"
mk_gh "doorway";   t 1 "substring is not a match"

printf '#!/bin/sh\nexit 1\n' > "$tmp/gh"; chmod +x "$tmp/gh"
t 2 "gh cannot list labels -> could-not-check, not pass"

[ "$fails" = 0 ] && echo "PASS" || echo "$fails FAILED"
exit $((fails > 0))
