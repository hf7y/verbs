#!/usr/bin/env bash
# systemd-install-test.sh -- exercises install.sh/uninstall.sh end to end.
#
# gardien#153: the six unit files these scripts install/remove were carried
# back onto `bashified` by name only -- restored in #5 alongside the four
# scripts, but never themselves put back after the earlier "Total purge"
# deleted them. `install.sh` (`set -eu`) died on its first `cp` and nobody
# noticed, because nothing exercised it. This never touches the real
# `systemctl --user` state on the runner -- GARDE_SYSTEMCTL points every
# call at a stub that only logs what it was asked to do.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
GARDE="$ROOT/bin/garde"
pass=0; fail=0
ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (want $3, got $2)"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (output lacked: $3)" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/home"
CALLS="$TMP/systemctl.calls"
mkdir -p "$FAKE_HOME"

cat > "$TMP/systemctl-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
exit 0
STUB
chmod +x "$TMP/systemctl-stub"

UNIT_DIR="$FAKE_HOME/.config/systemd/user"
UNITS="gardien.service gardien.timer gardien-check-stale.service gardien-check-stale.timer gardien-git-hygiene.service gardien-git-hygiene.timer"

echo "=== systemd install/uninstall: exercises the real scripts"; echo

: > "$CALLS"
OUT="$(HOME="$FAKE_HOME" GARDE_SYSTEMCTL="$TMP/systemctl-stub" bash "$ROOT/systemd/install.sh" 2>&1)"; RC=$?
check "install.sh exits 0 on a fresh HOME" "$RC" 0

missing=0
for u in $UNITS; do
  [ -f "$UNIT_DIR/$u" ] || missing=$((missing+1))
done
[ "$missing" -eq 0 ] && ok "all six unit files landed in \$HOME/.config/systemd/user" \
                      || bad "all six unit files landed in \$HOME/.config/systemd/user ($missing missing)"

diff -q "$ROOT/systemd/gardien.service" "$UNIT_DIR/gardien.service" >/dev/null 2>&1 \
  && ok "the installed unit is byte-identical to the repo's copy" \
  || bad "the installed unit is byte-identical to the repo's copy"

CALL_LOG="$(cat "$CALLS")"
has "install.sh reloaded the daemon" "$CALL_LOG" "--user daemon-reload"
has "...and enabled gardien.timer" "$CALL_LOG" "--user enable --now gardien.timer"
has "...and enabled gardien-check-stale.timer" "$CALL_LOG" "--user enable --now gardien-check-stale.timer"
has "...and enabled gardien-git-hygiene.timer" "$CALL_LOG" "--user enable --now gardien-git-hygiene.timer"

# --- re-running install.sh is idempotent --------------------------------
OUT="$(HOME="$FAKE_HOME" GARDE_SYSTEMCTL="$TMP/systemctl-stub" bash "$ROOT/systemd/install.sh" 2>&1)"; RC=$?
check "a second install.sh run still exits 0" "$RC" 0

# --- install.sh --json (gardien#164) -- GARDE_JSON is how bin/garde hands
# --json through its exec into this POSIX-sh script, since it cannot
# source verb.sh itself ------------------------------------------------
OUT="$(HOME="$FAKE_HOME" GARDE_SYSTEMCTL="$TMP/systemctl-stub" GARDE_JSON=1 bash "$ROOT/systemd/install.sh" 2>&1)"; RC=$?
check "install.sh --json (GARDE_JSON=1) still exits 0" "$RC" 0
printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 \
  && ok "install.sh GARDE_JSON=1 emits parseable JSON" || bad "install.sh GARDE_JSON=1 produced invalid JSON: $OUT"
[ "$(printf '%s' "$OUT" | jq -r .ok)" = true ] \
  && ok "install.sh --json reports ok:true" || bad "install.sh --json ok flag wrong: $OUT"
[ "$(printf '%s' "$OUT" | jq -r '.units | length')" = 6 ] \
  && ok "install.sh --json names all six unit files" || bad "install.sh --json units array wrong: $OUT"
case "$OUT" in *"installed and enabled"*) bad "install.sh --json must not also print the prose confirmation" ;;
                *) ok "install.sh --json stdout carries only JSON, no prose" ;; esac

# --- through bin/garde: install --json (gardien#164) --------------------
OUT="$(HOME="$FAKE_HOME" GARDE_SYSTEMCTL="$TMP/systemctl-stub" VERB_COST_FILE="$TMP/cost" "$GARDE" install --json 2>&1)"; RC=$?
check "garde install --json still exits 0" "$RC" 0
[ "$(printf '%s' "$OUT" | jq -r .ok)" = true ] \
  && ok "garde install --json relays GARDE_JSON through the exec" \
  || bad "garde install --json shape wrong: $OUT"

# --- uninstall removes everything it installed --------------------------
: > "$CALLS"
OUT="$(HOME="$FAKE_HOME" GARDE_SYSTEMCTL="$TMP/systemctl-stub" bash "$ROOT/systemd/uninstall.sh" 2>&1)"; RC=$?
check "uninstall.sh exits 0" "$RC" 0

left=0
for u in $UNITS; do
  [ -f "$UNIT_DIR/$u" ] && left=$((left+1))
done
[ "$left" -eq 0 ] && ok "uninstall.sh removed all six unit files" \
                   || bad "uninstall.sh removed all six unit files ($left still present)"

CALL_LOG="$(cat "$CALLS")"
has "uninstall.sh disabled gardien.timer" "$CALL_LOG" "--user disable --now gardien.timer"
has "...and reloaded the daemon afterward" "$CALL_LOG" "--user daemon-reload"

# --- uninstall.sh --json (gardien#164) -----------------------------------
: > "$CALLS"
OUT="$(HOME="$FAKE_HOME" GARDE_SYSTEMCTL="$TMP/systemctl-stub" GARDE_JSON=1 bash "$ROOT/systemd/uninstall.sh" 2>&1)"; RC=$?
check "uninstall.sh --json (GARDE_JSON=1) still exits 0" "$RC" 0
printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 \
  && ok "uninstall.sh GARDE_JSON=1 emits parseable JSON" || bad "uninstall.sh GARDE_JSON=1 produced invalid JSON: $OUT"
[ "$(printf '%s' "$OUT" | jq -r .ok)" = true ] \
  && ok "uninstall.sh --json reports ok:true" || bad "uninstall.sh --json ok flag wrong: $OUT"
[ "$(printf '%s' "$OUT" | jq -r .unit_dir)" = "$UNIT_DIR" ] \
  && ok "uninstall.sh --json names the unit dir it cleared" || bad "uninstall.sh --json unit_dir wrong: $OUT"
case "$OUT" in *"disabled and unit files removed"*) bad "uninstall.sh --json must not also print the prose confirmation" ;;
                *) ok "uninstall.sh --json stdout carries only JSON, no prose" ;; esac

# --- through bin/garde: uninstall --json (gardien#164) -------------------
OUT="$(HOME="$FAKE_HOME" GARDE_SYSTEMCTL="$TMP/systemctl-stub" VERB_COST_FILE="$TMP/cost" "$GARDE" uninstall --json 2>&1)"; RC=$?
check "garde uninstall --json still exits 0" "$RC" 0
[ "$(printf '%s' "$OUT" | jq -r .ok)" = true ] \
  && ok "garde uninstall --json relays GARDE_JSON through the exec" \
  || bad "garde uninstall --json shape wrong: $OUT"

printf '\n--- systemd-install: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
