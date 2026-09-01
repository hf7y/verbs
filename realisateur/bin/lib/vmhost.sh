#!/usr/bin/env bash
VMHOST_VBOX="${VMHOST_VBOX:-/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe}"  # vmhost.sh: backend-neutral VM-host vocabulary (#563) -- VMHOST_BACKEND=hyperv swaps the driver, not every call site
VMHOST_WSL="${VMHOST_WSL:-/mnt/c/Windows/System32/wsl.exe}"  # the wsl backend's driver: monkey is decided to become a WSL2 distro on dexter, so the vocabulary has to survive VirtualBox being deleted

VMHOST_REG="${VMHOST_REG:-/mnt/c/Windows/System32/reg.exe}"  # the wsl backend keeps a distro's disk location in the registry, not in any wsl.exe subcommand

_VMHOST_WSL_DISTROS=""
_vmhost_wsl_has() {  # <name> -- is there a WSL distro by that name? one launch per process, then cached
  [ -x "$VMHOST_WSL" ] || return 1
  [ -n "$_VMHOST_WSL_DISTROS" ] || _VMHOST_WSL_DISTROS="$(_wsl -l -q)"
  printf '%s\n' "$_VMHOST_WSL_DISTROS" | grep -qx "$1"
}

vmhost_backend() {  # [vm] -> "virtualbox" | "wsl" | "unknown", from $VMHOST_BACKEND or detected from the drivers present
  local vm="${1:-}"
  if [ -n "${VMHOST_BACKEND:-}" ]; then
    printf '%s\n' "$VMHOST_BACKEND"
  elif [ -n "$vm" ] && [ -x "$VMHOST_VBOX" ] && [ -x "$VMHOST_WSL" ] && _vmhost_wsl_has "$vm"; then
    printf 'wsl\n'   # both drivers installed is the migration window: a live distro by that name wins over a VirtualBox registration that may be a leftover
  elif [ -x "$VMHOST_VBOX" ]; then
    printf 'virtualbox\n'
  elif [ -x "$VMHOST_WSL" ]; then
    printf 'wsl\n'
  else
    printf 'unknown\n'
  fi
}

_vmhost_require_vbox() {
  [ -x "$VMHOST_VBOX" ] && return 0
  printf 'vmhost: VBoxManage not at %s\n' "$VMHOST_VBOX" >&2
  return 2
}

_vmhost_require_wsl() {
  [ -x "$VMHOST_WSL" ] && return 0
  printf 'vmhost: wsl.exe not at %s\n' "$VMHOST_WSL" >&2
  return 2
}

vmhost_require() {  # [vm] -- 0 if the active backend can be driven, else 2 and a reason on stderr
  case "$(vmhost_backend "${1:-}")" in
    virtualbox) _vmhost_require_vbox ;;
    wsl) _vmhost_require_wsl ;;
    unknown) printf 'vmhost: no VM host driver here (no VBoxManage at %s, no wsl.exe at %s)\n' "$VMHOST_VBOX" "$VMHOST_WSL" >&2; return 2 ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

_vbm() { "$VMHOST_VBOX" "$@" < /dev/null 2>&1 | tr -d '\0\r'; }
_wsl() { "$VMHOST_WSL" "$@" < /dev/null 2>&1 | tr -d '\0\r'; }
_reg() { "$VMHOST_REG" "$@" < /dev/null 2>/dev/null | tr -d '\0\r'; }

_vmhost_wsl_basepath() {  # <distro> -> where the distro's ext4.vhdx lives, in Windows coordinates
  _reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss' /s | awk -v want="$1" '
    /^HKEY_/               { base=""; name=""; next }
    $1=="BasePath"         { $1=""; $2=""; sub(/^[ \t]+/,""); base=$0 }
    $1=="DistributionName" { $1=""; $2=""; sub(/^[ \t]+/,""); name=$0 }
    name==want && base!="" { print base; exit }
  '
}

