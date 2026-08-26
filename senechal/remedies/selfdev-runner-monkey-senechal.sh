#!/usr/bin/env bash
# senechal: keep this project's own self-hosted GitHub Actions runner alive
# on monkey.
#
#   ./selfdev-runner-monkey-senechal.sh enable    # restart it (needs sudo, asks once)
#   ./selfdev-runner-monkey-senechal.sh verify    # non-AI, cron-safe: is it active?
#
# Found 2026-08-23: three PRs (#397, #400, #401) sat with `prose` checks
# stuck "pending" for 1h44m+. `gh api repos/hf7y/senechal/actions/runners`
# showed the runner offline; `systemctl status` showed it exited cleanly
# (status=0/SUCCESS) at 16:49:36 UTC and never came back -- no crash loop,
# no Restart= policy catching it. Confirmed host-wide, not senechal-specific:
# monkey-gardien and monkey-ecosim were offline the same way at the same
# time. This remedy only restarts senechal's own instance; the host-wide
# question (why did none of them come back, and should the unit carry a
# Restart= policy) is flagged on hf7y/senechal#377, not fixed here -- this
# repo only owns its own runner's config file, not systemd unit definitions
# installed by bin/selfdev-runner-provision.sh (realisateur's).
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

UNIT="actions.runner.hf7y-senechal.monkey-senechal.service"
# Overridable for tests only: exercise enable/verify against a fake
# systemctl, no real sudo prompt or live systemd involved.
SUDO_CMD="${SENECHAL_SUDO_CMD-sudo}"
SYSTEMCTL="${SENECHAL_SYSTEMCTL:-systemctl}"

query_state() {
  # is-active needs no privilege -- read-only, safe under cron.
  "$SYSTEMCTL" is-active "$UNIT" 2>/dev/null
}

do_enable() {
  say "senechal remedy: restart $UNIT (it is currently $(query_state 2>/dev/null || echo unknown))"
  say "This asks for sudo once. Undo, if it turns out to be wanted: there is"
  say "no disable verb -- a runner you want off stays off via GitHub's own"
  say "'remove runner' flow, not a config toggle here."
  say ""
  $SUDO_CMD "$SYSTEMCTL" restart "$UNIT" || die "restart failed -- see: systemctl status $UNIT"
  say ""
  say "run: ./selfdev-runner-monkey-senechal.sh verify"
}

do_verify() {
  head_ "selfdev-runner-monkey-senechal: $UNIT active"
  # Branch on whether systemctl ANSWERED, not on its exit code. `is-active`
  # exits 3 for a dead unit, so keying on rc filed the one shape this remedy
  # exists for -- cleanly exited, status=0/SUCCESS, never came back -- as
  # "could not check" instead of a failure. Empty output is the only real
  # can't-look: no systemctl on this host, or not this host at all.
  local state
  state="$(query_state)"
  case "$state" in
    active) ok "$UNIT is active" ;;
    "")     skip "could not query $UNIT (systemctl unavailable, or this is not monkey)" ;;
    *)      fail "$UNIT reports '$state', not active -- run: ./selfdev-runner-monkey-senechal.sh enable" ;;
  esac
  finish_verify "OK -- $UNIT is active."
}

case "${1:-}" in
  enable) shift; parse_common_args "$@"; do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
