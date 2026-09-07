#!/usr/bin/env bash
# Run every remedy's `verify` verb. This is the cron entrypoint.
#
#   ./verify-all.sh        # full report
#   ./verify-all.sh -q     # print nothing unless something is wrong
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh   # for rc_severity: exit codes do NOT rank numerically

QUIET=0
[ "${1:-}" = "-q" ] || [ "${1:-}" = "--quiet" ] && QUIET=1

MFILE="${SENECHAL_VERIFY_ALL_MUTED:-$PWD/verify-all.muted}"
declare -A MUTED=()
if [ -f "$MFILE" ]; then
  while IFS=$'\t' read -r mname missue mreason || [ -n "$mname" ]; do
    case "$mname" in ''|'#'*) continue ;; esac
    MUTED["${mname#./}"]="${missue:-<no issue cited>} ${mreason:-}"
  done < "$MFILE"
fi

THIS_HOST="$(senechal_this_host)"

host_in_hosts() {
  local f="$1" tok
  for tok in $(sed -nE 's/^HOSTS=\(([^)]*)\)$/\1/p' "$f"); do
    [ "$tok" = "$THIS_HOST" ] && return 0
  done
  return 1
}

declares_reach() {
  local f="$1"
  [ -n "$(sed -nE 's/^REACHES=\(([^)]*)\)$/\1/p' "$f")" ]
}

worst=0
worst_sev=0
report=""
count=0
muted_failed=""

for s in ./*.sh; do
  case "$(basename "$s")" in
    _*|verify-all.sh) continue ;;
  esac
  [ -x "$s" ] || continue
  count=$((count + 1))
  bn="$(basename "$s")"
  if host_in_hosts "$s" || declares_reach "$s"; then
    out="$("$s" verify 2>&1)" && rc=0 || rc=$?
  else
    out="wrong host (#637): HOSTS=(...) does not include $THIS_HOST and REACHES declares no remote transport -- skipping rather than risk a false FAIL"
    rc=$RC_INCOMPLETE
  fi

  if [ -n "${MUTED[$bn]+set}" ]; then
    if [ "$rc" -eq 0 ]; then
      [ "$QUIET" -eq 0 ] && report+="::notice file=$s::mute entry is stale -- $bn passed. Remove its line from $MFILE."$'\n'
    else
      muted_failed="$muted_failed $bn"
      [ "$QUIET" -eq 0 ] && report+="=== $bn (exit $rc, MUTED -- ${MUTED[$bn]})"$'\n'"$out"$'\n'
    fi
    continue
  fi

  sev="$(rc_severity "$rc")"
  if [ "$sev" -gt "$worst_sev" ]; then
    worst_sev="$sev"
    worst="$rc"
  fi
  if [ "$rc" -ne 0 ] || [ "$QUIET" -eq 0 ]; then
    report+="=== $bn (exit $rc)"$'\n'"$out"$'\n'
  fi
done

if [ "$count" -eq 0 ]; then
  echo "no remedy scripts found in $(pwd) -- nothing verified." >&2
  exit 2
fi

if [ "$worst" -ne 0 ] || [ "$QUIET" -eq 0 ]; then
  printf '%s' "$report"
  [ -n "$muted_failed" ] && echo "muted, not surfaced:$muted_failed"
  echo "verify-all: $count remedy script(s), worst exit $worst (0 pass / 2 could-not-check / 3 warn / 5 fail / 6 blind / 7 refused; anything else -- an exit the vocabulary never defined -- ranks as the worst kind of fail there is)"
fi
exit "$worst"
