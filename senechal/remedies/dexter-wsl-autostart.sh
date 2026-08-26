#!/usr/bin/env bash
# senechal: start dexter's Ubuntu WSL2 distro automatically, so the
# unattended jobs that live inside it actually run.
#
#   ./dexter-wsl-autostart.sh enable    # install the launcher + Scheduled Task on dexter
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

# --- target values, defined once, read by both verbs --------------------
DEXTER_ADDR="192.168.0.22"      # WSL2 mirrored networking -> dexter's LAN address
DEXTER_PORT="2223"              # the distro's own sshd; port 22 is native Windows OpenSSH
DEXTER_USER="zach"
DEXTER_KEY="$HOME/.ssh/id_dexter_gardien"
TASK_NAME="wsl-ubuntu-autostart"
DISTRO="Ubuntu"
VBS_WIN='C:\Users\Zach\wsl-autostart.vbs'
VBS_WSL="/mnt/c/Users/Zach/wsl-autostart.vbs"
XML_WIN='C:\Users\Zach\wsl-autostart-task.xml'
XML_WSL="/mnt/c/Users/Zach/wsl-autostart-task.xml"
SYS32="/mnt/c/Windows/System32"
TIMEOUT=10
# No-elevation fallback. Verified 2026-07-28: an ssh-into-WSL session gets
# a UAC-filtered token, so registering a root-folder Scheduled Task is
# refused even though zach is an Administrator -- and UAC has no remote
# consent path, so no command fixes that from here. The Startup folder
# needs no elevation and fires at logon, which is when the task would
# have fired anyway (dexter has no autologon).
STARTUP_WSL="/mnt/c/Users/Zach/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup"
STARTUP_WIN='C:\Users\Zach\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
STARTUP_NAME="senechal-wsl-autostart.vbs"
STARTUP_USED=0

# Run a command inside dexter's WSL2 distro. Every Windows binary is
# called by full path: System32 is NOT on that session's PATH, so a bare
# `schtasks.exe` there fails with "command not found" and would otherwise
# look like the task tooling is missing.
#
# Three variants, because the difference bit once already:
#   dex     - probe. stdin from /dev/null, stderr discarded.
#   dex_in  - write. MUST NOT redirect stdin, or the piped content is
#             silently replaced by nothing and you get a 0-byte file on
#             dexter plus a baffling "Could not read XML file".
#   dex_e   - run and keep stderr, so Windows' own error text survives.
dex() {
  ssh -i "$DEXTER_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
      -o ConnectTimeout="$TIMEOUT" -p "$DEXTER_PORT" \
      "$DEXTER_USER@$DEXTER_ADDR" "$@" </dev/null 2>/dev/null
}

dex_in() {
  ssh -i "$DEXTER_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
      -o ConnectTimeout="$TIMEOUT" -p "$DEXTER_PORT" \
      "$DEXTER_USER@$DEXTER_ADDR" "$@" 2>/dev/null
}

dex_e() {
  ssh -i "$DEXTER_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
      -o ConnectTimeout="$TIMEOUT" -p "$DEXTER_PORT" \
      "$DEXTER_USER@$DEXTER_ADDR" "$@" </dev/null 2>&1
}

# Write stdin to a path on dexter and prove it is non-empty. A silent
# 0-byte write is the exact failure this function exists to make loud.
dex_write() {
  local dest="$1" label="$2"
  dex_in "cat > '$dest'" || die "could not write $dest"
  local size; size="$(dex "stat -c %s '$dest' 2>/dev/null")"
  case "$size" in
    ''|0) die "$label wrote 0 bytes to $dest -- the content never reached dexter. Nothing was registered; re-run enable." ;;
  esac
  say "  wrote $size bytes"
}

dex_up() { dex 'exit 0'; }

