#!/usr/bin/env bash
# Concern: windows land on the wrong virtual desktop.
#
#   ./window-spawn-desktop.sh enable       # install the shims (run by hand, once)
#   ./window-spawn-desktop.sh verify       # check they're in effect (no AI, cron-safe)
#   [rest: vault:senechal/header-archaeology-20260818.md]

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

REPO_TOOLS="$SENECHAL_ROOT/tools"
BIN="$HOME/.local/bin"
SHIMS=(spawn-here browse)
KWINRULES="$HOME/.config/kwinrulesrc"

QUIET=0
[ "${2:-}" = "-q" ] && QUIET=1
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
loud() { printf '%s\n' "$*" >&2; }

# A symlink onto PATH outlives the process that made it. Run from a
# throwaway clone (tools/vault.sh run, any mktemp -d checkout) this used
# to bake /tmp/tmp.XXXX/tools/<shim> into ~/.local/bin, and `verify`
# passed at enable time -- the temp dir was still there. It broke when
# the clone was deleted, with nothing watching. Refuse at the source.
#
# ephemeral_path() now lives in ../lib/common.sh: the same defect reached
# the two --user timers' ExecStart on 2026-08-22 because this guard was
# local to this file. One copy, three callers.
ephemeral_root() { ephemeral_path "$REPO_TOOLS"; }

do_enable() {
  if ephemeral_root; then
    loud "REFUSING: $REPO_TOOLS is a temporary checkout -- the symlinks would"
    loud "dangle as soon as it is deleted. Run enable from the permanent clone."
    return "$RC_INCOMPLETE"
  fi
  mkdir -p "$BIN"
  for s in "${SHIMS[@]}"; do
    [ -x "$REPO_TOOLS/$s" ] || { loud "missing $REPO_TOOLS/$s -- nothing installed"; return "$RC_INCOMPLETE"; }
  done
  for s in "${SHIMS[@]}"; do
    if [ -e "$BIN/$s" ] && [ ! -L "$BIN/$s" ]; then
      loud "$BIN/$s exists and is NOT a symlink -- refusing to clobber it"
      return "$RC_FAIL"
    fi
    ln -sfn "$REPO_TOOLS/$s" "$BIN/$s"
    echo "linked $BIN/$s -> $REPO_TOOLS/$s"
  done
  # Symlinks, not copies, so the shim on PATH and the file in the repo
  # can never drift into two different versions of the same tool.
  # Filed TYPED (2026-08-16): one filing per shim, as the footprint records
  # they always were. This used to be one sentence naming both, which a human
  # then had to split into two estate.footprint rows by hand -- the prose
  # round trip registry/front-doors.json exists to delete.
  if command -v notify-senechal >/dev/null; then
    for s in "${SHIMS[@]}"; do
      notify-senechal footprint \
        "id=window-spawn-shim-$s" \
        kind=path \
        "target=$BIN/$s" \
        host="$(hostname -s 2>/dev/null || hostname)" \
        owner=senechal \
        status=live \
        "retire=remedies/window-spawn-desktop.sh disable" \
        "notes=symlink onto PATH into $REPO_TOOLS, installed by remedies/window-spawn-desktop.sh enable" || true
    done
  else
    loud "notify-senechal not on PATH -- footprint NOT filed; do it by hand"
  fi
  echo
  echo "Next: declare your profiles under \"windows\": {\"profiles\": {...}} in"
  echo "$SENECHAL_CONFIG (see senechal.json.example), then: browse <name>"
  return "$RC_PASS"
}

do_disable() {
  for s in "${SHIMS[@]}"; do
    if [ -L "$BIN/$s" ]; then rm -f "$BIN/$s"; echo "removed $BIN/$s"; fi
  done
  return "$RC_PASS"
}

