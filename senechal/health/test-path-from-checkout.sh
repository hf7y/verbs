#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/path-from-checkout.sh"
fails=0
t() { local want=$1 desc=$2; shift 2
  local out rc; out=$("$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then echo "ok   $desc"
  else echo "FAIL $desc (rc=$rc want $want)"; echo "$out" | sed 's/^/     /'; fails=$((fails+1)); fi
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/clone/.git" "$tmp/clone/bin" "$tmp/deployed/bin" "$tmp/h"
touch "$tmp/clone/bin/fromclone" "$tmp/deployed/bin/deployed"
ln -s "$tmp/clone/bin/fromclone" "$tmp/bin/fromclone"
ln -s "$tmp/deployed/bin/deployed" "$tmp/bin/deployed"
run() { PATH_FROM_CHECKOUT_BIN="$tmp/bin" HOME="$tmp/h" \
        SENECHAL_CONFIG="$tmp/cfg.json" bash "$CHECK" "$@"; }
echo '{"watch": []}' > "$tmp/cfg.json"

cp "$HERE/path-from-checkout.ceiling" "$tmp/ceiling.bak"
echo 1 > "$HERE/path-from-checkout.ceiling"
t 0 "one checkout shim, ceiling 1 -> pass" run -q
echo 0 > "$HERE/path-from-checkout.ceiling"
t 1 "same shim, ceiling 0 -> fail" run -q

# The dangling case that started this: must be a failure, not a shrug.
ln -s "$tmp/gone/x" "$tmp/bin/dangler"
t 1 "dangling shim -> fail" run -q
cp "$tmp/ceiling.bak" "$HERE/path-from-checkout.ceiling"

[ "$fails" = 0 ] && echo "PASS" || echo "$fails FAILED"
exit $((fails > 0))
