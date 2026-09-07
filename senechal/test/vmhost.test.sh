#!/usr/bin/env bash
set -uo pipefail  # SUBJECT: bin/lib/vmhost.sh -- pins the virtualbox backend against a stub VBoxManage as an inert wrap of the old vbm() call shape (#563)
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
harness_tmp

echo "vmhost.test.sh"

FAKE="$T/VBoxManage.exe"  # showvminfo prints $FAKE_VMINFO; controlvm screenshotpng writes a dummy PNG
FAKE_VMINFO="$T/vminfo"
cat > "$FAKE" <<STUB
#!/usr/bin/env bash
case "\$1" in
  showvminfo) cat "$FAKE_VMINFO" ;;
  controlvm)  [ "\$3" = screenshotpng ] && printf '\x89PNG-fake' > "\$4" ;;
esac
STUB
chmod +x "$FAKE"
printf 'VMState="running"\n"SATA-0-0"="C:\\VMs\\monkey.vdi"\n' > "$FAKE_VMINFO"

VMHOST_VBOX="$FAKE"
. "$REPO/bin/lib/vmhost.sh"

section "A. backend detection"
unset VMHOST_BACKEND
eq "A1 an executable VBoxManage at \$VMHOST_VBOX detects as virtualbox" "$(vmhost_backend)" "virtualbox"
eq "A2 no VBoxManage and no override detects as unknown" \
  "$(VMHOST_VBOX="$T/nowhere" vmhost_backend)" "unknown"
eq "A3 \$VMHOST_BACKEND overrides detection" "$(VMHOST_BACKEND=hyperv vmhost_backend)" "hyperv"

section "B. vmhost_require -- the fail-loud precondition monkey-watch.sh calls"
vmhost_require; rc "B1 virtualbox backend with VBoxManage present succeeds" 0 $?
VMHOST_VBOX="$T/nowhere" vmhost_require 2>/dev/null; rc "B2 virtualbox backend with VBoxManage missing fails" 2 $?
VMHOST_BACKEND=hyperv vmhost_require 2>/dev/null; rc "B3 an unimplemented backend fails, not silently no-ops" 2 $?

section "C. vmhost_state -- wraps showvminfo verbatim (#563's 'inert refactor')"
eq "C1 reads VMState out of --machinereadable" "$(vmhost_state monkey)" "running"
printf 'VMState="poweroff"\n' > "$FAKE_VMINFO"
eq "C2 a different fixture value passes through unchanged" "$(vmhost_state monkey)" "poweroff"
printf '' > "$FAKE_VMINFO"
eq "C3 no VMState line at all reads unknown, not empty" "$(vmhost_state monkey)" "unknown"

section "D. vmhost_disk_raw / vmhost_classify_disk -- the value monkey-watch.sh publishes as-is, and its classing"
printf '"SATA-0-0"="C:\\VMs\\monkey.vdi"\n' > "$FAKE_VMINFO"
eq "D1 the raw descriptor passes through for publishing" "$(vmhost_disk_raw monkey)" 'C:\VMs\monkey.vdi'
eq "D2 a C: drive letter classes internal" "$(vmhost_classify_disk 'C:\VMs\monkey.vdi')" "internal"
eq "D3 a D: drive letter classes EXTERNAL-USB -- the outage this exists to catch" \
  "$(vmhost_classify_disk 'D:\VMs\monkey.vdi')" "EXTERNAL-USB"
eq "D4 anything else classes unknown, not a guess" "$(vmhost_classify_disk '')" "unknown"
printf '"SATA-0-0"="D:\\VMs\\monkey.vdi"\n' > "$FAKE_VMINFO"
eq "D5 vmhost_disk composes raw + classify against a live fixture" "$(vmhost_disk monkey)" "EXTERNAL-USB"

section "E. vmhost_screenshot -- the #560 console capture, via the backend"
SHOT="$T/console.png"
rm -f "$SHOT"
vmhost_screenshot monkey "$SHOT"
[ -s "$SHOT" ] && ok "E1 a screenshot lands at the given path" || bad "E1 a screenshot lands at the given path" "nothing written to $SHOT"

section "G. vmhost_logdir -- the query AND the path translation, both backend-specific (#639)"
printf 'LogFldr="C:\\Users\\zach\\VirtualBox VMs\\monkey\\Logs"\n' > "$FAKE_VMINFO"
eq "G1 the folder comes from the backend, and lands in coordinates this host can open" \
  "$(vmhost_logdir monkey)" "/mnt/c/Users/zach/VirtualBox VMs/monkey/Logs"
printf '' > "$FAKE_VMINFO"
eq "G2 no LogFldr line yields nothing, so the caller skips rather than reading /VBox.log" \
  "$(vmhost_logdir monkey)" ""

section "F. an unsupported backend fails loud on every verb, not just detection"
VMHOST_BACKEND=hyperv vmhost_state monkey 2>/dev/null; rc "F1 vmhost_state" 2 $?
VMHOST_BACKEND=hyperv vmhost_disk_raw monkey 2>/dev/null; rc "F2 vmhost_disk_raw" 2 $?
VMHOST_BACKEND=hyperv vmhost_screenshot monkey "$T/x.png" 2>/dev/null; rc "F3 vmhost_screenshot" 2 $?
VMHOST_BACKEND=hyperv vmhost_logdir monkey 2>/dev/null; rc "F4 vmhost_logdir" 2 $?

summary
