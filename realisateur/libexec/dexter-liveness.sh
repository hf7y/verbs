#!/usr/bin/env bash
# dexter-liveness.sh -- is dexter actually serving what it is supposed to serve?
#
# THE OUTAGE THIS EXISTS FOR. zaxon was dead ten days and nothing noticed:
# `enabled` with Restart=always, while the WSL distro under it never came back
# from a reboot and a distro has no supervisor above it (hf7y/groc-mangr#9).
# Hence the last check here: dexter starts its distro and VMs at LOGIN, so a
# reboot nobody logs in after reads from outside like a quiet night.
#
#   bin/dexter-liveness.sh [--json]   # exit tells the story; --json for a doc
#
# Starts nothing and fixes nothing, as senechal's health/*.sh -- except the STT
# check, which transcribes a sample in the gateway container via a mktemp dir.
#
# exit: 0 all good  5 something declared is down  6 BLIND (cannot reach dexter)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/vmhost.sh"   # vmhost_pause_eval for #704's declared pause; vmhost_running_vms_cmd because the probe runs on the VM host, not here

HOST="${DEXTER_HOST:-dexter}"
JSON=0
[ "${1:-}" = "--json" ] && JSON=1

# THE EXPECTED SET, in one place. A thing running on dexter and not named here
# is invisible -- the failure mode this is named for.
# `hermes` is NOT here: STT moved into zaxon-whisper, leaving that distro dead
# weight awaiting realisateur#250 act 3.
EXPECT_DISTROS="Ubuntu"
EXPECT_VMS="monkey"              # nomac is the office VM, started by hand
EXPECT_PORTS="8643 8090"         # zaxon MCP, whisper STT
EXPECT_CONTAINERS="zaxon-gateway zaxon-relay zaxon-watcher zaxon-whisper"

# THE ASSERTION THAT A PORT CHECK IS NOT. STT was dead three weeks because
# nothing named 8090 -- but naming it would not have sufficed. Measured
# 2026-08-25: stopping zaxon-whisper does NOT close 8090; docker-proxy keeps it
# LISTEN for the gateway, which owns the shared namespace. A corrupt model
# passes a connect too. So we transcribe known speech and read the words back,
# via /opt/zaxon-relay/bin/stt-selftest.sh, which resolves the command as the
# gateway does.
STT_EXPECT="ask not what your country can do for you"

fail=0; blind=0; zaxon_fail=0; vm_fail=0; stt_fail=0; findings=()
note() { findings+=("$1"); }
zaxon_note() { note "$1"; fail=1; zaxon_fail=1; }
# Its own half: voice notes fail while typed messages arrive, so folding this
# into ZAXON would misreport the human channel as dead.
stt_note() { note "$1"; fail=1; stt_fail=1; }

probe="$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes "$HOST" '
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  echo "UPTIME_S=$(cut -d. -f1 /proc/uptime)"
  echo "DOCKER=$(systemctl is-active docker 2>/dev/null)"
  echo "CONTAINERS=$(sudo -n docker ps --format "{{.Names}}" 2>/dev/null | tr "\n" "," )"
  echo "PORTS=$(ss -ltn 2>/dev/null | awk "{print \$4}" | sed "s/.*://" | sort -un | tr "\n" ",")"
  # A TCP connect is not liveness: a hung gateway accepts one. Ask MCP to speak.
  # 127.0.0.1 IS CORRECT -- do not "fix" it to the tailnet to match zaxon.sh:
  # this payload executes ON dexter. That ordering is for callers that are not.
  curl -s -m 15 -H "Content-Type: application/json" \
    -H "Accept: application/json,text/event-stream" \
    -X POST http://127.0.0.1:8643/mcp \
    -d '"'"'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"dexter-liveness","version":"1"}}}'"'"' 2>/dev/null \
    | tr -d "\r" | sed -n "s/.*\"serverInfo\":{[^}]*\"name\":\"\([^\"]*\)\".*/MCP_SERVER=\1/p" | head -1
  # ONE LINE so it cannot break KEY=VALUE parsing; `timeout` because a sensor
  # that hangs on a wedged whisper is a sensor down.
  echo "STT=$(timeout 90 sudo -n docker exec zaxon-gateway /opt/zaxon-relay/bin/stt-selftest.sh 2>&1 | tr "\n" " " | tr -s " ")"
  sudo -n systemctl restart systemd-binfmt 2>/dev/null
  cd /mnt/c || exit 0
  echo "DISTROS=$(/mnt/c/Windows/System32/wsl.exe -l -q --running 2>/dev/null | tr -d "\0\r" | tr "\n" ",")"
  echo "VMS=$('"$(vmhost_running_vms_cmd)"' | tr "\n" ",")"
  echo "PAUSE_MONKEY=$(cat "$HOME/.local/state/vmhost-pause-monkey" 2>/dev/null | tr "\n" ";")"  # #704: joined with ";" to stay one line; vmhost_pause_dirs default path
  echo "WINBOOT=$(/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString(\"o\")" 2>/dev/null | tr -d "\0\r")"
