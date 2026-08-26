#!/usr/bin/env bash
# ausculte-cadence.sh -- put the health verb on a clock, and give it a mouth.
#
# Before this, nothing invoked `ausculte` -- it ran when a human typed it.
#
# TRAP: two consecutive DOWNs escalate, not one; the streak is on disk.
# TRAP: it escalates through the channel ausculte probes, so the issue is filed
#   FIRST -- if the relay is what is down, the record still exists.
#
set -uo pipefail

CLI_NAME='ausculte-cadence.sh'
CLI_SUMMARY='run ausculte on a clock; escalate a row that stays DOWN'
CLI_USAGE='  ausculte-cadence.sh                 run once, report, escalate if warranted
  ausculte-cadence.sh --install-cadence
                                      show the crontab line
  ausculte-cadence.sh --install-cadence --apply
                                      install it into this account'"'"'s crontab
  ausculte-cadence.sh --no-escalate   grade and record, but reach no human'
CLI_FLAGS='--install-cadence --apply --quiet --no-escalate'
CLI_POSITIONAL=none
CLI_EXITS='  0  every row OK, or a first-time DOWN recorded and not yet escalated
  5  a row has been DOWN twice running and was escalated
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
ISSUE_REPO="${AUSCULTE_ISSUE_REPO:-hf7y/realisateur}"
APP_MINT="${SELFDEV_APP_MINT:-${SELFDEV_LIBEXEC:-/usr/local/libexec/selfdev}/selfdev-gh-app.sh}"

MODE=run; APPLY=0; QUIET=0; NO_ESC=0
for a in "$@"; do
  case "$a" in
    --install-cadence) MODE=cadence ;;
    --apply)           APPLY=1 ;;
    --quiet)           QUIET=1 ;;
    --no-escalate)     NO_ESC=1 ;;
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

escalated=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  name="$(printf '%s' "$row" | jq -r '.probe // .row // empty' 2>/dev/null)"
  status="$(printf '%s' "$row" | jq -r '.status // empty' 2>/dev/null)"
  detail="$(printf '%s' "$row" | jq -r '.detail // empty' 2>/dev/null)"
  [ -n "$name" ] || continue

  # THREE INPUT STATES NEED THREE OUTCOMES. Ashby S.8/7: a transducer with
  # fewer output values than its input has distinct states loses distinctions.
  # This loop had two -- escalate, or clear -- for OK, DOWN and BLIND, so
  # `[ "$status" != DOWN ] && rm -f` cleared the streak on BLIND exactly as it
  # did on OK. Run as root on monkey, three of ausculte's probes are BLIND for
  # want of a gh credential, and a probe alternating DOWN/BLIND never reaches
  # two consecutive DOWNs at all. That is why this cadence has fired every four
  # hours since it was installed and escalated nothing.
  #
  # BLIND is NOT DOWN and must not be reported as it: "I could not look" is a
  # claim about the observer. It gets its own streak, its own word, and its own
  # issue title, so the two never collapse into one number again.
  case "$status" in
    OK)
      # CLEAR-DOWN -- the inverse of the escalation below, which did not exist.
      # Recovery cleared the STREAK FILE and nothing else, so an issue saying a
      # probe "has been DOWN for two consecutive runs" outlived the outage it
      # described. Worse: the dedup search below matches an OPEN issue of that
      # title, so the stale one then SUPPRESSED the next real filing -- an
      # escalation channel that goes quiet after its first use.
      # Reached only when this run actually read OK, and only for a streak this
      # host recorded, so it can never close an issue it did not file.
      for suffix in down blind; do
        [ -f "$STATE/$name.$suffix" ] || continue
        rm -f "$STATE/$name.$suffix"
        [ "$NO_ESC" -eq 1 ] && continue
        command -v gh >/dev/null 2>&1 || continue
        case "$suffix" in down) w=DOWN ;; *) w=BLIND ;; esac
        n="$(gh issue list -R "$ISSUE_REPO" --search "in:title \"ausculte: $name has been $w\"" \
               --state open --json number --jq '.[0].number' 2>/dev/null)"
        [ -n "$n" ] || continue
        if err="$(gh issue close "$n" -R "$ISSUE_REPO" \
                    --comment "Recovered: \`ausculte $name\` read OK. Filed by the health cadence, closed by it." 2>&1 >/dev/null)"; then
          echo "  ..      $name recovered; closed $ISSUE_REPO#$n"
        else
          echo "  BAD     $name recovered but $ISSUE_REPO#$n is still open: ${err:-no reason given}"
        fi
      done
      continue ;;
    DOWN)  f="$STATE/$name.down";  rm -f "$STATE/$name.blind"
           word=DOWN;  said='is not serving' ;;
    BLIND) f="$STATE/$name.blind"; rm -f "$STATE/$name.down"
           word=BLIND; said='could not be looked at' ;;
    *)     rm -f "$STATE/$name.down" "$STATE/$name.blind"; continue ;;
  esac

  # SECOND STRIKE ESCALATES: one reading can be a probe catching a restart.
  if [ ! -f "$f" ]; then
    printf '%s\n' "$detail" > "$f"
    [ "$QUIET" -eq 1 ] || echo "  ..      $name $word once; escalates if it is $word again next run"
    continue
  fi

  echo "  $word    $name -- twice running: $detail"
  escalated=1
  # A test run must never reach a person.
  [ "$NO_ESC" -eq 1 ] && continue

  title="ausculte: $name has been $word for two consecutive runs"
  body="NO-DECISION: filed by the health cadence, which escalates a row only on its second consecutive $word

\`ausculte $name\` reported $word twice running -- it $said.

    $detail

Reproduce: \`ausculte $name\`

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->"
  if command -v gh >/dev/null 2>&1; then
    existing="$(gh issue list -R "$ISSUE_REPO" --search "in:title \"ausculte: $name has been $word\"" \
                  --state open --json number --jq '.[0].number' 2>/dev/null)"
    if [ -n "$existing" ]; then
      echo "  ..      already filed as $ISSUE_REPO#$existing"
    else
      # WHY THE REASON IS KEPT: this call goes through gh-sign, which REFUSES
      # a body that breaks lib/body-grammar.sh (exit 7). Sending its stderr to
      # /dev/null made a refusal read exactly like a filing, and that is how
      # this cadence escalated four BLIND rows into nothing at all -- its own
      # body carried no DELIVERS block, so every `gh issue create` since the
      # grammar landed was refused, silently, every four hours.
      if err="$(gh issue create -R "$ISSUE_REPO" --title "$title" --body "$body" 2>&1 >/dev/null)"; then
        echo "  ..      filed on $ISSUE_REPO"
      else
        echo "  BAD     could not file the issue -- the record is this line only: ${err:-no reason given}"
      fi
    fi
  fi

  # THIS DOES NOT ASK ZACH. 47 questions sent, 0 ever answered, 44% of the
  # relay's lifetime traffic; the single slot (hf7y/crt#67) meant each held the
  # only channel to him for its full TTL. bin/tests/ausculte-cadence.test.sh
  # section H is what enforces that, not this comment. The issue above is the
  # escalation and always was.

done <<< "$rows"

[ "$escalated" -eq 0 ] || exit 5
exit 0
