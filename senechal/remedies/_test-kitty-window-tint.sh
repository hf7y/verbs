#!/usr/bin/env bash
set -uo pipefail   # no real kitty required; probes injected via SENECHAL_KITTY_PID_STARTS / SENECHAL_KITTEN

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMEDY="$HERE/kitty-window-tint.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

check_rc() { # <expected> <actual> <label>
  if [ "$2" = "$1" ]; then pass "$3 (rc=$2)"; else fail "$3: expected rc=$1, got rc=$2"; fi
}

export HOME="$SANDBOX/home"
export SENECHAL_CONFIG="$SANDBOX/senechal.json"
export SENECHAL_BACKUP_ROOT="$SANDBOX/backups"
export SENECHAL_KITTY_CONF="$SANDBOX/kitty.conf"
export SENECHAL_BASHRC="$SANDBOX/bashrc"
export SENECHAL_KITTY_SOCKET_GLOB="$SANDBOX/sockets/senechal-kitty-*"
export SENECHAL_KITTY_PID_STARTS=""   # empty = "no kitty running", not unset
mkdir -p "$HOME" "$SANDBOX/sockets" "$SANDBOX/bin"
printf '{}\n' > "$SENECHAL_CONFIG"

cat > "$SANDBOX/bin/kitten" <<'FAKE'
#!/usr/bin/env bash
sock=""
for a in "$@"; do case "$a" in unix:*) sock="${a#unix:}" ;; esac; done
answer="$(cat "${sock}.answer" 2>/dev/null)"
[ -n "$answer" ] || exit 1
printf 'background            %s\nforeground            #dddddd\ncursor                #cccccc\n' "$answer"
FAKE
chmod +x "$SANDBOX/bin/kitten"
export SENECHAL_KITTEN="$SANDBOX/bin/kitten"

mksock() { # <name> <background it will report>
  python3 - "$SANDBOX/sockets/$1" <<'PY'
import socket, sys, os
p = sys.argv[1]
if os.path.exists(p): os.unlink(p)
s = socket.socket(socket.AF_UNIX); s.bind(p)
PY
  printf '%s' "$2" > "$SANDBOX/sockets/$1.answer"
}
rmsocks() { rm -f "$SANDBOX/sockets/"senechal-kitty-*; }

mkrtsock() { # <pid> -- $XDG_RUNTIME_DIR socket, a different path than verify's glob
  python3 -c 'import socket,sys,os
p=sys.argv[1]
if os.path.exists(p): os.unlink(p)
s=socket.socket(socket.AF_UNIX); s.bind(p)' "$SANDBOX/senechal-kitty-$1"
}
rmrtsocks() { rm -f "$SANDBOX"/senechal-kitty-*; }

cat > "$SENECHAL_KITTY_CONF" <<'EOF'
copy_on_select yes
enabled_layouts splits,stack
window_padding_width 5
EOF
cat > "$SENECHAL_BASHRC" <<'EOF'
export EDITOR=nvim
alias ll='ls -alF'
EOF
ORIGINAL_KITTY="$(cat "$SENECHAL_KITTY_CONF")"
ORIGINAL_BASHRC="$(cat "$SENECHAL_BASHRC")"

echo "== kitty-window-tint =="

out="$("$REMEDY" verify 2>&1)"; rc=$?
check_rc 5 "$rc" "verify before enable reports FAIL"
case "$out" in
  *"listen_on is ignored without it"*)
    pass "verify explains that allow_remote_control gates listen_on" ;;
  *) fail "verify did not explain the allow_remote_control gate: $out" ;;
esac

out="$("$REMEDY" enable 2>&1)"; rc=$?
check_rc 0 "$rc" "enable succeeds"
case "$out" in
  *"ctrl+shift+f5"*) pass "enable warns that a reload will not open the socket" ;;
  *) fail "enable did not warn against ctrl+shift+f5: $out" ;;
esac

grep -q '^allow_remote_control socket-only$' "$SENECHAL_KITTY_CONF" \
  && pass "allow_remote_control written" || fail "allow_remote_control missing"
grep -q '^listen_on unix:${XDG_RUNTIME_DIR}/senechal-kitty$' "$SENECHAL_KITTY_CONF" \
  && pass "listen_on written" || fail "listen_on missing"
grep -q '^__senechal_kitty_tint$' "$SENECHAL_BASHRC" \
  && pass "tint function is actually CALLED, not just defined" \
  || fail "tint function defined but never called"
