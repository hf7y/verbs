#!/usr/bin/env bash
# run-suites.sh -- run every suite handed to it; a quarantined failure (see
# run-suites.quarantine) still prints loud but does not fail the exit code.
# Gives a suite gone red under time pressure a one-line lever instead of
# dropping the whole `tests` required check.
#
# Ported verbatim from realisateur/bin/run-suites.sh (2026-08-23), which
# exists because that repo had the same finding senechal has: suites that
# were real, passed, and that nothing ever ran -- "which makes them
# documentation" (.github/workflows/tests.yml). senechal had 48 of them,
# ~7,700 lines, no runner and no CI job.
#
# Caller globs, not this file: a roster in here would rot the first time a
# suite was added and nobody remembered to list it.
#
# A suite is run with STDIN CLOSED. One that reads stdin hangs forever under
# any runner without a tty -- cron, CI, a background job.
#
# usage:  run-suites.sh <suite-path>...
# exit 0  ran; nothing failed, or every failure was quarantined
# exit 1  a non-quarantined suite failed
# exit 6  BLIND -- no suite paths given
set -uo pipefail

SUITE_TIMEOUT="${RUN_SUITES_TIMEOUT:-300}"
QFILE="${RUN_SUITES_QUARANTINE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-suites.quarantine}"

[ $# -gt 0 ] || { echo "run-suites: BLIND -- no suite paths given, nothing was run" >&2; exit 6; }

declare -A QUARANTINED=()
if [ -f "$QFILE" ]; then
  while IFS=$'\t' read -r qpath qissue qreason || [ -n "$qpath" ]; do
    case "$qpath" in ''|'#'*) continue ;; esac
    QUARANTINED["$qpath"]="${qissue:-<no issue cited>} ${qreason:-}"
  done < "$QFILE"
fi

failed=""
quarantined_failed=""
for t in "$@"; do
  echo "::group::$t"
  rc=0
  # STDIN CLOSED -- see the header. Dispatch on extension: senechal's
  # suites are both shell and unittest-style Python (each ends in
  # unittest.main()), unlike realisateur's all-bash bin/tests/.
  #
  # TIMEOUT, not "it will finish": a suite that hangs takes the whole run
  # with it, and a CI job that never returns reads as "still working" for
  # its entire billing window. Same reasoning as test/contract-test.sh's
  # own per-invocation timeout. 124 is reported as the failure it is.
  case "$t" in
    *.py) timeout "$SUITE_TIMEOUT" python3 "$t" </dev/null || rc=$? ;;
    *)    timeout "$SUITE_TIMEOUT" bash    "$t" </dev/null || rc=$? ;;
  esac
  [ "$rc" = 124 ] && echo "::error file=$t::TIMED OUT after ${SUITE_TIMEOUT}s"
  echo "::endgroup::"
  if [ "$rc" -ne 0 ]; then
    if [ -n "${QUARANTINED[$t]+set}" ]; then
      echo "::warning file=$t::QUARANTINED (${QUARANTINED[$t]}) -- still failing, exit $rc, not gating"
      quarantined_failed="$quarantined_failed $t"
    else
      echo "::error file=$t::suite failed (exit $rc)"
      failed="$failed $t"
    fi
  elif [ -n "${QUARANTINED[$t]+set}" ]; then
    echo "::notice file=$t::quarantine entry is stale -- $t passed. Remove its line from $QFILE."
  fi
done

echo
echo "ran $# suite(s)."
[ -n "$quarantined_failed" ] && echo "quarantined, not gating:$quarantined_failed"
if [ -n "$failed" ]; then
  echo "FAILED:$failed"
  exit 1
fi
echo "all non-quarantined suite(s) passed."
