#!/usr/bin/env bash
# monkey-vm.sh -- create the self-dev host: a VirtualBox guest named `monkey`.
#
#   [rest: vault:realisateur/guard-archaeology-20260817.md]

set -euo pipefail

VM="${MONKEY_VM_NAME:-monkey}"
VBM="${VBOXMANAGE:-/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe}"
ISO_DIR="${MONKEY_ISO_DIR:-/mnt/c/Users/Zach/Downloads}"
ISO_NAME="${MONKEY_ISO_NAME:-ubuntu-24.04.4-live-server-amd64.iso}"
ISO_SHA="${MONKEY_ISO_SHA:-e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433}"
VM_USER="${MONKEY_USER:-zach}"
HOSTFWD_PORT="${MONKEY_SSH_PORT:-2225}"
RAM_MB="${MONKEY_RAM_MB:-6144}"
CPUS="${MONKEY_CPUS:-4}"
DISK_MB="${MONKEY_DISK_MB:-122880}"

# The SHORT hostname must be exactly `monkey`. scheduler resolves
# schedule/_paced.$(hostname -s).conf, _runner.$(hostname -s).conf and
#   [rest: vault:realisateur/guard-archaeology-20260817.md]
FQDN="${MONKEY_FQDN:-monkey.selfdev.local}"

# Windows-native path string, passed verbatim to VBoxManage.exe. NEVER
# /mnt/d/... -- the hypervisor is a Windows process and does not know that path.
BASEFOLDER="${MONKEY_BASEFOLDER:-D:\\VirtualBox VMs}"

MODE="${1:---check}"
case "$MODE" in --check|--dry-run|--create) ;; *) echo "usage: $0 [--check|--dry-run|--create]" >&2; exit 2;; esac

die()  { echo "monkey-vm: FATAL $*" >&2; exit 1; }
ok()   { printf '  OK      %s\n' "$*"; }
gap()  { printf '  MISSING %s\n' "$*"; }
act()  { printf '  DO      %s\n' "$*"; }
# `< /dev/null` is load-bearing, not tidiness. VBoxManage.exe is a WINDOWS
# process reached through WSL interop and it inherits this shell's stdin. If
#   [rest: vault:realisateur/guard-archaeology-20260817.md]
vbm()  { "$VBM" "$@" 2>&1 < /dev/null | tr -d '\r'; }

