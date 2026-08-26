#!/usr/bin/env bash
# Regression: enable from a temp checkout must refuse rather than bake a
# doomed symlink into ~/.local/bin (found 2026-08-16 -- two dangling shims
# pointing into a deleted /tmp/tmp.XXXX/tools/).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
fails=0
t() { if "$@"; then echo "ok   $*"; else echo "FAIL $*"; fails=$((fails+1)); fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/clone/tools" "$tmp/clone/remedies" "$tmp/clone/lib" "$tmp/home/.local/bin"
cp "$REPO/lib/common.sh" "$tmp/clone/lib/"
cp "$REPO/remedies/window-spawn-desktop.sh" "$tmp/clone/remedies/"
echo "{\"watch\": []}" > "$tmp/cfg.json"
for s in spawn-here browse; do printf '#!/bin/sh\n' > "$tmp/clone/tools/$s"; chmod +x "$tmp/clone/tools/$s"; done

out=$(HOME="$tmp/home" SENECHAL_CONFIG="$tmp/cfg.json" \
      bash "$tmp/clone/remedies/window-spawn-desktop.sh" enable 2>&1)
rc=$?
t [ "$rc" = 2 ]
t grep -q REFUSING <<<"$out"
t [ ! -e "$tmp/home/.local/bin/spawn-here" ]

# And a dangling shim must fail verify, not merely go unmentioned.
ln -sfn "$tmp/gone/tools/browse" "$tmp/home/.local/bin/browse"
out=$(HOME="$tmp/home" SENECHAL_CONFIG="$tmp/cfg.json" \
      bash "$REPO/remedies/window-spawn-desktop.sh" verify 2>&1)
t grep -q "dangles" <<<"$out"

[ "$fails" = 0 ] && echo "PASS" || echo "$fails FAILED"
exit $((fails > 0))
