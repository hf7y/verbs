#!/usr/bin/env bash
# senechal: how much of PATH still runs out of a git checkout?
#
#   ./path-from-checkout.sh            # list the stragglers, ratchet against the ceiling
#   ./path-from-checkout.sh -q         # silent unless the ceiling is breached
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

BIN="${PATH_FROM_CHECKOUT_BIN:-$HOME/.local/bin}"
CEILING_FILE="$HERE/path-from-checkout.ceiling"

QUIET=0; LOWER=0
case "${1:-}" in -q) QUIET=1 ;; --lower) LOWER=1 ;; esac
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
loud() { printf '%s\n' "$*" >&2; }

[ -d "$BIN" ] || { loud "no $BIN -- cannot check"; exit "$RC_INCOMPLETE"; }
[ -r "$CEILING_FILE" ] || { loud "no $CEILING_FILE -- cannot check"; exit "$RC_INCOMPLETE"; }
ceiling=$(tr -dc 0-9 < "$CEILING_FILE")
[ -n "$ceiling" ] || { loud "$CEILING_FILE holds no number"; exit "$RC_INCOMPLETE"; }

rc="$RC_PASS"
count=0
for f in "$BIN"/*; do
  [ -L "$f" ] || continue
  target=$(readlink -f "$f")
  if [ ! -e "$target" ]; then
    loud "FAIL $(basename "$f") dangles -> $(readlink "$f")"
    rc="$RC_FAIL"; continue
  fi
  # A checkout is a path with a .git anywhere above it. The deployed
  # tree (verb-builds/current/...) has none, which is the whole point.
  d=$(dirname "$target")
  while [ "$d" != "/" ]; do
    if [ -e "$d/.git" ]; then
      count=$((count + 1))
      say "checkout $(basename "$f") -> $target"
      break
    fi
    d=$(dirname "$d")
  done
done

if [ "$LOWER" = 1 ]; then
  if [ "$count" -lt "$ceiling" ]; then
    printf '%s\n' "$count" > "$CEILING_FILE"
    echo "ceiling lowered $ceiling -> $count"
    exit "$RC_PASS"
  fi
  loud "nothing to lower: $count still on PATH from a checkout, ceiling is $ceiling"
  exit "$RC_FAIL"
fi

say "$count of PATH runs from a checkout (ceiling $ceiling)"
if [ "$count" -gt "$ceiling" ]; then
  loud "FAIL $count > ceiling $ceiling -- a new shim was linked into a working clone."
  loud "Deploy it as a verb instead, or raise the ceiling in a reviewable diff."
  rc="$RC_FAIL"
elif [ "$count" -lt "$ceiling" ]; then
  say "note below ceiling -- run --lower to bank it"
fi
exit "$rc"
