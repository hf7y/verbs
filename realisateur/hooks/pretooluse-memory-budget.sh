#!/usr/bin/env bash
set -uo pipefail  # hooks/pretooluse-memory-budget.sh: PreToolUse guard on Write|Edit (#715) -- refuses a write to a memory/MEMORY.md index that would push it past its load budget, instead of letting the tail truncate silently

log() { printf 'pretooluse-memory-budget: %s\n' "$*" >&2; }

payload="$(cat 2>/dev/null)" || { log "could not read hook payload from stdin"; exit 1; }

tool="$(printf '%s' "$payload" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q')"
case "$tool" in
  Write|Edit) ;;
  *) exit 0 ;;  # not a file write this guard has an opinion about
esac

command -v jq >/dev/null 2>&1 || { log "no jq on PATH -- cannot size the write reliably, letting it through"; exit 0; }

path="$(jq -r '.tool_input.file_path // empty' <<<"$payload" 2>/dev/null)"
case "$path" in
  */memory/MEMORY.md) ;;
  *) exit 0 ;;  # only the loaded index has a documented budget; per-topic memory files do not
esac

BUDGET="${MEMORY_BUDGET_BYTES:-24400}"  # measured #715: Claude Code's load budget for MEMORY.md was 24,400 bytes when the truncation was caught

if [ "$tool" = Write ]; then
  new_size="$(jq -r '.tool_input.content // ""' <<<"$payload" 2>/dev/null | wc -c)"
else
  old_size=0
  [ -r "$path" ] && old_size="$(wc -c < "$path" 2>/dev/null || echo 0)"
  old_len="$(jq -r '.tool_input.old_string // ""' <<<"$payload" 2>/dev/null | wc -c)"
  new_len="$(jq -r '.tool_input.new_string // ""' <<<"$payload" 2>/dev/null | wc -c)"
  new_size=$(( old_size - old_len + new_len ))
fi

if [ "$new_size" -gt "$BUDGET" ]; then
  {
    echo "BLOCKED: this write would leave $path at $new_size bytes, over its $BUDGET-byte load budget."
    echo
    echo "Past budget, the tail is silently dropped -- entries never load, not even the guard that would have caught it (#715)."
    echo "Compress or delete an entry first (fold a superseded rule into the memory that superseded it, or retire one whose work has closed), then retry the write."
  } >&2
  exit 2
fi

exit 0
