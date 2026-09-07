#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${SENECHAL_ROOT:-$HERE}"
cd "$ROOT"

OUT="$(python3 tools/absorb-notices.py --write --close 2>&1)" && RC=0 || RC=$?
printf '%s\n' "$OUT"

[ "$RC" -ne 2 ] || exit "$RC"

if git diff --quiet -- registry/ 2>/dev/null && git diff --cached --quiet -- registry/ 2>/dev/null; then
  echo "absorb-and-pr: no registry/ change -- nothing to PR"
  exit "$RC"
fi

ORIG_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BRANCH="absorb-notices-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo run)-$$"
git checkout -q -b "$BRANCH"
git add registry/
git commit -q -F - <<EOF
registry/: absorb pending door filing(s)

$(git diff --cached --stat -- registry/)

The actuator half of #484: tools/absorb-notices.py --write --close applied
these mechanically. boundary.py's CONFIG_KEYS did the fleet/taste routing;
nothing here needed a judgment call, and anything that did (an existing
key, a taste filing off the taste host) was left open instead.
EOF
git push -q -u origin "$BRANCH"

gh pr create \
  --title "registry/: absorb pending door filing(s)" \
  --body "$(cat <<'BODY'
NO-DECISION: mechanical -- tools/absorb-notices.py --write --close applied
every pending fleet filing to registry/senechal-registry.json, the store
issue #411 already designated as canonical. No field required a judgment
call: boundary.py's CONFIG_KEYS did the fleet/taste routing, and any filing
that needed a human (an existing key already registered, a taste filing off
the taste host) was left open rather than absorbed.

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- repo:hf7y/senechal path:registry/senechal-registry.json -- absorbed filing(s) applied
<!-- /DELIVERS -->
BODY
)" >&2

git checkout -q "$ORIG_BRANCH"
echo "absorb-and-pr: opened a PR for $BRANCH"
exit "$RC"
