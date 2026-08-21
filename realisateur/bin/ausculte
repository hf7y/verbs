#!/usr/bin/env bash
# ausculte.sh -- can Zach stop looking? Composed from probes that already exist.
# KIND: verb
# THE HUMAN CHANNEL IS FIRST: every other failure reaches Zach through zaxon,
# so a green report with zaxon down reaches nobody. BLIND never folds into OK.
set -uo pipefail

CLI_NAME='ausculte.sh'
CLI_SUMMARY='is self-dev healthy enough to stop watching?'
CLI_USAGE='  ausculte              every probe; the exit code is the answer
  ausculte --json       one object per probe
  ausculte <probe>      just one: channel hosts arming propagation rot silence'
CLI_FLAGS='--json'
CLI_POSITIONAL=any
CLI_EXITS='  0  every declared probe answered OK
  5  something declared is DOWN (the report names it)
  6  BLIND: at least one probe could not look, and none was DOWN'
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
cli_guard "$@"

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# part <name> -- the first path that exists: beside this file, in the host's
# libexec, or on PATH. ausculte travels in the verb build and the probes it
# composes do not, so without this it is BLIND about them on a host.
part() {
  local n="$1" p
  for p in "$HERE/$n" "${SELFDEV_LIBEXEC:-/usr/local/libexec/selfdev}/$n" \
           "$HERE/${n%.sh}" "$(command -v "${n%.sh}" 2>/dev/null || true)"; do
    [ -n "$p" ] && [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}
. "$HERE/lib/host-check.sh"
JSON=0; ONLY=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    -*) printf '%s: unknown flag: %s\n' "$CLI_NAME" "$1" >&2; exit 2 ;;
    *)  ONLY+=("$1") ;;
  esac; shift
done

down=0; blind=0; rows=()
record() {
  rows+=("$1|$2|$3")
  case "$2" in DOWN) down=1 ;; BLIND) blind=1 ;; esac
}
want() {
  [ ${#ONLY[@]} -eq 0 ] && return 0
  local p; for p in "${ONLY[@]}"; do [ "$p" = "$1" ] && return 0; done
  return 1
}

if want channel; then
  . "$HERE/lib/zaxon.sh"
  ep="$(zaxon_probe ausculte)" || ep=''
  if [ -n "$ep" ]; then record channel OK "zaxon answers at $ep"
  else record channel DOWN 'no zaxon relay answered -- questions cannot reach Zach'; fi
fi

if want hosts; then
  if dl="$(part dexter-liveness.sh)"; then
    out="$(bash "$dl" 2>&1)"; rc=$?
    case $rc in
      0) record hosts OK 'dexter serves what it declares' ;;
      6) record hosts BLIND 'cannot reach dexter' ;;
      *) record hosts DOWN "$(printf '%s' "$out" | grep -iE 'down|missing|not running' | head -1)" ;;
    esac
  else record hosts BLIND 'dexter-liveness.sh not present'; fi
fi

