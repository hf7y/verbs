#!/usr/bin/env bash
# session-marker.sh -- record a live interactive session for a registered project so
# scheduler's registry-lock.sh can defer unattended jobs to it. RESTORED (hf7y/vim-arcade#207).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/conf.sh
. "$SELF_DIR/../bin/lib/conf.sh"

SCHED_ROOT="${SCHED_ROOT:-${INSTALLE_PROJECTS:-$HOME/Documents/Projects}/scheduler}"
REGISTRY_DIR="${SCHEDULER_REGISTRY_DIR:-$HOME/.local/share/scheduler-registry}"

action="${1:-}"

RESOLVE_CONFS=0   # confs that carry a PROJECT_REPO_PATH at all
RESOLVE_LIVE=0    # ...of those, how many name a directory that exists
RESOLVE_HIT=""    # the matched PROJECT_KEY, empty when nothing matched
resolve_project() {  # matches PROJECT_REPO_PATH in schedule/*.conf, same resolution the surveys use
  local dir="$1" conf name repo hit=""
  RESOLVE_CONFS=0; RESOLVE_LIVE=0; RESOLVE_HIT=""
  [ -n "$dir" ] || return 1
  for conf in "$SCHED_ROOT"/schedule/*.conf; do
    [ -f "$conf" ] || continue
    name="$(basename "$conf" .conf)"
    case "$name" in _*) continue ;; esac
    repo="$(conf_repo_path "$conf")" || continue
    RESOLVE_CONFS=$((RESOLVE_CONFS + 1))
    [ -d "$repo" ] && RESOLVE_LIVE=$((RESOLVE_LIVE + 1))
    [ -n "$hit" ] && continue
    case "$dir/" in "$repo"/*) hit="$name" ;; esac  # repo root or beneath it
  done
  [ -n "$hit" ] || return 1
  RESOLVE_HIT="$hit"
  printf '%s\n' "$hit"
}

resolve_blind() { [ "$RESOLVE_CONFS" -gt 0 ] && [ "$RESOLVE_LIVE" -eq 0 ]; }  # BLIND: the #73 shape
resolve_blind_say() {
  echo "session-marker: BLIND -- $RESOLVE_CONFS conf(s) under $SCHED_ROOT/schedule/ carry a PROJECT_REPO_PATH and NOT ONE resolves to a directory that exists." >&2
  echo "session-marker: no marker can be written for any project, so every unattended job reads every repo as free even with a human in it. This is the #73 shape; check the confs and this script's resolution together." >&2
}

read_cwd() {  # hook contract: JSON on stdin with a cwd field; CLAUDE_PROJECT_DIR wins when set
  local json cwd=""
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then printf '%s\n' "$CLAUDE_PROJECT_DIR"; return 0; fi
  json="$(cat 2>/dev/null || true)"
  cwd="$(printf '%s' "$json" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$cwd" ] || cwd="$PWD"
  printf '%s\n' "$cwd"
}

case "$action" in
  acquire|release)
    cwd="$(read_cwd)"
    resolve_project "$cwd" >/dev/null || true
    project="$RESOLVE_HIT"
    resolve_blind && resolve_blind_say  # loud even here; exit stays 0, a hook must not block a session
    [ -n "$project" ] || exit 0                       # not a registered project
    mkdir -p "$REGISTRY_DIR" 2>/dev/null || exit 0
    marker="$REGISTRY_DIR/$project.interactive"
    if [ "$action" = "acquire" ]; then
      session_pid() {  # walks up from the short-lived intermediate PPID to the actual claude process
        local p="${PPID}" d=0 comm
        while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$d" -lt 12 ]; do
          comm="$(ps -p "$p" -o comm= 2>/dev/null | tr -d ' ')"
          case "$comm" in
            claude|claude.exe) printf '%s\n' "$p"; return 0 ;;
          esac
          p="$(ps -p "$p" -o ppid= 2>/dev/null | tr -d ' ')"
          d=$((d + 1))
        done
        printf '%s\n' "${PPID}"
      }
      {
        echo "pid=$(session_pid)"
        echo "started_at=$(date -Is)"
        echo "cwd=$cwd"
        echo "owner=realisateur/hooks/session-marker.sh"
      } > "$marker" 2>/dev/null || true
    else
      rm -f "$marker" 2>/dev/null || true
    fi
    exit 0
    ;;
  resolve)
    dir="${2:-$PWD}"
    resolve_project "$dir" || true
    if resolve_blind; then
      resolve_blind_say
      exit 3  # not 1: a broken registry (matching hygiene-lint.sh/silence-audit.sh) differs from "dir matches nothing"
    fi
    if [ -n "$RESOLVE_HIT" ]; then exit 0; fi
    echo "session-marker: $dir is under no registered project ($RESOLVE_LIVE of $RESOLVE_CONFS conf(s) resolve)" >&2
    exit 1
    ;;
  probe)
    project="${2:?usage: session-marker.sh probe <project>}"
    marker="$REGISTRY_DIR/$project.interactive"
    if [ -f "$marker" ]; then
      mpid="$(awk -F= '$1=="pid"{print $2}' "$marker" 2>/dev/null)"
      if [ -n "$mpid" ] && kill -0 "$mpid" 2>/dev/null; then
        echo "BUSY: interactive session (pid $mpid, since $(awk -F= '$1=="started_at"{print $2}' "$marker" 2>/dev/null))"
        exit 1
      fi
      echo "free (stale marker: pid ${mpid:-?} is gone -- SessionEnd never fired)"
      exit 0
    fi
    echo "free"
    exit 0
    ;;
  -h|--help)
    printf 'session-marker.sh -- record/probe a live interactive session for a project\n\n'
    printf 'usage:\n'
    printf '  session-marker.sh acquire < hook-json   from a Claude SessionStart hook\n'
    printf '  session-marker.sh release < hook-json   from a Claude SessionEnd hook\n'
    printf '  session-marker.sh probe <project>       print "free" or a live-session line\n'
    printf '  session-marker.sh resolve [dir]         which project owns dir (default $PWD)\n\n'
    printf 'flags: none -- the first argument is a subcommand\n\n'
    printf 'exit codes:\n'
    printf '  0  the subcommand completed (probe prints its answer on stdout)\n'
    printf '  1  resolve: dir is under no registered project\n'
    printf '  2  usage error: unknown subcommand or missing argument\n'
    printf '  3  resolve: BLIND -- no conf resolves to a directory that exists,\n'
    printf '     so no marker can ever be written for any project\n\n'
    printf 'this tool makes no AI calls and cannot spend: --summon is rejected.\n'
    exit 0 ;;
  *)
    echo "usage: session-marker.sh {acquire|release} < hook-json" >&2
    echo "       session-marker.sh probe <project>" >&2
    echo "       session-marker.sh resolve [dir]" >&2
    exit 2
    ;;
esac