' 2>/dev/null)" || { blind=1; }

[ -z "$probe" ] && blind=1

if [ "$blind" = 1 ]; then
  # BLIND IS NOT OK, nor "down". Saying which is the point: "I could not
  # look" reported as healthy is how ten days pass.
  if [ "$JSON" = 1 ]; then
    printf '{"host":"%s","status":"BLIND","reason":"ssh to %s failed or returned nothing"}\n' "$HOST" "$HOST"
  else
    echo "BLIND -- cannot reach $HOST over ssh. This is not 'healthy'."
  fi
  exit 6
fi

val() { printf '%s\n' "$probe" | sed -n "s/^$1=//p" | head -1; }
has() { case ",$2," in *",$1,"*) return 0;; *) return 1;; esac; }

for d in $EXPECT_DISTROS; do
  has "$d" "$(val DISTROS)" || { note "WSL distro '$d' is not running"; fail=1; }
done
RESUME_GRACE_MIN="${RESUME_GRACE_MIN:-30}"  # #704: only monkey's pause rides the probe; any other EXPECT_VMS entry falls straight to "not running", as before
vm_paused=0
for v in $EXPECT_VMS; do
  has "$v" "$(val VMS)" && continue
  vupper="$(printf '%s' "$v" | tr '[:lower:]' '[:upper:]')"
  praw="$(val "PAUSE_$vupper")"
  puntil="$(printf '%s' "$praw" | tr ';' '\n' | sed -n 's/^until=//p' | head -1)"
  presumed="$(printf '%s' "$praw" | tr ';' '\n' | sed -n 's/^resumed_at=//p' | head -1)"
  pstatus="$(vmhost_pause_eval "$puntil" "$presumed" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  pkind="${pstatus%% *}"; pwhen="${pstatus#* }"
  if [ "$pkind" = PAUSED ]; then
    note "VirtualBox VM '$v' is not running -- declared pause, resumes $pwhen"
    vm_paused=1; continue
  fi
  if [ "$pkind" = RESUMING ]; then
    resumed_s="$(date -u -d "$pwhen" +%s 2>/dev/null || echo 0)"
    now_s="$(date -u +%s)"
    if [ $(( now_s - resumed_s )) -lt $(( RESUME_GRACE_MIN * 60 )) ]; then
      note "VirtualBox VM '$v' is not running -- pause expired $pwhen, resume triggered, waiting for boot"
      vm_paused=1; continue
    fi  # else: grace exhausted and still not up -- falls through, loud, same as DOWN
  fi
  note "VirtualBox VM '$v' is not running -- if this is monkey, self-dev dispatch is down"; fail=1; vm_fail=1
done
for p in $EXPECT_PORTS; do
  has "$p" "$(val PORTS)" && continue
  case "$p" in
    8090) stt_note "nothing is listening on port 8090 (whisper STT) -- voice notes will fail with exit 7" ;;
    *)    zaxon_note "nothing is listening on port $p (zaxon MCP) -- the relay cannot carry a question to a human" ;;
  esac