if want arming; then
  # WHAT THE ACCOUNTS ARE DOING, not how many times the word "armed" appears.
  # Counting the key said OK while three accounts had been dead for eight days:
  # exited 3 in zero seconds, into a per-account log nobody reads.
  st="$(curl -s -m 20 "${MONKEY_STATUS_URL:-https://hf7y.com/monkey/status.json}" 2>/dev/null)"
  if ! printf '%s' "$st" | jq -e '.accounts' >/dev/null 2>&1; then
    record arming BLIND 'the published monkey status could not be read'
  elif vu="$(printf '%s' "$st" | jq -r '.valid_until // empty')" && [ -n "$vu" ] \
       && [ "$(date -u +%s)" -gt "$(date -u -d "$vu" +%s 2>/dev/null || echo 0)" ]; then
    # A document past the freshness it declares for itself is not evidence.
    record arming BLIND "the published monkey status expired at $vu -- nothing is publishing it"
  else
    # TRAP: fromdateiso8601 rejects a "+00:00" offset and accepts only "Z", so
    # the ledger's own timestamps make jq exit mid-stream. Unnormalised, this
    # row printed OK off an empty result -- the error-read-as-nothing-found
    # this file exists to refuse. A jq failure is BLIND, never clean.
    if ! stale="$(printf '%s' "$st" | jq -er --argjson d "${ARMING_STALE_DAYS:-3}" '
      (now - ($d * 86400)) as $cut
      | [ .accounts[]
          | select(.armed)
          | select(.last_run.started_at != null)
          | select(((.last_run.started_at | sub("\\+00:00$"; "Z") | fromdateiso8601)) < $cut)
          | .account ] | join(" ")' 2>/dev/null)"; then
      record arming BLIND 'the status document could not be graded (unreadable timestamps)'
      stale=SKIP
    fi
    # NO RECORD IS NOT NO DISPATCH: three accounts run and write none at all
    # (hf7y/scheduler#259), so the document cannot say. That is BLIND.
    norec="$(printf '%s' "$st" | jq -r '[.accounts[]|select(.armed)|select(.last_run.started_at == null)|.account]|join(" ")' 2>/dev/null)"
    n_armed="$(printf '%s' "$st" | jq -r '[.accounts[]|select(.armed)]|length')"
    gen="$(printf '%s' "$st" | jq -r '.generated')"
    if [ "$stale" = SKIP ]; then :
    elif [ -n "$stale" ]; then
      record arming DOWN "armed but not dispatching for ${ARMING_STALE_DAYS:-3}d: $stale (status generated $gen)"
    elif [ -n "$norec" ]; then
      record arming BLIND "no run record published for: $norec -- cannot tell whether they dispatched (hf7y/scheduler#259)"
    else
      record arming OK "$n_armed account(s) armed, each dispatched within ${ARMING_STALE_DAYS:-3}d"
    fi
  fi
fi

if want propagation; then
  # THE CHANNEL'S OWN VERDICT FIRST. Counting verbs answers "is something
  # installed", not "is the channel running": the cutter refused for two days
  # over one undeclared command while every host still had its full set of
  # verbs, and this row said OK throughout. The cutter publishes decision,
  # last_cut.at and blocked_streak; nothing read them until now.
  # A verb build carries verbs, not every lib they source: with no copy
  # reachable the pin path is unknown, and an empty one blames the hosts.
  ps=""
  for cand in "$HERE/lib/propagation-set.sh" \
              "${SELFDEV_LIBEXEC:-/usr/local/libexec/selfdev}/lib/propagation-set.sh"; do
    [ -r "$cand" ] && { ps="$cand"; break; }
  done
  # shellcheck source=lib/propagation-set.sh
  [ -n "$ps" ] && . "$ps"
  v="$(curl -s -m 15 "${VERBS_STATUS_URL:-https://hf7y.com/verbs/status.json}" 2>/dev/null)"
  dec="$(printf '%s' "$v" | jq -r '.decision // empty' 2>/dev/null)"
  if [ -z "$dec" ]; then
    record propagation BLIND 'cannot read the release channel verdict'
  else
    cut_at="$(printf '%s' "$v" | jq -r '.last_cut.at // empty' 2>/dev/null)"
    streak="$(printf '%s' "$v" | jq -r '.blocked_streak // 0' 2>/dev/null)"
    max_h=$(( $(printf '%s' "$v" | jq -r '.cadence_hours // 24') + $(printf '%s' "$v" | jq -r '.grace_hours // 4') ))
    age_h=-1
    if [ -n "$cut_at" ]; then
      cut_epoch="$(date -u -d "$cut_at" +%s 2>/dev/null)" \
        && age_h=$(( ( $(date -u +%s) - cut_epoch ) / 3600 ))
    fi
    if [ "$dec" != CUT ]; then
      record propagation DOWN "the channel is $dec ($streak run(s) running); nothing has propagated since $cut_at"
    elif [ "$age_h" -lt 0 ]; then
      record propagation BLIND 'the verdict names no last cut this could age'
    elif [ "$age_h" -gt "$max_h" ]; then
      record propagation DOWN "the newest build is ${age_h}h old, past its ${max_h}h cadence"
    else
      # Only once the channel is proven live does what is installed mean
      # anything: a host behind the pin is a consumer that did not adopt.
      bid="$(printf '%s' "$v" | jq -r '.build_id // empty' 2>/dev/null)"
      if [ -z "${PROP_HOST_PIN:-}" ]; then
        record propagation BLIND 'no propagation-set.sh reachable, so the host pin path is unknown'
        bid=""
      fi
      bad=''
      for h in monkey "-p 2223 dexter"; do
        # LOCALHOST IS NOT AN SSH TARGET: the row read "monkey:unreachable"
        # about the host it was standing on.
        if on_target_host "${h##* }"; then
          n="$(readlink "$PROP_HOST_PIN" 2>/dev/null)"
        else
          # shellcheck disable=SC2086
          n="$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes $h "readlink $PROP_HOST_PIN" 2>/dev/null)"
        fi
        [ -n "$n" ] || { bad="$bad ${h##* }:unreachable"; continue; }
        [ "$(basename "$n")" = "$bid" ] || bad="$bad ${h##* }:$(basename "$n")"
      done
      if [ -z "$bid" ]; then :
      elif [ -n "$bad" ]; then record propagation DOWN "channel cut $bid ${age_h}h ago; behind:$bad"
      else record propagation OK "channel cut $bid ${age_h}h ago; every host is on it"; fi
    fi
  fi
fi

if want rot; then
  if dr="$(part decision-rot.sh)"; then
    out="$(bash "$dr" --all 2>&1)"; rc=$?
      case $rc in
      0) record rot OK 'no answered-and-abandoned issues' ;;
      1) record rot DOWN "$(printf '%s' "$out" | tail -1)" ;;
      2) record rot BLIND 'ausculte invoked decision-rot.sh wrongly -- fix ausculte' ;;
      *) record rot BLIND "$(printf '%s' "$out" | tail -1)" ;;
    esac
  else record rot BLIND 'decision-rot.sh not present'; fi
