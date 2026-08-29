#!/usr/bin/env bash
set -uo pipefail  # hooks/pretooluse-credential-hold.sh: Rule 3 of #714's Netlify post-mortem -- a credential entering the session holds state-changing curl calls for the rest of that turn, until a fresh UserPromptSubmit clears the hold

log() { printf 'pretooluse-credential-hold: %s\n' "$*" >&2; }

payload="$(cat 2>/dev/null)" || { log "could not read hook payload from stdin"; exit 1; }

event="$(sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q' <<<"$payload")"
session="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q' <<<"$payload")"
[ -n "$session" ] || exit 0  # nothing to key the hold on

HOLD_DIR="${CREDENTIAL_HOLD_DIR:-$HOME/tmp}"
MARKER="$HOLD_DIR/credential-hold.$session"

case "$event" in
  UserPromptSubmit)
    rm -f -- "$MARKER" 2>/dev/null  # a fresh turn starts with a clean slate
    exit 0 ;;
  PreToolUse) ;;
  *) exit 0 ;;
esac

tool="$(sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q' <<<"$payload")"
[ "$tool" = Bash ] || exit 0

command -v jq >/dev/null 2>&1 || { log "no jq on PATH -- cannot parse the Bash command reliably, letting this call through"; exit 0; }
cmd="$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null)"
[ -n "$cmd" ] || exit 0

is_credential_read() { # <command> -> 0 if it reads or names a credential
  local w
  for w in $1; do
    case "$w" in
      *[Tt][Oo][Kk][Ee][Nn]*|*[Ss][Ee][Cc][Rr][Ee][Tt]*|*[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll]*|*.pem) return 0 ;;
      [A-Za-z_]*_TOKEN=*|[A-Za-z_]*_KEY=*|[A-Za-z_]*_SECRET=*|[A-Za-z_]*_PASSWORD=*) return 0 ;;
    esac
  done
  case "$1" in *[Aa]uthorization:*) return 0 ;; esac
  return 1
}

is_external_write() { # <command> -> 0 if it is a curl call that changes state on a non-local host
  case "$1" in *curl*) ;; *) return 1 ;; esac
  case "$1" in
    *' -X POST'*|*' -X PATCH'*|*' -X PUT'*|*' -X DELETE'*|*' -XPOST'*|*' -XPATCH'*|*' -XPUT'*|*' -XDELETE'*) ;;
    *'--data'*|*' -d'*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *'http://localhost'*|*'https://localhost'*|*'http://127.0.0.1'*|*'https://127.0.0.1'*|*'http://[::1]'*) return 1 ;;
  esac
  case "$1" in *'http://'*|*'https://'*) return 0 ;; esac
  return 1
}

held=0
[ -e "$MARKER" ] && held=1

if is_credential_read "$cmd"; then
  mkdir -p "$HOLD_DIR" 2>/dev/null
  : > "$MARKER" 2>/dev/null
  held=1
fi

if [ "$held" -eq 1 ] && is_external_write "$cmd"; then
  {
    echo "BLOCKED: a credential just entered this session -- read first, state the plan, then act."
    echo
    echo "Re-run after saying what you intend to change and how to undo it."
  } >&2
  exit 2
fi

exit 0
