#!/usr/bin/env bash
# The runner remedy exists because three PRs (#397, #400, #401) sat with their
# prose checks pending for 1h44m while the unit was cleanly dead -- exited
# status=0/SUCCESS, no crash loop, nothing to notice. So the case that matters
# here is not "restart worked", it is that a unit reporting anything other than
# `active` FAILS rather than being reported as fine.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
fails=0
t() { if "$@"; then echo "ok   $*"; else echo "FAIL $*"; fails=$((fails+1)); fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo '{"watch": []}' > "$tmp/cfg.json"
run() { HOME="$tmp/home" SENECHAL_CONFIG="$tmp/cfg.json" \
        SENECHAL_SYSTEMCTL="$tmp/systemctl" SENECHAL_SUDO_CMD="" \
        bash "$REPO/remedies/selfdev-runner-monkey-senechal.sh" "$@" 2>&1; }

fake() {  # $1 = what `is-active` prints, $2 = its exit code
  cat > "$tmp/systemctl" <<EOF
#!/bin/sh
[ "\$1" = is-active ] && { echo "$1"; exit $2; }
echo "restart \$2" >> "$tmp/restarts"
exit 0
EOF
  chmod +x "$tmp/systemctl"
}

fake active 0
out=$(run verify); t [ "$?" = 0 ]
t grep -q "PASS" <<<"$out"

# The 2026-08-23 shape: cleanly exited, not crashed. Must FAIL, not pass.
fake inactive 3
out=$(run verify); rc=$?
t [ "$rc" = 1 ]
t grep -q "not active" <<<"$out"

fake failed 3
out=$(run verify); t [ "$?" = 1 ]

# Cannot see the unit at all is INCOMPLETE (2), never a pass -- this remedy is
# meant to run from a laptop that is not monkey.
rm -f "$tmp/systemctl"
out=$(run verify); t [ "$?" = 2 ]
t grep -qi "could not query" <<<"$out"

# enable restarts the named unit, and only that one.
fake inactive 3
: > "$tmp/restarts"
run enable >/dev/null
t grep -q "actions.runner.hf7y-senechal.monkey-senechal.service" "$tmp/restarts"
t [ "$(wc -l < "$tmp/restarts")" = 1 ]

[ "$fails" = 0 ] && echo "PASS" || echo "$fails FAILED"
exit $((fails > 0))
