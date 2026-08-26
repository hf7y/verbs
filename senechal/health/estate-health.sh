#!/usr/bin/env bash
# senechal: estate health check. Non-AI, cron-safe, read-only.
#
#   ./estate-health.sh          # full report
#   ./estate-health.sh -q       # silent unless something needs attention
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

DISK_WARN="$(cfg health.disk_warn_pct 85)"
DISK_FAIL="$(cfg health.disk_fail_pct 95)"
BATT_WARN="$(cfg health.battery_wear_warn_pct 75)"
TEMP_WARN="$(cfg health.temp_warn_c 85)"
BACKUP_UNIT="$(cfg health.backup_unit gardien.service)"
BACKUP_MAX_AGE_H="$(cfg health.backup_max_age_hours 36)"
UPDATES_WARN="$(cfg health.pending_updates_warn 40)"
SMART_DUMP="$(cfg health.smart_dump_file /var/lib/senechal/smart-health.txt)"
SMART_DUMP_MAX_AGE_H="$(cfg health.smart_dump_max_age_hours 48)"
REMOTE_SSH_TIMEOUT="$(cfg health.remote_ssh_timeout 6)"
NOTIFY_AUDIT_WARN="$(cfg health.notify_audit_warn_count 20)"
# Memory/swap. See the "memory pressure, as EVENTS" block in lib/common.sh
# for why every one of these is a change detector rather than a gauge.
SWAP_BANDS_DEFAULT='50
75
90'
SWAP_SUSTAINED_H="$(cfg health.swap_sustained_hours 24)"
OOM_LOOKBACK_H="$(cfg health.oom_lookback_hours 24)"
SQUAT_MIN_MB="$(cfg health.swap_squatter_min_mb 50)"
SQUAT_MIN_DAYS="$(cfg health.swap_squatter_min_idle_days 7)"
SQUAT_MAX_CPU_PCT="$(cfg health.swap_squatter_max_cpu_pct 1)"
MEM_CHECK_REMOTE="$(cfg health.memory_check_remote true)"
# Dedicated probe identity (see remedies/remote-health-keys.sh). Used
# only if the file exists; otherwise ssh's own config decides, so this
# stays optional rather than a hard dependency.
REMOTE_SSH_IDENTITY="$(cfg health.remote_ssh_identity "$HOME/.ssh/senechal-estate-ed25519")"
REMOTE_SSH_IDENTITY="${REMOTE_SSH_IDENTITY/#\~/$HOME}"

# --- reachability, every device in the registry -------------------------
check_reachability() {
  head_ "Reachability"
  local n k addr reach owner expect ssh_host os
  local found=0
  while IFS=$'\x1f' read -r n k addr reach owner expect ssh_host os; do
    [ -n "$n" ] || continue
    found=1
    case "$reach" in
      local)
        ok "$n ($k) -- this host, up $(uptime -p 2>/dev/null | sed 's/^up //')"
        ;;
      ssh|ping)
        if ping -c1 -W2 "$addr" >/dev/null 2>&1; then
          ok "$n ($k) reachable at $addr"
        else
          # Severity depends on the device's declared expectation
          # (estate.devices[].expect in senechal.json): a dark always-on
          # box is broken, a dark laptop is Tuesday, and a device with no
          # declaration stays a WARN so the gap itself is visible.
          case "$expect" in
            always-on)
              fail "$n ($k) not answering at $addr -- declared always-on, so this is an outage. Owner: $owner"
              ;;
            intermittent)
              ok "$n ($k) not answering at $addr -- declared intermittent (laptop/installation), off is normal"
              ;;
            "")
              warn_ "$n ($k) not answering at $addr -- powered off, or gone (no expect declared). Owner: $owner"
              ;;
            *)
              warn_ "$n ($k) not answering at $addr -- and its expect value \"$expect\" is not always-on/intermittent, fix it in senechal.json. Owner: $owner"
              ;;
          esac
        fi
        ;;
      *)
        skip "$n ($k) -- no reach method defined (reach=\"$reach\")"
        ;;
    esac
  done <<< "$(cfg_devices)"
  [ "$found" -eq 1 ] || skip "no devices in senechal.json estate.devices"
}

# --- remote host health, over SSH ---------------------------------------
# Every reach=ssh device in the registry gets one SSH round-trip emitting
# prefixed lines (disk/temp/failedunit) parsed against the same thresholds
# as mandark's own checks -- one config source, not per-host copies.
#   [rest: vault:senechal/header-archaeology-20260818.md]

# read -d '' returns nonzero at EOF by design; the || true keeps set -u
# pipelines honest without masking anything else.
read -r -d '' _LINUX_PROBE <<'PROBE' || true
echo SENECHAL-RHC-1
df -P -h 2>/dev/null | awk '$1 ~ /^\/dev\// {gsub(/%/,"",$5); print "disk", $6, $5, $4}'
for z in /sys/class/thermal/thermal_zone*/temp; do
  [ -r "$z" ] && printf 'temp %s\n' "$(cat "$z" 2>/dev/null)"
done
systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk 'NF {print "failedunit", $1}'
PROBE

# The memory half of the Linux probe, built separately because the OOM
# lookback is configuration and the probe above is a fixed heredoc.
# Swap + OOM DO run remotely; the squatter scan does NOT -- it walks
# every /proc/<pid>/status on the host, and potato has ~905MB of RAM
# (crt/POTATO.md), so the cheap two-thirds run everywhere and the
# expensive third stays local. That limit is printed rather than left to
# be inferred from a PASS.
_mem_remote_probe() {
  cat <<EOF
awk '/^SwapTotal:|^SwapFree:/ {print "swapkb", \$1, \$2}' /proc/meminfo
if journalctl -k -n1 --no-pager >/dev/null 2>&1 && [ -n "\$(journalctl -k -n1 --no-pager 2>/dev/null)" ]; then
  echo oomok
  journalctl -k -o short-iso --since "-${OOM_LOOKBACK_H}h" --no-pager 2>/dev/null \
    | grep -F 'Out of memory: Killed process' | sed 's/^/oomline /'
else
  echo oomdenied
fi
EOF
}

read -r -d '' _WINDOWS_PROBE <<'PROBE' || true
Write-Output 'SENECHAL-RHC-1'
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
  if ($_.Size -gt 0) {
    $pct = [math]::Round((($_.Size - $_.FreeSpace) * 100) / $_.Size)
    $freeg = [math]::Round($_.FreeSpace / 1GB, 1)
    Write-Output ("disk {0} {1} {2}G" -f $_.DeviceID, $pct, $freeg)
  }
}
PROBE

