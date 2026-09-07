#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

MIMEAPPS_FILE="${MIMEAPPS_HANDLERS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list}"

QUIET=0
[ "${1:-}" = -q ] && QUIET=1
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
loud() { printf '%s\n' "$*" >&2; }

[ -r "$MIMEAPPS_FILE" ] || { loud "no $MIMEAPPS_FILE -- cannot check"; exit "$RC_INCOMPLETE"; }

desktop_file_path() { # <id> -> path on stdout; 1 if unresolved
  local id="$1" dir
  local -a dirs=("${XDG_DATA_HOME:-$HOME/.local/share}")
  local -a extra
  IFS=: read -r -a extra <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  dirs+=("${extra[@]}")
  for dir in "${dirs[@]}"; do
    [ -n "$dir" ] || continue
    [ -f "$dir/applications/$id" ] && { printf '%s\n' "$dir/applications/$id"; return 0; }
  done
  return 1
}

desktop_exec_binary() { # <path> -> Exec binary on stdout; 1 if gone
  local f="$1" line bin
  line="$(grep -m1 '^Exec=' "$f" 2>/dev/null)" || return 1
  line="${line#Exec=}"; bin="${line%% *}"
  [ -n "$bin" ] || return 1
  case "$bin" in
    /*) [ -x "$bin" ] && printf '%s\n' "$bin" && return 0; return 1 ;;
    *)  command -v "$bin" 2>/dev/null && return 0; return 1 ;;
  esac
}

resolved=0; dead=0
while IFS='=' read -r section_or_key value; do
  case "$section_or_key" in
    '['*)
      in_default=0
      [ "$section_or_key" = "[Default Applications]" ] && in_default=1
      continue ;;
  esac
  [ "${in_default:-0}" = 1 ] || continue
  [ -n "$value" ] || continue
  mime="$section_or_key"
  id="${value%%;*}"
  [ -n "$id" ] || continue

  if ! path="$(desktop_file_path "$id")"; then
    say "  DEAD  $mime -> $id (no .desktop anywhere)"
    dead=$((dead + 1))
  elif ! bin="$(desktop_exec_binary "$path")"; then
    say "  DEAD  $mime -> $id ($path), Exec binary missing"
    dead=$((dead + 1))
  else
    resolved=$((resolved + 1))
  fi
done < "$MIMEAPPS_FILE"

total=$((resolved + dead))
say "[Default Applications]: $resolved resolve, $dead dead (of $total)"

if [ "$dead" -gt 0 ]; then
  loud "FAIL $dead of $total mimeapps.list handler(s) resolve to nothing runnable"
  exit "$RC_FAIL"
fi
exit "$RC_PASS"
