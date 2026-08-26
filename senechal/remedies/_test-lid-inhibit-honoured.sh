#!/usr/bin/env bash
# Tests for lid-inhibit-honoured.sh. Underscore-prefixed so verify-all.sh
# does not glob it up and run it as a remedy.
#
#   ./_test-lid-inhibit-honoured.sh
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="./lid-inhibit-honoured.sh"
PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/.config/senechal"
# A minimal valid config: common.sh refuses to run without one, and the
# real one must never be read by a test.
printf '{"estate":{"devices":[]},"health":{}}\n' > "$SCRATCH/.config/senechal/senechal.json"
# A profiles file with three DIFFERENT lidAction values, which is what
# catches a section-blind rewrite. Battery=0 is the value the previous
# version of this remedy wrote -- the one that disabled lid suspend.
cat > "$SCRATCH/.config/powermanagementprofilesrc" <<'EOF'
[AC]
icon=battery-charging

[AC][HandleButtonEvents]
lidAction=64
powerButtonAction=16

[Battery][HandleButtonEvents]
lidAction=0
powerButtonAction=16

[AC][SuspendSession]
idleTime=900000
suspendType=1

[LowBattery][HandleButtonEvents]
lidAction=1
powerButtonAction=16

[LowBattery][SuspendSession]
idleTime=300000
suspendType=1
EOF