[ "$(grep -c '^  "#[0-9a-f]\{6\} #[0-9a-f]\{6\}"$' "$SENECHAL_BASHRC")" = 6 ] \
  && pass "all six tint pairs written" || fail "wrong number of tint pairs"

grep -q '^window_border_width 1px$' "$SENECHAL_KITTY_CONF" \
  && pass "divider is a 1px line, pinned in pixels not points" \
  || fail "window_border_width is not 1px -- Zach rejected anything thicker"
grep -q '^draw_minimal_borders yes$' "$SENECHAL_KITTY_CONF" \
  && pass "minimal borders: the splitter only, no frame around each pane" \
  || fail "draw_minimal_borders not pinned -- panes may gain a full frame"

grep -q '^tab_bar_min_tabs' "$SENECHAL_KITTY_CONF" \
  && fail "forced a tab bar on -- Zach asked for the splitter, no extra bars" \
  || pass "tab bar left at its default; no bar appears uninvited"

grep -q 'inactive_border_color=\$edge' "$SENECHAL_BASHRC" \
  && pass "both border colours take the edge, so the divider is one colour" \
  || fail "inactive_border_color unset -- the divider will be half grey"

grep -q '^allow_remote_control yes$' "$SENECHAL_KITTY_CONF" \
  && fail "opened the escape-code control channel with 'yes'" \
  || pass "escape-code control channel left shut"

for line in "copy_on_select yes" "enabled_layouts splits,stack" "window_padding_width 5"; do
  grep -qxF "$line" "$SENECHAL_KITTY_CONF" \
    && pass "kept: $line" || fail "clobbered pre-existing kitty.conf line: $line"
done
for line in "export EDITOR=nvim" "alias ll='ls -alF'"; do
  grep -qxF "$line" "$SENECHAL_BASHRC" \
    && pass "kept: $line" || fail "clobbered pre-existing .bashrc line: $line"
done

before_k="$(cat "$SENECHAL_KITTY_CONF")"; before_b="$(cat "$SENECHAL_BASHRC")"
"$REMEDY" enable >/dev/null 2>&1; rc=$?
check_rc 0 "$rc" "second enable succeeds"
[ "$(cat "$SENECHAL_KITTY_CONF")" = "$before_k" ] \
  && pass "kitty.conf byte-identical after re-enable" || fail "re-enable changed kitty.conf"
[ "$(cat "$SENECHAL_BASHRC")" = "$before_b" ] \
  && pass ".bashrc byte-identical after re-enable" || fail "re-enable changed .bashrc"

out="$("$REMEDY" verify 2>&1)"; rc=$?
check_rc 2 "$rc" "verify with no running kitty is INCOMPLETE, not PASS"
case "$out" in
  *"no control socket"*) pass "verify says why it could not prove anything" ;;
  *) fail "verify did not name the missing socket: $out" ;;
esac

mksock "senechal-kitty-4242" "#00040b"
"$REMEDY" verify >/dev/null 2>&1; rc=$?
check_rc 0 "$rc" "verify PASSes when a live window carries a palette tint"

printf '%s' "#000000" > "$SANDBOX/sockets/senechal-kitty-4242.answer"
out="$("$REMEDY" verify 2>&1)"; rc=$?
check_rc 5 "$rc" "verify FAILs when the config is right but the window is still black"
case "$out" in
  *"still #000000"*"never tinted"*) pass "verify names the untinted window" ;;
  *) fail "verify did not name the black window: $out" ;;
esac

printf '%s' "#123456" > "$SANDBOX/sockets/senechal-kitty-4242.answer"
"$REMEDY" verify >/dev/null 2>&1; rc=$?
check_rc 5 "$rc" "verify FAILs on a colour that is not in the palette"

printf '%s' "" > "$SANDBOX/sockets/senechal-kitty-4242.answer"
"$REMEDY" verify >/dev/null 2>&1; rc=$?
check_rc 5 "$rc" "verify FAILs when the socket answers no colour"

printf '%s' "#00040b" > "$SANDBOX/sockets/senechal-kitty-4242.answer"
mksock "senechal-kitty-4243" "#000000"
"$REMEDY" verify >/dev/null 2>&1; rc=$?
check_rc 5 "$rc" "verify FAILs when only one of two live windows is untinted"
rm -f "$SANDBOX/sockets/senechal-kitty-4243"*

