#!/usr/bin/env bash
# Test harness for live-references.sh. Runs the real script against a
# throwaway target directory with systemctl/crontab/installe all
# PATH-stubbed, so no real host state (real units, real crontabs, real
# installe manifest) is ever touched or required.
#
# Exit: 0 all assertions pass / 1 any assertion failed.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

T="$(mktemp -d)"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/target/health" "$T/elsewhere" \
  "$T/spool-readable" "$T/spool-noaccess"

SELF_USER="$(id -un)"
TARGET="$T/target"
: > "$TARGET/health/estate-health.sh"

# --- stub systemctl: replays canned unit lists / show blocks ------------
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
scope=system
if [ "$1" = "--user" ]; then scope=user; shift; fi
cmd="${1:-}"; shift || true
case "$cmd" in
  list-unit-files)
    [ -f "$STUB_DIR/units-$scope.txt" ] && cat "$STUB_DIR/units-$scope.txt"
    ;;
  show)
    unit="${1:-}"
    [ -f "$STUB_DIR/show-$scope-$unit.txt" ] && cat "$STUB_DIR/show-$scope-$unit.txt"
    ;;
esac
exit 0
STUB
chmod +x "$T/bin/systemctl"

# --- stub crontab: this account's crontab only (real spool dirs are
# read directly by the script, not through this stub) -------------------
cat > "$T/bin/crontab" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then
  if [ -f "$STUB_DIR/crontab-self.txt" ]; then
    cat "$STUB_DIR/crontab-self.txt"
    exit 0
  fi
  echo "no crontab for $(id -un)" >&2
  exit 1
fi
exit 1
STUB
chmod +x "$T/bin/crontab"

# --- stub installe: replays a canned `installe list --json` -------------
cat > "$T/bin/installe" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "list" ] && [ "${2:-}" = "--json" ]; then
  [ -f "$STUB_DIR/installe-list.json" ] && cat "$STUB_DIR/installe-list.json"
  exit 0
fi
exit 1
STUB
chmod +x "$T/bin/installe"

run() {
  STUB_DIR="$T" PATH="$T/bin:$PATH" \
  SENECHAL_CRON_SPOOL_DIRS="$T/spool-readable $T/spool-noaccess" \
  bash ./live-references.sh "$@"
}

fails=0
expect_line() { # expect_line <marker> <substring...>
  local marker="$1"; shift
  if grep -qF "  $marker  $*" <<< "$out"; then
    printf 'ok:   %s  %s\n' "$marker" "$*"
  else
    printf 'MISS: %s  %s\n' "$marker" "$*"
    fails=$((fails + 1))
  fi
}
expect_text() {
  if grep -qF "$1" <<< "$out"; then
    printf 'ok:   text %s\n' "$1"
  else
    printf 'MISS: text %s\n' "$1"
    fails=$((fails + 1))
  fi
}
expect_no_text() {
  if grep -qF "$1" <<< "$out"; then
    printf 'MISS: unexpectedly present: %s\n' "$1"
    fails=$((fails + 1))
  else
    printf 'ok:   absent %s\n' "$1"
  fi
}
expect_rc() {
  if [ "$rc" -eq "$1" ]; then
    printf 'ok:   rc=%s\n' "$1"
  else
    printf 'MISS: expected rc=%s, got %s\n' "$1" "$rc"
    fails=$((fails + 1))
  fi
}

# =========================================================================
# Scenario A: references everywhere -- a mixed, realistic run.
# =========================================================================

# systemd, user scope: senechal-health.timer-shaped hit, WITH TriggeredBy
# context -- the exact motivating case from hf7y/senechal#66.
cat > "$T/units-user.txt" <<EOF
senechal-health.service                static  -
unrelated-user.service                 enabled enabled
EOF
cat > "$T/show-user-senechal-health.service.txt" <<EOF
ExecStart=$TARGET/health/estate-health.sh --quiet
TriggeredBy=senechal-health.timer
FragmentPath=/home/x/.config/systemd/user/senechal-health.service
EOF
cat > "$T/show-user-unrelated-user.service.txt" <<'EOF'
ExecStart=/usr/bin/true
EOF

