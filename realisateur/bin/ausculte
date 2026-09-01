#!/usr/bin/env bash
# ausculte.sh -- can Zach stop looking? Composed from probes that already exist.
# KIND: verb
# THE HUMAN CHANNEL IS FIRST: every other failure reaches Zach through zaxon,
# so a green report with zaxon down reaches nobody. BLIND never folds into OK.
set -uo pipefail

CLI_NAME='ausculte.sh'
CLI_SUMMARY='is self-dev healthy enough to stop watching?'
CLI_USAGE='  ausculte              every probe; the exit code is the answer
  ausculte --json       one object per probe
  ausculte <probe>      just one: channel hosts arming hygiene propagation
                        rot fleet handoff'
CLI_FLAGS='--json'
CLI_POSITIONAL=any
CLI_EXITS='  0  every declared probe answered OK
  5  something declared is DOWN (the report names it)
  6  BLIND: at least one probe could not look, and none was DOWN'
# readlink -f: a verb is a symlink; without this the guard silently misses.
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/cli-guard.sh"
cli_guard "$@"

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# part <name> -- first path that exists: beside this file, libexec, or PATH.
part() {
  local n="$1" p
  for p in "$HERE/$n" "${SELFDEV_LIBEXEC:-/usr/local/libexec/selfdev}/$n" \
           "$HERE/${n%.sh}" "$(command -v "${n%.sh}" 2>/dev/null || true)"; do
    [ -n "$p" ] && [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}
. "$HERE/lib/host-check.sh"
. "$HERE/lib/estate-set.sh"
JSON=0; ONLY=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    -*) printf '%s: unknown flag: %s\n' "$CLI_NAME" "$1" >&2; exit 2 ;;
    *)  ONLY+=("$1") ;;
  esac; shift
done

_monkey_status=''; _monkey_status_fetched=0
fetch_monkey_status() {  # one curl per run for monkey/status.json -- hosts and arming both want it, and two fetches could disagree with each other about the same fact
  [ "$_monkey_status_fetched" = 1 ] && return 0
  _monkey_status_fetched=1
  _monkey_status="$(curl -s -m 20 "${MONKEY_STATUS_URL:-https://$GH_ESTATE_SITE/monkey/status.json}" 2>/dev/null)"
}

down=0; blind=0; rows=()
# FOUR STATES, NOT THREE (2026-08-22). OK / DOWN / BLIND could not express
# "this host must not answer that question", so containment showed up as
# failure: monkey is a VM GUEST on dexter, and a guest holding shell on its own
# hypervisor is backwards. Without a fourth word the only honest readings left
# were BLIND forever -- an alarm that can never clear, which trains its reader
# to ignore the row and then the verb.
#
#   OK        it serves what it declares
#   DOWN      it does not                       -> exit 5
#   BLIND     I could not look                  -> exit 6
#   NOT-MINE  I must not look, from here        -> neither
#
# NOT-MINE IS NOT A QUIET BLIND. It says the question has an owner and this is
# not it, and it names who. dexter is watched from dexter by monkey-watch.sh,
# which publishes where monkey cannot suppress it -- that is the answer, and it
# is a better one than a guest reaching across the boundary to ask.
record() {
  rows+=("$1|$2|$3")
  case "$2" in DOWN) down=1 ;; BLIND) blind=1 ;; esac
}