conf_epoch="$(stat -c %Y "$SENECHAL_KITTY_CONF")"
out="$(SENECHAL_KITTY_PID_STARTS="4242 $((conf_epoch - 3600))" "$REMEDY" verify 2>&1)"; rc=$?
check_rc 5 "$rc" "verify FAILs when a running kitty predates the config"
case "$out" in
  *"pid 4242"*"ctrl+shift+f5 will not open the socket"*)
    pass "verify names the stale pid AND that a reload will not fix it" ;;
  *) fail "verify did not explain the restart requirement: $out" ;;
esac
SENECHAL_KITTY_PID_STARTS="4242 $((conf_epoch + 3600))" "$REMEDY" verify >/dev/null 2>&1; rc=$?
check_rc 0 "$rc" "verify PASSes when the running kitty postdates the config"

cp "$SENECHAL_KITTY_CONF" "$SANDBOX/kitty.conf.enabled"
cp "$SENECHAL_BASHRC" "$SANDBOX/bashrc.enabled"

sed -i '/^allow_remote_control socket-only$/d' "$SENECHAL_KITTY_CONF"
"$REMEDY" verify >/dev/null 2>&1; rc=$?
check_rc 5 "$rc" "verify FAILs when only allow_remote_control is removed"
cp "$SANDBOX/kitty.conf.enabled" "$SENECHAL_KITTY_CONF"

sed -i '/^listen_on unix:/d' "$SENECHAL_KITTY_CONF"
"$REMEDY" verify >/dev/null 2>&1; rc=$?
check_rc 5 "$rc" "verify FAILs when only listen_on is removed"
cp "$SANDBOX/kitty.conf.enabled" "$SENECHAL_KITTY_CONF"

sed -i '/^__senechal_kitty_tint$/d' "$SENECHAL_BASHRC"
"$REMEDY" verify >/dev/null 2>&1; rc=$?
check_rc 5 "$rc" "verify FAILs when the tint function is defined but never called"
cp "$SANDBOX/bashrc.enabled" "$SENECHAL_BASHRC"

block="$(sed -n '/>>> senechal taste:kitty-window-tint/,/<<< senechal taste:kitty-window-tint/p' "$SENECHAL_BASHRC" \
        | sed '1d;$d')"
out="$(env -u KITTY_LISTEN_ON -u KITTY_PID PATH="/usr/bin:/bin" \
        bash -c "set -eu; $block; echo REACHED_END" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ "$out" = "REACHED_END" ]; then
  pass "block is silent and harmless in a non-kitty shell"
else
  fail "block misbehaved in a non-kitty shell (rc=$rc): $out"
fi

out="$(env KITTY_LISTEN_ON="unix:/nonexistent" KITTY_PID=999 \
        XDG_RUNTIME_DIR="$SANDBOX" PATH="/usr/bin:/bin" \
        bash -c "set -eu; $block; echo REACHED_END" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ "$out" = "REACHED_END" ]; then
  pass "block survives a dead socket without breaking the shell"
else
  fail "block broke a shell when the tint failed (rc=$rc): $out"
fi
[ -e "$SANDBOX/senechal-tint.999" ] \
  && pass "once-per-process stamp written" || fail "stamp not written"
grep -qE '^#[0-9a-f]{6} #[0-9a-f]{6}$' "$SANDBOX/senechal-tint.999" \
  && pass "stamp records the pair it claimed" || fail "stamp does not record its pair"

out="$(env KITTY_LISTEN_ON="unix:/nonexistent" KITTY_PID=999 \
        XDG_RUNTIME_DIR="$SANDBOX" PATH="/usr/bin:/bin" \
        bash -c "set -eu; $block; echo REACHED_END" 2>&1)"
[ "$out" = "REACHED_END" ] && pass "second shell in the same process is a no-op" \
  || fail "second shell re-tinted: $out"

tint_window() { # <pid> -- run the block, leave a socket "running" (its stamp's liveness test)
  env KITTY_LISTEN_ON="unix:/nonexistent" KITTY_PID="$1" \
      XDG_RUNTIME_DIR="$SANDBOX" PATH="/usr/bin:/bin" \
      bash -c "set -eu; $block" >/dev/null 2>&1
  mkrtsock "$1"
}
rm -f "$SANDBOX"/senechal-tint.*; rmrtsocks
for pid in 501 502 503 504 505 506; do tint_window "$pid"; done
distinct="$(cat "$SANDBOX"/senechal-tint.5?? 2>/dev/null | sort -u | grep -c .)"
[ "$distinct" = 6 ] \
  && pass "six live windows drew six DISTINCT tints" \
  || fail "six live windows drew only $distinct distinct tints -- collision avoidance is not working"