do_clean_rules() {
  [ -f "$KWINRULES" ] || { loud "no $KWINRULES -- nothing to clean"; return "$RC_INCOMPLETE"; }
  local backup="$KWINRULES.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$KWINRULES" "$backup"
  echo "backed up to $backup"
  python3 - "$KWINRULES" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
# Split on group headers, keeping them.
parts = re.split(r'(?m)^(?=\[)', text)
kept, dropped = [], []
for p in parts:
    header = p.split('\n', 1)[0].strip()
    is_chromium_dead = 'wmclass=chromium' in p and re.search(r'^desktops=\\+0\s*$', p, re.M)
    if is_chromium_dead:
        dropped.append(header)
        continue
    kept.append(p)
open(path, 'w').write(''.join(kept))
print("dropped: " + (", ".join(dropped) if dropped else "nothing"))
PY
  # Renumber [General] to match what survived, or KWin reads a rule
  # count that no longer corresponds to any group.
  python3 - "$KWINRULES" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
groups = [g for g in re.findall(r'(?m)^\[(.+?)\]\s*$', text)
          if g not in ('$Version', 'General')]
text = re.sub(r'(?m)^count=.*$', 'count=%d' % len(groups), text)
text = re.sub(r'(?m)^rules=.*$', 'rules=%s' % ','.join(groups), text)
open(path, 'w').write(text)
print("[General] now: count=%d rules=%s" % (len(groups), ','.join(groups)))
PY
  echo "KWin re-reads this on 'qdbus org.kde.KWin /KWin reconfigure' or next login."
  if command -v qdbus >/dev/null && [ -n "${DISPLAY:-}" ]; then
    qdbus org.kde.KWin /KWin reconfigure >/dev/null 2>&1 && echo "kwin reconfigured"
  fi
  return "$RC_PASS"
}

do_verify() {
  local rc="$RC_PASS"
  for s in "${SHIMS[@]}"; do
    if [ ! -L "$BIN/$s" ]; then
      loud "FAIL $BIN/$s is not a symlink -- the concern is not in effect (run: enable)"
      rc="$RC_FAIL"; continue
    fi
    local target; target=$(readlink -f "$BIN/$s")
    if [ ! -e "$target" ]; then
      loud "FAIL $BIN/$s dangles -> $(readlink "$BIN/$s") (gone; re-run enable from the permanent clone)"
      rc="$RC_FAIL"; continue
    fi
    if [ "$target" != "$(readlink -f "$REPO_TOOLS/$s")" ]; then
      loud "FAIL $BIN/$s points at $target, not $REPO_TOOLS/$s"
      rc="$RC_FAIL"; continue
    fi
    [ -x "$target" ] || { loud "FAIL $target is not executable"; rc="$RC_FAIL"; continue; }
    say "ok   $BIN/$s -> $target"
  done

  # The tools are useless without wmctrl; say so rather than letting the
  # first real launch fail at 2am.
  if ! command -v wmctrl >/dev/null; then
    loud "FAIL wmctrl is not installed -- spawn-here cannot place anything (apt install wmctrl)"
    rc="$RC_FAIL"
  else
    say "ok   wmctrl present"
  fi

  # Dead chromium rules are a finding, not a failure: they do nothing.
  if [ -f "$KWINRULES" ] && grep -q 'wmclass=chromium' "$KWINRULES"; then
    loud "WARN $KWINRULES still holds a chromium rule with an empty desktop id (no effect; run: clean-rules)"
    [ "$rc" = "$RC_PASS" ] && rc="$RC_WARN"
  fi

  # Declared profiles are optional, but an empty registry means `browse`
  # has nothing to do, which is worth saying out loud once.
  local n; n=$(python3 -c "
import json,sys
try: print(len(json.load(open('$SENECHAL_CONFIG')).get('windows',{}).get('profiles',{})))
except Exception: print(-1)" 2>/dev/null)
  if [ "$n" = "0" ]; then
    say "note no windows.profiles declared yet in $SENECHAL_CONFIG -- spawn-here works, browse has nothing to open"
  elif [ "$n" = "-1" ]; then
    loud "WARN could not read windows.profiles from $SENECHAL_CONFIG"
    [ "$rc" = "$RC_PASS" ] && rc="$RC_WARN"
  else
    say "ok   $n window profile(s) declared"
  fi

  return "$rc"
}

case "${1:-}" in
  enable)      do_enable ;;
  disable)     do_disable ;;
  clean-rules) do_clean_rules ;;
  verify)      do_verify ;;
  *) echo "usage: $(basename "$0") {enable|disable|clean-rules|verify [-q]}" >&2; exit "$RC_INCOMPLETE" ;;
esac