# systemd, system scope: a hit via ExecStartPre, no TriggeredBy.
cat > "$T/units-system.txt" <<EOF
other-live.service                     enabled enabled
clean-system.service                   enabled enabled
EOF
cat > "$T/show-system-other-live.service.txt" <<EOF
ExecStartPre=$TARGET/health/pre-check.sh
FragmentPath=/etc/systemd/system/other-live.service
EOF
cat > "$T/show-system-clean-system.service.txt" <<'EOF'
ExecStart=/usr/bin/false
EOF

# crontab, this account: one active hit, one commented-out (ignored) line.
cat > "$T/crontab-self.txt" <<EOF
# this line is a comment and must be ignored even though it names the path
# 0 0 * * * $TARGET/health/commented-out.sh
15 * * * * $TARGET/health/cron-job.sh --flag
EOF

# crontab, other accounts, via the real spool dirs (not the stub).
: > "$T/spool-readable/$SELF_USER"          # must be skipped (it's us)
echo "0 3 * * * $TARGET/health/other-user-job.sh" > "$T/spool-readable/otheruser"
echo "0 4 * * * /some/unrelated/path.sh"     > "$T/spool-readable/clean-user"
: > "$T/spool-readable/locked-out"
chmod 000 "$T/spool-readable/locked-out"
chmod 000 "$T/spool-noaccess"

# installe: one verb resolves inside the target dir, one does not.
cat > "$T/installe-list.json" <<EOF
[
  {"name": "estate-health", "target": "$TARGET/health/estate-health.sh"},
  {"name": "unrelated-verb", "target": "$T/elsewhere/tool"}
]
EOF

out="$(run "$TARGET" 2>&1)"
rc=$?

expect_line FAIL "systemd user unit senechal-health.service -- ExecStart=$TARGET/health/estate-health.sh --quiet (triggered by: senechal-health.timer)"
expect_line FAIL "systemd system unit other-live.service -- ExecStartPre=$TARGET/health/pre-check.sh"
expect_no_text "unrelated-user.service"
expect_no_text "clean-system.service"

expect_line FAIL "crontab ($SELF_USER) -- 15 * * * * $TARGET/health/cron-job.sh --flag"
expect_no_text "commented-out.sh"
expect_line FAIL "crontab (otheruser) -- 0 3 * * * $TARGET/health/other-user-job.sh"
expect_no_text "clean-user"
expect_line SKIP "crontab (locked-out): $T/spool-readable/locked-out exists but is not readable from here"
expect_line SKIP "crontab (other accounts): cannot list $T/spool-noaccess (permission denied)"

expect_line FAIL "installed verb 'estate-health' -> $TARGET/health/estate-health.sh (resolves to $TARGET/health/estate-health.sh)"
expect_no_text "unrelated-verb"

expect_text "NOT-REMOVABLE"
expect_no_text "        REMOVABLE -- "   # the all-clear NOTE line must not also appear
expect_rc 1

chmod 755 "$T/spool-readable/locked-out" "$T/spool-noaccess" 2>/dev/null

# =========================================================================
# Scenario B: a fully clean, fully checkable target -- REMOVABLE, rc=0.
# =========================================================================
T2="$(mktemp -d)"
mkdir -p "$T2/target" "$T2/spool-readable" "$T2/spool-noaccess"
cat > "$T2/units-user.txt" <<'EOF'
clean.service enabled enabled
EOF
cat > "$T2/show-user-clean.service.txt" <<'EOF'
ExecStart=/usr/bin/true
EOF
: > "$T2/units-system.txt"
cat > "$T2/crontab-self.txt" <<'EOF'
0 5 * * * /nothing/to/see.sh
EOF
cat > "$T2/installe-list.json" <<'EOF'
[{"name": "clean-verb", "target": "/usr/bin/true"}]
EOF

out2="$(STUB_DIR="$T2" PATH="$T/bin:$PATH" \
        SENECHAL_CRON_SPOOL_DIRS="$T2/spool-readable $T2/spool-noaccess" \
        bash ./live-references.sh "$T2/target" 2>&1)"
rc2=$?
if [ "$rc2" -eq 0 ] && grep -qF "REMOVABLE -- " <<< "$out2" && ! grep -qF "NOT-REMOVABLE" <<< "$out2"; then
  printf 'ok:   clean target is REMOVABLE, rc=0\n'