env KITTY_LISTEN_ON="unix:/nonexistent" KITTY_PID=507 \
    XDG_RUNTIME_DIR="$SANDBOX" PATH="/usr/bin:/bin" \
    bash -c "set -eu; $block" >/dev/null 2>&1
grep -qE '^#[0-9a-f]{6} #[0-9a-f]{6}$' "$SANDBOX/senechal-tint.507" \
  && pass "a seventh window falls back to the full palette, not to nothing" \
  || fail "seventh window got no tint once every live colour was taken"

rm -f "$SANDBOX/senechal-tint.507"
rmrtsocks                            # every window "exits", stamps remain
before="$(ls "$SANDBOX"/senechal-tint.* 2>/dev/null | wc -l)"
env KITTY_LISTEN_ON="unix:/nonexistent" KITTY_PID=601 \
    XDG_RUNTIME_DIR="$SANDBOX" PATH="/usr/bin:/bin" \
    bash -c "set -eu; $block" >/dev/null 2>&1
after="$(ls "$SANDBOX"/senechal-tint.* 2>/dev/null | wc -l)"
if [ "$before" = 6 ] && [ "$after" = 1 ]; then
  pass "stamps of exited kitties are reaped, not left reserving colours"
else
  fail "stale stamps not reaped: $before before, $after after (expected 6 then 1)"
fi
rm -f "$SANDBOX"/senechal-tint.*; rmrtsocks

rmsocks
"$REMEDY" disable >/dev/null 2>&1; rc=$?
check_rc 0 "$rc" "disable succeeds"
[ "$(cat "$SENECHAL_KITTY_CONF")" = "$ORIGINAL_KITTY" ] \
  && pass "kitty.conf restored byte for byte" || fail "kitty.conf not restored"
[ "$(cat "$SENECHAL_BASHRC")" = "$ORIGINAL_BASHRC" ] \
  && pass ".bashrc restored byte for byte" || fail ".bashrc not restored"

"$REMEDY" disable >/dev/null 2>&1; rc=$?
check_rc 0 "$rc" "second disable succeeds"
[ "$(cat "$SENECHAL_BASHRC")" = "$ORIGINAL_BASHRC" ] \
  && pass ".bashrc still byte-identical after re-disable" || fail "re-disable changed .bashrc"

"$REMEDY" verify >/dev/null 2>&1; rc=$?
check_rc 5 "$rc" "verify after disable reports FAIL"

cat > "$SENECHAL_CONFIG" <<'JSON'
{"estate": {"taste": [
  {"id": "kitty-window-tint", "files": ["kitty.conf", ".bashrc"],
   "hosts": ["mandark"], "status": "disabled"}
]}}
JSON

out="$("$REMEDY" enable 2>&1)"; rc=$?
check_rc 0 "$rc" "enable is a no-op while status is disabled"
printf '%s\n' "$out" | grep -q '"disabled" -- nothing to do' \
  && pass "enable says why it did nothing" || fail "enable's no-op message missing: $out"
[ "$(cat "$SENECHAL_KITTY_CONF")" = "$ORIGINAL_KITTY" ] \
  && pass "kitty.conf untouched while disabled" || fail "kitty.conf was written while disabled"
[ "$(cat "$SENECHAL_BASHRC")" = "$ORIGINAL_BASHRC" ] \
  && pass ".bashrc untouched while disabled" || fail ".bashrc was written while disabled"

out="$("$REMEDY" verify 2>&1)"; rc=$?
check_rc 2 "$rc" "verify reports could-not-check while status is disabled"
printf '%s\n' "$out" | grep -q '"disabled" -- not expected to be in effect' \
  && pass "verify says why it skipped" || fail "verify's skip message missing: $out"

printf '{}\n' > "$SENECHAL_CONFIG"
"$REMEDY" enable >/dev/null 2>&1; rc=$?
check_rc 0 "$rc" "enable runs normally with no estate.taste row at all"
grep -q "senechal taste:kitty-window-tint" "$SENECHAL_KITTY_CONF" \
  && pass "kitty.conf written with no registry row present" \
  || fail "kitty.conf not written with no registry row present"

echo ""
if [ "$fails" -eq 0 ]; then echo "PASS -- kitty-window-tint"; exit 0; fi
echo "FAIL -- $fails assertion(s) failed"; exit 1
