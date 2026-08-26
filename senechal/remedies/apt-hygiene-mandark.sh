#!/usr/bin/env bash
# senechal: clean up two stale apt sources on mandark.
#
#   ./apt-hygiene-mandark.sh enable    # fix both (needs sudo, asks once)
#   ./apt-hygiene-mandark.sh verify    # non-AI, cron-safe: are both gone?
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

# --- target values, defined once, read by both verbs --------------------
STALE_KEY="/etc/apt/trusted.gpg.d/home_aggraef_purr-data-jgu.gpg"
STALE_REPO_LIST="/etc/apt/sources.list.d/home:aggraef:purr-data-jgu.list"
DUP_LIST="/etc/apt/sources.list.d/dvd.list"
DISABLED_SUFFIX=".disabled-by-senechal"

do_enable() {
  say "senechal remedy: apt hygiene on mandark"
  say "Nothing is deleted -- files are renamed with a $DISABLED_SUFFIX"
  say "suffix, so this is a rename away from a full undo."
  say ""

  if [ ! -f "$STALE_KEY" ] && [ ! -f "$STALE_REPO_LIST" ]; then
    say "1/2 expired home:aggraef purr-data-jgu repo: already gone -- nothing to do."
  else
    say "1/2 disabling expired home:aggraef purr-data-jgu repo (key + list)"
    say "    this needs sudo -- you may be prompted for your password."
    if [ -f "$STALE_REPO_LIST" ]; then
      sudo mv -n "$STALE_REPO_LIST" "${STALE_REPO_LIST}${DISABLED_SUFFIX}" \
        || die "failed to disable $STALE_REPO_LIST"
    fi
    if [ -f "$STALE_KEY" ]; then
      sudo mv -n "$STALE_KEY" "${STALE_KEY}${DISABLED_SUFFIX}" \
        || die "failed to disable $STALE_KEY"
    fi
    say "    done -- re-enable by renaming back if you ever get a fresh key for this repo."
  fi

  say ""
  if [ ! -f "$DUP_LIST" ]; then
    say "2/2 duplicate dvd.list universe/multiverse entries: already gone -- nothing to do."
  else
    say "2/2 disabling $DUP_LIST (universe/multiverse already covered by ubuntu.sources)"
    sudo mv -n "$DUP_LIST" "${DUP_LIST}${DISABLED_SUFFIX}" \
      || die "failed to disable $DUP_LIST"
    say "    done."
  fi

  say ""
  say "refreshing apt's view (sudo apt-get update) so verify reflects the change immediately..."
  sudo apt-get update >/tmp/senechal-apt-hygiene-update.log 2>&1 \
    && say "apt-get update: clean." \
    || warn "apt-get update reported problems -- see /tmp/senechal-apt-hygiene-update.log (may be unrelated to this remedy)"

  say ""
  say "run: ./apt-hygiene-mandark.sh verify"
}

do_verify() {
  if [ ! -f "$STALE_KEY" ] && [ ! -f "$STALE_REPO_LIST" ]; then
    ok "expired home:aggraef purr-data-jgu repo is not active"
  else
    fail "expired home:aggraef purr-data-jgu repo still present ($STALE_REPO_LIST / $STALE_KEY) -- run: ./apt-hygiene-mandark.sh enable"
  fi

  if [ ! -f "$DUP_LIST" ]; then
    ok "duplicate $DUP_LIST is not active"
  else
    fail "$DUP_LIST still duplicates ubuntu.sources's universe/multiverse -- run: ./apt-hygiene-mandark.sh enable"
  fi

  finish_verify "OK -- both stale apt sources are disabled."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