# The hidden launcher. WScript.Shell.Run(cmd, 0, False) = no console
# window, do not block. `exec sleep infinity` is the anchor process that
# keeps the distro from shutting down once the launching command exits.
vbs_body() {
  cat <<'VBS'
' wsl-autostart.vbs -- start the Ubuntu WSL2 distro and hold it open.
' Owner: senechal (host health). Installed by senechal's
' remedies/dexter-wsl-autostart.sh -- edit that, not this copy.
'
' ssh.socket is already systemd-enabled inside the distro, so nothing
' here starts sshd; booting the distro is sufficient. The sleep anchor
' exists because WSL tears the VM down when its last process exits.
' Run hidden (0), do not wait (False).
'
' Retire: schtasks /delete /tn "wsl-ubuntu-autostart" /f, then delete
' this file and C:\Users\Zach\wsl-autostart-task.xml.
CreateObject("WScript.Shell").Run "wsl.exe -d Ubuntu --exec /bin/sh -c ""exec sleep infinity""", 0, False
VBS
}

# Task definition. LogonTrigger + InteractiveToken + LeastPrivilege
# mirrors the crt-whisper-server task already working on this host.
# ExecutionTimeLimit PT0S = no time limit: this process is meant to live
# as long as the login session does.
task_xml() {
  cat <<'XML'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>senechal: start the Ubuntu WSL2 distro at logon so distro-hosted timers (gardien backup, gardien git-hygiene) actually fire.</Description>
    <URI>\wsl-ubuntu-autostart</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>C:\Windows\System32\wscript.exe</Command>
      <Arguments>"C:\Users\Zach\wsl-autostart.vbs"</Arguments>
    </Exec>
  </Actions>
</Task>
XML
}

# The no-elevation path. Windows runs anything dropped in the Startup
# folder at logon, .vbs included (wscript is the registered handler), so
# this needs no .lnk and no admin -- only the ability to write one file
# into the user's own profile, which the SSH session already has.
install_startup_fallback() {
  if ! dex "test -d '$STARTUP_WSL'"; then
    die "no Startup folder at $STARTUP_WSL -- cannot fall back. Register the task by hand from an elevated prompt on dexter:
    schtasks /create /tn $TASK_NAME /xml \"$XML_WIN\" /f"
  fi
  say ""
  say "installing $STARTUP_WIN\\$STARTUP_NAME"
  vbs_body | sed 's/$/\r/' | dex_write "$STARTUP_WSL/$STARTUP_NAME" "startup entry"

  # Witness: run the launcher exactly as logon will, and prove the anchor
  # appears. Existence of the file is not evidence that it works.
  say ""
  say "confirming it works by running it the way logon will"
  local before after
  before="$(dex "pgrep -fc 'sleep infinity' 2>/dev/null" | tr -d '\r')"
  dex "cd /mnt/c && $SYS32/wscript.exe '$STARTUP_WIN\\$STARTUP_NAME'" >/dev/null
  sleep 3
  after="$(dex "pgrep -fc 'sleep infinity' 2>/dev/null" | tr -d '\r')"
  if [ "${after:-0}" -gt 0 ]; then
    say "confirmed: keepalive anchor running inside the distro (was ${before:-0}, now ${after:-0})."
  else
    warn "the startup entry is installed but running it produced no 'sleep infinity'"
    warn "anchor in the distro. It will probably not work at logon either --"
    warn "run it by hand on dexter and watch for an error before trusting this."
  fi
  STARTUP_USED=1
}

task_registered() {
  dex "$SYS32/schtasks.exe /query /tn $TASK_NAME" | tr -d '\000' | grep -qi "$TASK_NAME"
}