else
  printf 'MISS: clean target gave rc=%s, out=%s\n' "$rc2" "$out2"; fails=$((fails + 1))
fi
rm -rf "$T2"

# --- quiet flag: clean pass prints nothing -------------------------------
T3="$(mktemp -d)"
mkdir -p "$T3/target" "$T3/spool-readable" "$T3/spool-noaccess"
: > "$T3/units-user.txt"; : > "$T3/units-system.txt"
: > "$T3/crontab-self.txt"
echo '[]' > "$T3/installe-list.json"
out3="$(STUB_DIR="$T3" PATH="$T/bin:$PATH" \
        SENECHAL_CRON_SPOOL_DIRS="$T3/spool-readable $T3/spool-noaccess" \
        bash ./live-references.sh "$T3/target" -q 2>&1)"
rc3=$?
if [ "$rc3" -eq 0 ] && [ -z "$out3" ]; then
  printf 'ok:   -q on a clean pass prints nothing\n'
else
  printf 'MISS: -q clean pass gave rc=%s, out=%q\n' "$rc3" "$out3"; fails=$((fails + 1))
fi
rm -rf "$T3"

# =========================================================================
# Scenario C: usage / could-not-check edge cases.
# =========================================================================

out4="$(bash ./live-references.sh 2>&1)"; rc4=$?
if [ "$rc4" -eq 2 ]; then
  printf 'ok:   no path argument -> rc=2\n'
else
  printf 'MISS: no path argument gave rc=%s\n' "$rc4"; fails=$((fails + 1))
fi

out5="$(bash ./live-references.sh "$T/does-not-exist" 2>&1)"; rc5=$?
if [ "$rc5" -eq 2 ] && grep -qF 'does not exist or is not a directory' <<< "$out5"; then
  printf 'ok:   nonexistent path -> rc=2, said so\n'
else
  printf 'MISS: nonexistent path gave rc=%s, out=%s\n' "$rc5" "$out5"; fails=$((fails + 1))
fi

# installe missing entirely -> SKIP, not a silent "no verbs found".
# Filters any real `installe` off PATH -- wherever it actually resolves
# (~/.local/bin on a personal dev machine, /usr/local/bin host-wide on a
# self-dev account) -- rather than shrinking PATH to a handful of dirs,
# so every other tool the script needs (grep, sed, date, python3, id...)
# still resolves normally.
T6="$(mktemp -d)"
mkdir -p "$T6/target" "$T6/spool-readable" "$T6/spool-noaccess" "$T6/bin"
: > "$T6/units-user.txt"; : > "$T6/units-system.txt"
: > "$T6/crontab-self.txt"
cp "$T/bin/systemctl" "$T/bin/crontab" "$T6/bin/"
REAL_INSTALLE_DIRS="$(IFS=:; for d in $PATH; do [ -x "$d/installe" ] && printf '%s\n' "$d"; done)"
if [ -n "$REAL_INSTALLE_DIRS" ]; then
  FILTERED_PATH="$T6/bin:$(printf '%s' "$PATH" | tr ':' '\n' | grep -vFxf <(printf '%s\n' "$REAL_INSTALLE_DIRS") | paste -sd: -)"
else
  FILTERED_PATH="$T6/bin:$PATH"
fi
out6="$(STUB_DIR="$T6" PATH="$FILTERED_PATH" \
        SENECHAL_CRON_SPOOL_DIRS="$T6/spool-readable $T6/spool-noaccess" \
        bash ./live-references.sh "$T6/target" 2>&1)"
rc6=$?
if [ "$rc6" -eq 2 ] && grep -qF "installe: not on PATH" <<< "$out6" && grep -qF "UNKNOWN" <<< "$out6"; then
  printf 'ok:   installe unavailable -> SKIP + rc=2, verdict UNKNOWN\n'
else
  printf 'MISS: installe-missing case gave rc=%s, out=%s\n' "$rc6" "$out6"; fails=$((fails + 1))
fi
rm -rf "$T6"

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'all assertions passed\n'; exit 0
fi
printf '%d assertion(s) failed\n' "$fails"
exit 1
