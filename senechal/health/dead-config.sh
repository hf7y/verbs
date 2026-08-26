#!/usr/bin/env bash
# senechal: dead machine-config check. Non-AI, cron-safe, READ-ONLY.
#
#   ./dead-config.sh          # full report
#   ./dead-config.sh -q       # silent unless something needs attention
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

# This host's name, so entries for other hosts SKIP visibly rather than
# being probed against the wrong machine -- a `systemctl is-active` for
# a dexter unit run on mandark answers confidently and wrongly.
THIS_HOST="${SENECHAL_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"

# How long a unit may sit inactive-but-installed, or keep failing, before
# it counts as suspected dead rather than merely idle.
STALE_DAYS="$(cfg health.dead_config_stale_days 3)"

# --- probes -------------------------------------------------------------
# Each probe echoes one of:
#   present    -- it is there and doing its job
#   suspect    -- it is there but looks like a corpse (why: on stderr-ish
#   [rest: vault:senechal/header-archaeology-20260818.md]

# Age in days of a systemd timestamp property value, or -1 if unparseable.
_ts_age_days() {
  local ts="$1" then_ now
  [ -n "$ts" ] && [ "$ts" != "n/a" ] || { echo -1; return; }
  then_="$(date -d "$ts" +%s 2>/dev/null)" || { echo -1; return; }
  [ -n "$then_" ] || { echo -1; return; }
  now="$(date +%s)"
  echo $(( (now - then_) / 86400 ))
}

# Did this unit's last run fail, in the sense SYSTEMD means it?
# Not the same question as "did it exit non-zero". A unit with
# SuccessExitStatus=1 2 3 -- like senechal's own senechal-health.service,
# whose exit code IS its report -- exits 1 on a perfectly correct run.
#   [rest: vault:senechal/header-archaeology-20260818.md]
_unit_failed_status() {
  local sctl_scope="$1" unit="$2" sctl=(systemctl) result status
  [ "$sctl_scope" = user ] && sctl=(systemctl --user)
  result="$("${sctl[@]}" show -p Result --value "$unit" 2>/dev/null)"
  status="$("${sctl[@]}" show -p ExecMainStatus --value "$unit" 2>/dev/null)"
  # No Result at all (a stub, or a systemd too old to report it): fall
  # back to the exit code rather than declaring everything healthy --
  # a missing verdict must not read as a passing one.
  if [ -z "$result" ]; then
    [ -n "$status" ] && [ "$status" != 0 ] && printf '%s' "$status"
    return
  fi
  [ "$result" = success ] && return
  printf '%s' "${status:-$result}"
}

probe_systemd() {
  local scope="$1" unit="$2" sctl=(systemctl) load active enabled status age trigger
  [ "$scope" = user ] && sctl=(systemctl --user)
  command -v systemctl >/dev/null 2>&1 || { echo "unknown systemctl not available"; return; }

  load="$("${sctl[@]}" show -p LoadState --value "$unit" 2>/dev/null)"
  if [ -z "$load" ]; then
    echo "unknown could not query $scope unit $unit"; return
  fi
  if [ "$load" != loaded ]; then
    # not-found / masked-but-absent: nothing installed under that name.
    echo "absent no $scope unit named $unit is installed"; return
  fi

  active="$("${sctl[@]}" is-active "$unit" 2>/dev/null)"
  enabled="$("${sctl[@]}" is-enabled "$unit" 2>/dev/null)"

  case "$unit" in
    *.timer)
      # A timer's corpse-shape is different: it can be perfectly alive
      # while the service it triggers fails every single night, which is
      # the gardien case exactly. Judge the timer by what it triggers.
      trigger="$("${sctl[@]}" show -p Unit --value "$unit" 2>/dev/null)"
      if [ -n "$trigger" ]; then
        status="$(_unit_failed_status "$scope" "$trigger")"
        if [ -n "$status" ]; then
          echo "suspect $unit is $active/$enabled but $trigger last failed ($status) -- firing on schedule into a failure"
          return
        fi
      fi
      echo "present $unit is $active/$enabled"
      return
      ;;
  esac

  if [ "$active" = active ]; then
    echo "present $unit is active/$enabled"; return
  fi
  # Installed but not running. Idle-on-purpose (a oneshot between runs)
  # and abandoned look identical in a single `is-active`, so date it.
  status="$(_unit_failed_status "$scope" "$unit")"
  age="$(_ts_age_days "$("${sctl[@]}" show -p InactiveEnterTimestamp --value "$unit" 2>/dev/null)")"
  if [ -n "$status" ]; then
    echo "suspect $unit is installed, inactive, and last failed ($status)"
  elif [ "$age" -lt 0 ]; then
    echo "suspect $unit is installed but inactive and has no recorded run -- installed and never used"
  elif [ "$age" -ge "$STALE_DAYS" ]; then
    echo "suspect $unit is installed, inactive for ${age}d (>= ${STALE_DAYS}d), enabled=$enabled"
  else
    echo "present $unit is installed, inactive ${age}d, enabled=$enabled"
  fi
}

