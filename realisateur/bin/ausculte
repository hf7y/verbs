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
  if [ -x "$HERE/dexter-liveness.sh" ]; then
    out="$(bash "$HERE/dexter-liveness.sh" 2>&1)"; rc=$?
    case $rc in
      0) record hosts OK 'dexter serves what it declares' ;;
      6) record hosts BLIND 'cannot reach dexter' ;;
      *) record hosts DOWN "$(printf '%s' "$out" | grep -iE 'down|missing|not running' | head -1)" ;;
    esac
  else record hosts BLIND 'dexter-liveness.sh not present'; fi
fi

if want arming; then
  if on_target_host monkey; then
    out="$(sudo -n python3 /usr/local/libexec/selfdev/monkey-status-collect.py 2>/dev/null || sudo -n python3 ~zach/realisateur/bin/monkey-status-collect.py 2>/dev/null)"
  else
    out="$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes monkey \
            'sudo -n python3 /usr/local/libexec/selfdev/monkey-status-collect.py 2>/dev/null || sudo -n python3 ~zach/realisateur/bin/monkey-status-collect.py 2>/dev/null' 2>/dev/null)"
  fi
  if [ -z "$out" ]; then record arming BLIND 'monkey did not answer the collector'
  else
    n="$(printf '%s' "$out" | grep -co 'armed' || true)"
    record arming OK "$n account(s) reported armed"
  fi
fi

if want propagation; then
  pub="$(gh api repos/hf7y/verbs/contents/manifest.tsv --jq .content 2>/dev/null | base64 -d 2>/dev/null | grep -cv '^#')" || pub=0
  if [ "${pub:-0}" -lt 1 ]; then record propagation BLIND 'cannot read the published manifest'
  else
    bad=''
    for h in monkey "-p 2223 dexter"; do
      # shellcheck disable=SC2086
      n="$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes $h 'ls /usr/local/bin | wc -l' 2>/dev/null)"
      [ -n "$n" ] || { bad="$bad ${h##* }:unreachable"; continue; }
      [ "$n" -ge "$pub" ] || bad="$bad ${h##* }:$n/$pub"
    done
    if [ -n "$bad" ]; then record propagation DOWN "behind the $pub-verb build:$bad"
    else record propagation OK "$pub verb(s) published and installed"; fi
  fi
fi

if want rot; then
  if [ -x "$HERE/decision-rot.sh" ]; then
    out="$(bash "$HERE/decision-rot.sh" --all 2>&1)"; rc=$?
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
  if   [ -x "$HERE/silence-audit.sh" ]; then sa="$HERE/silence-audit.sh"
  elif [ -x "$HERE/silence-audit" ];    then sa="$HERE/silence-audit"
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
