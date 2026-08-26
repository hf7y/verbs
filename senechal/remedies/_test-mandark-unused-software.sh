#!/usr/bin/env bash
# Tests for remedies/mandark-unused-software.sh.
#
#   ./_test-mandark-unused-software.sh
#
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
REMEDY="$(pwd)/mandark-unused-software.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0; failed=0
check() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
  fi
}

H="$T/home"
CFG="$H/.config/senechal/senechal.json"
PLASMA_CONF="$H/.config/plasma-org.kde.plasma.desktop-appletsrc"

write_registry() { # <json items array, already comma-joined>
  mkdir -p "$(dirname "$CFG")"
  printf '{"unused_software": {"items": [%s]}}\n' "$1" > "$CFG"
}

R() { # <verb...>
  OUT="$(HOME="$H" XDG_CONFIG_HOME="$H/.config" SENECHAL_CONFIG="$CFG" \
         SENECHAL_BACKUP_ROOT="$H/.backups" bash "$REMEDY" "$@" 2>&1)"
  RC=$?
}

fresh() {
  rm -rf "$H"
  mkdir -p "$H/.local/bin"
}

# --- ordinary localbin case: no panel involved -------------------------
fresh
write_registry '{"name": "abandoned-tool", "kind": "localbin", "evidence": "test fixture"}'
: > "$H/.local/bin/abandoned-tool"

R verify
check "localbin present: verify FAILs"                1 "$RC"
check "localbin present: verify names the file"       yes \
  "$(case "$OUT" in *"abandoned-tool still present"*) echo yes ;; *) echo no ;; esac)"

R enable
check "localbin: enable exits 0"                      0 "$RC"
check "localbin: enable removed the file"             no \
  "$([ -e "$H/.local/bin/abandoned-tool" ] && echo yes || echo no)"

R verify
check "localbin: verify PASSes after enable"          0 "$RC"

R enable
check "localbin: second enable is idempotent"         0 "$RC"
check "localbin: second enable says already absent"   yes \
  "$(case "$OUT" in *"already absent"*) echo yes ;; *) echo no ;; esac)"

# --- empty registry ------------------------------------------------------
fresh
write_registry ''
R verify
check "empty registry: verify does not FAIL"          yes \
  "$([ "$RC" -eq 0 ] || [ "$RC" -eq 2 ] && echo yes || echo no)"

# --- unknown kind ----------------------------------------------------------
fresh
write_registry '{"name": "mystery", "kind": "flatpak", "evidence": "test fixture"}'
R verify
check "unknown kind: verify does not crash"           yes \
  "$(case "$OUT" in *"unknown kind"*) echo yes ;; *) echo no ;; esac)"

# --- THE CASE: registered removal target still pinned to the KDE panel ---
# Shaped exactly like the real obs-studio/digikam/darktable finding:
# zero usage evidence, but a real launchers= entry on a live panel.
fresh
write_registry '{"name": "abandoned-tool", "kind": "localbin", "evidence": "test fixture", "desktop_id": "abandoned-tool.desktop"}'
: > "$H/.local/bin/abandoned-tool"
mkdir -p "$(dirname "$PLASMA_CONF")"
cat > "$PLASMA_CONF" <<'EOF'
[Containments][2][Applets][24][Configuration]
launchers=preferred://browser,applications:krita.desktop,applications:abandoned-tool.desktop,applications:gimp.desktop
EOF

R enable
check "pinned: enable removed the file"               no \
  "$([ -e "$H/.local/bin/abandoned-tool" ] && echo yes || echo no)"
check "pinned: the pin is gone from the panel after enable" no \
  "$(grep -q 'applications:abandoned-tool.desktop' "$PLASMA_CONF" && echo yes || echo no)"
check "pinned: neighbouring launchers survive"        yes \
  "$(grep -q 'applications:krita.desktop' "$PLASMA_CONF" && grep -q 'applications:gimp.desktop' "$PLASMA_CONF" && echo yes || echo no)"

R verify
check "pinned: verify PASSes only once the pin is gone too" 0 "$RC"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
