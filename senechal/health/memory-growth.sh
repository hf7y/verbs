#!/usr/bin/env bash
# Read-only leak sniffer: sample every process's RSS twice and report
# the ones that grew, largest growth first.
#
# Growth over a single window is a SUSPECT, not a verdict -- an active
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

WINDOW="${1:-60}"
MIN_KB="${2:-10240}"   # 10 MiB of growth within the window

# pid rss comm, one per line, sorted by pid for join(1). comm can
# contain spaces ("Isolated Web Co"), so squash them -- otherwise the
# field count varies per row and the join silently mis-aligns.
snap() {
  ps -eo pid=,rss=,comm= |
    awk '{pid=$1; rss=$2; $1=""; $2=""; sub(/^ +/,""); gsub(/ +/,"_"); print pid, rss, $0}' |
    sort -k1,1
}

before=$(snap)
sleep "$WINDOW"
after=$(snap)

# join on pid -> "pid before_rss before_comm after_rss after_comm".
# Emit the delta as a leading field so the sort is by GROWTH, then cut
# it back off for display.
report=$(join -j 1 <(printf '%s\n' "$before") <(printf '%s\n' "$after") |
  awk -v min="$MIN_KB" '{d=$4-$2; if (d>=min) printf "%.1f\t%-8s %-20s %8.1f MiB -> %8.1f MiB  (+%.1f MiB)\n", d, $1, $3, $2/1024, $4/1024, d/1024}' |
  sort -gr | cut -f2-)

if [ -z "$report" ]; then
  echo "PASS: no process grew by ${MIN_KB} KiB over ${WINDOW}s"
  exit "$RC_PASS"
fi
echo "WARN: RSS growth over ${WINDOW}s (suspects, not proof):"
printf '%s\n' "$report"
exit "$RC_WARN"
