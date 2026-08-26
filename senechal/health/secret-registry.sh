#!/usr/bin/env bash
# senechal: credential inventory check. Non-AI, cron-safe, READ-ONLY.
#
#   ./secret-registry.sh          # full report
#   ./secret-registry.sh -q       # silent unless something needs attention
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

THIS_HOST="${SENECHAL_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
SSH_TIMEOUT="${SENECHAL_SSH_TIMEOUT:-10}"

# --- probing another host -----------------------------------------------
# A remote entry is PROBED over BatchMode ssh, this estate's standing
# precedent: it never prompts, ConnectTimeout bounds the wait, and an
# unreachable host degrades to SKIP. What stays SKIP is a host with no
# ssh_host, or one that did not answer.
ssh_host_for() {
  local want="$1" name kind addr reach owner expect ssh_host os
  while IFS=$'\x1f' read -r name kind addr reach owner expect ssh_host os; do
    [ "$name" = "$want" ] || continue
    printf '%s' "$ssh_host"
    return 0
  done < <(cfg_devices)
  return 0
}

# Echo "<exists 0|1> <mode>" for a path on a remote host, or nothing if
# the host could not be reached. Never reads contents -- `test` and
# `stat` only, exactly as the local path does.
remote_probe() {
  local sshh="$1" p="$2"
  ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$sshh" \
      "if [ -e '$p' ]; then printf '1 '; stat -c '%a' '$p' 2>/dev/null || printf '?\n'; else printf '0 -\n'; fi" \
      </dev/null 2>/dev/null
}

# --- is this path inside a gardien backup set? --------------------------
# Answers the plaintext-egress question. Populated once, because reading
# gardien's config per secret would be the same answer N times.
GARDE_SETS=""
GARDE_READABLE=0
_load_garde_sets() {
  local out
  if out="$(cfg_garde_sets)"; then
    GARDE_SETS="$out"
    GARDE_READABLE=1
  fi
}