vmhost_state() {  # <vm> -> running | poweroff | paused | unknown
  local vm="$1" s
  case "$(vmhost_backend "$vm")" in
    virtualbox)
      _vmhost_require_vbox || return 2
      s="$(_vbm showvminfo "$vm" --machinereadable | grep '^VMState=' | cut -d'"' -f2)"
      printf '%s\n' "${s:-unknown}"
      ;;
    wsl)
      _vmhost_require_wsl || return 2
      if _wsl -l -q --running | grep -qx "$vm"; then printf 'running\n'; else printf 'poweroff\n'; fi  # a stopped distro holds no RAM, so --running answers the only question this vocabulary asks
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_disk_raw() {  # <vm> -> the backend's own disk descriptor, published as-is
  local vm="$1"
  case "$(vmhost_backend "$vm")" in
    virtualbox)
      _vmhost_require_vbox || return 2
      _vbm showvminfo "$vm" --machinereadable | grep '^"SATA-0-0"=' | cut -d'"' -f4
      ;;
    wsl)
      _vmhost_require_wsl || return 2
      _vmhost_wsl_basepath "$vm"
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_classify_disk() {  # <raw> -> internal | EXTERNAL-USB | unknown -- pure, no host round-trip
  local d="${1#\\\\?\\}"   # the drive letter IS the classification, so asking which backend produced it bought nothing -- and cost: asked with no vm name it classed every WSL disk virtualbox. A wsl BasePath may arrive as \\?\C:\... ; VirtualBox never does
  case "$d" in
    [Cc]:*) printf 'internal\n' ;;
    [Dd]:*) printf 'EXTERNAL-USB\n' ;;
    *)      printf 'unknown\n' ;;
  esac
}

vmhost_disk() {  # <vm> -> vmhost_disk_raw, then vmhost_classify_disk
  local vm="$1" d
  d="$(vmhost_disk_raw "$vm")" || return 2
  vmhost_classify_disk "$d"
}

vmhost_screenshot() {  # <vm> <path> -- capture the VM console to <path> as a PNG
  local vm="$1" path="$2"
  case "$(vmhost_backend "$vm")" in
    virtualbox)
      _vmhost_require_vbox || return 2
      _vbm controlvm "$vm" screenshotpng "$path" >/dev/null
      ;;
    wsl)
      return 4   # GAP, not a driver error: a distro has no framebuffer. Silent, because monkey-watch asks every 10 minutes and stderr here lands in cron mail
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_save() {  # <vm> -- suspend to disk and free the host's RAM. savestate, not acpipowerbutton: #704 measured the VM still `running` 60s after an ACPI request
  local vm="$1"
  case "$(vmhost_backend "$vm")" in
    virtualbox)
      _vmhost_require_vbox || return 2
      _vbm controlvm "$vm" savestate >/dev/null
      ;;
    wsl)
      _vmhost_require_wsl || return 2
      _wsl --terminate "$vm" >/dev/null  # --terminate, NEVER --shutdown: --shutdown stops EVERY distro including dexter's own Ubuntu, the route in; terminating one distro is what returns its RAM to the host
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_save_cmd() {  # <vm> -- the exact command vmhost_save would run, so a dry run can print it rather than describe it
  local vm="$1"
  case "$(vmhost_backend "$vm")" in
    virtualbox) printf '%s controlvm %s savestate\n' "$VMHOST_VBOX" "$vm" ;;
    wsl)        printf '%s --terminate %s\n' "$VMHOST_WSL" "$vm" ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_running_vms_cmd() {  # -> the command that lists running VM names, one per line, on the VM HOST -- for a payload that runs THERE and so cannot source this file. Every driver present answers: detection picks one ACTUATOR, because savestate and --terminate are exclusive, and a read-only listing is not
  printf '%s\n' "{ [ -x \"$VMHOST_VBOX\" ] && \"$VMHOST_VBOX\" list runningvms | sed 's/\" .*//;s/\"//'; [ -x \"$VMHOST_WSL\" ] && \"$VMHOST_WSL\" -l -q --running; } 2>/dev/null | tr -d '\\0\\r'"
}

