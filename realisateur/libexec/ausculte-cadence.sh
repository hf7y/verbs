#!/usr/bin/env bash
# ausculte-cadence.sh -- put the health verb on a clock, and keep the record.
#
# Before this, nothing invoked `ausculte` -- it ran when a human typed it.
#
# IT NO LONGER HAS A MOUTH, AND THAT IS THE POINT (Zach, 2026-08-27). Its two
# channels were both retired for cause. The relay leg went on 2026-08-25: 47
# questions sent, 0 ever answered, 44% of the relay's lifetime traffic. The
# issue-filing leg goes here: 10 issues in 5 days over 5 distinct rows, and on
# 2026-08-26 Zach closed three of them in one batch -- "Closing as probe
# output, not a work item." A channel whose output its reader has ruled is not
# work is not a channel, and filing into it again is how the ruling went unread.
#
# WHAT IT DOES NOW: runs `ausculte`, prints the rows, and records WHEN each row
# entered the state it is in. That record is the only thing the escalation ever
# produced that something else can use.
#
# TRAP: the state file is a SINCE, not a counter. It is written on entry into a
#   state and left alone while the state holds, so its mtime answers "how long".
#
set -uo pipefail

CLI_NAME='ausculte-cadence.sh'
CLI_SUMMARY='run ausculte on a clock and record how long each row has said it'
CLI_USAGE='  ausculte-cadence.sh                 run once, report, record
  ausculte-cadence.sh --install-cadence
                                      show the crontab line
  ausculte-cadence.sh --install-cadence --apply
                                      install it into this account'"'"'s crontab'
CLI_FLAGS='--install-cadence --apply --quiet'
CLI_POSITIONAL=none
CLI_EXITS='  0  no row is DOWN
  5  a row is DOWN -- named in the output, filed at nobody
  6  BLIND -- ausculte itself could not be run
  2  usage error'
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
cli_guard "$@"

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$(dirname "${BASH_SOURCE[0]}")/lib/cron-lock.sh"
STATE="${AUSCULTE_CADENCE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/ausculte-cadence}"
AUSCULTE="${AUSCULTE_BIN:-$HERE/ausculte.sh}"
[ -x "$AUSCULTE" ] || AUSCULTE="$(command -v ausculte || true)"
CRON_TAG='# realisateur:ausculte:CADENCE'
CRON_SPEC="${AUSCULTE_CRON_SPEC:-37 */4 * * *}"
APP_MINT="${SELFDEV_APP_MINT:-${SELFDEV_LIBEXEC:-/usr/local/libexec/selfdev}/selfdev-gh-app.sh}"

MODE=run; APPLY=0; QUIET=0
for a in "$@"; do
  case "$a" in
    --install-cadence) MODE=cadence ;;
    --apply)           APPLY=1 ;;
    --quiet)           QUIET=1 ;;
    -*) echo "$CLI_NAME: unknown flag $a" >&2; exit 2 ;;
    *)  echo "$CLI_NAME: unexpected argument $a" >&2; exit 2 ;;
  esac
done

if [ "$MODE" = cadence ]; then
  self="$(readlink -f "${BASH_SOURCE[0]}")"
  line="$CRON_SPEC $self --quiet $CRON_TAG"
  if [ "$APPLY" -eq 0 ]; then echo "  would   install into $(id -un)'s crontab: $line"; exit 0; fi
  ( crontab -l 2>/dev/null | grep -v 'realisateur:ausculte:CADENCE'; printf '%s\n' "$line" ) | crontab -
  # WITNESS: read it back rather than believing `crontab -` exited 0.
  if crontab -l 2>/dev/null | grep -q 'realisateur:ausculte:CADENCE'; then
    echo "  OK      cadence in $(id -un)'s crontab (re-read, not asserted): $line"
    exit 0
  fi
  echo "  BAD     the cadence is NOT in the crontab -- nothing will run ausculte" >&2
  exit 1
fi

cron_lock ausculte-cadence

[ -n "$AUSCULTE" ] && [ -x "$AUSCULTE" ] \
  || { echo "$CLI_NAME: BLIND -- ausculte is not runnable from here" >&2; exit 6; }

mkdir -p "$STATE" || { echo "$CLI_NAME: BLIND -- cannot write $STATE" >&2; exit 6; }

# THE CLOCK RUNS AS ROOT, AND ROOT HAS NO gh LOGIN, so the rows that read
# GitHub went BLIND on every repo. The host holds the App key; mint from it.
if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] && [ -x "$APP_MINT" ]; then
  t="$("$APP_MINT" --token 2>/dev/null | tail -1)"
  case "$t" in ghs_*|ghu_*|gh[a-z]_*) export GH_TOKEN="$t" ;; esac
fi

out="$("$AUSCULTE" --json 2>/dev/null)"
# --json is ONE array: reading it line-wise grades nothing and exits 0.
rows="$(printf '%s' "$out" | jq -c '.[]' 2>/dev/null)"
[ -n "$rows" ] || { echo "$CLI_NAME: BLIND -- ausculte produced no rows" >&2; exit 6; }
[ "$QUIET" -eq 1 ] || printf '%s\n' "$out"

down=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  name="$(printf '%s' "$row" | jq -r '.probe // .row // empty' 2>/dev/null)"
  status="$(printf '%s' "$row" | jq -r '.status // empty' 2>/dev/null)"
  detail="$(printf '%s' "$row" | jq -r '.detail // empty' 2>/dev/null)"
  [ -n "$name" ] || continue

  # THREE INPUT STATES NEED THREE OUTCOMES. Ashby S.8/7: a transducer with
  # fewer output values than its input has distinct states loses distinctions.
  # This loop once had two for OK, DOWN and BLIND, so a probe alternating
  # DOWN/BLIND was recorded as neither.
  #
  # BLIND is NOT DOWN: "I could not look" is a claim about the observer. It
  # keeps its own file so the two never collapse into one number again.
  case "$status" in
    OK)    rm -f "$STATE/$name.down" "$STATE/$name.blind"; continue ;;
    DOWN)  f="$STATE/$name.down";  rm -f "$STATE/$name.blind"; word=DOWN ;;
    BLIND) f="$STATE/$name.blind"; rm -f "$STATE/$name.down"; word=BLIND ;;
    *)     rm -f "$STATE/$name.down" "$STATE/$name.blind"; continue ;;
  esac
  [ "$word" = DOWN ] && down=1

  # WRITTEN ONCE, ON ENTRY. Rewriting it every run would reset the mtime and
  # destroy the only fact this file carries: how long the row has said this.
  if [ ! -f "$f" ]; then
    printf '%s\n' "$detail" > "$f"
    [ "$QUIET" -eq 1 ] || echo "  $word    $name -- since now: $detail"
  else
    [ "$QUIET" -eq 1 ] || echo "  $word    $name -- since $(date -u -r "$f" +%Y-%m-%dT%H:%MZ 2>/dev/null || echo earlier): $detail"
  fi
done <<< "$rows"

# NOTHING IS FILED AND NOBODY IS PAGED. The exit code and the printed rows are
# the whole output; bin/tests/ausculte-cadence.test.sh sections G and H are what
# enforce that, not this comment.
[ "$down" -eq 0 ] || exit 5
exit 0
