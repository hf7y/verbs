#!/usr/bin/env bash
# zaxon.sh -- the ask_zach call in ONE place. crt's `demande` verb is the
# estate-wide door. NEVER FATAL: a recovery that aborts because it could not
# announce itself is worse than a silent one.
# 140 CHARS, REFUSED NOT TRUNCATED -- and the rendered length counts the
# `[<from_agent>] ` tag, so a long from_agent spends the budget (ZAXON_MAX=110).

# Same ordering as zaxon_ask, for the same reason.
zaxon_probe() {
  local from="${1:-agent}" url
  for url in ${ZAXON:-http://100.107.253.56:8643/mcp http://127.0.0.1:8643/mcp}; do
    curl -s -m 8 -o /dev/null -H 'Content-Type: application/json' \
      -H 'Accept: application/json,text/event-stream' -X POST "$url" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"$from\",\"version\":\"1\"}}}" \
      2>/dev/null && { printf '%s\n' "$url"; return 0; }
  done
  return 1
}

zaxon_ask() {
  local msg="$1" from="${2:-agent}" url hdr sid body tid
  hdr="$(mktemp)"; body="$(mktemp)"
  # TAILNET FIRST: zaxon runs on dexter, so 127.0.0.1 answers only when the
  # caller IS dexter. Loopback listed first reads as the primary route, which
  # is how "zaxon is unreachable from monkey" keeps being re-derived.
  for url in ${ZAXON:-http://100.107.253.56:8643/mcp http://127.0.0.1:8643/mcp}; do
    : > "$hdr"
    curl -s -D "$hdr" -o /dev/null --connect-timeout 5 -m 20 -H 'Content-Type: application/json' \
      -H 'Accept: application/json,text/event-stream' -X POST "$url" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"$from\",\"version\":\"1\"}}}" \
      >/dev/null 2>&1 || continue
    sid="$(tr -d '\r' < "$hdr" | awk 'tolower($1)=="mcp-session-id:"{print $2}')"
    [ -n "$sid" ] || continue
    curl -s -o /dev/null -m 20 -H 'Content-Type: application/json' \
      -H 'Accept: application/json,text/event-stream' -H "mcp-session-id: $sid" \
      -X POST "$url" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null 2>&1
    MSG="$msg" FROM="$from" python3 -c 'import json,os; print(json.dumps({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ask_zach","arguments":{"question":os.environ["MSG"],"from_agent":os.environ["FROM"]}}}))' > "$body" || continue
    ans="$(curl -s -m 30 -H 'Content-Type: application/json' \
      -H 'Accept: application/json,text/event-stream' -H "mcp-session-id: $sid" \
      -X POST "$url" --data-binary "@$body" 2>/dev/null | tr -d '\r')"
    tid="$(printf '%s' "$ans" | grep -oE '"ticket_id\\?": ?\\?"[0-9a-f]+' | grep -oE '[0-9a-f]{6,}$' | head -1)"
    if [ -z "$tid" ]; then
      why="$(printf '%s' "$ans" | grep -oE '\\?"error\\?": ?\\?"[^"\\]*' | sed 's/.*"//' | head -1)"
      [ -n "$why" ] && { rm -f "$hdr" "$body"
        printf 'zaxon_ask: the relay REFUSED this message: %s\n' "$why" >&2; return 0; }
      continue
    fi
    rm -f "$hdr" "$body"; printf '%s\n' "$tid"; return 0
  done
  rm -f "$hdr" "$body"
  printf 'zaxon_ask: no relay answered; the message was NOT delivered\n' >&2
  return 0
}
