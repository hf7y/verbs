#!/usr/bin/env bash
# Tests remedies/snap-free-mandark.sh's `verify` against stubbed `snap`,
# `dpkg-query` and `tailscale` on PATH -- never the real machine, and no
# sudo. The point is the PASS side: on mandark today every snap is still
# installed, so a live run can only ever demonstrate the FAIL side, and
# a verify that cannot pass is indistinguishable from one that cannot
# fail.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

pass=0; fail=0
check() { # check <label> <expected-rc> <actual-rc>
  if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1 (expected rc=$2, got rc=$3)"; fail=$((fail+1)); fi
}

# $1: snaps still present (space-separated), $2: debs installed,
# $3: tailscale status rc, $4: systemctl is-active rc for tailscaled.
# Echoes verify's exit code.
run_verify() {
  local stub; stub="$(mktemp -d)"
  cat >"$stub/snap" <<EOF
#!/usr/bin/env bash
[ "\$1" = list ] || exit 0
for s in ${1:-}; do [ "\$s" = "\$2" ] && exit 0; done
exit 1
EOF
  cat >"$stub/dpkg-query" <<EOF
#!/usr/bin/env bash
for d in ${2:-}; do [ "\$d" = "\${!#}" ] && { echo installed; exit 0; }; done
exit 1
EOF
  cat >"$stub/tailscale" <<EOF
#!/usr/bin/env bash
exit ${3:-0}
EOF
  cat >"$stub/systemctl" <<EOF
#!/usr/bin/env bash
exit ${4:-0}
EOF
  chmod +x "$stub"/*
  PATH="$stub:$PATH" ./snap-free-mandark.sh verify -q >/dev/null 2>&1
  local rc=$?
  rm -rf "$stub"
  echo "$rc"
}

echo "snap-free-mandark.sh verify:"
check "all four swapped + tailnet up -> PASS" 0 \
  "$(run_verify "" "tailscale gnome-firmware glow obsidian" 0)"
check "a snap still installed -> FAIL" 1 \
  "$(run_verify "glow" "tailscale gnome-firmware glow obsidian" 0)"
check "replacement deb missing -> FAIL" 1 \
  "$(run_verify "" "tailscale gnome-firmware obsidian" 0)"
check "tailscale installed but off the tailnet -> FAIL" 1 \
  "$(run_verify "" "tailscale gnome-firmware glow obsidian" 1 0)"
check "tailscaled not running -> FAIL" 1 \
  "$(run_verify "" "tailscale gnome-firmware glow obsidian" 0 3)"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