# Windows path -> WSL path, for ANY drive letter. The ancestor hardcoded
# `s|C:\\|/mnt/c/|`, which is correct only while everything lives on C: --
#   [rest: vault:realisateur/guard-archaeology-20260817.md]
win_to_wsl() {
  local p="$1" drive rest
  drive="$(printf '%s' "$p" | cut -c1 | tr 'A-Z' 'a-z')"
  rest="$(printf '%s' "${p#?:}" | sed 's|\\\\|/|g; s|\\|/|g')"
  printf '/mnt/%s%s' "$drive" "$rest"
}

# --- preflight ---------------------------------------------------------------
echo "== monkey VM provisioning ($MODE) =="
[[ -f "$VBM" ]] || die "VBoxManage not found at '$VBM'. Run this from dexter (WSL2) where /mnt/c is mounted, or set VBOXMANAGE."
ok "VBoxManage $(vbm --version | head -1)"

grep -qi microsoft /proc/version 2>/dev/null || gap "this does not look like WSL; interop to the Windows hypervisor may not work"

# The basefolder's drive must exist and have room. A VirtualBox error about an
# unwritable path 15 minutes in is a worse way to learn this.
BASE_WSL="$(win_to_wsl "$BASEFOLDER")"
BASE_DRIVE="$(printf '%s' "$BASE_WSL" | cut -d/ -f1-3)"
if [[ -d "$BASE_DRIVE" ]]; then
  # `|| true` on both: these are ADVISORY probes. Under `set -e` with pipefail a
  # failing pipeline inside a command substitution aborts the whole script, so an
  #   [rest: vault:realisateur/guard-archaeology-20260817.md]
  avail_g=$(df -BG --output=avail "$BASE_DRIVE" 2>/dev/null | tail -1 | tr -dc '0-9' || true)
  need_g=$(( DISK_MB / 1024 ))
  if [[ -n "$avail_g" ]] && (( avail_g < need_g )); then
    gap "$BASE_DRIVE has ${avail_g}G free; the disk is declared at ${need_g}G (dynamic, so it grows into it -- but the ceiling is real)"
  else
    ok "basefolder drive $BASE_DRIVE present, ${avail_g:-?}G free (disk declared ${need_g}G, dynamic)"
  fi
else
  die "basefolder drive $BASE_DRIVE is not mounted in WSL. Set MONKEY_BASEFOLDER, or mount it."
fi

# RAM is a HOST-level decision, and WSL2's own /proc/meminfo is a ceiling it was
# given, not the machine's total -- so it cannot answer this. Ask Windows.
if command -v powershell.exe >/dev/null 2>&1; then
  host_bytes="$(powershell.exe -NoProfile -c '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory' 2>/dev/null | tr -dc '0-9' || true)"
  if [[ -n "$host_bytes" ]]; then
    host_g=$(( host_bytes / 1024 / 1024 / 1024 ))
    ok "Windows host has ${host_g}G RAM"
    # nomac already holds 4G, and WSL2 takes its own ceiling on top of this.
    if (( host_g < 16 )); then
      gap "with nomac at 4G and WSL2's ceiling on top, ${RAM_MB}M for monkey may overcommit a ${host_g}G host -- consider MONKEY_RAM_MB=4096"
    fi
  fi
fi

ISO="$ISO_DIR/$ISO_NAME"
if [[ ! -f "$ISO" ]]; then
  gap "installer ISO absent: $ISO"
  echo "        get it with: wget -c -O '$ISO' https://releases.ubuntu.com/24.04/$ISO_NAME"
  ISO_OK=0
else
  size=$(stat -c%s "$ISO")
  echo "  ..      verifying ISO sha256 ($((size/1024/1024)) MB, this takes a moment)"
  actual="$(sha256sum "$ISO" | cut -d' ' -f1 || true)"
  if [[ $actual == "$ISO_SHA" ]]; then ok "ISO checksum matches the published SHA256SUMS"; ISO_OK=1
  else
    ISO_OK=0
    if (( size < 2500000000 )); then gap "ISO is only $((size/1024/1024)) MB -- download still in progress?"
    else die "ISO checksum MISMATCH. Expected $ISO_SHA, got $actual. Refusing to install an unverified image."; fi
  fi
fi

# Windows-side path of the ISO, which is what VBoxManage.exe needs.
iso_win() { printf 'C:%s' "$(printf '%s' "${ISO#/mnt/c}" | tr '/' '\\')"; }

# The VDI path is DERIVED from CfgFile rather than assembled, so it follows
# --basefolder for free -- and so do snapshots and logs.
vdi_path() {
  vbm showvminfo "$VM" --machinereadable | grep '^CfgFile=' | cut -d'"' -f2 | sed 's/\.vbox$/.vdi/'
}

if vbm list vms | grep -q "\"$VM\""; then
  ok "VM '$VM' already exists"
  VM_EXISTS=1
  echo "        state: $(vbm showvminfo "$VM" --machinereadable | grep '^VMState=' | cut -d'"' -f2)"
  echo "        disk:  $(vdi_path)"
else
  gap "VM '$VM' does not exist yet"
  VM_EXISTS=0
fi

# nomac is a different machine with a different job. Say so, so that a reader
# who knows about nomac does not wonder whether this is going to disturb it.
if vbm list vms | grep -q '"nomac"'; then
  ok "nomac exists and is untouched by this script (different VM, different disk, different port)"
fi

if [[ $MODE == --check ]]; then
  echo
  echo "check only. Nothing changed."
  echo "Next: $0 --dry-run  (generates the autoinstall answer files without installing)"
  exit 0
fi

# --- secrets, required and never echoed ---------------------------------------
[[ -n "${MONKEY_PUBKEY:-}" ]]   || die "MONKEY_PUBKEY is unset. Export the ssh public key to authorize; this script will not invent one or leave the VM key-less."
[[ -n "${MONKEY_PASSWORD:-}" ]] || die "MONKEY_PASSWORD is unset. Ubuntu autoinstall requires a user password; generate one, keep it OUT of this repo."
[[ "${MONKEY_PUBKEY}" == ssh-* ]] || die "MONKEY_PUBKEY does not look like an ssh public key"
ok "MONKEY_PUBKEY and MONKEY_PASSWORD present (values not printed)"

(( ISO_OK )) || die "will not create a VM without a checksum-verified ISO"

# --- create -------------------------------------------------------------------
if (( ! VM_EXISTS )); then
  act "createvm $VM (Ubuntu 24.04 LTS 64-bit) in basefolder '$BASEFOLDER'"
  vbm createvm --name "$VM" --ostype Ubuntu24_LTS_64 --basefolder "$BASEFOLDER" --register >/dev/null
  act "modifyvm: ${RAM_MB}MB RAM, $CPUS vCPU, NAT with hostfwd $HOSTFWD_PORT -> 22"
  # The hostfwd host-IP field is left EMPTY deliberately, exactly as nomac's is:
  # binding it to 127.0.0.1 would make the guest unreachable from WSL, which is
  #   [rest: vault:realisateur/guard-archaeology-20260817.md]
  vbm modifyvm "$VM" \
      --memory "$RAM_MB" --cpus "$CPUS" \
      --nic1 nat --nictype1 virtio \
      --natpf1 "ssh,tcp,,$HOSTFWD_PORT,,22" \
      --audio-driver none --usb off \
      --graphicscontroller vmsvga --vram 16 \
      --boot1 dvd --boot2 disk --boot3 none --boot4 none \
      --rtcuseutc on --ioapic on >/dev/null
  act "create ${DISK_MB}MB disk and attach it plus the installer ISO"
  vbm storagectl "$VM" --name SATA --add sata --controller IntelAhci --portcount 2 >/dev/null
  vbm createmedium disk --filename "$(vdi_path)" --size "$DISK_MB" --format VDI >/dev/null
  vbm storageattach "$VM" --storagectl SATA --port 0 --device 0 --type hdd --medium "$(vdi_path)" >/dev/null
  vbm storageattach "$VM" --storagectl SATA --port 1 --device 0 --type dvddrive --medium "$(iso_win)" >/dev/null
  ok "VM '$VM' created, disk at $(vdi_path)"
else
  ok "skipping creation; VM already exists"
fi

# --- unattended install -------------------------------------------------------
# Kept BYTE-IDENTICAL in shape to nomac's, which is proven to survive assembly
#   [rest: vault:realisateur/guard-archaeology-20260817.md]
POST_INSTALL="/bin/bash -c 'set -e; \
apt-get update; \
DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server git python3 ca-certificates; \
install -d -m 700 -o $VM_USER -g $VM_USER /home/$VM_USER/.ssh; \
printf \"%s\\n\" \"$MONKEY_PUBKEY\" > /home/$VM_USER/.ssh/authorized_keys; \
chmod 600 /home/$VM_USER/.ssh/authorized_keys; \
chown $VM_USER:$VM_USER /home/$VM_USER/.ssh/authorized_keys; \
systemctl enable ssh; \
loginctl enable-linger $VM_USER || true'"

# The password goes through a mode-600 temp FILE, not argv: an argument to
# VBoxManage.exe is visible in the Windows process list to anything that can
# enumerate processes. --user-password-file exists precisely for this.
PWFILE="$(mktemp -t monkey-pw-XXXXXX)"
chmod 600 "$PWFILE"
cleanup_pw() { [[ -f "$PWFILE" ]] && { shred -u "$PWFILE" 2>/dev/null || rm -f "$PWFILE"; }; }
trap cleanup_pw EXIT INT TERM
printf '%s' "$MONKEY_PASSWORD" > "$PWFILE"
ok "password staged in a mode-600 temp file (never on a command line)"

UNATTENDED_ARGS=(
  unattended install "$VM"
  --iso="$(iso_win)"
  --user="$VM_USER"
  --user-password-file="$PWFILE"
  --admin-password-file="$PWFILE"
  --full-user-name="$VM_USER"
  --hostname="$FQDN"
  --time-zone=UTC
  --locale=en_US
  --country=US
  --package-selection-adjustment=minimal
  --post-install-command="$POST_INSTALL"
)

if [[ $MODE == --dry-run ]]; then
  act "unattended install --dry-run (generates answer files, installs nothing)"
  vbm "${UNATTENDED_ARGS[@]}" --dry-run
  aux_win="$(vbm showvminfo "$VM" --machinereadable | grep '^CfgFile=' | cut -d'"' -f2 | sed 's/[^\\]*$//')"
  aux="$(win_to_wsl "$aux_win")"
  echo
  echo "generated answer files under: ${aux}Unattended-*"
  ls -la "${aux}"Unattended-* 2>/dev/null | head -10 || echo "  (none found -- inspect $aux)"
  echo
  echo "READ the generated user-data before --create. The post-install command is"
  echo "assembled by string interpolation through two shells and VBoxManage.exe;"
  echo "dry-run is how you find out whether the quoting survived, instead of"
  echo "discovering it 20 minutes into an install that leaves you locked out."
  echo
  echo "Check specifically: the hostname line reads '$FQDN' (short name must be"
  echo "'monkey' -- scheduler resolves its rotation file by \`hostname -s\`), and"
  echo "the authorized_keys line carries your key on ONE line."
  exit 0
fi

act "unattended install (headless; this takes ~10-20 minutes)"
vbm "${UNATTENDED_ARGS[@]}" --start-vm=headless
ok "installer started"

# WHICH ADDRESS REACHES THE GUEST -- probed, not asserted, because BOTH of the
# obvious answers are wrong on some WSL2 configuration and this script has now
#   [rest: vault:realisateur/guard-archaeology-20260817.md]
echo
echo "-- finding the address that actually reaches the guest --"
GUESS_HOSTS=(127.0.0.1)
_gw="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
[ -n "$_gw" ] && GUESS_HOSTS+=("$_gw")
REACHED=""
for _h in "${GUESS_HOSTS[@]}"; do
  if timeout 5 bash -c "</dev/tcp/$_h/$HOSTFWD_PORT" 2>/dev/null; then
    REACHED="$_h"; ok "port $HOSTFWD_PORT answers at $_h"; break
  else
    gap "port $HOSTFWD_PORT does not answer at $_h (yet -- the install takes 10-20 min)"
  fi
done
echo
if [ -n "$REACHED" ]; then
  echo "   From dexter (WSL2):  ssh -p $HOSTFWD_PORT -i ~/.ssh/selfdev_monkey $VM_USER@$REACHED"
else
  echo "   From dexter (WSL2):  try $VM_USER@127.0.0.1 first, then $VM_USER@${_gw:-<windows-host-ip>}"
fi
echo "   From mandark:        ssh -p $HOSTFWD_PORT -i ~/.ssh/selfdev_monkey $VM_USER@<dexter-tailnet-ip>"
echo
echo "Do not assume it came up, and do not take an OPEN PORT as done: Ubuntu's"
echo "installer environment answers on 22 before the post-install command has"
echo "written authorized_keys, so the first successful connection is the"
echo "witness, not the first open socket. Poll for:"
echo "   ssh ... $VM_USER@<addr> hostname -s     # must print exactly: monkey"
echo
echo "Then the root sitting on the guest (users, linger, node, claude, sshd"
echo "hardening), and only then:"
echo "   bin/land-selfdev.sh --check     # probes, writes nothing"
echo "   bin/land-selfdev.sh --land"
echo
echo "See vault:realisateur/MONKEY.md for the whole sequence and what each step must witness."
