#!/usr/bin/env bash
VMHOST_VBOX="${VMHOST_VBOX:-/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe}"  # vmhost.sh: backend-neutral VM-host vocabulary (#563) -- VMHOST_BACKEND=hyperv swaps the driver, not every call site

vmhost_backend() {  # "virtualbox" | "unknown", from $VMHOST_BACKEND or detected via $VMHOST_VBOX
  if [ -n "${VMHOST_BACKEND:-}" ]; then
    printf '%s\n' "$VMHOST_BACKEND"
  elif [ -x "$VMHOST_VBOX" ]; then
    printf 'virtualbox\n'
  else
    printf 'unknown\n'
  fi
}

_vmhost_require_vbox() {
  [ -x "$VMHOST_VBOX" ] && return 0
  printf 'vmhost: VBoxManage not at %s\n' "$VMHOST_VBOX" >&2
  return 2
}

vmhost_require() {  # 0 if the active backend can be driven, else 2 and a reason on stderr
  case "$(vmhost_backend)" in
    virtualbox) _vmhost_require_vbox ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

_vbm() { "$VMHOST_VBOX" "$@" < /dev/null 2>&1 | tr -d '\0\r'; }

vmhost_state() {  # <vm> -> running | poweroff | paused | unknown
  local vm="$1" s
  case "$(vmhost_backend)" in
    virtualbox)
      _vmhost_require_vbox || return 2
      s="$(_vbm showvminfo "$vm" --machinereadable | grep '^VMState=' | cut -d'"' -f2)"
      printf '%s\n' "${s:-unknown}"
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_disk_raw() {  # <vm> -> the backend's own disk descriptor, published as-is
  local vm="$1"
  case "$(vmhost_backend)" in
    virtualbox)
      _vmhost_require_vbox || return 2
      _vbm showvminfo "$vm" --machinereadable | grep '^"SATA-0-0"=' | cut -d'"' -f4
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_classify_disk() {  # <raw> -> internal | EXTERNAL-USB | unknown -- pure, no host round-trip
  local d="$1"
  case "$(vmhost_backend)" in
    virtualbox)
      case "$d" in
        C:*) printf 'internal\n' ;;
        D:*) printf 'EXTERNAL-USB\n' ;;
        *)   printf 'unknown\n' ;;
      esac
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_disk() {  # <vm> -> vmhost_disk_raw, then vmhost_classify_disk
  local vm="$1" d
  d="$(vmhost_disk_raw "$vm")" || return 2
  vmhost_classify_disk "$d"
}

vmhost_screenshot() {  # <vm> <path> -- capture the VM console to <path> as a PNG
  local vm="$1" path="$2"
  case "$(vmhost_backend)" in
    virtualbox)
      _vmhost_require_vbox || return 2
      _vbm controlvm "$vm" screenshotpng "$path" >/dev/null
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}

vmhost_logdir() {  # <vm> -> log directory as a path THIS host can read; VBox answers `C:\Users\...` on Windows, translated here not at the call site (#639)
  local vm="$1" d
  case "$(vmhost_backend)" in
    virtualbox)
      _vmhost_require_vbox || return 2
      d="$(_vbm showvminfo "$vm" --machinereadable | grep '^LogFldr=' | cut -d'"' -f2)"
      [ -n "$d" ] || return 0
      printf '%s\n' "$d" | sed 's|\\|/|g; s|^\([A-Za-z]\):|/mnt/\L\1|'
      ;;
    *) printf 'vmhost: backend "%s" has no driver\n' "$(vmhost_backend)" >&2; return 2 ;;
  esac
}
