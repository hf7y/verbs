#!/usr/bin/env bash
# Test harness for curl-bash-installs.sh. Runs the real script against a
# throwaway HOME/history with PATH-stubbed package-manager tools, so the
# managed/unmanaged/vanished cases are exercised deterministically and no
# real shell history, package database, or binary is ever touched.
#
# Exit: 0 all assertions pass / 1 any assertion failed.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home" "$T/snap/bin" "$T/home/.local/bin"

# --- fake shell history: one managed (snap), one unmanaged-still-here,
# one that ran once and left no trace on PATH, and one ordinary command
# that must NOT be picked up at all.
cat > "$T/home/.bash_history" <<'HIST'
ls -la
curl -fsSL https://managedthing.example.com/install.sh | sh
curl -fsSL https://looseends.example.com/install | bash
curl -fsSL https://ghosttool.example.com/install.sh | bash
echo not a curl line
HIST

# managedthing: lands in $T/snap/bin, snap-tracked
cat > "$T/snap/bin/managedthing" <<'SH'
#!/bin/sh
SH
chmod +x "$T/snap/bin/managedthing"

# looseends: lands in ~/.local/bin, no package manager owns it
cat > "$T/home/.local/bin/looseends" <<'SH'
#!/bin/sh
SH
chmod +x "$T/home/.local/bin/looseends"

# ghosttool: history shows it ran, but nothing is on PATH now

# --- stub package-manager tools -----------------------------------------
cat > "$T/bin/snap" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = list ]; then
  if [ "${2:-}" = managedthing ]; then
    echo "Name  Version  Rev  Tracking  Publisher  Notes"
    echo "managedthing  1  1  stable  x  -"
    exit 0
  fi
  echo "Name  Version  Rev  Tracking  Publisher  Notes"
  echo "managedthing  1  1  stable  x  -"
  echo "otherapp  1  1  stable  x  -"
  exit 0
fi
exit 1
STUB
chmod +x "$T/bin/snap"

cat > "$T/bin/dpkg" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "-S" ]; then
  [ "\$2" = "$T/snap/bin/managedthing" ] && exit 0
  exit 1
fi
exit 1
STUB
chmod +x "$T/bin/dpkg"

cat > "$T/bin/apt-mark" <<'STUB'
#!/usr/bin/env bash
[ "$1" = showmanual ] && { echo pkg1; echo pkg2; echo pkg3; exit 0; }
exit 1
STUB
chmod +x "$T/bin/apt-mark"

cat > "$T/bin/npm" <<'STUB'
#!/usr/bin/env bash
echo "/fake"
echo "└── some-global-tool@1.0.0"
STUB
chmod +x "$T/bin/npm"

cat > "$T/bin/pip3" <<'STUB'
#!/usr/bin/env bash
echo "Package Version"
echo "------- -------"
echo "somepkg 1.0"
STUB
chmod +x "$T/bin/pip3"

echo '{}' > "$T/senechal.json"

out="$(PATH="$T/bin:$T/snap/bin:$T/home/.local/bin:$PATH" \
       HOME="$T/home" \
       SENECHAL_CONFIG="$T/senechal.json" \
       bash ./curl-bash-installs.sh 2>&1)"
rc=$?

fails=0
expect() {
  if grep -qF "$1" <<<"$out"; then
    printf 'ok:   %s\n' "$1"
  else
    printf 'MISS: %s\n' "$1"
    fails=$((fails + 1))
  fi
}

expect "managedthing (https://managedthing.example.com/install.sh) -- $T/snap/bin/managedthing, handed off to dpkg, tracked like any other package"
expect "looseends (https://looseends.example.com/install) -- unmanaged binary at $T/home/.local/bin/looseends, only curl|bash can update or remove it"
expect "ghosttool (https://ghosttool.example.com/install.sh) -- ran once (history), nothing found on PATH now"
expect "unmanaged curl|bash: 1"
expect "unmanaged: looseends"
if ! grep -q "not a curl line" <<<"$out" 2>/dev/null; then
  printf 'ok:   ordinary command not picked up as a curl|bash install\n'
else
  printf 'MISS: ordinary command wrongly picked up\n'
  fails=$((fails + 1))
fi

[ "$rc" -eq 3 ] && printf 'ok:   exit 3 (warn -- unmanaged installs present)\n' || {
  printf 'MISS: expected exit 3, got %s\n' "$rc"
  fails=$((fails + 1))
}

# --- no readable history at all: must be INCOMPLETE, not a silent pass --
out2="$(PATH="$T/bin:$PATH" HOME="$T/nohome" SENECHAL_CONFIG="$T/senechal.json" \
        bash ./curl-bash-installs.sh 2>&1)"
rc2=$?
if grep -qF "no readable shell history" <<<"$out2"; then
  printf 'ok:   no-history case reports could-not-check\n'
else
  printf 'MISS: no-history case did not report could-not-check\n%s\n' "$out2"
  fails=$((fails + 1))
fi
[ "$rc2" -eq 2 ] && printf 'ok:   exit 2 (incomplete) with no history\n' || {
  printf 'MISS: expected exit 2 with no history, got %s\n' "$rc2"
  fails=$((fails + 1))
}

echo "---"
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "$fails FAILED"
  exit 1
fi
