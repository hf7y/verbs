#!/usr/bin/env bash
# Test harness for auto-apply-remedies.sh. Builds a throwaway "origin"
# repo and a throwaway "checkout" that fetches from it, so the real
# senechal repo and Zach's real state dir are never touched.
#
# Exit: 0 all assertions pass / 1 any assertion failed.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
expect() { # expect <description> <actual> <expected>
  if [ "$2" = "$3" ]; then
    printf 'ok:   %s\n' "$1"
  else
    printf 'FAIL: %s -- got %q, expected %q\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}
expect_contains() { # expect_contains <description> <haystack> <needle>
  if grep -qF "$3" <<< "$2"; then
    printf 'ok:   %s\n' "$1"
  else
    printf 'FAIL: %s -- did not find %q\n' "$1" "$3"
    fails=$((fails + 1))
  fi
}

git config --global user.email "test@example.com" >/dev/null 2>&1 || true
git config --global user.name "test" >/dev/null 2>&1 || true

# --- build a throwaway "origin" with a minimal remedy under remedies/ ----
ORIGIN="$T/origin"
mkdir -p "$ORIGIN/remedies" "$ORIGIN/tools" "$ORIGIN/lib"
git -C "$ORIGIN" init --quiet --initial-branch=main
cp ./auto-apply-remedies.sh "$ORIGIN/tools/auto-apply-remedies.sh"
touch "$ORIGIN/lib/common.sh"
git -C "$ORIGIN" add -A
git -C "$ORIGIN" commit --quiet -m "seed"

# --- checkout: clones origin, runs the real script against it -----------
CHECKOUT="$T/checkout"
git clone --quiet "$ORIGIN" "$CHECKOUT"
STATE_DIR="$T/state"

run() {
  SENECHAL_AUTOAPPLY_STATE_DIR="$STATE_DIR" bash "$CHECKOUT/tools/auto-apply-remedies.sh" "$@"
}

# 1) first run: no state yet -> establishes baseline, applies nothing
out="$(run)"; rc=$?
expect "first run exits 0" "$rc" "0"
expect_contains "first run establishes a baseline" "$out" "establishing baseline"
[ -f "$STATE_DIR/auto-apply-remedies.sha" ] && printf 'ok:   %s\n' "state file created" || { printf 'FAIL: state file not created\n'; fails=$((fails+1)); }

# 2) add a non-sudo remedy that currently FAILs verify (rc=1) -> must auto-enable
cat > "$ORIGIN/remedies/marker-file.sh" <<'EOF'
#!/usr/bin/env bash
TARGET="${MARKER_TARGET:-/nonexistent}"
case "${1:-}" in
  enable) mkdir -p "$(dirname "$TARGET")"; touch "$TARGET"; echo "created $TARGET" ;;
  verify) [ -f "$TARGET" ] && exit 0 || exit 1 ;;
esac
EOF
chmod +x "$ORIGIN/remedies/marker-file.sh"
git -C "$ORIGIN" add -A
git -C "$ORIGIN" commit --quiet -m "add marker-file remedy"

MARKER="$T/marker-target/marker"
export MARKER_TARGET="$MARKER"
out="$(run)"; rc=$?
expect "second run (new non-sudo remedy) exits 0" "$rc" "0"
expect_contains "auto-enabled the new remedy" "$out" "ENABLING  marker-file.sh"
expect_contains "reports it now passes" "$out" "OK    marker-file.sh -- enabled, verify now passes"
[ -f "$MARKER" ] && printf 'ok:   %s\n' "enable actually ran (marker file exists)" || { printf 'FAIL: marker file was not created -- enable did not really run\n'; fails=$((fails+1)); }

# 3) re-run with no new commits -> no-op, must not re-enable
rm -f "$MARKER"
out="$(run)"; rc=$?
expect "third run (nothing new) exits 0" "$rc" "0"
expect_contains "third run is a no-op" "$out" "nothing to do"
[ -f "$MARKER" ] && { printf 'FAIL: third run re-ran enable when nothing changed\n'; fails=$((fails+1)); } || printf 'ok:   %s\n' "did not re-enable on an unchanged remote"