# Shared gate: is the device even up, and did ssh give us a probe result?
# Prints nothing; echoes probe output on success. Callers branch on rc:
# 0 = probe output in hand, 1 = down-and-that's-normal (already reported),
# 2 = could not check (skip already emitted).
_remote_probe_output=""
_remote_probe() {
  local n="$1" host="$2" expect="$3" addr="$4"; shift 4
  _remote_probe_output=""
  if ! ping -c1 -W2 "$addr" >/dev/null 2>&1; then
    if [ "$expect" = "intermittent" ]; then
      ok "$n is off (declared intermittent) -- remote checks not applicable while off"
      return 1
    fi
    skip "$n is not answering at $addr -- see Reachability above for severity"
    return 2
  fi
  local out rc
  local -a sshopts=(-o BatchMode=yes -o ConnectTimeout="$REMOTE_SSH_TIMEOUT")
  [ -f "$REMOTE_SSH_IDENTITY" ] && sshopts+=(-i "$REMOTE_SSH_IDENTITY" -o IdentitiesOnly=yes)
  out="$(ssh "${sshopts[@]}" "$host" "$@" 2>&1)"
  rc=$?
  out="${out//$'\r'/}"
  if [ "$rc" -ne 0 ] || ! grep -q '^SENECHAL-RHC-1$' <<< "$out"; then
    # Say which failure this is. rc=255 is ssh itself (auth/transport); any
    # other non-zero rc came FROM the remote shell, which means the login
    # worked and the probe did not -- blaming key auth there sends you to
    # fix a thing that is already fine. Found 2026-08-05 on dexter: os was
    # declared "windows", so it got the powershell probe, but `ssh dexter`
    # lands in WSL2 where `powershell` is not on PATH -- rc=127, reported
    # for weeks as "key auth may be missing" while key auth worked.
    local why
    case "$rc" in
      255) why="ssh itself failed -- key auth for BatchMode ssh to \"$host\" may be missing" ;;
      127) why="logged in fine, but the probe command does not exist on $n -- check the \"os\" declared for it in senechal.json" ;;
      0)   why="logged in and ran, but the reply carried no SENECHAL-RHC-1 marker -- probe output is not what this parser expects" ;;
      *)   why="the probe ran on $n and exited $rc -- this is the remote command failing, not ssh" ;;
    esac
    skip "$n is up but the ssh probe failed (rc=$rc) -- $why"
    note "last line: $(tail -n1 <<< "$out")"
    return 2
  fi
  _remote_probe_output="$out"
  return 0
}

# Parse the probe's prefixed lines against the shared thresholds.
# $2 restricts which line kinds this host's probe can produce, so a
# Windows host missing temp lines doesn't read as "no thermal data".
_remote_report() {
  local n="$1" owner="$2" kinds="$3"
  local tag a b c disks=0 maxt=0 units=0
  local swaptot="" swapfree="" oomstate="" oomtext=""
  while read -r tag a b c; do
    case "$tag" in
      swapkb)
        case "$a" in
          SwapTotal:) swaptot="$b" ;;
          SwapFree:)  swapfree="$b" ;;
        esac
        ;;
      oomok)     oomstate=ok ;;
      oomdenied) oomstate=denied ;;
      oomline)   oomtext+="$a $b $c"$'\n' ;;
      disk)
        case "$b" in ''|*[!0-9]*) continue ;; esac
        disks=$((disks + 1))
        if [ "$b" -ge "$DISK_FAIL" ]; then
          fail "$n: $a at ${b}% (>= ${DISK_FAIL}% fail threshold), $c free. Owner: $owner"
        elif [ "$b" -ge "$DISK_WARN" ]; then
          warn_ "$n: $a at ${b}% (>= ${DISK_WARN}% warn threshold), $c free"
        else
          ok "$n: $a at ${b}%, $c free"
        fi
        ;;
      temp)
        case "$a" in ''|*[!0-9]*) continue ;; esac
        a=$(( a / 1000 ))
        [ "$a" -gt "$maxt" ] && maxt=$a
        ;;
      failedunit)
        units=$((units + 1))
        fail "$n: systemd unit failed: $a  (ssh in and check journalctl -u $a). Owner: $owner"
        ;;
    esac
  done <<< "$_remote_probe_output"

  [ "$disks" -gt 0 ] || skip "$n: probe returned no disk data"
  case "$kinds" in
    *temp*)
      if [ "$maxt" -gt 0 ]; then
        if [ "$maxt" -ge "$TEMP_WARN" ]; then
          warn_ "$n: hottest zone at ${maxt}C (>= ${TEMP_WARN}C) -- likely throttling"
        else
          ok "$n: hottest zone at ${maxt}C"
        fi
      else
        skip "$n: no readable thermal zones over ssh"
      fi
      ;;
  esac
  case "$kinds" in
    *units*) [ "$units" -gt 0 ] || ok "$n: no failed systemd units" ;;
  esac
  case "$kinds" in
    *mem*)
      _mem_report_swap "$n" "$swaptot" "$swapfree"
      case "$oomstate" in
        ok)     _mem_report_oom "$n" "$oomtext" ;;
        denied) skip "$n: kernel journal not readable over ssh as the probe user -- OOM kills on that host are invisible" ;;
        *)      skip "$n: probe returned no OOM section -- cannot say whether that host has been OOM-killing" ;;
      esac
      note "$n: swap band + OOM only -- the idle-swap-squatter scan is local-only (it walks every /proc/<pid>/status)"
      ;;
  esac
}

check_remote_health() {
  head_ "Remote host health (over SSH)"
  local n k addr reach owner expect ssh_host os
  local found=0 enc probe kinds
  while IFS=$'\x1f' read -r n k addr reach owner expect ssh_host os; do
    [ -n "$n" ] || continue
    [ "$reach" = "ssh" ] || continue
    found=1
    if [ -z "$ssh_host" ]; then
      skip "$n -- reach is ssh but no ssh_host declared in senechal.json"
      continue
    fi
    case "$os" in
      linux)
        probe="$_LINUX_PROBE"
        kinds="disk temp units"
        if [ "$MEM_CHECK_REMOTE" = true ]; then
          probe="$probe"$'\n'"$(_mem_remote_probe)"
          kinds="$kinds mem"
        fi
        if _remote_probe "$n" "$ssh_host" "$expect" "$addr" sh -s <<< "$probe"; then
          _remote_report "$n" "$owner" "$kinds"
        fi
        ;;
      windows)
        if ! command -v iconv >/dev/null 2>&1; then
          skip "$n -- iconv not available to encode the PowerShell probe"
          continue
        fi
        enc="$(printf '%s' "$_WINDOWS_PROBE" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
        # </dev/null: ssh inherits the device-list herestring as stdin
        # here and would silently eat the rest of the loop without it.
        if _remote_probe "$n" "$ssh_host" "$expect" "$addr" \
             powershell -NoProfile -NonInteractive -EncodedCommand "$enc" \
             < /dev/null; then
          _remote_report "$n" "$owner" "disk"
          note "$n: disk only -- temp/service checks not implemented for windows hosts"
        fi
        ;;
      "")
        skip "$n -- no \"os\" declared in its estate entry (add os: linux|windows in senechal.json)"
        ;;
      *)
        skip "$n -- os \"$os\" has no remote probe (linux|windows); fix it in senechal.json"
        ;;
    esac
  done <<< "$(cfg_devices)"
  [ "$found" -eq 1 ] || skip "no reach=ssh devices in senechal.json estate.devices"
}

# --- disks, this host ---------------------------------------------------
check_disks() {
  head_ "Disk space (mandark)"
  local line target pcent avail n
  while read -r target pcent avail; do
    [ "$target" = "Mounted" ] && continue
    n="${pcent%\%}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    if [ "$n" -ge "$DISK_FAIL" ]; then
      fail "$target at ${n}% (>= ${DISK_FAIL}% fail threshold), $avail free"
    elif [ "$n" -ge "$DISK_WARN" ]; then
      warn_ "$target at ${n}% (>= ${DISK_WARN}% warn threshold), $avail free"
    else
      ok "$target at ${n}%, $avail free"
    fi
  done <<< "$(df -h --output=target,pcent,avail -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | grep -vE '^/(sys|run|dev)')"
}

