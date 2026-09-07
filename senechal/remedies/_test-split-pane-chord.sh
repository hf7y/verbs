#!/usr/bin/env bash
# Sandboxed state-machine test for remedies/split-pane-chord.sh.
#
# The underscore prefix is load-bearing: verify-all.sh globs ./*.sh and
# runs each as `<script> verify`, so an unprefixed test would run against
# the live machine. Every path the remedy touches is redirected into a
# mktemp -d -- scoping HOME alone is not enough, since common.sh reads
# SENECHAL_CONFIG at source time and the backup root is its own variable.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMEDY="$HERE/split-pane-chord.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

check_rc() { # <expected> <actual> <label>
  if [ "$2" = "$1" ]; then pass "$3 (rc=$2)"; else fail "$3: expected rc=$1, got rc=$2"; fi
}

# ---- sandbox --------------------------------------------------------
export HOME="$SANDBOX/home"
export SENECHAL_CONFIG="$SANDBOX/senechal.json"
export SENECHAL_BACKUP_ROOT="$SANDBOX/backups"
export SENECHAL_KITTY_CONF="$SANDBOX/kitty.conf"
export SENECHAL_FIREFOX_ROOT="$SANDBOX/mozilla/firefox"
export SENECHAL_FIREFOX_PGREP="false"   # "Firefox is not running"
export SENECHAL_KITTY_PID_STARTS=""   # empty = "no kitty running", not unset
mkdir -p "$HOME"
printf '{}\n' > "$SENECHAL_CONFIG"

# Pre-existing content, to prove unrelated settings survive.
cat > "$SENECHAL_KITTY_CONF" <<'EOF'
copy_on_select yes
strip_trailing_spaces always
window_padding_width 5
hide_window_decorations yes
EOF
ORIGINAL_KITTY="$(cat "$SENECHAL_KITTY_CONF")"

# Shaped like mandark's, INCLUDING the [Install...] section whose
# Default= holds a path rather than the flag 1 -- a resolver matching
# "any section with a Default key" picks that up, and this fixture is
# what makes that bug fail the test. Profile2's directory is absent on
# purpose, and the real default is listed last.
mkdir -p "$SENECHAL_FIREFOX_ROOT/realprofile.default"
cat > "$SENECHAL_FIREFOX_ROOT/profiles.ini" <<'EOF'
[General]
StartWithLastProfile=1
Version=2

[Profile2]
Name=other
IsRelative=1
Path=missing.default-release-2

[Install4F96D1932A9F858E]
Default=realprofile.default
Locked=1

[Profile0]
Name=default-release
IsRelative=1
Path=realprofile.default
Default=1
EOF
CUSTOM_KEYS="$SENECHAL_FIREFOX_ROOT/realprofile.default/customKeys.json"

echo "== split-pane-chord =="

# ---- 1. verify before enable: FAIL, not pass, not "could not check" --
out="$("$REMEDY" verify 2>&1)"; rc=$?
check_rc 5 "$rc" "verify before enable reports FAIL"
case "$out" in
  *"the map line alone is a silent no-op"*)
    pass "verify names enabled_layouts as the silent-failure line" ;;
  *) fail "verify did not explain the enabled_layouts trap: $out" ;;
esac

# ---- 2. enable ------------------------------------------------------
out="$("$REMEDY" enable 2>&1)"; rc=$?
check_rc 0 "$rc" "enable succeeds"

grep -q '^enabled_layouts splits,stack$' "$SENECHAL_KITTY_CONF" \
  && pass "enabled_layouts written" || fail "enabled_layouts missing"
grep -q '^map kitty_mod+enter launch --location=split --cwd=current$' "$SENECHAL_KITTY_CONF" \
  && pass "split binding written" || fail "split binding missing"
grep -q '^map kitty_mod+backslash layout_action rotate 90$' "$SENECHAL_KITTY_CONF" \
  && pass "rotate binding written" || fail "rotate binding missing"

# Clobbering the real 88KB config is the worst thing this could do.
for line in "copy_on_select yes" "strip_trailing_spaces always" \
            "window_padding_width 5" "hide_window_decorations yes"; do
  grep -qxF "$line" "$SENECHAL_KITTY_CONF" \
    && pass "kept: $line" || fail "clobbered pre-existing line: $line"
done

# Into the Default=1 profile, not [Install] and not the missing one.
if [ -f "$CUSTOM_KEYS" ]; then
  pass "customKeys.json written into the Default=1 profile"
  python3 - "$CUSTOM_KEYS" <<'PY' && pass "customKeys.json content correct" || fail "customKeys.json content wrong"
import json, sys
d = json.load(open(sys.argv[1]))
e = d.get("key_addTabSplitView") or {}
assert e.get("modifiers") == "accel,shift", e
assert e.get("keycode") == "VK_RETURN", e
PY
else
  fail "customKeys.json not written"
