#!/usr/bin/env bash
# senechal: unabsorbed-notices check. Non-AI, cron-safe, READ-ONLY.
#
#   ./unabsorbed-notices.sh          # full report
#   ./unabsorbed-notices.sh -q       # silent unless something needs attention
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

REPO="hf7y/senechal"

# How many days an open `idea`-labelled notice may sit unabsorbed before
# it counts as stale rather than merely new. senechal.json's
# health.notice_stale_days, so it can be tightened without a code change.
STALE_DAYS="$(cfg health.notice_stale_days 2)"
case "$STALE_DAYS" in
  ''|*[!0-9]*)
    warn "health.notice_stale_days='$STALE_DAYS' is not a whole number of days -- using 2"
    STALE_DAYS=2 ;;
esac

check_notices() {
  head_ "Unabsorbed notices ($REPO, label:idea, open)"

  if ! command -v gh >/dev/null 2>&1; then
    skip "gh is not on PATH -- cannot check the notice queue"
    return
  fi

  local raw_file err rc
  raw_file="$(mktemp)"
  err="$(mktemp)"
  gh issue list --repo "$REPO" --label idea --state open \
    --json number,title,createdAt >"$raw_file" 2>"$err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    skip "gh issue list failed (exit $rc): $(tr '\n' ' ' < "$err")"
    rm -f "$raw_file" "$err"
    return
  fi
  rm -f "$err"

  # Parsed and aged here, not in gh: gh has no notion of "stale", and
  # doing the arithmetic in one place keeps the test able to assert
  # against fixed JSON instead of the wall clock.
  #
  #   [rest: vault:senechal/header-archaeology-20260818.md]
  local parsed
  parsed="$(python3 - "$raw_file" "$STALE_DAYS" 2>/dev/null <<'PY'
import json, sys
from datetime import datetime, timezone

raw_file, stale_days = sys.argv[1], int(sys.argv[2])
try:
    issues = json.load(open(raw_file))
except Exception as e:
    print("PARSE_ERROR\t%s: %s" % (type(e).__name__, e))
    raise SystemExit(0)
if not isinstance(issues, list):
    print("PARSE_ERROR\tgh returned %s, expected a list" % type(issues).__name__)
    raise SystemExit(0)

now = datetime.now(timezone.utc)
for i in issues:
    try:
        created = datetime.strptime(i["createdAt"], "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except Exception as e:
        print("BAD_DATE\t%s\t%s\t%s" % (i.get("number", "?"), i.get("title", ""), e))
        continue
    age_days = (now - created).days
    stale = "1" if age_days >= stale_days else "0"
    title = str(i.get("title", "")).replace("\t", " ")
    print("%s\t%s\t%s\t%s\t%s" % (i.get("number", "?"), title, age_days,
                                   i["createdAt"], stale))
PY
  )"
  rm -f "$raw_file"

  if [ -z "$parsed" ]; then
    ok "no open $REPO notices labelled idea"
    return
  fi

  local num title age created stale found=0
  while IFS=$'\t' read -r num title age created stale; do
    [ -n "$num" ] || continue
    found=1
    if [ "$num" = PARSE_ERROR ]; then
      skip "could not parse gh's JSON -- $title"
      continue
    fi
    if [ "$num" = BAD_DATE ]; then
      skip "#$title -- could not parse createdAt ($stale)"
      continue
    fi
    if [ "$stale" = 1 ]; then
      warn_ "#$num (${age}d old, created $created) still open and unabsorbed: $title"
      note "close it once its content has been folded into ESTATE.md/senechal.json -- closing IS the acknowledgement, per its own filing footer."
    else
      ok "#$num -- ${age}d old, under the ${STALE_DAYS}d threshold: $title"
    fi
  done <<< "$parsed"

  [ "$found" -eq 1 ] || ok "no open $REPO notices labelled idea"
}

main() {
  parse_common_args "$@"
  _emit "senechal unabsorbed-notices check -- $(date '+%Y-%m-%d %H:%M')"
  check_notices
  finish_verify "OK -- no unabsorbed notice has sat past ${STALE_DAYS}d."
}
main "$@"
