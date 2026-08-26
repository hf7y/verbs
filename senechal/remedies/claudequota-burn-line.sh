#!/usr/bin/env bash
# Concern: the "Claude Quota" KDE plasmoid's weekly quota bar has no burn-
# line -- hf7y/senechal#4 ("add burn line to weekly usage as well. display
# burn line as red line overlay on quota bar").
#
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

PLASMOID_DIR="${SENECHAL_CLAUDEQUOTA_DIR:-$HOME/.local/share/plasma/plasmoids/com.docusketch.claudequota}"
QML="$PLASMOID_DIR/contents/ui/main.qml"
MARKER="senechal-burn-line-2026-08-11"

_patch() { # $1 = path to main.qml, writes in place, idempotent
  python3 - "$1" "$MARKER" <<'PY'
import re, sys
path, marker = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()

if marker in src:
    print("already patched")
    raise SystemExit(0)

# 1) target-pct properties, right after weekBurn's own definition.
anchor1 = '    readonly property var winBurnOnline: (source === "online" && winActive) ? burnLine(winPct, winRemMin, 5 * 60, false) : null\n'
if anchor1 not in src:
    print("ANCHOR1-NOT-FOUND", file=sys.stderr)
    raise SystemExit(1)
addition1 = anchor1 + (
    "\n    // %s -- where usage SHOULD be right now under an even-burn pace,\n"
    "    // as an x-position on the bar (0..100). Pure arithmetic over fields\n"
    "    // already fetched above; no new data source.\n"
    "    readonly property real winBurnTargetPct: winActive ? Math.min(100, (5 * 60 - winRemMin) / (5 * 60) * 100) : -1\n"
    "    readonly property real weekBurnTargetPct: weekActive ? Math.min(100, (7 * 24 * 60 - weekRemMin) / (7 * 24 * 60) * 100) : -1\n"
) % marker
src = src.replace(anchor1, addition1, 1)

# 2) QuotaBar component: add the property + the red marker rectangle.
anchor2 = '    component QuotaBar: Rectangle {\n        property int pct: 0\n        property bool active: false\n        property bool loading: false\n'
if anchor2 not in src:
    print("ANCHOR2-NOT-FOUND", file=sys.stderr)
    raise SystemExit(1)
addition2 = anchor2 + "        property real burnTargetPct: -1  // %s\n" % marker
src = src.replace(anchor2, addition2, 1)

marker_rect = (
    "        // %s: even-burn pace marker -- a thin red line at the x\n"
    "        // position usage would be at under a straight burn to 100%%\n"
    "        // by reset. Visible only once we have a real target (>= 0).\n"
    "        Rectangle {\n"
    "            anchors { top: parent.top; bottom: parent.bottom; margins: 2 }\n"
    "            visible: parent.active && parent.burnTargetPct >= 0\n"
    "            x: 2 + Math.max(0, Math.min(1, parent.burnTargetPct / 100)) * (parent.width - 4) - width / 2\n"
    "            width: 2\n"
    "            color: \"#da4453\"\n"
    "            z: 10\n"
    "        }\n"
) % marker
# Insert right before the closing "}" of the QuotaBar component, i.e.
# right before the trailing label's closing brace + component's own
# closing brace. Anchor on the label block, which is the last child.
anchor3 = '        PlasmaComponents.Label {\n            anchors.centerIn: parent\n            text: parent.active ? parent.pct + "%" : (parent.loading ? "loading…" : "—")\n            font.bold: true\n        }\n    }\n}\n'
if anchor3 not in src:
    print("ANCHOR3-NOT-FOUND", file=sys.stderr)
    raise SystemExit(1)
src = src.replace(anchor3, marker_rect + anchor3, 1)

# 3) wire the two QuotaBar instantiations to pass the target.
anchor4 = 'QuotaBar { pct: root.winPct; active: root.winActive; loading: !root.ready }'
if anchor4 not in src:
    print("ANCHOR4-NOT-FOUND", file=sys.stderr)
    raise SystemExit(1)
src = src.replace(anchor4, 'QuotaBar { pct: root.winPct; active: root.winActive; loading: !root.ready; burnTargetPct: root.winBurnTargetPct }', 1)

anchor5 = 'QuotaBar { pct: root.weekPct; active: root.weekActive; loading: !root.ready }'
if anchor5 not in src:
    print("ANCHOR5-NOT-FOUND", file=sys.stderr)
    raise SystemExit(1)
src = src.replace(anchor5, 'QuotaBar { pct: root.weekPct; active: root.weekActive; loading: !root.ready; burnTargetPct: root.weekBurnTargetPct }', 1)

open(path, "w", encoding="utf-8").write(src)
print("patched")
PY
}

cmd_enable() {
  [ -f "$QML" ] || die "not found: $QML -- is the claudequota plasmoid installed under a different path? Override with SENECHAL_CLAUDEQUOTA_DIR."
  if grep -q "$MARKER" "$QML" 2>/dev/null; then
    say "already applied ($MARKER present in $QML) -- nothing to do"
    exit 0
  fi
  local bak
  bak="$(backup_file "$QML")"
  say "backed up: $bak"
  _patch "$QML" || die "patch failed -- main.qml's shape has changed since this remedy was written; restored nothing (original is untouched, patch is all-or-nothing on a fresh read). Diff main.qml against the anchors in this script's _patch()."
  command -v qmllint >/dev/null 2>&1 && { qmllint "$QML" && say "qmllint: clean" || warn "qmllint reported issues -- review $QML before trusting the widget"; }
  say "applied. Restart plasmashell (or just wait for the widget's own refresh timer) to see it: plasmashell --replace &"
}

cmd_verify() {
  parse_common_args "$@"
  head_ "Claude Quota plasmoid: burn-line marker on both quota bars"
  if [ ! -f "$QML" ]; then
    skip "plasmoid not found at $QML"
    finish_verify
  fi
  if grep -q "burnTargetPct: root.winBurnTargetPct" "$QML" && grep -q "burnTargetPct: root.weekBurnTargetPct" "$QML" && grep -q '"#da4453"' "$QML"; then
    ok "both quota bars wired to a burn-target marker"
  else
    fail "burn-line marker not present in $QML -- run: $0 enable"
  fi
  finish_verify "OK -- burn-line overlay present on both windows."
}

case "${1:-}" in
  enable) cmd_enable ;;
  verify) shift; cmd_verify "$@" ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
