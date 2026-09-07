#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/os-rebuild-witness.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; echo "       $2"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpected '$3'" ;; *) ok "$1" ;; esac; }

mkdir -p "$T/bin"

cat > "$T/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -l) cat "$FAKE_ROOT/dpkg-l.txt" ;;
  -S) grep -F "$2" "$FAKE_ROOT/dpkg-S.txt" 2>/dev/null || exit 1 ;;
  *) exit 1 ;;
esac
EOF

cat > "$T/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "remove" ]; then
  cat "$FAKE_ROOT/apt-get-remove-output.txt"
  exit "$(cat "$FAKE_ROOT/apt-get-remove-exit.txt" 2>/dev/null || echo 0)"
fi
exit 1
EOF

cat > "$T/bin/apt-cache" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "depends" ]; then
  pkg="${*: -1}"
  cat "$FAKE_ROOT/apt-cache-depends-$pkg.txt" 2>/dev/null
  exit 0
fi
exit 1
EOF
chmod +x "$T/bin/dpkg" "$T/bin/apt-get" "$T/bin/apt-cache"

for app in kitty firefox signal-desktop synergy; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$app"
  chmod +x "$T/bin/$app"
done

export FAKE_ROOT="$T"
export PATH="$T/bin:$PATH"

echo '{}' > "$T/senechal.json"
export SENECHAL_CONFIG="$T/senechal.json"

reset_fakes() {
  : > "$T/dpkg-l.txt"
  : > "$T/dpkg-S.txt"
  : > "$T/apt-get-remove-output.txt"
  rm -f "$T/apt-get-remove-exit.txt"
  rm -f "$T"/apt-cache-depends-*.txt
  for app in kitty firefox signal-desktop synergy; do
    echo "$app-pkg: $T/bin/$app" >> "$T/dpkg-S.txt"
  done
}

run() { RUN_OUT="$(bash "$SCRIPT" "$@" 2>&1)"; RUN_RC=$?; }

echo "test-os-rebuild-witness.sh"

echo "-- A. no KDE-ish meta-package installed -- SKIP, exit 2, not a guess"
reset_fakes
echo "ii  vim  9.0  amd64  editor" >> "$T/dpkg-l.txt"
run
[ "$RUN_RC" -eq 2 ] && ok "A1 exit 2 (RC_INCOMPLETE)" || bad "A1 exit 2 (RC_INCOMPLETE)" "got $RUN_RC"
has "A2 says SKIP" "$RUN_OUT" "SKIP"
has "A3 points at mandark" "$RUN_OUT" "run this on mandark itself"

echo "-- B. KDE detected, clean removal, no keep-target conflict"
reset_fakes
echo "ii  plasma-desktop  5.0  amd64  desktop" >> "$T/dpkg-l.txt"
{
  echo "Remv unrelated-pkg-a [1.0]"
  echo "Remv unrelated-pkg-b [2.0]"
} > "$T/apt-get-remove-output.txt"
echo "kitty-pkg-dep-1" > "$T/apt-cache-depends-kitty-pkg.txt"
echo "firefox-pkg-dep-1" > "$T/apt-cache-depends-firefox-pkg.txt"
run
[ "$RUN_RC" -eq 0 ] && ok "B1 exit 0 (RC_PASS)" || bad "B1 exit 0 (RC_PASS)" "got $RUN_RC"
has "B2 says PASS" "$RUN_OUT" "PASS"
has "B3 counts the two removals" "$RUN_OUT" "would-remove: 2 package(s)"

echo "-- C. a keep-target's own package is in the would-remove list"
reset_fakes
echo "ii  plasma-desktop  5.0  amd64  desktop" >> "$T/dpkg-l.txt"
{
  echo "Remv kitty-pkg [1.0]"
  echo "Remv unrelated-pkg [2.0]"
} > "$T/apt-get-remove-output.txt"
run
[ "$RUN_RC" -eq 3 ] && ok "C1 exit 3 (RC_WARN)" || bad "C1 exit 3 (RC_WARN)" "got $RUN_RC"
has "C2 says WARN" "$RUN_OUT" "WARN"
has "C3 names the conflicting package" "$RUN_OUT" "kitty-pkg itself is in the would-remove list"

echo "-- D. a keep-target's dependency (not the package itself) is in the would-remove list"
reset_fakes
echo "ii  plasma-desktop  5.0  amd64  desktop" >> "$T/dpkg-l.txt"
{
  echo "Remv libshared-thing [1.0]"
} > "$T/apt-get-remove-output.txt"
echo "libshared-thing" > "$T/apt-cache-depends-firefox-pkg.txt"
run
[ "$RUN_RC" -eq 3 ] && ok "D1 exit 3 (RC_WARN)" || bad "D1 exit 3 (RC_WARN)" "got $RUN_RC"
has "D2 names which keep target depends on it" "$RUN_OUT" "firefox-pkg depends on libshared-thing"

echo "-- E. apt-get --simulate itself fails -- SKIP, exit 2, not a false PASS"
reset_fakes
echo "ii  plasma-desktop  5.0  amd64  desktop" >> "$T/dpkg-l.txt"
echo "E: some apt error" > "$T/apt-get-remove-output.txt"
echo 100 > "$T/apt-get-remove-exit.txt"
run
[ "$RUN_RC" -eq 2 ] && ok "E1 exit 2 (RC_INCOMPLETE)" || bad "E1 exit 2 (RC_INCOMPLETE)" "got $RUN_RC"
has "E2 says SKIP" "$RUN_OUT" "SKIP"
hasnt "E3 does not claim PASS" "$RUN_OUT" "PASS"

echo "-- F. a --keep name with no installed binary is noted, not fatal"
reset_fakes
echo "ii  plasma-desktop  5.0  amd64  desktop" >> "$T/dpkg-l.txt"
echo "Remv unrelated-pkg [1.0]" > "$T/apt-get-remove-output.txt"
run --keep=kitty,does-not-exist-anywhere
[ "$RUN_RC" -eq 0 ] && ok "F1 still exits 0" || bad "F1 still exits 0" "got $RUN_RC"

echo "-- G. --help documents the exit-code contract and never touches the host"
run --help
[ "$RUN_RC" -eq 0 ] && ok "G1 exit 0" || bad "G1 exit 0" "got $RUN_RC"
has "G2 states the --simulate guarantee" "$RUN_OUT" "--simulate"
has "G3 documents exit code 3" "$RUN_OUT" "3 conflict found"

echo "-- H. an unknown flag refuses rather than guessing"
run --bogus
[ "$RUN_RC" -eq 1 ] && ok "H1 exit 1" || bad "H1 exit 1" "got $RUN_RC"
has "H2 names the bad argument" "$RUN_OUT" "unknown argument: --bogus"

echo
echo "test-os-rebuild-witness.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