# Echo the name of the gardien set that actually COPIES $1, or nothing.
#
# "Inside a set" is not the same as "copied": a set's `exclude` list is
# fed straight to `rsync --exclude=`, so an excluded path never leaves
#   [rest: vault:senechal/header-archaeology-20260818.md]
_backed_up_by() {
  local p="$1" set_path set_name excl rel e
  [ "$GARDE_READABLE" -eq 1 ] || return 0
  while IFS=$'\x1f' read -r set_path set_name excl; do
    [ -n "$set_path" ] || continue
    # Prefix match on a path BOUNDARY: ~/.config must not match
    # ~/.configuration, which would silently over-report egress.
    case "$p" in
      "$set_path"|"$set_path"/*) ;;
      *) continue ;;
    esac
    rel="${p#"$set_path"/}"
    if [ -n "$excl" ]; then
      local IFS_SAVE=$IFS
      IFS=$'\x1e'
      for e in $excl; do
        [ -n "$e" ] || continue
        # rsync excludes a named path and everything beneath it.
        case "$rel" in
          "$e"|"$e"/*) IFS=$IFS_SAVE; return 0 ;;
        esac
      done
      IFS=$IFS_SAVE
    fi
    printf '%s' "$set_name"; return 0
  done <<< "$GARDE_SETS"
  return 0
}

check_secrets() {
  head_ "Registered credentials (senechal.json estate.secrets)"
  local id host owner path purpose mode recovery reprovision_cost offhost status verify reprovision notes
  local expanded actual found=0 in_set

  while IFS=$'\x1f' read -r id host owner path purpose mode recovery reprovision_cost offhost status verify reprovision notes; do
    [ -n "$id" ] || continue
    found=1
    # An entry that does not say is live. Absent status must not silently
    # mean "retired" -- that would turn a missing credential into a pass.
    [ -n "$status" ] || status=live

    if [ -n "$host" ] && [ "$host" != "$THIS_HOST" ]; then
      local sshh probe rexists rmode
      sshh="$(ssh_host_for "$host")"
      if [ -z "$sshh" ]; then
        skip "$id ($host, owner: $owner) -- no ssh_host for '$host' in estate.devices, so it cannot be reached"
        note "declared: $purpose"
        continue
      fi
      probe="$(remote_probe "$sshh" "$path")"
      if [ -z "$probe" ]; then
        skip "$id ($host, owner: $owner) -- $sshh did not answer a BatchMode ssh"
        note "declared: $purpose"
        continue
      fi
      read -r rexists rmode <<< "$probe"
      if [ "$rexists" != 1 ]; then
        fail "$id -- MISSING on $host: $path does not exist"
        note "purpose: $purpose"
        note "owner: $owner. Reissue it: ${reprovision:-<no runbook recorded>}"
      elif [ -n "$mode" ] && [ "$rmode" != "$mode" ] && [ "$rmode" != "?" ]; then
        fail "$id -- MODE DRIFT on $host: $path is $rmode, declared $mode"
        note "owner: $owner. Restore it: ssh $sshh chmod $mode $path"
      else
        ok "$id -- present on $host, mode $rmode (probed over ssh)"
      fi
      continue
    fi

    expanded="${path/#\~/$HOME}"

    # DESTROYED ON PURPOSE: gone is the pass, and a reappearance is the
    # finding. Handled before every live-credential rule below, none of
    # which mean anything for a key that is supposed to not exist.
    if [ "$status" = retired ]; then
      if [ -e "$expanded" ]; then
        fail "$id -- declared RETIRED but it is BACK: $expanded exists"
        note "owner: $owner. A dead private key is still a private key. $reprovision"
      else
        ok "$id -- retired and still gone ($expanded)"
      fi
      continue
    fi

    # A REGISTRY ENTRY WITH NO WAY TO RECREATE THE CREDENTIAL IS THE
    # FAILURE THIS EXISTS TO PREVENT. Checked before presence, because
    # it is exactly when the file is still there that nobody notices.
    # NOT BACKING IT UP IS ONLY SAFE IF REISSUING IT IS WRITTEN DOWN.
    # This is the gate that makes the whole strategy honest, so it runs
    # before presence: it is exactly while the file is still sitting
    # there that nobody notices the runbook is missing.
    if [ -z "$reprovision" ]; then
      warn_ "$id -- NO reprovision runbook: nothing here says how to issue another one"
      note "owner: $owner. Add \"reprovision\" to its estate.secrets entry, or retire the credential."
    else
      case "$reprovision_cost" in
        high)
          warn_ "$id -- reissuing is recorded but NOT straightforward (reprovision_cost=high)"
          note "owner: $owner. $notes" ;;
        unknown|"")
          warn_ "$id -- reissue cost unrecorded, so 'we can just make another' is untested"
          note "owner: $owner. Set reprovision_cost: low|medium|high after walking the runbook once." ;;
      esac
    fi

    if [ ! -e "$expanded" ]; then
      case "$recovery" in
        remint)
          fail "$id -- MISSING: $expanded does not exist"
          note "purpose: $purpose"
          note "owner: $owner. Issue a new one: ${reprovision:-<no runbook recorded>}" ;;
        escrow)
          fail "$id -- MISSING: $expanded does not exist, and it is NOT re-mintable"
          note "purpose: $purpose"
          note "owner: $owner. Restore from escrow: ${reprovision:-<no runbook recorded>}" ;;
        *)
          fail "$id -- MISSING: $expanded does not exist, and its recovery is '$recovery' (expected remint or escrow)"
          note "owner: $owner. ${reprovision:-<no runbook recorded>}" ;;
      esac
      continue
    fi

    # Least privilege. Declared mode is the CEILING, and a wider mode is
    # the finding -- 0777 on a private key is how this check was born.
    actual="$(stat -c '%a' "$expanded" 2>/dev/null)"
    if [ -z "$actual" ]; then
      skip "$id -- $expanded exists but its mode could not be read"
      continue
    fi
    if [ -n "$mode" ] && [ "$actual" != "$mode" ]; then
      fail "$id -- MODE DRIFT: $expanded is $actual, declared $mode"
      note "owner: $owner. Restore it: chmod $mode $expanded"
      continue
    fi

    # Plaintext egress: a credential declared host-only that a backup set
    # is nevertheless copying off the machine, unencrypted. This is the
    # monkey.pem/0777-on-dexter finding, mechanized.
    in_set="$(_backed_up_by "$expanded")"
    if [ "$offhost" = forbid ] && [ -n "$in_set" ]; then
      fail "$id -- PLAINTEXT LEAVES THE HOST: declared offhost=forbid, but gardien set '$in_set' copies it"
      note "purpose: $purpose"
      note "owner: $owner. Either exclude it from that set, or change the entry to offhost=allow and say why."
      [ -n "$notes" ] && note "why it matters: $notes"
      continue
    fi
    if [ "$offhost" = forbid ] && [ "$GARDE_READABLE" -eq 0 ]; then
      skip "$id -- present and mode $actual, but gardien's set list is unreadable so egress could not be checked"
      continue
    fi

    if [ -n "$in_set" ]; then
      ok "$id -- present, mode $actual, offhost=$offhost (gardien set '$in_set' copies it, as declared)"
    else
      ok "$id -- present, mode $actual, no backup set copies it ($recovery)"
    fi
  done < <(cfg_secrets)

  if [ "$found" -eq 0 ]; then
    # Same reasoning as dead-config: an empty registry and a registry
    # that did not parse look identical from here, and "this estate holds
    # no credentials" is false by inspection.
    skip "no estate.secrets entries readable from $SENECHAL_CONFIG -- empty registry, or config did not parse"
  fi
}

# --- reprovision: print the runbook, run nothing -------------------------
# The whole point of not backing a credential up is that losing it is a
# PROCEDURE rather than an emergency. This prints that procedure. It
# deliberately does not execute it: minting a credential revokes or
# supersedes a live one, which is the irreversible-against-a-real-service
# class that stays human-confirmed (the acting authority `discipline` prints).
reprovision_runbook() {
  local want="$1" found=0
  local id host owner path purpose mode recovery reprovision_cost offhost status verify reprovision notes
  while IFS=$'\x1f' read -r id host owner path purpose mode recovery reprovision_cost offhost status verify reprovision notes; do
    [ -n "$id" ] || continue
    [ "$want" = all ] || [ "$want" = "$id" ] || continue
    found=1
    say ""
    say "=== $id  ($host, owner: $owner)"
    say "    what   : $purpose"
    say "    lives  : $path  (mode $mode)"
    [ -n "$verify" ] && say "    prove  : $verify"
    say "    cost   : ${reprovision_cost:-unrecorded}"
    if [ -n "$reprovision" ]; then
      say "    reissue: $reprovision"
    else
      say "    reissue: NO RUNBOOK RECORDED -- this is the gap; add \"reprovision\" to its entry."
    fi
  done < <(cfg_secrets)
  if [ "$found" -eq 0 ]; then
    say "no credential registered as '$want'. Known ids:"
    cfg_secrets | cut -d$'\x1f' -f1 | sed 's/^/  /'
    return "$RC_FAIL"
  fi
  say ""
  say "Nothing above was executed. Minting supersedes a live credential;"
  say "that stays a human act."
  return "$RC_PASS"
}

# --- verify: does the credential actually WORK ---------------------------
# OPT-IN, and never part of the hourly run: estate-health.sh is
# "non-AI, cron-safe, read-only" and these commands touch the network and
# spend rate limit. Presence is what the timer checks; validity is what a
# person checks when they want to know.
verify_credentials() {
  head_ "Credential validity (running each entry's verify command)"
  local id host owner path purpose mode recovery reprovision_cost offhost status verify reprovision notes
  local found=0
  while IFS=$'\x1f' read -r id host owner path purpose mode recovery reprovision_cost offhost status verify reprovision notes; do
    [ -n "$id" ] || continue
    [ "$status" = retired ] && continue
    found=1
    if [ -n "$host" ] && [ "$host" != "$THIS_HOST" ]; then
      skip "$id -- registered on $host, not verifiable from here"
      continue
    fi
    if [ -z "$verify" ]; then
      skip "$id -- no verify command recorded, so 'it exists' is all senechal can say"
      note "owner: $owner. Add \"verify\": a command that proves this credential still works."
      continue
    fi
    # </dev/null is load-bearing, not tidiness: a verify command that
    # reads stdin -- any `ssh`, which slurps it by default -- otherwise
    # eats the rest of THIS loop's input and the run ends early with
    # every remaining credential silently unchecked. Seen on the first
    # real run: `ssh monkey sha256sum` swallowed four entries and the
    # report still exited cleanly, which is the worst possible shape.
    if bash -c "$verify" </dev/null >/dev/null 2>&1; then
      ok "$id -- verified working"
    else
      fail "$id -- PRESENT BUT NOT WORKING: \`$verify\` failed"
      note "owner: $owner. Reissue it: ${reprovision:-<no runbook recorded>}"
    fi
  done < <(cfg_secrets)
  [ "$found" -eq 0 ] && skip "no live credentials to verify"
  return 0
}

main() {
  # Strip our own flags before parse_common_args, which knows -q and not
  # these. --reprovision takes an optional id; bare means all.
  local mode=report want=all argv=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --verify) mode=verify; shift ;;
      --reprovision)
        mode=reprovision; shift
        case "${1:-}" in -*|"") ;; *) want="$1"; shift ;; esac ;;
      *) argv+=("$1"); shift ;;
    esac
  done
  set -- ${argv+"${argv[@]}"}

  if [ "$mode" = reprovision ]; then
    say "senechal: how to reissue a registered credential"
    reprovision_runbook "$want"
    return $?
  fi

  parse_common_args "$@"

  if [ "$mode" = verify ]; then
    _emit "senechal credential VALIDITY -- $(date '+%Y-%m-%d %H:%M') on $THIS_HOST"
    _emit "(opt-in: these commands touch the network; the hourly check does not run them)"
    verify_credentials
    finish_verify "OK -- every registered credential that can be verified, works."
    return $?
  fi

  _emit "senechal credential inventory -- $(date '+%Y-%m-%d %H:%M') on $THIS_HOST"
  _load_garde_sets
  [ "$GARDE_READABLE" -eq 1 ] \
    || note "gardien set list unreadable -- plaintext-egress checks will report could-not-look, not pass"
  check_secrets
  finish_verify "OK -- every registered credential is present, no wider than declared, and where it is allowed to be."
}
main "$@"