# not_mine <probe> <who owns it> -- record the boundary, and never the alarm.
not_mine() { record "$1" NOT-MINE "$2"; }
want() {
  [ ${#ONLY[@]} -eq 0 ] && return 0
  local p; for p in "${ONLY[@]}"; do [ "$p" = "$1" ] && return 0; done
  return 1
}

if want channel; then
  . "$HERE/lib/zaxon.sh"
  ep="$(zaxon_probe ausculte)" || ep=''
  if [ -n "$ep" ]; then record channel OK "zaxon answers at $ep"
  else record channel DOWN 'no zaxon relay answered -- questions cannot reach Zach'; fi
fi

if want hosts; then
  # A CONTAINED GUEST DOES NOT AUDIT ITS OWN HYPERVISOR. dexter-liveness.sh
  # ssh's to dexter; monkey is a VirtualBox guest ON dexter and root there
  # holds an empty authorized_keys with no config, key or known_hosts -- so
  # from here this row could only ever read BLIND. The question is answered
  # where it belongs: monkey-watch.sh runs ON dexter every ten minutes and
  # publishes, precisely so the report survives monkey being down.
  if on_target_host monkey; then
    not_mine hosts 'dexter is watched from dexter by monkey-watch.sh; a guest must not hold shell on its host'
  elif dl="$(part dexter-liveness.sh)"; then
    out="$(bash "$dl" 2>&1)"; rc=$?
    case $rc in
      0) record hosts OK 'dexter serves what it declares' ;;
      6) record hosts BLIND 'cannot reach dexter' ;;
      *) record hosts DOWN "$(printf '%s' "$out" | grep -iE 'down|missing|not running' | head -1)" ;;
    esac
  else
    fetch_monkey_status  # not present does not mean BLIND (#735): monkey-watch.sh already publishes this exact verdict from dexter every 10 minutes
    wv="$(printf '%s' "$_monkey_status" | jq -r '.watcher.verdict // empty' 2>/dev/null)"
    wvu="$(printf '%s' "$_monkey_status" | jq -r '.watcher.valid_until // empty' 2>/dev/null)"
    why="$(printf '%s' "$_monkey_status" | jq -r '.watcher.why // empty' 2>/dev/null)"
    if [ -z "$wv" ]; then
      record hosts BLIND 'dexter-liveness.sh not present, and the published monkey-watch status could not be read'
    elif [ -n "$wvu" ] && [ "$(date -u +%s)" -gt "$(date -u -d "$wvu" +%s 2>/dev/null || echo 0)" ]; then
      record hosts BLIND "the published monkey-watch status expired at $wvu -- nothing is publishing it"
    elif [ "$wv" = OK ]; then
      record hosts OK 'monkey-watch (dexter) reports dexter serves what it declares'
    else
      record hosts DOWN "${why:-monkey-watch (dexter) reports $wv}"
    fi
  fi
fi

if want arming; then
  # WHAT THE ACCOUNTS ARE DOING, not how often the word "armed" appears.
  fetch_monkey_status; st="$_monkey_status"
  vu="$(printf '%s' "$st" | jq -r '.watcher.valid_until // .valid_until // empty' 2>/dev/null)"
  if ! printf '%s' "$st" | jq -e '.accounts' >/dev/null 2>&1; then
    record arming BLIND 'the published monkey status could not be read'
  elif [ -n "$vu" ] && [ "$(date -u +%s)" -gt "$(date -u -d "$vu" +%s 2>/dev/null || echo 0)" ]; then
    # A document past the freshness it declares for itself is not evidence.
    record arming BLIND "the published monkey status expired at $vu -- nothing is publishing it"
  elif [ "$(printf '%s' "$st" | jq -r '.accounts | length' 2>/dev/null)" = 0 ]; then
    record arming BLIND "the published monkey status lists no accounts: $(printf '%s' "$st" | jq -r '.watcher.accounts_from // .accounts_from // "no reason given"' 2>/dev/null)"
  else
    # TRAP: fromdateiso8601 rejects a "+00:00" offset and takes only "Z", so
    # the timestamps make jq exit mid-stream and this row printed OK off an
    # empty result. A jq failure is BLIND, never clean.
    if ! stale="$(printf '%s' "$st" | jq -er --argjson d "${ARMING_STALE_DAYS:-3}" '
      (now - ($d * 86400)) as $cut
      | [ .accounts[]
          | select(.armed)
          | select(.last_run.started_at != null)
          | select(((.last_run.started_at | sub("\\+00:00$"; "Z") | fromdateiso8601)) < $cut)
          | .account ] | join(" ")' 2>/dev/null)"; then
      record arming BLIND 'the status document could not be graded (unreadable timestamps)'
      stale=SKIP
    fi
    # NO RECORD IS NOT NO DISPATCH (hf7y/scheduler#259).
    norec="$(printf '%s' "$st" | jq -r '[.accounts[]|select(.armed)|select(.last_run.started_at == null)|.account]|join(" ")' 2>/dev/null)"
    n_armed="$(printf '%s' "$st" | jq -r '[.accounts[]|select(.armed)]|length')"
    gen="$(printf '%s' "$st" | jq -r '.generated')"
    if [ "$stale" = SKIP ]; then :
    elif [ -n "$stale" ]; then
      record arming DOWN "armed but not dispatching for ${ARMING_STALE_DAYS:-3}d: $stale (status generated $gen)"
    elif [ -n "$norec" ]; then
      # The document omits their last_run; their ledgers are on the host.
      lr="$(${AUSCULTE_SSH:-ssh} -o ConnectTimeout=10 -o BatchMode=yes "${AUSCULTE_FLEET_HOST:-monkey}" "
        sudo -n true 2>/dev/null && SU='sudo -n' || SU=''
        for a in $norec; do
          f=/home/\$a/.local/share/scheduler-paced-runner/ledger.tsv
          \$SU test -r \"\$f\" && printf '%s %s\n' \"\$a\" \"\$(\$SU tail -1 \"\$f\" | cut -f1)\"
        done" 2>/dev/null)"
      if [ -n "$lr" ]; then
        record arming DOWN "published status omits last_run for: $norec (hf7y/scheduler#259) -- their own ledgers say: $(printf '%s' "$lr" | tr '\n' ' ')"
      else
        record arming BLIND "no run record published for: $norec -- cannot tell whether they dispatched (hf7y/scheduler#259)"
      fi
    else
      record arming OK "$n_armed account(s) armed, each dispatched within ${ARMING_STALE_DAYS:-3}d"
    fi
  fi