# --- SMART --------------------------------------------------------------
# Preferred source: the root-timer dump written by
# remedies/smart-health.sh (smartctl needs root; the dump doesn't). Falls
# back to direct smartctl -- which SKIPs without root -- when the dump is
# absent or stale, so a dead timer degrades to could-not-check, never to
# a silent pass on old data.
check_smart() {
  head_ "Drive SMART health"
  local dev ts now age_h
  if [ -r "$SMART_DUMP" ]; then
    ts="$(stat -c %Y "$SMART_DUMP" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    age_h=$(( (now - ts) / 3600 ))
    if [ "$ts" -gt 0 ] && [ "$age_h" -le "$SMART_DUMP_MAX_AGE_H" ]; then
      local verdict any=0
      while read -r dev verdict; do
        case "$dev" in ''|\#*) continue ;; esac
        any=1
        case "$verdict" in
          PASSED) ok "/dev/$dev SMART self-assessment PASSED (root dump, ${age_h}h old)" ;;
          FAILED) fail "/dev/$dev SMART FAILING -- back up now and replace the drive" ;;
          *)      skip "/dev/$dev -- dump could not interpret smartctl output" ;;
        esac
      done < "$SMART_DUMP"
      # A drive attached after the last dump isn't covered by it yet.
      while read -r dev; do
        [ -n "$dev" ] || continue
        grep -q "^$dev " "$SMART_DUMP" \
          || skip "/dev/$dev present but not in the SMART dump yet -- covered after the next senechal-smart.timer run"
      done <<< "$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')"
      [ "$any" -eq 1 ] || skip "SMART dump $SMART_DUMP contains no disks"
      return
    fi
    note "SMART dump $SMART_DUMP is ${age_h}h old (> ${SMART_DUMP_MAX_AGE_H}h) -- senechal-smart.timer may be dead; trying smartctl directly"
  fi
  if ! command -v smartctl >/dev/null 2>&1; then
    skip "smartctl not installed (apt install smartmontools)"
    return
  fi
  local out found=0
  while read -r dev; do
    [ -n "$dev" ] || continue
    found=1
    out="$(smartctl -H "/dev/$dev" 2>&1)"
    if printf '%s' "$out" | grep -qiE 'Permission denied|requires root|Operation not permitted'; then
      skip "/dev/$dev -- smartctl needs root; cannot read SMART as your user"
      note "fixable now: run remedies/smart-health.sh enable (installs a root timer dumping SMART to $SMART_DUMP)"
    elif printf '%s' "$out" | grep -qiE 'test result: *PASSED|Health Status: *OK'; then
      ok "/dev/$dev SMART self-assessment PASSED"
    elif printf '%s' "$out" | grep -qiE 'test result: *FAILED|Health Status: *FAILING'; then
      fail "/dev/$dev SMART FAILING -- back up now and replace the drive"
    else
      skip "/dev/$dev -- could not interpret smartctl output"
    fi
  done <<< "$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')"
  [ "$found" -eq 1 ] || skip "no physical disks found to check"
}

# --- memory and swap ----------------------------------------------------
# Three event detectors and no thresholds-on-a-level:
#   swap       -- reports CROSSING a band, not sitting in one
#   OOM kills  -- a fact that already happened, inside a lookback window
#   [rest: vault:senechal/header-archaeology-20260818.md]

MEM_STATE_DIR="$(senechal_state_dir)"
mkdir -p "$MEM_STATE_DIR" 2>/dev/null || true

# kB -> something a human can compare against `free -h` output.
_mem_h() {
  local kb="$1"
  case "$kb" in ''|*[!0-9]*) printf '?'; return ;; esac
  if [ "$kb" -ge 1048576 ]; then
    awk -v k="$kb" 'BEGIN { printf "%.1fGi", k / 1048576 }'
  else
    printf '%dMi' $(( kb / 1024 ))
  fi
}

# Bands for one host, per-host override first. This is the knob that
# keeps potato honest: it has ~905MB of RAM (crt/POTATO.md) and is
# legitimately near the line all the time, so the estate-wide bands are
# the wrong bands for it. Raising them there is a config edit, not a
#   [rest: vault:senechal/header-archaeology-20260818.md]
_swap_bands_for() {
  local h="$1" b=""
  case "$h" in
    *.*|*' '*) ;;
    *) b="$(cfg_list "health.swap_bands_by_host.$h" "")" ;;
  esac
  [ -n "$b" ] || b="$(cfg_list health.swap_bands "$SWAP_BANDS_DEFAULT")"
  printf '%s\n' "$b" | tr '\n' ' '
}

# Swap, as a crossing. <host> <swap_total_kb> <swap_free_kb>
_mem_report_swap() {
  local h="$1" tot="$2" fr="$3"
  case "$tot" in ''|*[!0-9]*) skip "$h: SwapTotal unreadable (got \"$tot\") -- swap pressure is unknown here, which is not the same as fine"; return ;; esac
  case "$fr"  in ''|*[!0-9]*) skip "$h: SwapFree unreadable (got \"$fr\") -- swap pressure is unknown here, which is not the same as fine"; return ;; esac

  if [ "$tot" -eq 0 ]; then
    ok "$h: no swap configured -- nothing to exhaust, but also no early warning; here an OOM kill is the FIRST signal"
    return
  fi

  local used pct bands b topband=0 sf line rc verdict band prev hours human
  used=$(( tot - fr ))
  pct=$(( used * 100 / tot ))
  bands="$(_swap_bands_for "$h")"
  for b in $bands; do
    case "$b" in ''|*[!0-9]*) continue ;; esac
    topband=$(( topband + 1 ))
  done
  if [ "$topband" -eq 0 ]; then
    skip "$h: health.swap_bands holds no usable numbers (\"$bands\") -- without bands there is no crossing to detect"
    return
  fi

  sf="$MEM_STATE_DIR/swap-band.$h"
  # shellcheck disable=SC2086  -- $bands is a deliberate word split
  line="$(mem_swap_transition "$sf" "$pct" "$SWAP_SUSTAINED_H" "$(date +%s)" $bands)" && rc=0 || rc=$?
  if [ "$rc" -eq 2 ]; then
    skip "$h: could not evaluate swap band from ${pct}% -- change detection did not run"
    return
  fi
  IFS=$'\t' read -r verdict band prev hours <<< "$line"
  [ "$rc" -eq 3 ] && skip "$h: swap band state file $sf is not writable -- this run cannot remember its band, so the next run will re-report rather than compare"

  human="swap ${pct}% used ($(_mem_h "$used") of $(_mem_h "$tot")), bands ${bands% }"
  # "was band -1" is the no-prior-state sentinel leaking into a human
  # sentence; say what actually happened instead.
  local from="was band $prev"
  [ "$prev" -lt 0 ] && from="first reading, no previous run to compare against"

  if [ "$band" -eq 0 ]; then
    ok "$h: $human -- below the first band"
    return
  fi

  case "$verdict" in
    first|rise)
      if [ "$band" -ge "$topband" ]; then
        fail "$h: $human -- swap CROSSED INTO the top band ($from, now band $band). This is the leading indicator of thrashing; RAM will still look survivable"
      else
        warn_ "$h: $human -- swap crossed up into band $band ($from)"
      fi
      ;;
    sustained)
      if [ "$band" -ge "$topband" ]; then
        fail "$h: $human -- has sat in the TOP swap band for ${hours}h (>= ${SWAP_SUSTAINED_H}h). Reported once per residency, not per run"
      else
        warn_ "$h: $human -- has sat in band $band for ${hours}h (>= ${SWAP_SUSTAINED_H}h)"
      fi
      ;;
    fall)
      ok "$h: $human -- swap fell from band $prev to band $band since the last run"
      ;;
    *)
      ok "$h: $human -- band $band unchanged for ${hours}h, no crossing"
      ;;
  esac
}