fi
[ -e "$SENECHAL_FIREFOX_ROOT/missing.default-release-2" ] \
  && fail "wrote into the profile whose directory should not exist" \
  || pass "left the non-existent profile alone"

# ---- 3. idempotence: a second enable changes nothing -----------------
before_k="$(cat "$SENECHAL_KITTY_CONF")"; before_f="$(cat "$CUSTOM_KEYS")"
"$REMEDY" enable >/dev/null 2>&1; rc=$?
check_rc 0 "$rc" "second enable succeeds"
[ "$(cat "$SENECHAL_KITTY_CONF")" = "$before_k" ] \
  && pass "kitty.conf byte-identical after re-enable" || fail "re-enable changed kitty.conf"
[ "$(cat "$CUSTOM_KEYS")" = "$before_f" ] \
  && pass "customKeys.json byte-identical after re-enable" || fail "re-enable changed customKeys.json"

# ---- 4. verify after enable: PASS -----------------------------------
SENECHAL_KITTY_PID_STARTS="" "$REMEDY" verify >/dev/null 2>&1; rc=$?
check_rc 0 "$rc" "verify after enable reports PASS"

conf_epoch="$(stat -c %Y "$SENECHAL_KITTY_CONF")" # SENECHAL_KITTY_PID_STARTS stands in for pgrep+ps, hermetically (#503)
stale_epoch=$((conf_epoch - 3600))
fresh_epoch=$((conf_epoch + 3600))

out="$(SENECHAL_KITTY_PID_STARTS="4242 $stale_epoch" "$REMEDY" verify 2>&1)"; rc=$?
check_rc 5 "$rc" "verify FAILs when a running kitty predates the config"
case "$out" in
  *"pid 4242"*"reload with ctrl+shift+f5"*) pass "verify names the stale pid" ;;
  *) fail "verify did not name the stale pid: $out" ;;
esac

out="$(SENECHAL_KITTY_PID_STARTS="4242 $fresh_epoch" "$REMEDY" verify 2>&1)"; rc=$?
check_rc 0 "$rc" "verify PASSes when the running kitty is newer than the config"
case "$out" in
  *"no running instance predates the config"*) pass "verify reports the liveness check explicitly" ;;
  *) fail "liveness OK line missing: $out" ;;
esac

out="$(SENECHAL_KITTY_PID_STARTS="1111 $stale_epoch
2222 $fresh_epoch" "$REMEDY" verify 2>&1)"; rc=$?
check_rc 5 "$rc" "verify FAILs when even one of several running kitty instances is stale"

# ---- 5. the guard must SEE a hand-edit, not report OK on it ----------
# The failure this repo keeps hitting: a check passing on the harm it
# exists to detect. Strip only the load-bearing line; require a FAIL.
cp "$SENECHAL_KITTY_CONF" "$SANDBOX/kitty.conf.enabled"
cp "$CUSTOM_KEYS" "$SANDBOX/customKeys.json.enabled"
sed -i '/^enabled_layouts splits,stack$/d' "$SENECHAL_KITTY_CONF"
"$REMEDY" verify >/dev/null 2>&1; rc=$?
check_rc 5 "$rc" "verify FAILs when only enabled_layouts is removed"
cp "$SANDBOX/kitty.conf.enabled" "$SENECHAL_KITTY_CONF"

# A chord set but WRONG must fail, not pass on the key's presence.
printf '{"key_addTabSplitView":{"modifiers":"accel","keycode":"VK_RETURN"}}' > "$CUSTOM_KEYS"
"$REMEDY" verify >/dev/null 2>&1; rc=$?
check_rc 5 "$rc" "verify FAILs on a wrong Firefox chord"
cp "$SANDBOX/customKeys.json.enabled" "$CUSTOM_KEYS"

# ---- 6. a running Firefox is refused, not written under --------------
# The chord must need changing, or the already-correct short-circuit
# answers first and the refusal never runs.
printf '{"key_addTabSplitView":{"modifiers":"accel","keycode":"VK_F1"}}' > "$CUSTOM_KEYS"
wrong_f="$(cat "$CUSTOM_KEYS")"
SENECHAL_FIREFOX_PGREP="true" "$REMEDY" enable >/dev/null 2>&1; rc=$?
check_rc 2 "$rc" "enable reports INCOMPLETE while Firefox is running"
[ "$(cat "$CUSTOM_KEYS")" = "$wrong_f" ] \
  && pass "customKeys.json untouched while Firefox is running" \
  || fail "wrote customKeys.json under a running Firefox"
cp "$SANDBOX/customKeys.json.enabled" "$CUSTOM_KEYS"