do_enable() {
  say "senechal remedy: autostart the $DISTRO WSL2 distro on dexter"
  say ""

  [ -f "$DEXTER_KEY" ] || die "no key at $DEXTER_KEY -- that is the key authorized in dexter's WSL2 authorized_keys; without it this script cannot reach the distro"

  if ! dex_up; then
    die "cannot reach dexter's distro at $DEXTER_ADDR:$DEXTER_PORT.

That is very likely THIS EXACT BUG: the distro is down, which is the
condition this remedy prevents. Bring it up by hand first -- on dexter,
open a terminal and run:  wsl -d $DISTRO
then re-run: ./dexter-wsl-autostart.sh enable"
  fi
  say "reached the distro over ssh:$DEXTER_PORT."

  if task_registered; then
    say "a task named \"$TASK_NAME\" is already registered -- re-registering it (this is safe to re-run; /f overwrites)."
  fi

  # Back up anything we are about to overwrite, per the remedies contract.
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  for f in "$VBS_WSL" "$XML_WSL"; do
    if dex "test -f '$f'"; then
      dex "cp '$f' '$f.bak.$stamp'" && say "backed up $f -> $f.bak.$stamp"
    fi
  done
  if task_registered; then
    dex "$SYS32/schtasks.exe /query /tn $TASK_NAME /xml" | tr -d '\000' > "./$TASK_NAME.pre-enable.$stamp.xml" \
      && say "saved the previous task definition here: remedies/$TASK_NAME.pre-enable.$stamp.xml"
  fi

  say "installing the hidden launcher at $VBS_WIN"
  # CRLF for a native Windows script file.
  vbs_body | sed 's/$/\r/' | dex_write "$VBS_WSL" "launcher"

  say "installing the task definition at $XML_WIN"
  # schtasks /create /xml requires UTF-16LE *with a BOM*, matching the
  # XML declaration. The BOM is not decoration: without the leading
  # FF FE, schtasks reads the first two bytes as content and fails with
  # "(1,2)::ERROR: one root element" -- an error that sounds like the
  #   [rest: vault:senechal/header-archaeology-20260818.md]
  { printf '\xff\xfe'; task_xml | iconv -f UTF-8 -t UTF-16LE; } | dex_write "$XML_WSL" "task XML"

  say "registering Scheduled Task \"$TASK_NAME\""
  local out
  out="$(dex_e "cd /mnt/c && $SYS32/schtasks.exe /create /tn $TASK_NAME /xml '$XML_WIN' /f" | tr -d '\000' | tr -d '\r')"
  if ! task_registered; then
    warn "schtasks said: ${out:-(no output at all -- that itself is a bug here, not a Windows answer)}"
    # Read Windows' own words rather than assuming the usual cause. Both
    # earlier failures of this remedy were misdiagnosed as elevation.
    case "$out" in
      *"denied"*|*"Denied"*)
        say ""
        say "access denied: an ssh-into-WSL session holds a FILTERED token."
        say "zach is in Administrators on dexter, but UAC hands this session the"
        say "unelevated half, and writing into the root Task Scheduler folder"
        say "needs the elevated one. UAC has no remote consent path, so this"
        say "cannot be fixed from here at all -- not with a better command."
        say ""
        say "falling back to the Startup folder, which needs no elevation."
        say "this is not a downgrade in behaviour: the task was LOGON-triggered"
        say "anyway (dexter has no autologon), and a Startup entry fires at"
        say "exactly the same moment. What it gives up is Task Scheduler's run"
        say "history and Last Run Result, which are debugging comforts, not"
        say "function. The Startup folder runs .vbs directly via wscript, so"
        say "the launcher is the same file."
        install_startup_fallback ;;
      *"malformed"*|*"root element"*|*"Could not read XML"*)
        die "schtasks could not parse $XML_WIN. This is senechal's bug, not yours and not a permission problem -- the file is generated by task_xml() in this script. Check its encoding first (it must be UTF-16LE *with* a BOM) before suspecting the markup." ;;
      *)
        die "the task did not register, and the error above is not one this script recognises. Do not assume elevation -- report the exact text." ;;
    esac
  else
    say "registered: $out"

    say ""
    say "confirming it works by running the task now (the distro is already up,"
    say "so this proves the ACTION is valid, not that boot-time start works)"
    dex "cd /mnt/c && $SYS32/schtasks.exe /run /tn $TASK_NAME" >/dev/null
    if dex "pgrep -f 'sleep infinity' >/dev/null"; then
      say "confirmed: the keepalive anchor process is running inside the distro."
    else
      warn "ran the task but found no 'sleep infinity' anchor in the distro -- the"
      warn "task exists but its action may not be doing what it should. Check"
      warn "Task Scheduler's Last Run Result on dexter before trusting this."
    fi
  fi

  say ""
  say "steps this script could NOT do for you:"
  say "  - THE IMPORTANT ONE: dexter has no autologon, so this fires at"
  say "    LOGON, not at boot. After an unattended reboot the distro stays"
  say "    down until someone logs in -- and gardien's timers stay silent."
  say "    To close that gap you must decide, and do, one of:"
  say "      (a) enable autologon on dexter (Sysinternals Autologon stores the"
  say "          password in LSA rather than plaintext in the registry), which"
  say "          makes this task effectively boot-triggered; or"
  say "      (b) accept logon-only start, and treat 'dexter timer reported"
  say "          nothing' as suspicious rather than healthy."
  say "    senechal cannot make that call -- it is a security preference."
  say "  - a real reboot test. Reboot dexter, do NOT log in, and check whether"
  say "    port $DEXTER_PORT answers; then log in and check again. That is the only"
  say "    witness that distinguishes (a) from (b) in practice."
  say ""
  if [ "$STARTUP_USED" = 1 ]; then
    say "  - registering the Scheduled Task, which is the nicer mechanism (run"
    say "    history, Last Run Result). If you ever want it, run this from an"
    say "    ELEVATED prompt on dexter -- the XML is already in place:"
    say "        schtasks /create /tn $TASK_NAME /xml \"$XML_WIN\" /f"
    say "    and then delete the Startup entry so it does not fire twice."
  fi
  say ""
  say "to retire:"
  if [ "$STARTUP_USED" = 1 ]; then
    say "    del \"$STARTUP_WIN\\$STARTUP_NAME\""
  else
    say "    schtasks /delete /tn $TASK_NAME /f"
  fi
  say "  then delete $VBS_WIN and $XML_WIN"
}

