#!/usr/bin/env bash
# Sandboxed test of the browser-handler checks (sourced, not CLI-driven); underscore prefix load-bearing, verify-all.sh globs ./*.sh.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

export HOME="$SANDBOX/home"
export SENECHAL_CONFIG="$SANDBOX/senechal.json"
export XDG_DATA_HOME="$SANDBOX/home/.local/share"
export XDG_DATA_DIRS="$SANDBOX/usr/share"
mkdir -p "$XDG_DATA_HOME/applications" "$SANDBOX/usr/share/applications" "$SANDBOX/bin"
printf '{}\n' > "$SENECHAL_CONFIG"

sed -n '1,/^do_enable() {/p' "$HERE/mozilla-firefox-real.sh" \
  | sed '/^do_enable() {/d; /^\. \.\.\/lib\/common\.sh$/d; /^cd "\$(dirname/d' \
  > "$SANDBOX/helpers.sh"
# shellcheck disable=SC1090
. "$SANDBOX/helpers.sh"

echo "== mozilla-firefox-real: browser handlers =="

printf '[Desktop Entry]\nExec=%s/bin/realbrowser %%u\n' "$SANDBOX" \
  > "$XDG_DATA_HOME/applications/userapp-Firefox-TEST.desktop"
printf '[Desktop Entry]\nExec=%s/bin/realbrowser %%u\n' "$SANDBOX" \
  > "$SANDBOX/usr/share/applications/firefox.desktop"
printf '#!/bin/sh\ntrue\n' > "$SANDBOX/bin/realbrowser"; chmod +x "$SANDBOX/bin/realbrowser"

got="$(desktop_file_path "userapp-Firefox-TEST.desktop")"
[ "$got" = "$XDG_DATA_HOME/applications/userapp-Firefox-TEST.desktop" ] \
  && pass "resolves an id in XDG_DATA_HOME, not just /usr/share" \
  || fail "did not resolve the XDG_DATA_HOME id (got '$got')"

got="$(desktop_file_path "firefox.desktop")"
[ "$got" = "$SANDBOX/usr/share/applications/firefox.desktop" ] \
  && pass "resolves an id in XDG_DATA_DIRS" || fail "did not resolve the XDG_DATA_DIRS id"

# mandark's default-web-browser still named this dead snap id on 2026-09-02
desktop_file_path "firefox_firefox.desktop" >/dev/null 2>&1 \
  && fail "a snap id that exists nowhere still resolved" \
  || pass "a desktop id that exists nowhere does NOT resolve"

printf '[Desktop Entry]\nExec=%s/bin/gone-with-the-package %%u\n' "$SANDBOX" \
  > "$XDG_DATA_HOME/applications/stale-exec.desktop"
p="$(desktop_file_path "stale-exec.desktop")"
[ -n "$p" ] && pass "the stale-Exec file itself exists (so a file-only check would pass it)" \
            || fail "fixture missing"
desktop_exec_binary "$p" >/dev/null 2>&1 \
  && fail "a desktop file whose Exec binary is gone was reported runnable" \
  || pass "a desktop file whose Exec binary is gone is caught as dead"

got="$(desktop_exec_binary "$SANDBOX/usr/share/applications/firefox.desktop")"
[ "$got" = "$SANDBOX/bin/realbrowser" ] \
  && pass "a live handler resolves to its Exec binary" \
  || fail "live handler did not resolve (got '$got')"

printf '[Desktop Entry]\nExec=realbrowser %%u\n' > "$XDG_DATA_HOME/applications/onpath.desktop"
PATH="$SANDBOX/bin:$PATH" desktop_exec_binary "$XDG_DATA_HOME/applications/onpath.desktop" >/dev/null 2>&1 \
  && pass "a bare-command Exec resolves through PATH" \
  || fail "a bare-command Exec was not resolved through PATH"

export XDG_CONFIG_HOME="$SANDBOX/config"
mkdir -p "$XDG_CONFIG_HOME"
cat > "$XDG_CONFIG_HOME/mimeapps.list" <<'MIME'
[Added Associations]
x-scheme-handler/http=userapp-Firefox-TEST.desktop;firefox.desktop;
text/html=firefox.desktop;

[Default Applications]
x-scheme-handler/http=firefox_firefox.desktop
text/html=firefox.desktop;userapp-Firefox-TEST.desktop;
MIME

got="$(mimeapps_declared_id x-scheme-handler/http)"
[ "$got" = "firefox_firefox.desktop" ] \
  && pass "reads the DECLARED id, the dead one the resolver papers over" \
  || fail "declared id wrong (got '$got', wanted firefox_firefox.desktop)"

got="$(mimeapps_declared_id text/html)"
[ "$got" = "firefox.desktop" ] \
  && pass "takes the first id and drops the rest of a ';' list" \
  || fail "semicolon list not trimmed (got '$got')"

[ "$(mimeapps_declared_id x-scheme-handler/http)" != "userapp-Firefox-TEST.desktop" ] \
  && pass "reads [Default Applications], not [Added Associations]" \
  || fail "read the wrong section -- would miss the stale default"

mimeapps_declared_id x-scheme-handler/ftp >/dev/null 2>&1 \
  && fail "reported a declaration for a mime that has none" \
  || pass "an undeclared mime reports nothing rather than a stale guess"

rm -f "$XDG_CONFIG_HOME/mimeapps.list"
mimeapps_declared_id text/html >/dev/null 2>&1 \
  && fail "reported a declaration with no mimeapps.list at all" \
  || pass "no mimeapps.list is 'nothing declared', not an error"

echo ""
if [ "$fails" -eq 0 ]; then echo "PASS -- mozilla-firefox-real handlers"; exit 0; fi
echo "FAIL -- $fails assertion(s) failed"; exit 1