# OOM kills, from journal text on stdin-as-argument. <host> <journal text>
_mem_report_oom() {
  local h="$1" txt="$2" recs n raw when pid comm rss
  raw="$(printf '%s\n' "$txt" | grep -cF 'Out of memory: Killed process' || true)"
  recs="$(printf '%s\n' "$txt" | mem_oom_parse)"
  n="$(printf '%s' "$recs" | grep -c . || true)"

  # A parser that matched nothing while the journal plainly has OOM lines
  # is broken, and "0 kills" would be the most dangerous possible way to
  # say so. Kernel wording changes; this notices instead of reassuring.
  if [ "$raw" -gt 0 ] && [ "$n" -eq 0 ]; then
    skip "$h: $raw OOM line(s) in the journal but none parsed -- the kernel's wording has changed and mem_oom_parse needs updating"
    return
  fi

  if [ "$n" -eq 0 ]; then
    ok "$h: no OOM kills in the last ${OOM_LOOKBACK_H}h"
    return
  fi

  fail "$h: $n OOM kill(s) in the last ${OOM_LOOKBACK_H}h -- the kernel ran out of memory and picked a victim"
  while IFS=$'\t' read -r when pid comm rss; do
    [ -n "$when" ] || continue
    note "$when  killed $comm (pid $pid, $(_mem_h "$rss") resident)"
  done <<< "$recs"
  note "already happened -- not a level. It ages out of the ${OOM_LOOKBACK_H}h window by itself (health.oom_lookback_hours)"
}

# Is the kernel journal actually readable by this user? Membership in
# systemd-journal/adm is what decides, and without it journalctl exits 0
# and prints nothing -- indistinguishable from a machine that has never
# OOMed. That distinction is the entire point of exit 2 here.
_mem_journal_readable() {
  local out
  out="$(journalctl -k -n1 --no-pager 2>/dev/null)" || return 1
  [ -n "$out" ]
}

# Process table for the squatter check: "<pid> <swap_kb> <elapsed_s>
# <cpu_s> <comm>", plus "#denied N" / "#gone N" counters.
#
# The two counters are not the same thing and must not be merged. A
#   [rest: vault:senechal/header-archaeology-20260818.md]
_mem_swap_table_local() {
  ps -eo pid=,etimes=,times=,comm= 2>/dev/null | awk '
    {
      pid = $1; el = $2; cpu = $3
      comm = $4; for (i = 5; i <= NF; i++) comm = comm " " $i
      f = "/proc/" pid "/status"
      sw = -1; opened = 0
      while ((getline line < f) > 0) {
        opened = 1
        if (line ~ /^VmSwap:/) { split(line, a, /[ \t]+/); sw = a[2]; break }
      }
      close(f)
      if (!opened) {
        if (system("test -e \"" f "\"") == 0) denied++; else gone++
        next
      }
      # Readable but no VmSwap line: a kernel thread, which has no mm and
      # so cannot hold swap. Not a gap.
      if (sw < 0) next
      print pid, sw, el, cpu, comm
    }
    END { printf "#denied %d\n#gone %d\n", denied + 0, gone + 0 }'
}

_mem_report_squatters() {
  local h="$1" raw denied hits n pid mb days comm total=0
  raw="$(_mem_swap_table_local)"
  denied="$(printf '%s\n' "$raw" | awk '/^#denied /{print $2}')"
  case "$denied" in ''|*[!0-9]*) denied=0 ;; esac

  local rows
  rows="$(printf '%s\n' "$raw" | grep -v '^#' | grep -c . || true)"
  case "$rows" in ''|*[!0-9]*) rows=0 ;; esac
  if [ "$rows" -eq 0 ]; then
    skip "$h: could not read any process memory figures -- ps or /proc is not answering"
    return
  fi

  hits="$(printf '%s\n' "$raw" | grep -v '^#' \
    | mem_swap_squatters "$SQUAT_MIN_MB" "$SQUAT_MIN_DAYS" "$SQUAT_MAX_CPU_PCT" \
    | sort -t"$(printf '\t')" -k2 -rn)"
  n="$(printf '%s' "$hits" | grep -c . || true)"

  [ "$denied" -gt 0 ] && skip "$h: $denied process(es) whose /proc/<pid>/status could not be read -- swap held by another user's processes is invisible to this check"

  if [ "$n" -eq 0 ]; then
    ok "$h: no process holding >= ${SQUAT_MIN_MB}MB of swap while idle >= ${SQUAT_MIN_DAYS}d"
    return
  fi

  while IFS=$'\t' read -r pid mb days comm; do
    [ -n "$pid" ] || continue
    total=$(( total + mb ))
  done <<< "$hits"

  # ONE aggregate finding, not one per process: the alert layer dedupes
  # by text shape, so a per-process line would page again every time the
  # set shifted by one idle daemon. The detail goes in the notes.
  warn_ "$h: $n idle process(es) holding ${total}MB of swap between them (>= ${SQUAT_MIN_MB}MB each, idle >= ${SQUAT_MIN_DAYS}d at < ${SQUAT_MAX_CPU_PCT}% lifetime CPU) -- reclaimable without stopping anything that is doing work"
  while IFS=$'\t' read -r pid mb days comm; do
    [ -n "$pid" ] || continue
    note "$comm (pid $pid) -- ${mb}MB swapped, idle ${days}d"
  done <<< "$hits"
}

check_memory() {
  head_ "Memory pressure (mandark)"
  local mi=/proc/meminfo tot fr avail memtot
  if [ ! -r "$mi" ]; then
    skip "cannot read $mi -- memory pressure is unknown on this host"
    return
  fi
  tot="$(awk '/^SwapTotal:/{print $2; exit}' "$mi")"
  fr="$(awk '/^SwapFree:/{print $2; exit}' "$mi")"
  memtot="$(awk '/^MemTotal:/{print $2; exit}' "$mi")"
  avail="$(awk '/^MemAvailable:/{print $2; exit}' "$mi")"

  # RAM is CONTEXT, deliberately not a finding. It is the number that
  # looked survivable at 5.3/7.5 while the machine thrashed, so giving it
  # a threshold here would rebuild the exact blind spot this section was
  # written to close.
  if [ -n "$memtot" ] && [ -n "$avail" ]; then
    note "RAM: $(_mem_h "$avail") available of $(_mem_h "$memtot") (context only -- no threshold; swap and OOM are the signals)"
  fi

  _mem_report_swap mandark "$tot" "$fr"

  if _mem_journal_readable; then
    _mem_report_oom mandark "$(journalctl -k -o short-iso --since "-${OOM_LOOKBACK_H}h" --no-pager 2>/dev/null || true)"
  else
    skip "mandark: kernel journal not readable as this user -- OOM kills cannot be seen (add your user to the systemd-journal or adm group)"
  fi

  _mem_report_squatters mandark
}