fi

if want silence; then
  sa=''
  if   sa="$(part silence-audit.sh)"; then :
  elif command -v silence-audit >/dev/null 2>&1; then sa="$(command -v silence-audit)"
  fi
  if [ -n "$sa" ]; then
    out="$(bash "$sa" --strict 2>&1)"; rc=$?
    case $rc in
      0) record silence OK 'no silenced failure paths' ;;
      2) record silence BLIND 'ausculte invoked silence-audit wrongly -- fix ausculte' ;;
      *) record silence DOWN "$(printf '%s' "$out" | tail -1)" ;;
    esac
  else record silence BLIND 'silence-audit not present'; fi
fi

[ ${#rows[@]} -gt 0 ] || { printf '%s: no such probe: %s\n' "$CLI_NAME" "${ONLY[*]}" >&2; exit 2; }

if [ "$JSON" = 1 ]; then
  printf '['
  sep=''
  for r in "${rows[@]}"; do
    IFS='|' read -r p s d <<< "$r"
    printf '%s{"probe":"%s","status":"%s","detail":"%s"}' "$sep" "$p" "$s" "${d//\"/\\\"}"; sep=','
  done
  printf ']\n'
else
  for r in "${rows[@]}"; do
    IFS='|' read -r p s d <<< "$r"
    printf '  %-6s  %-12s %s\n' "$s" "$p" "$d"
  done
  echo
  if [ "$down" = 1 ]; then echo 'DOWN -- something declared is not serving. Named above.'
  elif [ "$blind" = 1 ]; then echo 'BLIND -- a probe could not look. This is NOT "all clear".'
  else echo 'OK -- every declared probe answered. You can stop looking.'; fi
fi

[ "$down" = 1 ] && exit 5
[ "$blind" = 1 ] && exit 6
exit 0
