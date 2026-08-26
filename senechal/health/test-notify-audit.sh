#!/usr/bin/env bash
# Test harness for estate-health.sh's check_notify_audit -- the
# summarize-and-clear half of remedies/notify-audit.sh (the daemon half,
# which needs a live session D-Bus bus, is not testable headless and is
# proven by remedies/notify-audit.sh's own verify against real state).
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state/senechal"

cat > "$T/senechal.json" <<'JSON'
{
  "estate": { "devices": [] },
  "health": { "notify_audit_warn_count": 3 }
}
JSON

pass=0; failed=0
check() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
  fi
}

run() { # -> full report on stdout
  SENECHAL_CONFIG="$T/senechal.json" XDG_STATE_HOME="$T/state" bash ./estate-health.sh 2>&1
}

# --- not enabled: no log at all -----------------------------------------
rm -f "$T/state/senechal/notify-audit.log" "$T/state/senechal/notify-audit-history.tsv"
out="$(run)"
check "no log -> SKIP naming the remedy" yes \
  "$(case "$out" in *'no notify-audit.log -- remedies/notify-audit.sh not enabled yet'*) echo yes ;; *) echo "no ($out)" ;; esac)"
check "no log -> no history file created" no \
  "$([ -f "$T/state/senechal/notify-audit-history.tsv" ] && echo yes || echo no)"

# --- enabled, nothing fired since the last check -------------------------
: > "$T/state/senechal/notify-audit.log"
out="$(run)"
check "empty log -> PASS, no senders" yes \
  "$(case "$out" in *'no desktop notifications, any sender, since the last check'*) echo yes ;; *) echo "no ($out)" ;; esac)"
check "empty log -> stays empty, no history line added" no \
  "$([ -s "$T/state/senechal/notify-audit-history.tsv" ] && echo yes || echo no)"

# --- real traffic: one sender over threshold, two under -------------------
{
  for _ in 1 2 3 4 5; do printf '2026-08-11T09:00:00-0500\tchromium\tDownload complete\n'; done
  for _ in 1 2;         do printf '2026-08-11T09:01:00-0500\tsenechal\testate health -- recovered\n'; done
  printf '2026-08-11T09:02:00-0500\tspotify\tNow playing\n'
} > "$T/state/senechal/notify-audit.log"

out="$(run)"
check "sender over threshold (5 >= 3) WARNs by name" yes \
  "$(case "$out" in *'chromium sent 5 desktop notifications since the last check (>= 3) -- possible spam'*) echo yes ;; *) echo "no ($out)" ;; esac)"
check "sender under threshold (2 < 3) does not WARN" yes \
  "$(case "$out" in *'senechal sent'*) echo "no ($out)" ;; *) echo yes ;; esac)"
check "sender under threshold (1 < 3) does not WARN" yes \
  "$(case "$out" in *'spotify sent'*) echo "no ($out)" ;; *) echo yes ;; esac)"
check "PASS line names total count and sender count" yes \
  "$(case "$out" in *'8 notification(s) from 3 sender(s) since the last check'*) echo yes ;; *) echo "no ($out)" ;; esac)"

check "the raw log is truncated after summarizing" "" "$(cat "$T/state/senechal/notify-audit.log")"
check "exactly one summary line was appended" 1 "$(grep -c . "$T/state/senechal/notify-audit-history.tsv")"
hist_line="$(cat "$T/state/senechal/notify-audit-history.tsv")"
check "the summary line carries every sender's count" yes \
  "$(case "$hist_line" in *'chromium:5'*'senechal:2'*'spotify:1'*) echo yes ;; *'chromium:5'*) echo yes ;; *) echo "no ($hist_line)" ;; esac)"
check "the summary line carries the total" yes \
  "$(case "$hist_line" in *$'\t8\t'*) echo yes ;; *) echo "no ($hist_line)" ;; esac)"

# --- a second summarize-and-clear run must not re-page on the same data --
: > "$T/state/senechal/notify-audit.log"
out="$(run)"
check "cleared log -> back to the clean PASS" yes \
  "$(case "$out" in *'no desktop notifications, any sender, since the last check'*) echo yes ;; *) echo "no ($out)" ;; esac)"
check "no second history line for an empty run" 1 \
  "$(grep -c . "$T/state/senechal/notify-audit-history.tsv")"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$failed"
[ "$failed" -eq 0 ]
