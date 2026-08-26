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

worst=0
worst_sev=0
report=""
count=0

for s in ./*.sh; do
  case "$(basename "$s")" in
    _*|verify-all.sh) continue ;;
  esac
  [ -x "$s" ] || continue
  count=$((count + 1))
  out="$("$s" verify 2>&1)" && rc=0 || rc=$?
  sev="$(rc_severity "$rc")"
  if [ "$sev" -gt "$worst_sev" ]; then
    worst_sev="$sev"
    worst="$rc"
  fi
  if [ "$rc" -ne 0 ] || [ "$QUIET" -eq 0 ]; then
    report+="=== $(basename "$s") (exit $rc)"$'\n'"$out"$'\n'
  fi
done

if [ "$count" -eq 0 ]; then
  echo "no remedy scripts found in $(pwd) -- nothing verified." >&2
  exit 2
fi

if [ "$worst" -ne 0 ] || [ "$QUIET" -eq 0 ]; then
  printf '%s' "$report"
  echo "verify-all: $count remedy script(s), worst exit $worst (0 pass / 1 fail / 2 could-not-check / 3 warn; severity 1>2>3>0)"
fi
exit "$worst"
