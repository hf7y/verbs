#!/usr/bin/env bash
# senechal: reachable-but-undeclared host sweep. Non-AI, cron-safe,
# READ-ONLY. hf7y/senechal#30.
#
# estate-health.sh's device checks all start from senechal.json's
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

SSH_CONFIG="${SENECHAL_SSH_CONFIG:-$HOME/.ssh/config}"

# One lowercased Host pattern per line from an OpenSSH client config,
# wildcards excluded. Handles multiple names on one "Host a b c" line
# (each becomes its own candidate) since that's valid ssh_config syntax.
#
#   [rest: vault:senechal/header-archaeology-20260818.md]
_ssh_config_hosts() {
  local f="$1"
  [ -r "$f" ] || return 0
  awk '
    function flush() {
      if (count > 0 && !is_github) for (i = 1; i <= count; i++) print names[i]
      count = 0; is_github = 0
    }
    tolower($1) == "host" {
      flush()
      n = NF; for (i = 2; i <= n; i++) names[i-1] = $i; count = n - 1
      next
    }
    tolower($1) == "hostname" && tolower($2) == "github.com" { is_github = 1 }
    END { flush() }
  ' "$f" | while read -r name; do
    [[ "$name" == *[*?]* ]] && continue
    printf '%s\n' "${name,,}"
  done
}

# Declared identifiers from estate.devices[]: name and ssh_host, both
# lowercased, one per line, deduped by the caller via grep -Fxq.
_declared_device_ids() {
  cfg_devices | while IFS=$'\x1f' read -r name _kind _addr _reach _owner _expect ssh_host _os; do
    [ -n "$name" ] && printf '%s\n' "${name,,}"
    [ -n "$ssh_host" ] && printf '%s\n' "${ssh_host,,}"
  done
}

check_ssh_config() {
  head_ "~/.ssh/config Host stanzas vs. estate.devices[]"
  if [ ! -r "$SSH_CONFIG" ]; then
    skip "$SSH_CONFIG not readable -- cannot sweep configured hosts"
    return
  fi

  local declared any=0 host
  declared="$(_declared_device_ids)"
  while read -r host; do
    [ -n "$host" ] || continue
    any=1
    if grep -Fxq "$host" <<< "$declared"; then
      ok "$host -- has an estate.devices[] row"
    else
      fail "$host has an ssh config stanza but no estate.devices[] row"
      note "add it to estate.devices in senechal.json, or if it's not senechal's estate, note why in the entry that would otherwise cover it"
    fi
  done < <(_ssh_config_hosts "$SSH_CONFIG" | sort -u)
  [ "$any" -eq 1 ] || note "no named Host stanzas in $SSH_CONFIG"
}

check_footprint_hosts() {
  head_ "estate.footprint[].host vs. estate.devices[]"
  local declared any=0 host
  declared="$(_declared_device_ids)"
  while IFS=$'\x1f' read -r _id host _owner _kind _target _status _retire _notes; do
    [ -n "$host" ] || continue
    any=1
    if grep -Fxq "${host,,}" <<< "$declared"; then
      ok "$host -- has an estate.devices[] row"
    else
      fail "footprint names host '$host' but estate.devices[] has no matching row"
      note "a footprint entry on a host the registry doesn't know about is already a contradiction -- add the device row or fix the footprint entry's host field"
    fi
  done < <(cfg_footprint | sort -u -t $'\x1f' -k2,2)
  [ "$any" -eq 1 ] || note "no footprint entries with a host field"
}

main() {
  parse_common_args "$@"
  _emit "senechal hosts-unregistered sweep -- $(date '+%Y-%m-%d %H:%M')"
  check_ssh_config
  check_footprint_hosts
  finish_verify "OK -- every configured/footprint host has an estate.devices[] row."
}
main "$@"