# --- battery wear -------------------------------------------------------
check_battery() {
  head_ "Battery"
  local b full design pct
  local found=0
  for b in /sys/class/power_supply/BAT*; do
    [ -d "$b" ] || continue
    found=1
    full="$(cat "$b/energy_full" 2>/dev/null || cat "$b/charge_full" 2>/dev/null || echo '')"
    design="$(cat "$b/energy_full_design" 2>/dev/null || cat "$b/charge_full_design" 2>/dev/null || echo '')"
    if [ -z "$full" ] || [ -z "$design" ] || [ "$design" -eq 0 ] 2>/dev/null; then
      skip "$(basename "$b") -- kernel does not expose design capacity"
      continue
    fi
    pct=$(( full * 100 / design ))
    if [ "$pct" -lt "$BATT_WARN" ]; then
      warn_ "$(basename "$b") health ${pct}% of design (< ${BATT_WARN}% warn threshold) -- worn, expect shorter runtime"
    else
      ok "$(basename "$b") health ${pct}% of design capacity"
    fi
  done
  [ "$found" -eq 1 ] || skip "no battery (not a laptop, or not exposed)"
}

# --- thermals -----------------------------------------------------------
check_temps() {
  head_ "Thermals"
  local z t max=0 maxzone="" name
  for z in /sys/class/thermal/thermal_zone*; do
    [ -r "$z/temp" ] || continue
    t="$(cat "$z/temp" 2>/dev/null || echo 0)"
    case "$t" in ''|*[!0-9-]*) continue ;; esac
    t=$(( t / 1000 ))
    if [ "$t" -gt "$max" ]; then
      max=$t
      name="$(cat "$z/type" 2>/dev/null || basename "$z")"
      maxzone="$name"
    fi
  done
  if [ "$max" -eq 0 ]; then
    skip "no readable thermal zones"
  elif [ "$max" -ge "$TEMP_WARN" ]; then
    warn_ "hottest zone $maxzone at ${max}C (>= ${TEMP_WARN}C) -- likely throttling"
  else
    ok "hottest zone $maxzone at ${max}C"
  fi
}

# --- services / units ---------------------------------------------------
# A GUI app is not a service -- see is_transient_scope in lib/common.sh
# for what that means and why the definition is shared rather than
# retyped here. What matters at this end: whatever gets filtered is
# NAMED in the report. A filter you cannot see is a blindfold, not a
# fix. Clearing the residue is a separate, non-read-only job that this
# read-only check only points at: tools/reap-failed-scopes.sh.
check_units() {
  head_ "Service liveness (mandark)"
  local failed_user failed_sys real_user transient_user
  failed_user="$(systemctl --user list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -v '^$' || true)"
  failed_sys="$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -v '^$' || true)"

  real_user=""; transient_user=""
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    if is_transient_scope "$u"; then
      transient_user+="$u"$'\n'
    else
      real_user+="$u"$'\n'
    fi
  done <<< "$failed_user"

  if [ -z "${real_user//[$'\n']/}" ]; then
    ok "no failed user units"
  else
    while IFS= read -r u; do
      [ -n "$u" ] && fail "user unit failed: $u  (journalctl --user -u $u -n 30)"
    done <<< "$real_user"
  fi

  if [ -n "${transient_user//[$'\n']/}" ]; then
    note "$(printf '%s' "$transient_user" | grep -c .) transient app scope(s) in failed state, not counted (a crashed GUI app, not a service): $(printf '%s' "$transient_user" | paste -sd' ' -)"
    note "clear with: tools/reap-failed-scopes.sh"
  fi

  if [ -z "$failed_sys" ]; then
    ok "no failed system units"
  else
    while IFS= read -r u; do
      [ -n "$u" ] && fail "system unit failed: $u  (journalctl -u $u -n 30)"
    done <<< "$failed_sys"
  fi
}

# --- backups: the estate's highest-stakes signal ------------------------
# A backup that silently stops is invisible until you need it, so this
# checks the unit's real last result, not just that a timer exists.
check_backups() {
  head_ "Backup freshness ($BACKUP_UNIT)"
  local status ts age_h now then_
  if ! systemctl --user cat "$BACKUP_UNIT" >/dev/null 2>&1; then
    skip "$BACKUP_UNIT not installed for your user -- no backup is configured at all"
    note "gardien owns backups; if it should be running, that is a gardien task"
    return
  fi

  status="$(systemctl --user show "$BACKUP_UNIT" -p ExecMainStatus --value 2>/dev/null || echo '')"
  ts="$(systemctl --user show "$BACKUP_UNIT" -p ExecMainExitTimestamp --value 2>/dev/null || echo '')"

  if [ -z "$ts" ]; then
    fail "$BACKUP_UNIT has never run -- there are no backups"
  else
    now="$(date +%s)"
    then_="$(date -d "$ts" +%s 2>/dev/null || echo 0)"
    age_h=$(( (now - then_) / 3600 ))
    if [ "$then_" -eq 0 ]; then
      skip "could not parse last-run timestamp: $ts"
    elif [ "$age_h" -gt "$BACKUP_MAX_AGE_H" ]; then
      fail "last backup attempt was ${age_h}h ago (> ${BACKUP_MAX_AGE_H}h) -- the timer may be dead"
    else
      ok "last backup attempt ${age_h}h ago"
    fi
  fi

  if [ "$status" = "0" ]; then
    ok "$BACKUP_UNIT last exited 0 (success)"
  elif [ -n "$status" ]; then
    fail "$BACKUP_UNIT last exited $status -- BACKUPS ARE FAILING, not just stale"
    note "$(journalctl --user -u "$BACKUP_UNIT" -n 3 --no-pager 2>/dev/null | tail -2 | sed 's/^/        /')"
    note "gardien owns this -- file it with: scheduler -i gardien \"...\""
  fi
}

# --- patch drift --------------------------------------------------------
check_updates() {
  head_ "Updates (mandark)"
  if [ -f /var/run/reboot-required ]; then
    warn_ "reboot required to finish applying updates"
  else
    ok "no reboot-required flag"
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    skip "not an apt system -- update check not implemented for this host"
    return
  fi
  local n
  n="$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst' || true)"
  case "$n" in ''|*[!0-9]*) skip "could not count pending updates"; return ;; esac
  if [ "$n" -ge "$UPDATES_WARN" ]; then
    warn_ "$n pending package updates (>= $UPDATES_WARN) -- patch drift"
  else
    ok "$n pending package updates"
  fi
}

# --- journal redaction, the project's own core invariant ----------------
# Everything else here watches the machine; this one watches senechal.
# `journal/*.json` is committed to git, so an unredacted preview is the
# one failure this project cannot walk back -- and the write-time check
#   [rest: vault:senechal/header-archaeology-20260818.md]
check_journal_redaction() {
  head_ "Journal redaction (committed snapshots)"
  local journal="$SENECHAL_ROOT/journal" out rc
  if [ ! -d "$journal" ]; then
    skip "no journal directory at $journal -- nothing to audit"
    return
  fi
  out="$(python3 "$SENECHAL_ROOT/senechal.py" --journal "$journal" --audit 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) ok "${out#OK -- }" ;;
    1)
      # Deliberately verbatim: every FAIL line names a snapshot + path,
      # never the offending preview text, so this report does not become
      # a second copy of the leak.
      fail "unredacted secret-looking content in committed journal snapshots"
      while IFS= read -r line; do [ -n "$line" ] && note "$line"; done <<<"$out"
      ;;
    *) skip "journal audit could not run (exit $rc): ${out:-no output}" ;;
  esac
}