# 4) add a sudo-using remedy -> must be skipped, never auto-run
cat > "$ORIGIN/remedies/needs-sudo.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  enable) sudo touch /should-never-run ;;
  verify) exit 1 ;;
esac
EOF
chmod +x "$ORIGIN/remedies/needs-sudo.sh"
git -C "$ORIGIN" add -A
git -C "$ORIGIN" commit --quiet -m "add sudo remedy"
out="$(run)"; rc=$?
expect "fourth run (sudo remedy) exits 0" "$rc" "0"
expect_contains "sudo remedy is skipped, not run" "$out" "SKIP  needs-sudo.sh -- enable uses sudo"

# 5) --dry-run must report without applying
cat > "$ORIGIN/remedies/dry-run-check.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  enable) touch "$DRYRUN_MARKER" ;;
  verify) exit 1 ;;
esac
EOF
chmod +x "$ORIGIN/remedies/dry-run-check.sh"
git -C "$ORIGIN" add -A
git -C "$ORIGIN" commit --quiet -m "add dry-run-check remedy"
export DRYRUN_MARKER="$T/dryrun-marker"
out="$(run --dry-run)"; rc=$?
expect_contains "dry-run reports what it would do" "$out" "WOULD ENABLE  dry-run-check.sh"
[ -f "$DRYRUN_MARKER" ] && { printf 'FAIL: dry-run actually ran enable\n'; fails=$((fails+1)); } || printf 'ok:   %s\n' "dry-run applied nothing"
# state must not have advanced past dry-run
out2="$(run)"; expect_contains "state unchanged after dry-run, real run still sees the commit" "$out2" "ENABLING  dry-run-check.sh"

# 6) a lib/*.sh-only change must still surface the wrapper that sources
#    it, even though the wrapper's own file didn't change in this diff
#    (regression: 'remedies/*.sh' pathspecs don't cross '/', so a
#    shared-engine edit used to be invisible here -- see #348 comment)
mkdir -p "$ORIGIN/remedies/lib"
cat > "$ORIGIN/remedies/lib/toggle-engine.sh" <<'EOF'
toggle_enable() { touch "$ENGINE_MARKER"; }
EOF
cat > "$ORIGIN/remedies/engine-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "${BASH_SOURCE[0]}")"
. lib/toggle-engine.sh
TARGET="${ENGINE_TARGET:-/nonexistent}"
case "${1:-}" in
  enable) toggle_enable; mkdir -p "$(dirname "$TARGET")"; touch "$TARGET" ;;
  verify) [ -f "$TARGET" ] && exit 0 || exit 1 ;;
esac
EOF
chmod +x "$ORIGIN/remedies/engine-wrapper.sh"
git -C "$ORIGIN" add -A
git -C "$ORIGIN" commit --quiet -m "add engine-wrapper sourcing lib/toggle-engine.sh"
ENGINE_TARGET="$T/engine-target/marker"
export ENGINE_TARGET
out="$(run)"; rc=$?
expect_contains "engine-wrapper picked up on its own commit" "$out" "ENABLING  engine-wrapper.sh"
rm -f "$ENGINE_TARGET"

# now change ONLY the lib file, in a commit that touches no remedies/*.sh
cat > "$ORIGIN/remedies/lib/toggle-engine.sh" <<'EOF'
toggle_enable() { touch "$ENGINE_MARKER"; }
# a comment-only edit is enough to advance the SHA
EOF
git -C "$ORIGIN" add -A
git -C "$ORIGIN" commit --quiet -m "edit lib/toggle-engine.sh only"
out="$(run)"; rc=$?
expect "lib-only-change run exits 0" "$rc" "0"
expect_contains "lib-only change still surfaces the wrapper that sources it" "$out" "ENABLING  engine-wrapper.sh"
[ -f "$ENGINE_TARGET" ] && printf 'ok:   %s\n' "wrapper actually re-ran off a lib-only commit" || { printf 'FAIL: wrapper did not re-run off a lib-only commit\n'; fails=$((fails+1)); }

if [ "$fails" -eq 0 ]; then
  echo "test-auto-apply-remedies: all assertions passed"
  exit 0
else
  echo "test-auto-apply-remedies: $fails assertion(s) failed"
  exit 1
fi