vmhost_start() {  # <vm> -- resume from a saved state or cold-boot; $VMHOST_START_TYPE overrides the default headless launch
  local vm="$1"
  case "$(vmhost_backend "$vm")" in
    virtualbox)
      _vmhost_require_vbox || return 2
      _vbm startvm "$vm" --type "${VMHOST_START_TYPE:-headless}" >/dev/null
      ;;
    wsl)
      _vmhost_require_wsl || return 2
      _wsl -d "$vm" --exec /bin/true >/dev/null  # a distro boots by being run in; $VMHOST_START_TYPE is a VirtualBox notion and does not apply
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_pause_dir() {  # -> the directory pause declarations live in, overridable for tests
  printf '%s\n' "${VMHOST_PAUSE_DIR:-$HOME/.local/state}"
}

vmhost_pause_file() {  # <vm> -> the path of that vm's declaration, if any
  printf '%s/vmhost-pause-%s\n' "$(vmhost_pause_dir)" "$1"
}

vmhost_pause_field() {  # <vm> <field> -> the field's value, or empty if no declaration or no such field
  local f; f="$(vmhost_pause_file "$1")"
  [ -f "$f" ] || return 0
  sed -n "s/^$2=//p" "$f" | head -1
}

vmhost_pause_declare() {  # <vm> <until-iso8601> -- record the absolute expiry; does not touch the VM
  local vm="$1" until="$2" f
  f="$(vmhost_pause_file "$vm")"
  mkdir -p "$(dirname "$f")"
  printf 'until=%s\ndeclared_at=%s\n' "$until" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$f"
}

vmhost_pause_mark_resumed() {  # <vm> <now-iso8601> -- the actuator fired; keep `until` for the record, add `resumed_at`
  local vm="$1" now="$2" until f
  until="$(vmhost_pause_field "$vm" until)"
  [ -n "$until" ] || return 0
  f="$(vmhost_pause_file "$vm")"
  printf 'until=%s\nresumed_at=%s\n' "$until" "$now" > "$f"
}

vmhost_pause_clear() {  # <vm> -- remove the declaration outright: the pause cycle is over
  rm -f "$(vmhost_pause_file "$1")"
}

vmhost_pause_eval() {  # <until> <resumed_at> <now-iso8601> -- split out of vmhost_pause_status so ssh-fetched fields and monkey-watch.sh's file-read fields share one comparison
  local until="$1" resumed_at="$2" now="$3" now_s until_s
  [ -n "$until" ] || { printf 'NONE\n'; return 0; }
  if [ -n "$resumed_at" ]; then printf 'RESUMING %s\n' "$resumed_at"; return 0; fi
  now_s="$(date -u -d "$now" +%s 2>/dev/null)"
  until_s="$(date -u -d "$until" +%s 2>/dev/null)"
  if [ -z "$now_s" ] || [ -z "$until_s" ]; then printf 'NONE\n'; return 0; fi  # unparseable is NONE, not a guess either way -- caller falls through to vmhost_state
  if [ "$now_s" -lt "$until_s" ]; then
    printf 'PAUSED %s\n' "$until"
  else
    printf 'EXPIRED %s\n' "$until"
  fi
}

vmhost_pause_status() {  # <vm> <now-iso8601> -> vmhost_pause_eval, fed from this vm's own declaration file
  local vm="$1" now="$2"
  vmhost_pause_eval "$(vmhost_pause_field "$vm" until)" "$(vmhost_pause_field "$vm" resumed_at)" "$now"
}

vmhost_logdir() {  # <vm> -> the VM's log directory, as a path THIS host can read
  # The backend answers in its own coordinates -- VirtualBox on a Windows host
  # says `C:\Users\...`, which is not a path dexter's WSL side can open. The
  # translation is as backend-specific as the query, so it lives here with it
  # rather than at the call site (#639's clock probe was the call site).
  local vm="$1" d
  case "$(vmhost_backend "$vm")" in
    virtualbox)
      _vmhost_require_vbox || return 2
      d="$(_vbm showvminfo "$vm" --machinereadable | grep '^LogFldr=' | cut -d'"' -f2)"
      [ -n "$d" ] || return 0
      printf '%s\n' "$d" | sed 's|\\|/|g; s|^\([A-Za-z]\):|/mnt/\L\1|'
      ;;
    wsl)
      return 0   # a distro has no VMM and so no VMM log; empty is the honest answer, and it is what the virtualbox arm already returns when LogFldr is empty
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}
