#!/usr/bin/env bash
set -uo pipefail  # SUBJECT: bin/lib/zaxon.sh's contract as the ONE place that talks to zaxon (#458). PINS the guard #458 asked for, mirroring realisateur's ausculte-cadence.test.sh: "the comment saying 'do not re-add' is prose, and prose is what failed here."
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
LIB="$REPO/bin/lib/zaxon.sh"

echo "zaxon-contract.test.sh"

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

section "A. no caller reimplements the protocol -- everyone sources the lib"
others="$(grep -rl 'jsonrpc\|ask_zach\|mcp-session-id' --include='*.sh' --include='*.py' "$REPO" 2>/dev/null | grep -v -e "^$LIB\$" -e "^$SELF\$")"
if [ -z "$others" ]; then
  ok "A1 no file outside bin/lib/zaxon.sh speaks the zaxon JSON-RPC wire format"
else
  bad "A1 no file outside bin/lib/zaxon.sh speaks the zaxon JSON-RPC wire format" "found in: $others"
fi

section "B. no copied constants -- zaxon's own contract, not a stale snapshot of it"
consts="$(grep -rl 'MAX_QUESTION_CHARS\|QUESTION_TTL_SECS' --include='*.sh' --include='*.py' "$REPO" 2>/dev/null | grep -v -e "^$SELF\$")"
if [ -z "$consts" ]; then
  ok "B1 no MAX_QUESTION_CHARS/QUESTION_TTL_SECS copy anywhere in this repo"
else
  bad "B1 no MAX_QUESTION_CHARS/QUESTION_TTL_SECS copy anywhere in this repo" "found in: $consts"
fi

section "C. no reply-polling loop -- the lib exposes ask and probe only, never a check"
if grep -q 'zaxon_check\|zaxon_poll\|zaxon_wait' "$LIB" 2>/dev/null; then
  bad "C1 the lib exposes no reply-checking function" "a check/poll/wait helper was added to $LIB"
else
  ok "C1 the lib exposes no reply-checking function"
fi
callers="$(grep -rl 'zaxon_ask\|zaxon_probe' --include='*.sh' "$REPO" 2>/dev/null | grep -v "^$LIB\$")"
blocking=""
for f in $callers; do
  grep -qE '(while|until)[^#]*(zaxon|ticket)' "$f" 2>/dev/null && blocking="$blocking $f"
done
if [ -z "$blocking" ]; then
  ok "C2 no caller loops waiting on a zaxon reply"
else
  bad "C2 no caller loops waiting on a zaxon reply" "found a wait-loop in:$blocking"
fi

section "D. never fatal -- an unreachable relay degrades to report-only (#458's own rule)"
. "$LIB"
out="$(ZAXON="http://127.0.0.1:1 http://127.0.0.1:2" zaxon_ask "test message" test-caller 2>&1)"; rc=$?
eq "D1 zaxon_ask exits 0 even when every relay is unreachable" "$rc" "0"
case "$out" in *"NOT delivered"*) ok "D2 it says the message was NOT delivered, rather than staying silent" ;;
  *) bad "D2 it says the message was NOT delivered, rather than staying silent" "got: $out" ;; esac
hasnt "D3 no ticket id is printed to stdout on failure" "$out" "$(printf '\n')ticket"

section "E. removing the ping must not remove the signal (H4 from ausculte-cadence)"
has "E1 monkey-watch.sh only marks an alert sent once zaxon_ask actually returned a ticket" \
  "$(grep -v '^[[:space:]]*#' "$REPO/bin/monkey-watch.sh")" 'if [ -n "$tid" ]; then'
has "E2 publishing is unconditional -- it does not sit inside that same guard" \
  "$(grep -v '^[[:space:]]*#' "$REPO/bin/monkey-watch.sh")" 'gh repo clone "$PUBLISH_REPO"'
ask_ln="$(grep -n 'zaxon_ask "\$msg"' "$REPO/bin/monkey-watch.sh" | head -1 | cut -d: -f1)"
publish_ln="$(grep -n 'gh repo clone "\$PUBLISH_REPO"' "$REPO/bin/monkey-watch.sh" | head -1 | cut -d: -f1)"
if [ -n "$ask_ln" ] && [ -n "$publish_ln" ] && [ "$ask_ln" -lt "$publish_ln" ]; then
  ok "E3 the publish step runs after the ask, unguarded by its outcome"
else
  bad "E3 the publish step runs after the ask, unguarded by its outcome" "ask at ${ask_ln:-none}, publish at ${publish_ln:-none}"
fi

summary
