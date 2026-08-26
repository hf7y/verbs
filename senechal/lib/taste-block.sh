#!/usr/bin/env bash
# lib/taste-block.sh -- idempotent marker-delimited block installer.
#
# A "taste" is a Zach preference (see CONCERNS.md, senechal.json's
# estate.taste) that should be applied to a file identically on every
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -euo pipefail

begin_mark() { printf '# >>> senechal taste:%s >>> (managed by senechal remedies/*.sh -- hand edits here are overwritten by the next enable)\n' "$1"; }
end_mark()   { printf '# <<< senechal taste:%s <<<\n' "$1"; }

# file id -> block content without markers on stdout; exit 1 if the file
# or the markers are absent (not an error -- "not installed yet").
extract_block() {
  local file="$1" id="$2" b e
  [ -f "$file" ] || return 1
  b="$(begin_mark "$id")"; e="$(end_mark "$id")"
  awk -v b="$b" -v e="$e" '
    $0==b {inblock=1; next}
    $0==e {inblock=0; found=1; next}
    inblock {print}
    END {exit found ? 0 : 1}
  ' "$file"
}

cmd_install() {
  local file="$1" id="$2" content b e cur
  content="$(printf '%s' "$3" | base64 -d)"
  b="$(begin_mark "$id")"; e="$(end_mark "$id")"
  mkdir -p "$(dirname "$file")"
  touch "$file"

  if cur="$(extract_block "$file" "$id" 2>/dev/null)"; then
    if [ "$cur" = "$content" ]; then
      echo "unchanged: $file [$id]"
      return 0
    fi
    # Splice by line number rather than through awk -v: the content is
    # full of backslash escapes (\[, \e, \u, ...) that awk -v's own
    # escape processing would silently mangle.
    local begin_line end_line
    begin_line="$(grep -n -F -x "$b" "$file" | head -n1 | cut -d: -f1)"
    end_line="$(grep -n -F -x "$e" "$file" | head -n1 | cut -d: -f1)"
    {
      head -n "$begin_line" "$file"
      printf '%s\n' "$content"
      tail -n "+$end_line" "$file"
    } > "$file.senechal-taste-tmp"
    mv "$file.senechal-taste-tmp" "$file"
    echo "updated: $file [$id]"
  else
    { printf '\n%s\n%s\n%s\n' "$b" "$content" "$e"; } >> "$file"
    echo "installed: $file [$id]"
  fi
}

cmd_verify() {
  local file="$1" id="$2" content cur
  content="$(printf '%s' "$3" | base64 -d)"
  if ! cur="$(extract_block "$file" "$id" 2>/dev/null)"; then
    echo "MISSING: $file [$id]"
    return 1
  fi
  if [ "$cur" = "$content" ]; then
    echo "OK: $file [$id]"
    return 0
  fi
  echo "DRIFTED: $file [$id]"
  return 1
}

main() {
  if [ $# -lt 1 ]; then
    echo "usage: taste-block.sh {install|verify} <file> <id> <base64-content>" >&2
    exit 64
  fi
  local verb="$1"
  shift
  case "$verb" in
    install) cmd_install "$@" ;;
    verify)  cmd_verify "$@" ;;
    *) echo "usage: taste-block.sh {install|verify} <file> <id> <base64-content>" >&2; exit 64 ;;
  esac
}

# Only run main when executed, not when sourced (lets a caller reuse
# extract_block directly if it ever needs to).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