do_verify() {
  if [ ! -f "$DEXTER_KEY" ]; then
    skip "no key at $DEXTER_KEY -- cannot probe dexter's distro from here"
    finish_verify
  fi

  if ! ping -c1 -W2 "$DEXTER_ADDR" >/dev/null 2>&1; then
    skip "dexter ($DEXTER_ADDR) is not answering ping -- cannot check while the host is off"
    finish_verify
  fi

  # The distro being reachable at all IS half the concern: this port only
  # answers when the distro is running.
  if dex_up; then
    ok "distro is up: ssh $DEXTER_ADDR:$DEXTER_PORT answers"
  else
    fail "dexter is up but its WSL2 distro is NOT (ssh $DEXTER_ADDR:$DEXTER_PORT refused) -- any gardien timer inside it is silently not running. Start it on dexter with: wsl -d $DISTRO"
    finish_verify
  fi

  # Either mechanism satisfies the concern; both firing is a warning, not
  # a pass, because a duplicate is a retirement hazard rather than a fault.
  local have_task=0 have_startup=0
  task_registered && have_task=1
  dex "test -f '$STARTUP_WSL/$STARTUP_NAME'" && have_startup=1

  if [ "$have_task" = 1 ] && [ "$have_startup" = 1 ]; then
    warn_ "BOTH the Scheduled Task and the Startup entry are installed -- they fire at the same moment. Harmless (WSL attaches to the running distro) but retire one: del \"$STARTUP_WIN\\$STARTUP_NAME\""
  elif [ "$have_task" = 1 ]; then
    ok "Scheduled Task \"$TASK_NAME\" is registered on dexter"
  elif [ "$have_startup" = 1 ]; then
    ok "Startup entry present: $STARTUP_WIN\\$STARTUP_NAME (fires at logon; no elevation needed)"
  else
    fail "neither the Scheduled Task nor a Startup entry is installed -- the distro is up by hand, not by autostart, and will not come back after a reboot. Run: ./dexter-wsl-autostart.sh enable"
  fi

  # The launcher the Scheduled Task points at. The Startup entry is a
  # self-contained copy, so it does not depend on this file existing.
  if [ "$have_task" = 1 ]; then
    if dex "test -f '$VBS_WSL'"; then
      ok "launcher present: $VBS_WIN"
    else
      fail "launcher $VBS_WIN is missing -- the task will fail when it fires. Run: ./dexter-wsl-autostart.sh enable"
    fi
  fi

  # sshd inside the distro is socket-activated; if that regressed, the
  # distro could boot and still be unreachable, which looks identical to
  # "distro down" from outside.
  if dex 'systemctl is-enabled ssh.socket 2>/dev/null | grep -q enabled'; then
    ok "ssh.socket is systemd-enabled inside the distro (sshd returns on its own after a distro boot)"
  else
    fail "ssh.socket is NOT enabled inside the distro -- it would boot but stay unreachable on $DEXTER_PORT. Fix on dexter: sudo systemctl enable --now ssh.socket"
  fi

  finish_verify "OK -- dexter's WSL2 distro is up and set to start at logon. Note: logon, not boot (no autologon on dexter)."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