fi

if want hygiene; then  # THE QUESTION'S OWNER, NOT ECOSIM'S CI (#706): hf7y/ecosim#91 refused a CI grant onto 0700 self-dev homes for "is any account holding something it shouldn't" -- a host fact about monkey, read where host facts about monkey already get read. monkey-status-collect.py (schema 2) already publishes containment and credentials per account; this probe only grades what it already collects.
  st="$(curl -s -m 20 "${MONKEY_STATUS_URL:-https://$GH_ESTATE_SITE/monkey/status.json}" 2>/dev/null)"
  if ! printf '%s' "$st" | jq -e '.accounts' >/dev/null 2>&1; then
    record hygiene BLIND 'the published monkey status could not be read'
  elif [ "$(printf '%s' "$st" | jq -r '.schema // 0')" -lt 2 ] 2>/dev/null; then
    record hygiene BLIND "monkey status schema $(printf '%s' "$st" | jq -r '.schema') publishes no containment/credentials field"
  else
    unreadable="$(printf '%s' "$st" | jq -r '.accounts[] | select(.containment == null) | .account' | tr '\n' ' ')"
    contained="$(printf '%s' "$st" | jq -r '
      .accounts[]
      | select(.containment != null)
      | select((.containment.foreign_clones|length)>0 or (.containment.outside_home|length)>0 or (.containment.sudoers|length)>0)
      | .account' | tr '\n' ' ')"
    shapes="$(printf '%s' "$st" | jq -r '[.accounts[].credentials | tostring] | unique | length')"  # UNIFORMITY, NOT AN ABSOLUTE BAR: this repo does not invent what mode a credential file "should" be -- only whether every account got the SAME treatment (ecosim#91's row_creds, ported as-is).
    if [ -n "$contained" ]; then
      record hygiene DOWN "holding something it should not: $contained${unreadable:+; unreadable: $unreadable}"
    elif [ "${shapes:-0}" -gt 1 ]; then
      record hygiene DOWN "$shapes distinct credential permission shapes across accounts -- not every account got the same treatment${unreadable:+; unreadable: $unreadable}"
    elif [ -n "$unreadable" ]; then
      record hygiene BLIND "containment unreadable for: $unreadable"
    else
      n="$(printf '%s' "$st" | jq -r '.accounts | length')"
      record hygiene OK "$n account(s): no foreign clone, no file outside home, no sudoers.d entry, one shared credential shape"
    fi
  fi
fi

if want propagation; then
  # THE CHANNEL'S OWN VERDICT FIRST: counting verbs answers "is something
  # installed", not "is the channel running", and said OK through an outage.
  ps=""
  for cand in "$HERE/lib/propagation-set.sh" \
              "${SELFDEV_LIBEXEC:-/usr/local/libexec/selfdev}/lib/propagation-set.sh"; do
    [ -r "$cand" ] && { ps="$cand"; break; }
  done
  # shellcheck source=lib/propagation-set.sh
  [ -n "$ps" ] && . "$ps"
  v="$(curl -s -m 15 "${VERBS_STATUS_URL:-https://$GH_ESTATE_SITE/verbs/status.json}" 2>/dev/null)"
  dec="$(printf '%s' "$v" | jq -r '.decision // empty' 2>/dev/null)"
  if [ -z "$dec" ]; then
    record propagation BLIND 'cannot read the release channel verdict'
  else
    cut_at="$(printf '%s' "$v" | jq -r '.last_cut.at // empty' 2>/dev/null)"
    streak="$(printf '%s' "$v" | jq -r '.blocked_streak // 0' 2>/dev/null)"
    # TWO NUMBERS, NOT ONE (realisateur#603). They answer different questions
    # and under a monthly cut they differ by 29 days:
    #   max_h      the ADOPTION window -- how long a host may lag a cut it has
    #              been told about. Keyed to the emitter's cadence, which stays
    #              nightly, so this is unchanged at 28h.
    #   cut_max_h  the BUILD-AGE floor -- how old the newest build may be
    #              before the cutter is presumed dead. Keyed to the cut
    #              interval the channel publishes, plus one adoption window.
    # Conflating them graded a healthy 20-day-old monthly build as DOWN on 29
    # nights in 30, and -- because line :183 below returns first -- meant the
    # adoption branch at the bottom of this block could never be reached.
    max_h=$(( $(printf '%s' "$v" | jq -r '.cadence_hours // 24') + $(printf '%s' "$v" | jq -r '.grace_hours // 4') ))
    # A document that declares no interval is a NIGHTLY one: defaulting to 0
    # makes cut_max_h == max_h, i.e. exactly the pre-#603 grade. A schema-2
    # verdict therefore reads identically after this change, which is what
    # lets the publisher and the consumers move on different nights.
    cut_max_h=$(( $(printf '%s' "$v" | jq -r '.cut_interval_days // 0') * 24 + max_h ))
    age_h=-1
    if [ -n "$cut_at" ]; then
      cut_epoch="$(date -u -d "$cut_at" +%s 2>/dev/null)" \
        && age_h=$(( ( $(date -u +%s) - cut_epoch ) / 3600 ))
    fi
    # NO_CHANGE IS A HEALTHY NIGHT -- gate green, nothing moved, today's build
    # still current. 5 of the last 54 read as an outage. BLOCKED/ERROR remain.
    if [ "$dec" != CUT ] && [ "$dec" != NO_CHANGE ]; then
      record propagation DOWN "the channel is $dec ($streak run(s) running); nothing has propagated since $cut_at"
    elif [ "$age_h" -lt 0 ]; then
      record propagation BLIND 'the verdict names no last cut this could age'
    elif [ "$age_h" -gt "$cut_max_h" ]; then
      record propagation DOWN "the newest build is ${age_h}h old, past the ${cut_max_h}h its cut interval allows -- the cutter has stopped"
    else
      # Only with the channel proven live does what is installed mean
      # anything: a host behind the pin did not adopt.
      # Graded against the row the AGE came from: "-" names no build.
      bid="$(printf '%s' "$v" | jq -r '.last_cut.build_id // .build_id // empty' 2>/dev/null)"
      [ "$bid" = "-" ] && bid=""
      if [ -z "${PROP_HOST_PIN:-}" ]; then
        record propagation BLIND 'no propagation-set.sh reachable, so the host pin path is unknown'
        bid=""
      fi
      # A GUEST DOES NOT SSH ITS OWN HYPERVISOR, so on monkey the dexter half
      # of this question is not ours to ask -- it could only read "unreachable"
      # and take the whole row BLIND with it. Recorded, not silently dropped:
      # a host omitted without saying so is how a partial answer reads as a
      # complete one.
      bad=''; unreachable=''; skipped=''
      _hosts=(monkey "-p 2223 dexter")
      on_target_host monkey && { _hosts=(monkey); skipped=' dexter'; }
      for h in "${_hosts[@]}"; do
        # LOCALHOST IS NOT AN SSH TARGET: the row read "monkey:unreachable"
        # about the host it was standing on.
        if on_target_host "${h##* }"; then
          n="$(readlink "$PROP_HOST_PIN" 2>/dev/null)"
        else
          # shellcheck disable=SC2086
          n="$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes $h "readlink $PROP_HOST_PIN" 2>/dev/null)"
        fi
        [ -n "$n" ] || { unreachable="$unreachable ${h##* }"; continue; }
        [ "$(basename "$n")" = "$bid" ] || bad="$bad ${h##* }:$(basename "$n")"
      done
      # A DAILY CONSUMER IS LEGITIMATELY BEHIND A FRESH CUT: exact equality
      # made this DOWN daily between the cut and dexter's 05:49 tick. Lagging
      # is DOWN only past the cadence+grace the channel grades ITSELF by.
      # The skipped host is named in every verdict below, so "every host is on
      # it" can never quietly mean "every host I was allowed to ask".
      _sk=""; [ -z "$skipped" ] || _sk=" (not asked from here:$skipped -- see monkey-watch on dexter)"
      if [ -z "$bid" ]; then :
      elif [ -n "$unreachable" ]; then
        record propagation BLIND "channel cut $bid ${age_h}h ago; could not read:$unreachable$_sk"
      elif [ -n "$bad" ] && [ "$age_h" -gt "$max_h" ]; then
        record propagation DOWN "channel cut $bid ${age_h}h ago, past the ${max_h}h adoption window; behind:$bad$_sk"
      elif [ -n "$bad" ]; then
        record propagation OK "channel cut $bid ${age_h}h ago; not yet adopted by:$bad (within the ${max_h}h window)$_sk"
      else record propagation OK "channel cut $bid ${age_h}h ago; every host is on it$_sk"; fi
    fi
  fi
fi

if want handoff; then
  # A HANDOFF THAT NEVER COMPLETES IS INVISIBLE. The senechal block moved on
  # 2026-08-22 and the deletion owed here was still outstanding four days
  # later, because "delete once it merges" lived in an issue body and nothing
  # read it on a clock. reprise reads bin/lib/handoffs.tsv instead.
  if rp="$(part reprise.sh)"; then
    out="$(bash "$rp" --check 2>&1)"; rc=$?
    case $rc in
      0) if printf '%s' "$out" | grep -q 'collectable'; then
           record handoff OK "$(printf '%s' "$out" | grep -E '^reprise: [0-9]+ row' | tail -1)"
         else record handoff OK 'no handoffs outstanding'; fi ;;
      1) record handoff DOWN "$(printf '%s' "$out" | grep -E 'MERGED but' | head -1)" ;;
      2) record handoff BLIND 'ausculte invoked reprise wrongly -- fix ausculte' ;;
      *) record handoff BLIND "$(printf '%s' "$out" | tail -1)" ;;
    esac
  # NOT-MINE, not BLIND: reprise is LOCAL to realisateur and the table it reads
  # is realisateur's. On any other account this row would otherwise be an alarm
  # that can never clear -- the exact failure the fourth state exists for.
  else not_mine handoff 'realisateur -- handoffs.tsv is its table'; fi