# --- dead machine config ------------------------------------------------
# Delegated to health/dead-config.sh rather than inlined: it is a whole
# registry pass with its own test harness, and it is useful to run alone
# ("what is still installed that shouldn't be?"). Folded in here so it
#   [rest: vault:senechal/header-archaeology-20260818.md]
check_issue_backlog() {
  head_ "Issue inbox (receipts swept, backlog readable)"
  command -v gh >/dev/null 2>&1 || { skip "gh is not on PATH"; return; }
  local out rc
  out="$(python3 "$SENECHAL_ROOT/tools/issue-janitor.py" 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) ok "no unswept receipts, and the backlog is readable" ;;
    1) fail "machine-filed receipts are sitting open and nothing swept them"
       note "run: python3 tools/issue-janitor.py --apply" ;;
    # 2 is could-not-look, and covers both "gh cannot answer" and the
    # BACKLOG_CEILING case. The latter is not a tidy INCOMPLETE -- it is
    # the inbox being buried past what a mechanical broom can read, which
    # is the exact condition the janitor exists to surface. Replay its
    # own UNSWEPT line so the reason is in the report, not just the code.
    2) skip "the janitor could not read the inbox"
       while IFS= read -r line; do
         case "$line" in *UNSWEPT*|*"open issue(s) examined"*) note "${line#  }" ;; esac
       done <<<"$out" ;;
    *) skip "issue-janitor.py exited $rc" ;;
  esac
}

# The pile, bounded. check_issue_backlog above says whether receipts were
# swept; this says whether the pile is BIGGER than last time. Counting is
# not bounding -- 58 open looks identical to 40 or 90 unless something
# remembers which way it moved (hf7y/senechal#305 follow-on).
check_issue_debt() {
  head_ "Issue debt (the ratchet only falls)"
  command -v gh >/dev/null 2>&1 || { skip "gh is not on PATH"; return; }
  local out rc
  out="$(bash "$SENECHAL_ROOT/tools/issue-debt.sh" 2>&1)" && rc=0 || rc=$?
  local head; head="$(printf '%s' "$out" | head -1)"
  case "$rc" in
    0) ok "$head" ;;
    1) fail "$head"
       note "close the overage, or raise the ceiling in a reviewable diff" ;;
    3) warn_ "$head"
       note "run tools/issue-debt.sh --lower and commit it" ;;
    *) skip "issue-debt.sh exited $rc" ;;
  esac
}

# Issue debt's sibling in shape: how much of PATH still executes out of a
# working clone rather than a deployed verb build. A clone can be deleted,
# rebased, or switched to a branch under a shim that never notices -- which
# is how two shims came to point into a deleted /tmp checkout (#328).
#   [rest: vault:senechal/header-archaeology-20260818.md]
check_front_door_labels() {
  head_ "Front-door labels exist (a filing that cannot be labelled is lost)"
  local out rc
  out="$(bash "$SENECHAL_ROOT/health/front-door-labels.sh" -q 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) ok "every label the typed door depends on exists" ;;
    1) fail "$(printf '%s' "$out" | head -1)"
       note "create it, then re-file: tools/absorb-notices.py cannot see an unlabelled filing" ;;
    *) skip "front-door-labels.sh exited $rc" ;;
  esac
}

# The 8710's K nozzle row is dead and says otherwise: lpstat reports the queue
# idle, marker-levels reports K at 90%, the printhead self-reports "ok". A job
# sent to any queue but the remapping one is accepted, reported successful, and
# printed with the black gone. Nothing detects that by asking the printer, so
# what gets checked is whether the guard is still routed around it.
# The verb build is cut from origin/bashified and copies the whole tree, so a
# stale ship branch means every deployed host runs stale code and nothing says
# so. CLAUDE.md asserted this was already handled; it was not (#406, measured
# again 2026-08-25). Delegated so the invariant lives in one runnable place.
# The checkable half of "how to write a remedy", which was a checklist in
# remedies/README.md until that file was deleted for drift (2026-08-25).
check_remedy_shape() {
  head_ "Remedies are the right shape"
  local out rc
  out="$(bash "$SENECHAL_ROOT/health/remedy-shape.sh" -q 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) ok "enable/verify present, no orphan or loose tests, coverage at or under ceiling" ;;
    1) fail "$(printf '%s' "$out" | sed -n 's/^ *FAIL  //p' | head -1)" ;;
    3) warn_ "$(printf '%s' "$out" | sed -n 's/^ *WARN  //p' | head -1)" ;;
    *) skip "remedy-shape.sh exited $rc" ;;
  esac
}

# Decisions Zach already gave (registry/standing-answers.json). An answer whose
# mechanism was deleted is an answer nothing enforces any more.
check_standing_answers() {
  head_ "Standing answers still have their mechanisms"
  local out rc
  out="$(python3 "$SENECHAL_ROOT/tools/standing-answers.py" --audit 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) ok "$(printf '%s' "$out" | tail -1)" ;;
    1) fail "$(printf '%s' "$out" | grep -m1 '^FAIL' || printf 'a standing answer lost its mechanism')" ;;
    *) skip "standing-answers.py exited $rc" ;;
  esac
}

check_bashified_ships_main() {
  head_ "The verb build ships all of main"
  local out rc
  out="$(bash "$SENECHAL_ROOT/health/bashified-ships-main.sh" -q 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) ok "origin/main is an ancestor of origin/bashified" ;;
    1) fail "$(printf '%s' "$out" | sed -n 's/^ *FAIL  //p' | head -1)"
       note "git push origin main:bashified --force-with-lease" ;;
    3) warn_ "$(printf '%s' "$out" | sed -n 's/^ *WARN  //p' | head -1)" ;;
    *) skip "bashified-ships-main.sh exited $rc" ;;
  esac
}

check_printer_black_channel() {
  head_ "Printing routes black away from the 8710's dead nozzle row"
  local out rc
  out="$(bash "$SENECHAL_ROOT/health/printer-black-channel.sh" -q 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) ok "the default destination remaps black" ;;
    1) fail "$(printf '%s' "$out" | sed -n 's/^ *FAIL  //p' | head -1)"
       note "remedies/print-black-via-colour.sh enable, or: lpoptions -d HP8710_K2CMY" ;;
    *) skip "printer-black-channel.sh exited $rc" ;;
  esac
}

check_path_from_checkout() {
  head_ "PATH runs from deployed verbs, not checkouts"
  local out rc
  out="$(bash "$SENECHAL_ROOT/health/path-from-checkout.sh" -q 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) ok "at or below the ceiling ($(cat "$SENECHAL_ROOT/health/path-from-checkout.ceiling"))" ;;
    1) fail "$(printf '%s' "$out" | head -1)"
       note "deploy it as a verb, or raise the ceiling in a reviewable diff" ;;
    *) skip "path-from-checkout.sh exited $rc" ;;
  esac
}

# Dead machine config's sibling: dead senechal.json KEYS. Retiring a script
# does not retire its configuration, and the live config is untracked, so no
# diff ever shows the leftovers (hf7y/senechal#311 left three).
check_dead_config_keys() {
  head_ "Dead config keys (senechal.json)"
  local out rc
  out="$(python3 "$SENECHAL_ROOT/tools/dead-config-keys.py" 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) ok "every key in senechal.json has a reader" ;;
    3) while IFS= read -r line; do
         case "$line" in
           "  WARN "*) warn_ "${line#  WARN }" ;;
           "      "*)  note "${line#      }" ;;
         esac
       done <<<"$out" ;;
    *) skip "dead-config-keys.py exited $rc" ;;
  esac
}