probe_port() {
  local port="$1" line
  command -v ss >/dev/null 2>&1 || { echo "unknown ss not available"; return; }
  # -H would be cleaner but is not in every ss build; drop the header by
  # matching the state column instead.
  line="$(ss -ltnp 2>/dev/null | awk -v p=":$port\$" '$1=="LISTEN" && $4 ~ p')"
  if [ -n "$line" ]; then
    echo "present something is listening on $port: $(printf '%s' "$line" | sed 's/  */ /g')"
  else
    echo "absent nothing is listening on port $port"
  fi
}

probe_path() {
  local p="${1/#\~/$HOME}"
  if [ -e "$p" ]; then
    echo "present $p exists"
  else
    echo "absent $p is not present"
  fi
}

probe_authorized_keys() {
  # target is the key's comment/label; the file is the LOCAL
  # authorized_keys. For an entry whose host is not this one, the caller
  # never gets here -- it SKIPs.
  #
  #   [rest: vault:senechal/header-archaeology-20260818.md]
  local label="$1" f="$HOME/.ssh/authorized_keys"
  [ -r "$f" ] || { echo "unknown no readable $f"; return; }
  if grep -qF -- "$label" "$f"; then
    echo "present a line labelled '$label' is in $f"
  else
    echo "absent no line labelled '$label' in $f"
  fi
}

# --- the report ---------------------------------------------------------
check_footprint() {
  head_ "Registered footprint (senechal.json estate.footprint)"
  local id host owner kind target status retire notes
  local result verdict detail found=0

  while IFS=$'\x1f' read -r id host owner kind target status retire notes; do
    [ -n "$id" ] || continue
    found=1

    if [ -n "$host" ] && [ "$host" != "$THIS_HOST" ]; then
      skip "$id ($host, owner: $owner) -- on another host, and this check does not probe remotely yet (senechal#111)"
      note "declared: $status. $retire"
      continue
    fi

    case "$kind" in
      systemd-system-unit) result="$(probe_systemd system "$target")" ;;
      systemd-user-unit)   result="$(probe_systemd user "$target")" ;;
      listening-port)      result="$(probe_port "$target")" ;;
      path)                result="$(probe_path "$target")" ;;
      authorized-keys)     result="$(probe_authorized_keys "$target")" ;;
      *)                   result="unknown no probe implemented for kind '$kind'" ;;
    esac
    verdict="${result%% *}"
    detail="${result#* }"

    case "$status:$verdict" in
      # Declared live and there: the ordinary case.
      live:present)   ok "$id -- live as declared ($detail)" ;;
      live:suspect)
        # The core finding this script exists for: still installed,
        # still enabled, and by every probe we have, nobody's using it.
        warn_ "$id -- SUSPECTED DEAD: $detail"
        note "owner: $owner. Confirm with them, then: $retire" ;;
      live:absent)
        # Also a real finding, and the one people forget: something
        # declared live has gone. Either it was retired without anyone
        # updating this file, or it broke.
        fail "$id -- declared live but ABSENT: $detail"
        note "owner: $owner. Either it was retired without updating senechal.json's footprint entry, or it is broken." ;;

      # Agreed dead, still installed: nag, every run, until it is gone.
      retiring:present|retiring:suspect)
        warn_ "$id -- agreed retiring, STILL INSTALLED: $detail"
        note "owner: $owner. Finish it: $retire"
        [ -n "$notes" ] && note "why: $notes" ;;
      retiring:absent)
        ok "$id -- retirement complete ($detail)"
        note "move this entry to status \"retired\" in senechal.json so a reappearance is a finding." ;;

      # Should be gone. If it is back, something reinstalled it.
      retired:absent)  ok "$id -- retired and still gone ($detail)" ;;
      retired:present|retired:suspect)
        fail "$id -- declared RETIRED but it is back: $detail"
        note "owner: $owner. Something reinstalled it, or the removal never happened: $retire" ;;

      *:unknown)
        skip "$id -- $detail"
        note "declared: $status, owner: $owner" ;;
      *)
        skip "$id -- unrecognised status '$status' in senechal.json (probe said: $verdict)"
        note "valid: live, retiring, retired" ;;
    esac
  done < <(cfg_footprint)

  if [ "$found" -eq 0 ]; then
    # Not a pass: an empty registry and a registry that failed to parse
    # look identical from here, and "senechal knows of no machine config"
    # is false on this estate by inspection.
    skip "no footprint entries readable from $SENECHAL_CONFIG -- empty registry, or config did not parse"
  fi
}

main() {
  parse_common_args "$@"
  _emit "senechal dead-config check -- $(date '+%Y-%m-%d %H:%M') on $THIS_HOST"
  check_footprint
  finish_verify "OK -- every registered footprint entry matches what it declares."
}
main "$@"
