#!/usr/bin/env bash
set -uo pipefail  # hooks/session-start-memory-budget.sh: SessionStart context hook (#715) -- states MEMORY.md's size against its load budget, and warns inside ~10% of it, so a cliff nobody sees coming doesn't produce another silent truncation. Always exits 0: context, never a gate.

payload="$(cat 2>/dev/null)" || true
cwd="${CLAUDE_PROJECT_DIR:-}"
[ -n "$cwd" ] || cwd="$(printf '%s' "$payload" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[ -n "$cwd" ] || cwd="$PWD"

MEMORY_ROOT="${MEMORY_ROOT:-$HOME/.claude/projects}"
slug="$(printf '%s' "$cwd" | tr '/' '-')"
memfile="$MEMORY_ROOT/$slug/memory/MEMORY.md"

[ -f "$memfile" ] || exit 0

size="$(wc -c < "$memfile" 2>/dev/null || echo 0)"
BUDGET="${MEMORY_BUDGET_BYTES:-24400}"  # same figure hooks/pretooluse-memory-budget.sh guards writes against (#715)
warn_at=$(( BUDGET - BUDGET / 10 ))     # ~10%: "a cliff nobody sees coming is what produced this" (#715)

[ "$size" -ge "$warn_at" ] || exit 0

pct=$(( size * 100 / BUDGET ))
if [ "$size" -gt "$BUDGET" ]; then
  printf 'memory: MEMORY.md is %d bytes, OVER its %d-byte load budget (%d%%) -- the tail is not loading. Compress now.\n' "$size" "$BUDGET" "$pct"
else
  printf 'memory: MEMORY.md is %d bytes of its %d-byte load budget (%d%%) -- headroom is running out.\n' "$size" "$BUDGET" "$pct"
fi
exit 0
