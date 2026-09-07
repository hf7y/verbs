#!/usr/bin/env bash
PRIVILEGED=no
HOSTS=(mandark)
REACHES=()
set -uo pipefail   # drop dead [Default Applications] entries in mimeapps.list (#628); picking a replacement is Zach's call

cd "$(dirname "${BASH_SOURCE[0]}")"
. ../lib/common.sh

MIMEAPPS_FILE="${MIMEAPPS_HANDLERS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list}"

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

dead_reason() { # <id> -> reason on stdout; 1 if it resolves fine
  local id="$1" path
  if ! path="$(desktop_file_path "$id")"; then
    printf 'no .desktop anywhere\n'; return 0
  elif ! desktop_exec_binary "$path" >/dev/null; then
    printf 'Exec binary missing\n'; return 0
  fi
  return 1
}

do_enable() {
  say "senechal remedy: drop dead mimeapps.list [Default Applications] entries (#628)"
  if [ ! -r "$MIMEAPPS_FILE" ]; then
    say "no $MIMEAPPS_FILE -- nothing to clean."
    return 0
  fi

  local tmp in_default=0 mime value id reason dropped=0
  tmp="$(mktemp)"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '['*']')
        in_default=0
        [ "$line" = "[Default Applications]" ] && in_default=1
        printf '%s\n' "$line" >> "$tmp"
        continue ;;
    esac
    if [ "$in_default" = 1 ] && [ "${line#*=}" != "$line" ]; then
      mime="${line%%=*}"; value="${line#*=}"; id="${value%%;*}"
      if [ -n "$id" ] && reason="$(dead_reason "$id")"; then
        say "  dropping $mime -> $id ($reason)"
        dropped=$((dropped + 1))
        continue
      fi
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$MIMEAPPS_FILE"

  if [ "$dropped" -eq 0 ]; then
    say "no dead [Default Applications] entries -- nothing to do."
    rm -f "$tmp"
    return 0
  fi

  local backup
  backup="$(backup_file "$MIMEAPPS_FILE")"
  mv "$tmp" "$MIMEAPPS_FILE"
  say ""
  say "dropped $dropped dead handler(s). Backup: ${backup:-<none>}"
  say "picking a real replacement for each is still your call -- this only"
  say "stopped mimeapps.list lying about pointing at something runnable."
}

do_verify() {
  head_ "mimeapps.list [Default Applications] entries all resolve (#628)"
  if [ ! -r "$MIMEAPPS_FILE" ]; then
    skip "no $MIMEAPPS_FILE -- cannot check"
    finish_verify
    return
  fi

  local in_default=0 mime value id reason total=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '['*']')
        in_default=0
        [ "$line" = "[Default Applications]" ] && in_default=1
        continue ;;
    esac
    [ "$in_default" = 1 ] || continue
    [ "${line#*=}" != "$line" ] || continue
    mime="${line%%=*}"; value="${line#*=}"; id="${value%%;*}"
    [ -n "$id" ] || continue
    total=$((total + 1))
    if reason="$(dead_reason "$id")"; then
      fail "$mime -> $id ($reason) -- run: ./mimeapps-dead-handlers-cleanup.sh enable"
    else
      ok "$mime -> $id"
    fi
  done < "$MIMEAPPS_FILE"

  [ "$total" -eq 0 ] && skip "no [Default Applications] entries in $MIMEAPPS_FILE"
  finish_verify "OK -- $total handler(s) checked, all resolve."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
