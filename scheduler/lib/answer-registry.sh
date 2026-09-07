#!/usr/bin/env bash
set -uo pipefail

_answer_registry_file() {
  printf '%s' "${ANSWER_REGISTRY_FILE:-${STATE_ROOT:-$HOME/.local/share}/scheduler-answers/registry.tsv}"
}

answer_registry_record() {
  local proj="${1:?answer_registry_record: project required}" \
        issue="${2:?answer_registry_record: issue required}" \
        marker="${3:-relay}" \
        text="${4:-}"
  local f; f="$(_answer_registry_file)"
  local dir; dir="$(dirname "$f")"
  mkdir -p "$dir" 2>/dev/null || return 1
  marker="$(printf '%s' "$marker" | tr -d '\t\n')"
  text="$(printf '%s' "$text" | sed ':a;N;$!ba;s/\\/\\\\/g; s/\t/\\t/g; s/\n/\\n/g')"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Is)" "$proj" "$issue" "${marker:-relay}" "$text" >> "$f" || return 1
}

answer_registry_unread() {
  local proj="${1:?answer_registry_unread: project required}" since="${2:-}"
  local f; f="$(_answer_registry_file)"
  [ -r "$f" ] || return 0
  local since_epoch=0
  if [ -n "$since" ]; then
    since_epoch="$(date -d "$since" +%s 2>/dev/null)" || since_epoch=0
  fi
  local ts p issue marker text row_epoch
  while IFS=$'\t' read -r ts p issue marker text; do
    [ "$p" = "$proj" ] || continue
    row_epoch="$(date -d "$ts" +%s 2>/dev/null)" || continue
    [ "$row_epoch" -gt "$since_epoch" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$ts" "$issue" "$marker" "$text"
  done < "$f"
}