# senechal.json and its committed example are two copies of the same prose.
# Only CHANGES to the known-diverged set are reported -- see the baseline
# rationale in tools/config-prose-drift.py.
check_config_prose_drift() {
  head_ "Config prose (live vs committed example)"
  local out rc
  out="$(python3 "$SENECHAL_ROOT/tools/config-prose-drift.py" 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) ok "$(printf '%s' "$out" | head -1)" ;;
    1) while IFS= read -r line; do
         case "$line" in
           "  FLAG "*) fail "${line#  FLAG }" ;;
           "      "*)  note "${line#      }" ;;
         esac
       done <<<"$out" ;;
    3) warn_ "a baseline entry no longer diverges -- remove it from tools/config-prose-drift.baseline" ;;
    *) skip "config-prose-drift.py exited $rc" ;;
  esac
}

# Every tracked mechanism file has a fleet/taste/shared/meta classification
# now (hf7y/senechal#396, merged from #401+#397 by #408). Same drift shape
# as dead config keys: a file added without an entry here just silently
# falls out of the registry, and nothing else would ever notice.
check_boundary_registry() {
  head_ "Fleet/taste boundary registry (hf7y/senechal#396)"
  local out rc
  out="$(python3 "$SENECHAL_ROOT/tools/boundary.py" --audit 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) ok "$out" ;;
    1) while IFS= read -r line; do
         case "$line" in
           "  FLAG "*) fail "${line#  FLAG }" ;;
         esac
       done <<<"$out" ;;
    3) while IFS= read -r line; do
         case "$line" in
           "WARN "*) warn_ "${line#WARN }" ;;
         esac
       done <<<"$out" ;;
    *) skip "boundary.py --audit exited $rc" ;;
  esac
}

check_dead_config() {
  head_ "Dead machine config (footprint registry)"
  local out rc
  out="$(bash "$SENECHAL_ROOT/health/dead-config.sh" 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) ok "every registered footprint entry matches what it declares" ;;
    *)
      # Replay its own findings verbatim, but re-count them here so the
      # aggregate severity and the alert threshold see them. Its report
      # lines already carry PASS/WARN/FAIL/SKIP markers; strip PASS so a
      # long healthy registry doesn't drown the finding.
      #   [rest: vault:senechal/header-archaeology-20260818.md]
      local keep=0
      while IFS= read -r line; do
        case "$line" in
          "  FAIL  "*) keep=1; fail "${line#  FAIL  }" ;;
          "  WARN  "*) keep=1; warn_ "${line#  WARN  }" ;;
          # skip() re-appends its own "(could not check...)" suffix, so
          # strip the one dead-config.sh already added rather than
          # printing it twice.
          "  SKIP  "*) keep=1; line="${line#  SKIP  }"; skip "${line% (could not check -- not a pass)}" ;;
          "        "*) [ "$keep" -eq 1 ] && note "${line#        }" ;;
          "  PASS  "*) keep=0 ;;
          # PASS lines, the blank spacer, its banner and its own closing
          # summary ("FAILED -- N check(s)...") are all dropped: this
          # report has its own summary, and a second one reads as a
          # second problem.
          *) ;;
        esac
      done <<<"$out"
      ;;
  esac
}

# --- registered credentials --------------------------------------------
# Delegated to health/secret-registry.sh for the same reasons
# check_dead_config delegates. Folded in here so a credential that went
# missing, widened its mode, or started being copied off-host in
#   [rest: vault:senechal/header-archaeology-20260818.md]
check_secret_registry() {
  head_ "Registered credentials (secret registry)"
  local out rc
  out="$(bash "$SENECHAL_ROOT/health/secret-registry.sh" 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) ok "every registered credential is present, no wider than declared, and where it is allowed to be" ;;
    *)
      local keep=0 line
      while IFS= read -r line; do
        case "$line" in
          "  FAIL  "*) keep=1; fail "${line#  FAIL  }" ;;
          "  WARN  "*) keep=1; warn_ "${line#  WARN  }" ;;
          "  SKIP  "*) keep=1; line="${line#  SKIP  }"; skip "${line% (could not check -- not a pass)}" ;;
          "        "*) [ "$keep" -eq 1 ] && note "${line#        }" ;;
          "  PASS  "*) keep=0 ;;
          *) ;;
        esac
      done <<<"$out"
      ;;
  esac
}

# --- unabsorbed notices (the issue queue senechal's front door feeds) ---
# Delegated to health/unabsorbed-notices.sh rather than inlined, for the
# same reason check_dead_config delegates: it has its own test harness
# and is useful to run alone. Folded in here so a notice that sat
# unabsorbed rides the hourly timer and the same alert path, instead of
# being found only by whoever happens to look at the issue list --
# exactly how #23-#26 sat unread until 2026-08-05 (hf7y/senechal#29).
check_unabsorbed_notices() {
  head_ "Unabsorbed notices (issue queue)"
  local out rc
  out="$(bash "$SENECHAL_ROOT/health/unabsorbed-notices.sh" 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) ok "no open notice has sat unabsorbed past its threshold" ;;
    *)
      # Replay its findings verbatim, exactly as check_dead_config does.
      local keep=0 line
      while IFS= read -r line; do
        case "$line" in
          "  FAIL  "*) keep=1; fail "${line#  FAIL  }" ;;
          "  WARN  "*) keep=1; warn_ "${line#  WARN  }" ;;
          "  SKIP  "*) keep=1; line="${line#  SKIP  }"; skip "${line% (could not check -- not a pass)}" ;;
          "        "*) [ "$keep" -eq 1 ] && note "${line#        }" ;;
          "  PASS  "*) keep=0 ;;
          *) ;;
        esac
      done <<<"$out"
      ;;
  esac
}

# --- typed door filings waiting to be absorbed ---------------------------
# The other half of check_unabsorbed_notices. Since 2026-08-16 notify-senechal
# files a TYPED payload (registry/front-doors.json) rather than prose, and
# tools/absorb-notices.py can write it into the live config unattended -- so a
# pending filing is not a "someone must transcribe this" nag, it is one
# --write away. Dry run here; the write is deliberately not automatic, because
# it edits the live config and lands as a reviewable registry diff.
check_pending_door_filings() {
  head_ "Typed door filings (waiting to be absorbed)"
  local out rc
  out="$(python3 "$SENECHAL_ROOT/tools/absorb-notices.py" 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) ok "no typed filing is waiting" ;;
    1) while IFS= read -r line; do
         case "$line" in "REJECT "*) fail "${line#REJECT  }" ;; esac
       done <<<"$out"
       note "a rejected filing is malformed and nobody is coming for it -- fix it at the caller" ;;
    3) while IFS= read -r line; do
         case "$line" in
           "ABSORB "*) warn_ "${line#ABSORB  }" ;;
           "DEFER  "*) warn_ "${line#DEFER   }" ;;
         esac
       done <<<"$out"
       note "absorb fleet filings: tools/absorb-notices.py --write --close, then commit registry/ as a PR (hf7y/senechal#411); a DEFERRED taste filing needs a run on the taste host instead" ;;
    *) skip "$(printf '%s' "$out" | head -1)" ;;
  esac
}

# --- Zach's slash commands, in every home -------------------------------
# Delegated to remedies/claude-slash-commands.sh verify rather than
# inlined, for the same reason check_dead_config delegates: it has its own
# test harness and is useful to run alone. Folded in here because the
#   [rest: vault:senechal/header-archaeology-20260818.md]
check_slash_commands() {
  head_ "Claude slash commands (present and current in every home)"
  local out rc
  out="$(bash "$SENECHAL_ROOT/remedies/claude-slash-commands.sh" verify 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) ok "every registered home has every command, byte-identical to source" ;;
    *)
      # Replay its findings verbatim so the aggregate severity and the
      # alert threshold see them, exactly as check_dead_config does.
      local keep=0 line
      while IFS= read -r line; do
        case "$line" in
          "  FAIL  "*) keep=1; fail "${line#  FAIL  }" ;;
          "  WARN  "*) keep=1; warn_ "${line#  WARN  }" ;;
          "  SKIP  "*) keep=1; line="${line#  SKIP  }"; skip "${line% (could not check -- not a pass)}" ;;
          "        "*) [ "$keep" -eq 1 ] && note "${line#        }" ;;
          "  PASS  "*) keep=0 ;;
          *) ;;
        esac
      done <<<"$out"
      ;;
  esac
}