# ---- 6b. ...but an ALREADY-CORRECT chord is not refused --------------
# The common case: set in about:keyboard, Firefox open, nothing to write.
SENECHAL_FIREFOX_PGREP="true" "$REMEDY" enable >/dev/null 2>&1; rc=$?
check_rc 0 "$rc" "enable PASSes with Firefox running when the chord is already correct"

# ---- 7. other custom keys are merged, never clobbered ----------------
python3 - "$CUSTOM_KEYS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["key_somethingElse"] = {"modifiers": "accel", "key": "J"}
json.dump(d, open(sys.argv[1], "w"), separators=(",", ":"))
PY
"$REMEDY" enable >/dev/null 2>&1
python3 - "$CUSTOM_KEYS" <<'PY' && pass "unrelated custom key survived enable" || fail "enable clobbered an unrelated custom key"
import json, sys
d = json.load(open(sys.argv[1]))
assert "key_somethingElse" in d, d
assert d["key_addTabSplitView"]["keycode"] == "VK_RETURN", d
PY

# ---- 8. disable restores kitty.conf BYTE FOR BYTE --------------------
# Including the blank line taste-block.sh prepends.
"$REMEDY" disable >/dev/null 2>&1; rc=$?
check_rc 0 "$rc" "disable succeeds"
if [ "$(cat "$SENECHAL_KITTY_CONF")" = "$ORIGINAL_KITTY" ]; then
  pass "kitty.conf restored byte for byte"
else
  fail "kitty.conf not restored:"
  diff <(printf '%s\n' "$ORIGINAL_KITTY") "$SENECHAL_KITTY_CONF" | sed 's/^/       /'
fi
python3 - "$CUSTOM_KEYS" <<'PY' && pass "disable removed only our key" || fail "disable removed the wrong keys"
import json, sys
d = json.load(open(sys.argv[1]))
assert "key_addTabSplitView" not in d, d
assert "key_somethingElse" in d, d
PY

# ---- 9. disable is idempotent, and verify is back to FAIL ------------
"$REMEDY" disable >/dev/null 2>&1; rc=$?
check_rc 0 "$rc" "second disable succeeds"
[ "$(cat "$SENECHAL_KITTY_CONF")" = "$ORIGINAL_KITTY" ] \
  && pass "kitty.conf still byte-identical after re-disable" || fail "re-disable changed kitty.conf"
"$REMEDY" verify >/dev/null 2>&1; rc=$?
check_rc 5 "$rc" "verify after disable reports FAIL"

# ---- 10. no profiles.ini at all: could-not-check, never a pass -------
mv "$SENECHAL_FIREFOX_ROOT/profiles.ini" "$SENECHAL_FIREFOX_ROOT/profiles.ini.away"
"$REMEDY" verify >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && pass "verify without profiles.ini is not a pass (rc=$rc)" \
                || fail "verify passed with no profiles.ini"
mv "$SENECHAL_FIREFOX_ROOT/profiles.ini.away" "$SENECHAL_FIREFOX_ROOT/profiles.ini"

# ---- 11. estate.taste[split-pane-chord].status: disabled -- a no-op ---
before_kitty="$(cat "$SENECHAL_KITTY_CONF")"
before_custom="$(cat "$CUSTOM_KEYS")"
cat > "$SENECHAL_CONFIG" <<'JSON'
{"estate": {"taste": [
  {"id": "split-pane-chord", "files": ["kitty.conf"],
   "hosts": ["mandark"], "status": "disabled"}
]}}
JSON

out="$("$REMEDY" enable 2>&1)"; rc=$?
check_rc 0 "$rc" "enable is a no-op while status is disabled"
printf '%s\n' "$out" | grep -q '"disabled" -- nothing to do' \
  && pass "enable says why it did nothing" || fail "enable's no-op message missing: $out"
[ "$(cat "$SENECHAL_KITTY_CONF")" = "$before_kitty" ] \
  && pass "kitty.conf untouched while disabled" || fail "kitty.conf was written while disabled"
[ "$(cat "$CUSTOM_KEYS")" = "$before_custom" ] \
  && pass "customKeys.json untouched while disabled" || fail "customKeys.json was written while disabled"

out="$("$REMEDY" verify 2>&1)"; rc=$?
check_rc 2 "$rc" "verify reports could-not-check while status is disabled"
printf '%s\n' "$out" | grep -q '"disabled" -- not expected to be in effect' \
  && pass "verify says why it skipped" || fail "verify's skip message missing: $out"

printf '{}\n' > "$SENECHAL_CONFIG"
"$REMEDY" verify >/dev/null 2>&1; rc=$?
check_rc 5 "$rc" "verify runs normally with no estate.taste row at all"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "PASS -- split-pane-chord"
  exit 0
fi
echo "FAIL -- $fails assertion(s) failed"
exit 1