run() { # run the remedy against the scratch HOME
  env HOME="$SCRATCH" XDG_CONFIG_HOME="$SCRATCH/.config" \
      SENECHAL_CONFIG="$SCRATCH/.config/senechal/senechal.json" \
      SENECHAL_LID_UNIT_DIR="$SCRATCH/.config/systemd/user" \
      SENECHAL_BACKUP_ROOT="$SCRATCH/backups" \
      "$SCRIPT" "$@"
}
has_group() { # $1 = full section header
  grep -qF "$1" "$SCRATCH/.config/powermanagementprofilesrc"
}
lid_action() { # $1 = section
  awk -v want="[$1][HandleButtonEvents]" '
    $0 == want { inside = 1; next } /^\[/ { inside = 0 }
    inside && /^lidAction=/ { sub(/^lidAction=/, ""); print; exit }
  ' "$SCRATCH/.config/powermanagementprofilesrc"
}

echo "lid-inhibit-honoured tests"

# 1. verify FAILS LOUD when nothing is installed. Tested by actually
#    having nothing installed, not by reading the code.
run verify >/dev/null 2>&1
check "verify on a bare HOME exits 1 (not-in-effect)" "$?" "1"

# 2. enable applies.
run enable >/dev/null 2>&1
check "enable exits 0" "$?" "0"
[ -x "$SCRATCH/.local/bin/lid-inhibit-daemon" ] && ok "daemon installed executable" || bad "daemon missing"
[ -x "$SCRATCH/.local/bin/lid-inhibit-watch" ]  && ok "watcher installed executable" || bad "watcher missing"
[ -e "$SCRATCH/.local/bin/lid-inhibit-hold" ]   && bad "obsolete holder still installed" || ok "no holder (attempt 2's machinery is gone)"
[ -f "$SCRATCH/.config/lid-inhibit/excludes.conf" ] && ok "excludes.conf written" || bad "excludes.conf missing"

# 3. every profile now only BLANKS on lid close (64 = turn off screen),
#    including the Battery one a previous version set to 0. PowerDevil
#    must not be the thing that suspends; the daemon is.
check "AC lidAction"         "$(lid_action AC)"         "64"
check "Battery lidAction"    "$(lid_action Battery)"    "64"
check "LowBattery lidAction" "$(lid_action LowBattery)" "64"

# 3b. idle autosuspend is gone from every profile, so PowerDevil cannot
#     suspend behind the daemon's back on a timer either.
has_group "[AC][SuspendSession]"         && bad "AC SuspendSession survived"         || ok "AC idle autosuspend removed"
has_group "[Battery][SuspendSession]"    && bad "Battery SuspendSession survived"    || ok "Battery idle autosuspend removed"
has_group "[LowBattery][SuspendSession]" && bad "LowBattery SuspendSession survived" || ok "LowBattery idle autosuspend removed"

# 4. unrelated keys in the same file survive.
check "powerButtonAction untouched" \
  "$(grep -c '^powerButtonAction=16' "$SCRATCH/.config/powermanagementprofilesrc")" "3"

# 5. idempotence: a second enable changes nothing and takes no backup.
before="$(ls "$SCRATCH/backups" 2>/dev/null | wc -l)"
run enable >/dev/null 2>&1
check "re-enable takes no fresh backup" "$(ls "$SCRATCH/backups" 2>/dev/null | wc -l)" "$before"

# 6. disable hands the lid back to PowerDevil. This is the check that
#    stops the never-suspends bug returning by the back door: with the
#    daemon gone, lidAction=64 would mean nothing suspends this machine
#    ever, so disable MUST restore sleep and idle autosuspend.
run disable >/dev/null 2>&1
check "disable restores AC=1"         "$(lid_action AC)"         "1"
check "disable restores Battery=1"    "$(lid_action Battery)"    "1"
check "disable restores LowBattery=1" "$(lid_action LowBattery)" "1"
has_group "[AC][SuspendSession]"         && ok "AC idle autosuspend restored"         || bad "AC SuspendSession not restored"
has_group "[Battery][SuspendSession]"    && ok "Battery idle autosuspend restored"    || bad "Battery SuspendSession not restored"
has_group "[LowBattery][SuspendSession]" && ok "LowBattery idle autosuspend restored" || bad "LowBattery SuspendSession not restored"

# 7. the watch discriminates. This is defect 1 -- the whole reason the
#    original inhibitor was held unbroken for a week: `pgrep -f claude`
#    matches Claude Code's idle daemon pool, so it never turned off.
run enable >/dev/null 2>&1
DAEMON="$SCRATCH/.local/bin/lid-inhibit-daemon"
printf 'zzz-no-such-process-zzz\n' > "$SCRATCH/.config/lid-inhibit/patterns.conf"
env HOME="$SCRATCH" "$DAEMON" --match >/dev/null 2>&1
check "--match says no when nothing matches" "$?" "1"

# Something that genuinely exists: this test's own shell.
printf '%s\n' "_test-lid-inhibit-honoured" > "$SCRATCH/.config/lid-inhibit/patterns.conf"
printf '# no excludes\n' > "$SCRATCH/.config/lid-inhibit/excludes.conf"
env HOME="$SCRATCH" "$DAEMON" --match >/dev/null 2>&1
match_without_exclude=$?
# ...now excluded by name. Same pattern, same processes, opposite answer:
# that is what proves the exclude list is the thing doing the work.
printf '_test-lid-inhibit\n' > "$SCRATCH/.config/lid-inhibit/excludes.conf"
env HOME="$SCRATCH" "$DAEMON" --match >/dev/null 2>&1
match_with_exclude=$?
check "--match says yes without the exclude" "$match_without_exclude" "0"
check "--match says no with the exclude"     "$match_with_exclude"    "1"

# 8. the watcher parses /proc/bus/input/devices correctly. Regression test:
#    the first version split the block on whitespace looking for a token
#    starting with "event", but the line reads "H: Handlers=event0", so it
#    found nothing and silently reported "no lid switch -- no beep" on a
#    laptop that has one.
python3 - "$SCRATCH/.local/bin/lid-inhibit-watch" <<'PY'
import sys, tempfile, os
src = open(sys.argv[1]).read()
ns = {"__name__": "notmain"}
exec(compile(src, "watch", "exec"), ns)
sample = '''I: Bus=0019 Vendor=0000 Product=0005
N: Name="Sleep Button"
H: Handlers=kbd event3

I: Bus=0019 Vendor=0000 Product=0005
N: Name="Lid Switch"
H: Handlers=event0

'''
path = tempfile.mktemp()
open(path, "w").write(sample)
real = "/proc/bus/input/devices"
# Point the parser at the sample by monkeypatching open() in its globals.
_open = ns["open"] if "open" in ns else open
ns["open"] = lambda p, *a, **k: _open(path if p == real else p, *a, **k)
got = ns["lid_device"]()
os.unlink(path)
print("  ok   watcher finds the lid switch (%s)" % got if got == "/dev/input/event0"
      else "  FAIL watcher lid_device() -> %r, want /dev/input/event0" % got)
raise SystemExit(0 if got == "/dev/input/event0" else 1)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# 9. THE DECISION ITSELF -- the whole point of this attempt. on_close()
#    must beep DIFFERENTLY and suspend ONLY when the watch is quiet.
#    Driven by monkeypatching watched()/play()/subprocess.call, with a
#    pipe standing in for the lid fd (nothing is written to it, so the
#    grace window simply expires -- no reopen).
python3 - "$SCRATCH/.local/bin/lid-inhibit-watch" <<'PY2'
import sys, os
src = open(sys.argv[1]).read()

def run(is_watched):
    ns = {"__name__": "notmain"}
    exec(compile(src, "watch", "exec"), ns)
    played, ran = [], []
    ns["watched"] = lambda: is_watched
    ns["play"] = lambda name: played.append(name)
    ns["GRACE_SEC"] = 0.05
    class FakeSub:
        DEVNULL = -3
        @staticmethod
        def call(cmd, *a, **k):
            ran.append(cmd)
            return 0
    ns["subprocess"] = FakeSub
    r, w = os.pipe()
    try:
        ns["on_close"](r)
    finally:
        os.close(r); os.close(w)
    return played, ran

held_played, held_ran = run(True)
quiet_played, quiet_ran = run(False)

fails = []
if len(held_played) != 1:
    fails.append("held: expected exactly one beep, got %r" % held_played)
if len(quiet_played) != 1:
    fails.append("quiet: expected exactly one beep, got %r" % quiet_played)
if held_played == quiet_played:
    fails.append("the two beeps are IDENTICAL (%r) -- the whole point is telling them apart" % held_played)
if held_ran:
    fails.append("held: suspended anyway via %r -- this is attempt 2's bug" % held_ran)
if [c for c in quiet_ran if c[:2] == ["systemctl", "suspend"]] == []:
    fails.append("quiet: never ran `systemctl suspend` (%r) -- this is attempt 1's bug" % quiet_ran)

for f in fails:
    print("  FAIL " + f)
if not fails:
    print("  ok   watch active -> beep %r, stays awake" % held_played[0])
    print("  ok   watch quiet  -> beep %r, then systemctl suspend" % quiet_played[0])
raise SystemExit(1 if fails else 0)
PY2
if [ $? -eq 0 ]; then PASS=$((PASS + 2)); else FAIL=$((FAIL + 1)); fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "PASS -- $PASS checks"
  exit 0
fi
echo "FAILED -- $FAIL of $((PASS + FAIL)) checks"
exit 1
