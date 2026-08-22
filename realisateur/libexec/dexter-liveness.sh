#!/usr/bin/env bash
# dexter-liveness.sh -- is dexter actually serving what it is supposed to serve?
#
# THE OUTAGE THIS EXISTS FOR. zaxon -- the only relay that carries a question
# to a human -- was dead for ten days and nothing noticed: the service was
# `enabled` with Restart=always while the WSL distro under it never came back
# from a reboot, and a distro has no supervisor above it (hf7y/groc-mangr#9).
# Hence the last check here: dexter starts its distro and
# its VMs from the Windows Startup folder, i.e. at LOGIN. A reboot nobody logs
# in after leaves monkey -- all of self-dev -- down, and reads from the outside
# like a quiet night.
#
#   bin/dexter-liveness.sh            # human-readable, exit tells the story
#   bin/dexter-liveness.sh --json     # one object, for a status document
#
# READ-ONLY: it starts nothing, fixes nothing, writes nothing on dexter, the
# same stance as senechal's health/*.sh; `ausculte hosts` composes it.
#
# exit: 0 all good  5 something declared is down  6 BLIND (cannot reach dexter)
set -uo pipefail

HOST="${DEXTER_HOST:-dexter}"
JSON=0
[ "${1:-}" = "--json" ] && JSON=1

# THE EXPECTED SET, in one place. A thing that should be running on dexter and
# is not named here is invisible to this probe -- which is the failure mode it
# is named after, so add to it rather than writing a second checker.
EXPECT_DISTROS="Ubuntu"          # hermes joins this when it is containerised
EXPECT_VMS="monkey"              # nomac is the office VM, started by hand
EXPECT_PORTS="8643"              # zaxon MCP
# whisper joins when hf7y/crt lands it -- naming it sooner turns this red (#405)
EXPECT_CONTAINERS="zaxon-gateway zaxon-relay zaxon-watcher"

fail=0; blind=0; zaxon_fail=0; vm_fail=0; findings=()
note() { findings+=("$1"); }
zaxon_note() { note "$1"; fail=1; zaxon_fail=1; }

probe="$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes "$HOST" '
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  echo "UPTIME_S=$(cut -d. -f1 /proc/uptime)"
  echo "DOCKER=$(systemctl is-active docker 2>/dev/null)"
  echo "CONTAINERS=$(sudo -n docker ps --format "{{.Names}}" 2>/dev/null | tr "\n" "," )"
  echo "PORTS=$(ss -ltn 2>/dev/null | awk "{print \$4}" | sed "s/.*://" | sort -un | tr "\n" ",")"
  # A TCP connect is not liveness: a hung gateway still accepts one, and the
  # relay'"'"'s own docker healthcheck is a connect too. Ask the MCP layer to
  # speak. Same call shape as monkey-watch.sh; 127.0.0.1 so this survives the
  # rebind off 0.0.0.0.
  #
  # 127.0.0.1 IS CORRECT HERE -- do not "fix" it to the tailnet address to
  # match bin/lib/zaxon.sh. This whole block is an ssh payload that executes
  # ON dexter (see the wsl.exe and /mnt/c lines below), and dexter is where
  # zaxon runs. The tailnet-first ordering in zaxon.sh/ausculte.sh is for
  # callers that are NOT dexter.
  curl -s -m 15 -H "Content-Type: application/json" \
    -H "Accept: application/json,text/event-stream" \
    -X POST http://127.0.0.1:8643/mcp \
    -d '"'"'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"dexter-liveness","version":"1"}}}'"'"' 2>/dev/null \
    | tr -d "\r" | sed -n "s/.*\"serverInfo\":{[^}]*\"name\":\"\([^\"]*\)\".*/MCP_SERVER=\1/p" | head -1
  sudo -n systemctl restart systemd-binfmt 2>/dev/null
  cd /mnt/c || exit 0
  echo "DISTROS=$(/mnt/c/Windows/System32/wsl.exe -l -q --running 2>/dev/null | tr -d "\0\r" | tr "\n" ",")"
  echo "VMS=$("/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe" list runningvms 2>/dev/null | tr -d "\0" | sed "s/\" .*//;s/\"//" | tr "\n" ",")"
  echo "WINBOOT=$(/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString(\"o\")" 2>/dev/null | tr -d "\0\r")"
' 2>/dev/null)" || { blind=1; }

[ -z "$probe" ] && blind=1

if [ "$blind" = 1 ]; then
  # BLIND IS NOT OK, and it is not "down" either. Saying which is the whole
  # point -- "I could not look" reported as healthy is how ten days pass.
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
for v in $EXPECT_VMS; do
  has "$v" "$(val VMS)" || { note "VirtualBox VM '$v' is not running -- if this is monkey, self-dev dispatch is down"; fail=1; vm_fail=1; }
done
for p in $EXPECT_PORTS; do
  has "$p" "$(val PORTS)" || zaxon_note "nothing is listening on port $p (zaxon MCP) -- the relay cannot carry a question to a human"
done
for c in $EXPECT_CONTAINERS; do
  case "$c" in
    zaxon-*) has "$c" "$(val CONTAINERS)" || zaxon_note "container '$c' is not running" ;;
    *)       has "$c" "$(val CONTAINERS)" || { note "container '$c' is not running"; fail=1; } ;;
  esac
done
mcp_server="$(val MCP_SERVER)"
[ -n "$mcp_server" ] || zaxon_note "zaxon MCP returned no serverInfo -- the socket is open but the relay is not answering"
[ "$(val DOCKER)" = "active" ] || { note "dockerd is not active -- every containerised service on this host is down"; fail=1; }

# THE CHECK THAT WOULD HAVE CAUGHT THE TEN DAYS: Windows booted long before the
# distro came up means the machine came back and nobody logged in, and no amount
# of service configuration fixes that.
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
vm_status="$([ "$vm_fail" = 1 ] && echo DOWN || echo OK)"

if [ "$JSON" = 1 ]; then
  printf '{"host":"%s","status":"%s","zaxon":"%s","selfdev_vm":"%s","mcp_server":"%s","distros":"%s","vms":"%s","docker":"%s","findings":[' \
    "$HOST" "$([ "$fail" = 1 ] && echo DOWN || echo OK)" \
    "$zaxon_status" "$vm_status" "$mcp_server" \
    "$(val DISTROS)" "$(val VMS)" "$(val DOCKER)"
  for i in "${!findings[@]}"; do
    [ "$i" -gt 0 ] && printf ','
    printf '"%s"' "$(printf '%s' "${findings[$i]}" | sed 's/"/\\"/g')"
  done
  printf ']}\n'
else
  printf 'ZAXON (human channel): %s%s\n' "$zaxon_status" "${mcp_server:+ -- serverInfo $mcp_server}"
  printf 'MONKEY (self-dev VM): %s\n' "$vm_status"
  if [ "${#findings[@]}" -eq 0 ]; then
    echo "OK -- distros: $(val DISTROS) vms: $(val VMS) docker: $(val DOCKER)"
  else
    printf 'FINDING: %s\n' "${findings[@]}"
  fi
fi

exit $(( fail ? 5 : 0 ))