fi

if want rot; then
  if dr="$(part decision-rot.sh)"; then
    out="$(bash "$dr" --all 2>&1)"; rc=$?
      case $rc in
      0) nm="$(printf '%s\n' "$out" | awk '$1 == "TOTAL" { print $4 }')"
         if [ "${nm:-0}" -gt 0 ] 2>/dev/null; then
           # Never silently: 30 real rows would otherwise vanish here.
           record rot OK "no answered decision open where anything dispatches ($nm NOT-MINE -- nothing is armed to act)"
         else record rot OK 'no answered-and-abandoned issues'; fi ;;
      # A COUNT AND THE OLDEST ROW, NOT `tail -1`: the block is sorted
      # oldest-first, so tail named the NEWEST and hid the rest (#661).
      1) n="$(printf '%s\n' "$out" | awk '$1 == "TOTAL" { print $3 }')"
         oldest="$(printf '%s\n' "$out" \
                    | awk '/^ROTTING/ { f = 1; next } f && NF { sub(/^ +/, ""); print; exit }')"
         if [ -n "$n" ] && [ -n "$oldest" ]; then
           record rot DOWN "$n answered decision(s) still open across the roster; oldest: $oldest"
         else record rot DOWN "$(printf '%s' "$out" | tail -1)"; fi ;;
      2) record rot BLIND 'ausculte invoked decision-rot.sh wrongly -- fix ausculte' ;;
      *) record rot BLIND "$(printf '%s' "$out" | tail -1)" ;;
    esac
  else record rot BLIND 'decision-rot.sh not present'; fi