done
for c in $EXPECT_CONTAINERS; do
  case "$c" in
    zaxon-whisper) has "$c" "$(val CONTAINERS)" || stt_note "container '$c' is not running" ;;
    zaxon-*) has "$c" "$(val CONTAINERS)" || zaxon_note "container '$c' is not running" ;;
    *)       has "$c" "$(val CONTAINERS)" || { note "container '$c' is not running"; fail=1; } ;;
  esac
done
mcp_server="$(val MCP_SERVER)"
[ -n "$mcp_server" ] || zaxon_note "zaxon MCP returned no serverInfo -- the socket is open but the relay is not answering"

stt_transcript="$(val STT)"
if [ -z "$stt_transcript" ]; then
  stt_note "STT self-test returned nothing -- could not run stt-selftest.sh in zaxon-gateway"
elif ! printf '%s' "$stt_transcript" | tr '[:upper:]' '[:lower:]' | grep -qF "$STT_EXPECT"; then
  stt_note "STT end-to-end check FAILED -- expected '$STT_EXPECT', got '$stt_transcript'"
fi
[ "$(val DOCKER)" = "active" ] || { note "dockerd is not active -- every containerised service on this host is down"; fail=1; }

# THE CHECK THAT WOULD HAVE CAUGHT THE TEN DAYS: Windows booted long before the
# distro means nobody logged in, which no service config can fix.
winboot="$(val WINBOOT)"; up_s="$(val UPTIME_S)"
if [ -n "$winboot" ] && [ -n "$up_s" ]; then
  win_epoch="$(date -u -d "$winboot" +%s 2>/dev/null)"
  if [ -n "$win_epoch" ]; then
    distro_started=$(( $(date -u +%s) - up_s ))
    drift=$(( distro_started - win_epoch ))
    if [ "$drift" -gt 3600 ]; then
      note "the Ubuntu distro started ${drift}s AFTER Windows booted -- dexter's autostart is login-scoped, so a reboot without a login leaves this host dark"
    fi
  fi
fi

# zaxon must work without monkey: one exit code cannot say which half is dark.
zaxon_status="$([ "$zaxon_fail" = 1 ] && echo DOWN || echo OK)"
vm_status="$([ "$vm_fail" = 1 ] && echo DOWN || { [ "$vm_paused" = 1 ] && echo PAUSED || echo OK; })"
stt_status="$([ "$stt_fail" = 1 ] && echo DOWN || echo OK)"

if [ "$JSON" = 1 ]; then
  printf '{"host":"%s","status":"%s","zaxon":"%s","stt":"%s","selfdev_vm":"%s","mcp_server":"%s","transcript":"%s","distros":"%s","vms":"%s","docker":"%s","findings":[' \
    "$HOST" "$([ "$fail" = 1 ] && echo DOWN || echo OK)" \
    "$zaxon_status" "$stt_status" "$vm_status" "$mcp_server" \
    "$(printf '%s' "$stt_transcript" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
    "$(val DISTROS)" "$(val VMS)" "$(val DOCKER)"
  for i in "${!findings[@]}"; do
    [ "$i" -gt 0 ] && printf ','
    printf '"%s"' "$(printf '%s' "${findings[$i]}" | sed 's/"/\\"/g')"
  done
  printf ']}\n'
else
  printf 'ZAXON (human channel): %s%s\n' "$zaxon_status" "${mcp_server:+ -- serverInfo $mcp_server}"
  printf 'STT   (voice notes):   %s%s\n' "$stt_status" "${stt_transcript:+ -- \"$stt_transcript\"}"
  printf 'MONKEY (self-dev VM): %s\n' "$vm_status"
  if [ "${#findings[@]}" -eq 0 ]; then
    echo "OK -- distros: $(val DISTROS) vms: $(val VMS) docker: $(val DOCKER)"
  else
    printf 'FINDING: %s\n' "${findings[@]}"
  fi
fi

exit $(( fail ? 5 : 0 ))
