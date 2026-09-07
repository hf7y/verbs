#!/usr/bin/env bash
# lib/part.sh -- where is the script I am about to call: beside me, under
# libexec, or on PATH as a verb. TRAP: needs $HERE set by the caller.

[ -n "${PART_LIB:-}" ] && return 0
PART_LIB=1

part() {
  local n="$1" p
  for p in "$HERE/$n" "${SELFDEV_LIBEXEC:-/usr/local/libexec/selfdev}/$n" \
           "$HERE/${n%.sh}" "$(command -v "${n%.sh}" 2>/dev/null || true)"; do
    [ -n "$p" ] && [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}