fi


if want fleet; then
  # LOCALHOST IS NOT AN SSH TARGET -- the same fix the propagation row above
  # already carries. This probe ssh'd to ${AUSCULTE_FLEET_HOST:-monkey}
  # unconditionally, including FROM monkey, where the ledgers actually live.
  # root there has an EMPTY authorized_keys and no config, key or known_hosts,
  # so `ssh monkey` from monkey fails host key verification and the row read
  # BLIND on the one machine that could have answered it by reading a file.
  # The cadence runs as root on monkey, so that was every scheduled reading.
  _fleet_probe='
    sudo -n true 2>/dev/null && SU="sudo -n" || SU=""   # homes are 0700
    n=0
    for f in $($SU sh -c "ls /home/*/.local/share/scheduler-paced-runner/ledger.tsv 2>/dev/null"); do
      $SU test -r "$f" || continue
      n=$((n + 1))
      $SU tail -1 "$f"
    done
    # PRESENCE is the signal; the runner clears these on recovery.
    for d in $($SU sh -c "ls -d /home/*/.local/share/scheduler-paced-runner 2>/dev/null"); do
      a=${d#/home/}; a=${a%%/*}
      $SU test -r "$d/gate-error-streak.state" &&
        echo "FLEET-GATE-ERR $a $($SU cat "$d/gate-error-streak.state")"
      $SU test -r "$d/pull-block.state" &&
        echo "FLEET-PULL $a $($SU cat "$d/pull-block.state")"
    done
    echo "FLEET-LEDGERS $n"'
  if on_target_host "${AUSCULTE_FLEET_HOST:-monkey}"; then
    led="$(bash -c "$_fleet_probe" 2>/dev/null)"
  else
    led="$(${AUSCULTE_SSH:-ssh} -o ConnectTimeout=10 -o BatchMode=yes "${AUSCULTE_FLEET_HOST:-monkey}" "$_fleet_probe" 2>/dev/null)"
  fi
  case "$led" in
    *FLEET-LEDGERS*)
      n_led="$(printf '%s\n' "$led" | sed -n 's/^FLEET-LEDGERS //p')"
      gate_err="$(printf '%s\n' "$led" | awk '$1=="FLEET-GATE-ERR" && $3+0 >= 2 {print $2"("$3")"}' | tr '\n' ' ')"
      # ANY cause, and >=2 not 3: the escalation dies before writing back.
      frozen="$(printf '%s\n' "$led" | awk '$1=="FLEET-PULL" && $3+0 >= 2 {print $2"("$3" "$4")"}' | tr '\n' ' ')"
      if [ -n "$gate_err" ]; then
        record fleet DOWN "the usage gate is ERRORing, not pacing: $gate_err consecutive failure(s) -- no account here is being held on purpose"
      elif [ -n "$frozen" ]; then
        record fleet DOWN "deployed code is FROZEN, so a merged fix cannot land: $frozen blocked tick(s)"
      elif [ "${n_led:-0}" -eq 0 ]; then
        # Zero ledgers is not a quiet fleet, it is a fleet we cannot see.
        record fleet BLIND 'no account has a paced-runner ledger -- cannot tell whether any of them worked'
      else
        # DONE and COOLDOWN are both fine -- COOLDOWN is the pacer holding a
        # finished account back on purpose.
        #
        # AND SO IS NOT-DONE WITH A REASON, which this row called DOWN until
        # 2026-08-22. NOT-DONE is what the runner records for an agent verdict
        # of CONTINUE -- schedule/_verdict-semantics.md: "there is ACTIONABLE
        # work left". It is the HEALTHY STEADY STATE of an account with a
        # backlog. Measured that day: 9 of 14 accounts read NOT-DONE and SIX of
        # them had shipped a merged PR in that very run (ecosim #105,
        # scheduler #269, senechal #389, groc-mangr #49, realisateur #334,
        # bibliothecaire #57). The row said DOWN while the fleet worked.
        #
        # A monitor that reports DOWN in the normal case is one a human must
        # check by hand every time, which is the whole thing ausculte exists to
        # stop. So the finding is SILENCE, not incompleteness:
        #
        #   blank reason      the account stopped and said nothing (scheduler#261)
        #   no-verdict:       the runner ran it and no verdict was written
        #
        # Both mean the sensor got nothing. An account that explained itself is
        # answering; whether its answer is good news is its own tracker's
        # question, not this probe's.
        mute="$(printf '%s\n' "$led" | grep -v '^FLEET-LEDGERS' \
                 | awk -F'\t' '$7 == "NOT-DONE" {
                     r = $8; sub(/^[ \t]+/, "", r)
                     if (r == "")                 print $3": *** NO REASON RECORDED ***"
                     else if (r ~ /^no-verdict:/) print $3": "r }' || true)"
        working="$(printf '%s\n' "$led" | grep -v '^FLEET-LEDGERS' \
                 | awk -F'\t' '$7 == "NOT-DONE" {
                     r = $8; sub(/^[ \t]+/, "", r)
                     if (r != "" && r !~ /^no-verdict:/) print $3 }' || true)"
        n_mute="$(printf '%s' "$mute" | grep -c . || true)"
        n_work="$(printf '%s' "$working" | grep -c . || true)"
        if [ "${n_mute:-0}" -gt 0 ]; then
          record fleet DOWN "$n_mute of $n_led account(s) stopped without saying why: $(printf '%s' "$mute" | head -1 | cut -c1-90)"
        else
          record fleet OK "$n_led account(s) reported${n_work:+, $n_work still working}"
        fi
      fi ;;
    *) record fleet BLIND 'could not read the accounts paced-runner ledgers' ;;
  esac
fi


[ ${#rows[@]} -gt 0 ] || { printf '%s: no such probe: %s\n' "$CLI_NAME" "${ONLY[*]}" >&2; exit 2; }

if [ "$JSON" = 1 ]; then
  printf '['
  sep=''
  for r in "${rows[@]}"; do
    IFS='|' read -r p s d <<< "$r"
    printf '%s{"probe":"%s","status":"%s","detail":"%s"}' "$sep" "$p" "$s" "${d//\"/\\\"}"; sep=','
  done
  printf ']\n'
else
  for r in "${rows[@]}"; do
    IFS='|' read -r p s d <<< "$r"
    printf '  %-6s  %-12s %s\n' "$s" "$p" "$d"
  done
  echo
  if [ "$down" = 1 ]; then echo 'DOWN -- something declared is not serving. Named above.'
  elif [ "$blind" = 1 ]; then echo 'BLIND -- a probe could not look. This is NOT "all clear".'
  else echo 'OK -- every declared probe answered. You can stop looking.'; fi
fi

[ "$down" = 1 ] && exit 5
[ "$blind" = 1 ] && exit 6
exit 0