# --- deployed code vs the mainline --------------------------------------
# senechal-health.timer's ExecStart points straight at this working
# checkout, which is also where humans and agents hop branches all
# evening -- so merged code can sit undeployed with nothing able to tell.
#   [rest: vault:senechal/header-archaeology-20260818.md]
check_deploy() {
  head_ "Deployed code (the checkout the timer executes)"
  local ref root state kind arg sha dirty
  root="$SENECHAL_ROOT"
  ref="$(cfg health.deploy_ref origin/main)"

  state="$(deploy_state "$root" "$ref")"
  read -r kind arg sha dirty <<<"$state"

  case "$kind" in
    nogit)   skip "$root is not a git checkout -- cannot compare running code to a git ref"; return ;;
    noref)   skip "$ref is not known in $root -- run: git -C '$root' fetch origin"; return ;;
    current) ok "running code at $sha contains $ref" ;;
    behind)
      fail "$root is $arg commit(s) behind $ref -- merged fixes are NOT running"
      note "bring it current: git -C '$root' fetch origin && git -C '$root' merge --ff-only $ref"
      deployed_units_note "$root"
      ;;
    *) skip "deploy_state returned something unrecognised ('$state') -- treating as unknown, not as healthy"; return ;;
  esac

  # A dirty tree means the running code is not any git ref at all. WARN,
  # not FAIL: concurrent agents and mid-session edits are normal here
  # (registry/standing-answers.json), and a FAIL every time someone is working would be
  # the same noise this whole change exists to stop.
  [ "${dirty:-0}" != 0 ] && \
    warn_ "$dirty uncommitted change(s) in $root -- the code running here is not $sha exactly"
  return 0
}

# --- notification audit: who is actually paging this session -----------
# remedies/notify-audit.sh runs a continuous D-Bus listener that logs
# every Notify call, any sender, to notify-audit.log -- it must be
# continuously alive, since dbus-monitor has no history to poll. This
# half reads that log, folds it into one summary line per sender, and
# truncates it, so a spam channel from an unrelated app is visible
# without the log growing forever between runs.
check_notify_audit() {
  head_ "Notification audit (any sender, mandark)"
  local log hist total counts
  log="$(senechal_state_dir)/notify-audit.log"
  hist="$(senechal_state_dir)/notify-audit-history.tsv"

  if [ ! -f "$log" ]; then
    skip "no notify-audit.log -- remedies/notify-audit.sh not enabled yet"
    return
  fi

  total="$(grep -c . "$log" 2>/dev/null || echo 0)"
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  if [ "$total" -eq 0 ]; then
    ok "no desktop notifications, any sender, since the last check"
    return
  fi

  # Counted by app name (field 2), not raw lines, so a summary reads as
  # "who", not a scoreboard -- the same complaint that killed the old
  # notify_alert body applies here just as much. Built by hand rather
  # than a field-splitting awk pass, because an app name can itself
  # contain spaces ("Firefox Web Browser") and a naive $2 would truncate it.
  counts="$(cut -f2 "$log" 2>/dev/null | sort | uniq -c | sort -rn)"
  local line n app breakdown=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*([0-9]+).*/\1/')"
    app="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//')"
    breakdown="$breakdown$app:$n "
    if [ "$n" -ge "$NOTIFY_AUDIT_WARN" ]; then
      warn_ "$app sent $n desktop notifications since the last check (>= $NOTIFY_AUDIT_WARN) -- possible spam"
    fi
  done <<<"$counts"
  ok "$total notification(s) from $(printf '%s\n' "$counts" | grep -c .) sender(s) since the last check"
  note "full breakdown in $hist"

  # Fold into one durable summary line, then clear the raw log -- the
  # counts are what's worth keeping, not the raw per-notification text,
  # so this cannot grow unbounded between runs.
  printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M')" "$total" "$breakdown" \
    >> "$hist" 2>/dev/null || true
  : > "$log" 2>/dev/null || true
}

# Name the units that actually execute out of a checkout, so a drift
# finding says what is stale rather than leaving Zach to grep. Best
# effort: no systemd (a container, a cron-only box) is a silent no-op,
# because the drift itself is already reported by the caller.
deployed_units_note() {
  local root="$1" unit
  command -v systemctl >/dev/null 2>&1 || return 0
  while read -r unit; do
    [ -n "$unit" ] && note "runs from here: $unit"
  done < <(
    systemctl --user list-units --type=service --all --no-legend --plain 2>/dev/null \
      | awk '{print $1}' \
      | while read -r u; do
          [ -n "$u" ] || continue
          systemctl --user show -p ExecStart --value "$u" 2>/dev/null \
            | grep -qF "$root" && printf '%s\n' "$u"
        done
  )
}

main() {
  parse_common_args "$@"
  # _emit, not say -- so `-q` stays truly silent on a healthy run.
  _emit "senechal estate health -- $(date '+%Y-%m-%d %H:%M') on $(hostname)"
  check_reachability
  check_remote_health
  check_disks
  check_memory
  check_smart
  check_battery
  check_temps
  check_units
  check_backups
  check_updates
  check_journal_redaction
  check_dead_config
  check_dead_config_keys
  check_config_prose_drift
  check_boundary_registry
  check_secret_registry
  check_unabsorbed_notices
  check_pending_door_filings
  check_issue_backlog
  check_issue_debt
  check_path_from_checkout
  check_front_door_labels
  check_printer_black_channel
  check_bashified_ships_main
  check_remedy_shape
  check_standing_answers
  check_slash_commands
  check_deploy
  check_notify_audit

  # Always leave the findings somewhere durable. Cron's usual channel is
  # mail, and on mandark mail is DEAD (postfix has no main.cf, failing
  # since 2026-07-23) -- so a cron run that relied on mail would report
  # into a void. Delivering an actual alert is a separate, unbuilt
  # decision recorded in ESTATE.md; this file is the floor beneath it.
  local logdir; logdir="$(senechal_state_dir)"
  if mkdir -p "$logdir" 2>/dev/null; then
    printf '%s' "$_out" > "$logdir/health-latest.txt" 2>/dev/null || true
    printf '%s\t%s\n' "$(date '+%Y-%m-%d %H:%M')" \
      "fail=$_fail_count incomplete=$_incomplete_count warn=$_warn_count" \
      >> "$logdir/health-history.tsv" 2>/dev/null || true
    note "findings saved to $logdir/health-latest.txt"
  fi

  # Two gates, not one. WHICH runs may page is health.alert_min_severity
  # (an INCOMPLETE-only run is a known ESTATE.md gap, not a phone buzz).
  # WHETHER this particular run is news is alert_if_changed: the estate
  # has been continuously non-clean since 2026-07-25, and paging hourly
  # about the same unchanged findings is how a channel stops being read.
  alert_if_changed "$logdir/health-latest.txt"

  finish_verify "OK -- estate healthy."
}
main "$@"
