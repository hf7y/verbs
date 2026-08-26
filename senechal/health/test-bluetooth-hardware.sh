#!/usr/bin/env bash
# Test harness for bluetooth-hardware.sh. Runs the real script with
# PATH-stubbed `systemctl`/`journalctl` and BT_SYSFS_DIR pointed at a
# throwaway directory, so every verdict cell is exercised
# deterministically and nothing real is ever queried.
#
# Exit: 0 all assertions pass / 1 any assertion failed.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sysfs-empty" "$T/sysfs-present/hci0" "$T/home"
cp ../senechal.json.example "$T/senechal.json"

# --- stub systemctl: answers `show -p ConditionResult --value UNIT` and
# `is-active UNIT` from $ST_COND / $ST_ACTIVE env vars.
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  show) echo "${ST_COND:-}" ;;
  is-active) echo "${ST_ACTIVE:-inactive}" ;;
esac
exit 0
STUB

# --- stub journalctl: replays $JOURNAL_OUT verbatim regardless of args.
cat > "$T/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
[ -n "${JOURNAL_OUT:-}" ] && printf '%s\n' "$JOURNAL_OUT"
exit 0
STUB
chmod +x "$T/bin/systemctl" "$T/bin/journalctl"

fails=0
run() { # run <label> <BT_SYSFS_DIR> <ST_COND> <ST_ACTIVE> <JOURNAL_OUT> [BT_BOOT_ID]
  local label="$1" sysfs="$2" cond="$3" active="$4" journal="$5"
  local bootid="${6:-boot-$label}"
  BT_SYSFS_DIR="$sysfs" ST_COND="$cond" ST_ACTIVE="$active" JOURNAL_OUT="$journal" \
    BT_BOOT_ID="$bootid" \
    PATH="$T/bin:$PATH" HOME="$T/home" XDG_STATE_HOME="$T/home/.state" \
    SENECHAL_CONFIG="$T/senechal.json" \
    bash ./bluetooth-hardware.sh > "$T/out-$label" 2>&1
  echo "$?"
}

expect_rc() { # expect_rc <label> <expected-rc>
  local label="$1" want="$2" got
  got="$(cat "$T/rc-$label" 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    printf 'ok:   %s exit=%s\n' "$label" "$got"
  else
    printf 'MISS: %s exit=%s want=%s\n' "$label" "$got" "$want"
    fails=$((fails + 1))
  fi
}

expect_text() { # expect_text <label> <substring>
  local label="$1" want="$2"
  if grep -qF "$want" "$T/out-$label"; then
    printf 'ok:   %s contains %q\n' "$label" "$want"
  else
    printf 'MISS: %s does not contain %q\n' "$label" "$want"
    cat "$T/out-$label"
    fails=$((fails + 1))
  fi
}

expect_not_text() { # expect_not_text <label> <substring>
  local label="$1" bad="$2"
  if grep -qF "$bad" "$T/out-$label"; then
    printf 'MISS: %s SHOULD NOT contain %q\n' "$label" "$bad"
    cat "$T/out-$label"
    fails=$((fails + 1))
  else
    printf 'ok:   %s avoids %q\n' "$label" "$bad"
  fi
}

expect_state() { # expect_state <label> <expected "<bootid> <n>">
  local label="$1" want="$2" got
  got="$(cat "$T/home/.state/senechal/bluetooth-hardware-fault.state" 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    printf 'ok:   %s state=%s\n' "$label" "$got"
  else
    printf 'MISS: %s state=%q want=%q\n' "$label" "$got" "$want"
    fails=$((fails + 1))
  fi
}

expect_no_state() { # expect_no_state <label>
  local label="$1"
  if [ -e "$T/home/.state/senechal/bluetooth-hardware-fault.state" ]; then
    printf 'MISS: %s expects no fault state file\n' "$label"
    fails=$((fails + 1))
  else
    printf 'ok:   %s no fault state recorded\n' "$label"
  fi
}

# --- adapter present: pass regardless of anything else -------------------
run present "$T/sysfs-present" no inactive '' > "$T/rc-present"
expect_rc present 0
expect_text present "adapter visible to the kernel"

# --- absent, no attach attempts: hardware simply not there ---------------
# A benign kernel line (journalctl reachable, just nothing bluetooth-shaped
# in it) so this is distinct from journalctl returning nothing at all.
run clean-absent "$T/sysfs-empty" no inactive 'kernel: ACPI: some unrelated line' > "$T/rc-clean-absent"
expect_rc clean-absent 1
expect_text clean-absent "no USB enumeration attempts seen this boot"
expect_text clean-absent "check BIOS"

# --- absent, but the kernel IS retrying enumeration: the mandark case ----
JOURNAL='usb usb1-port7: device descriptor read/64, error -71
usb usb1-port7: unable to enumerate USB device
usb usb1-port7: unable to enumerate USB device'
run stuck-usb "$T/sysfs-empty" no inactive "$JOURNAL" > "$T/rc-stuck-usb"
expect_rc stuck-usb 1
expect_text stuck-usb "IS attempting to attach"
expect_text stuck-usb "usb1-port7"
expect_text stuck-usb "fully power off"
expect_state stuck-usb "boot-stuck-usb 1"

# --- the SAME fault on the NEXT boot: the drain had its one chance -------
# bt_fault_tally must bump the consecutive-boot count and the advice must
# escalate from "drain it" to "reseat or replace" (mandark 2026-08-09).
run stuck-usb-recur "$T/sysfs-empty" no inactive "$JOURNAL" boot-stuck-usb-recur > "$T/rc-stuck-usb-recur"
expect_rc stuck-usb-recur 1
expect_text stuck-usb-recur "consecutive boot"
expect_text stuck-usb-recur "reseat"
expect_not_text stuck-usb-recur "fully power off"
expect_state stuck-usb-recur "boot-stuck-usb-recur 2"

# --- recovery resets the memory: adapter visible again clears the file ---
run present-reset "$T/sysfs-present" no inactive '' boot-present-reset > "$T/rc-present-reset"
expect_rc present-reset 0
expect_no_state present-reset

# --- ...so a fresh storm after recovery starts over at first-occurrence --
run stuck-usb-again "$T/sysfs-empty" no inactive "$JOURNAL" boot-stuck-usb-again > "$T/rc-stuck-usb-again"
expect_rc stuck-usb-again 1
expect_text stuck-usb-again "fully power off"
expect_not_text stuck-usb-again "consecutive boot"
expect_state stuck-usb-again "boot-stuck-usb-again 1"

# --- absent, journalctl unreadable: cannot tell, must not read as clean --
run no-journal "$T/sysfs-empty" no inactive '' > "$T/rc-no-journal-placeholder"
# override: force journalctl to fail outright for this one case
cat > "$T/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
BT_SYSFS_DIR="$T/sysfs-empty" ST_COND=no ST_ACTIVE=inactive \
  PATH="$T/bin:$PATH" HOME="$T/home" XDG_STATE_HOME="$T/home/.state" \
  SENECHAL_CONFIG="$T/senechal.json" \
  bash ./bluetooth-hardware.sh -q > "$T/out-no-journal" 2>&1
echo $? > "$T/rc-no-journal"
expect_rc no-journal 2
expect_text no-journal "SKIP"

echo
if [ "$fails" -eq 0 ]; then
  echo "PASS: all assertions held"
  exit 0
else
  echo "FAIL: $fails assertion(s) failed"
  exit 1
fi
