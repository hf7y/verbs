#!/usr/bin/env bash
# senechal: undeclared machine-config sweep. Non-AI, cron-safe, READ-ONLY.
#
# dead-config.sh answers "is every entry senechal already knows about
# still what it says it is". This answers the other half: "does
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

THIS_HOST="${SENECHAL_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
SYSTEM_UNIT_DIR="${SENECHAL_SYSTEM_UNIT_DIR:-/etc/systemd/system}"
USER_UNIT_DIR="${SENECHAL_USER_UNIT_DIR:-$HOME/.config/systemd/user}"
FIREFOX_PROFILES_DIR="${SENECHAL_FIREFOX_PROFILES_DIR:-$HOME/.mozilla/firefox}"
AUTOSTART_DIR="${SENECHAL_AUTOSTART_DIR:-$HOME/.config/autostart}"
KGLOBALSHORTCUTS_FILE="${SENECHAL_KGLOBALSHORTCUTS_FILE:-$HOME/.config/kglobalshortcutsrc}"
LOCAL_APPS_DIR="${SENECHAL_LOCAL_APPS_DIR:-$HOME/.local/share/applications}"
LOCAL_BIN_DIR="${SENECHAL_LOCAL_BIN_DIR:-$HOME/.local/bin}"

# Basenames known to be package/subsystem-managed rather than someone's
# project, even though they land as real (non-symlink) files. Extend
# as new noise turns up. Space-separated glob patterns.
KNOWN_NOISE="snap.*"

_is_known_noise() {
  local base="$1" pat
  for pat in $KNOWN_NOISE; do
    # shellcheck disable=SC2053
    [[ "$base" == $pat ]] && return 0
  done
  return 1
}

# Real (non-symlink) *.service/*.timer files directly in a systemd unit
# directory. One basename per line. A symlink means systemd enabled a
# vendor unit living elsewhere -- exactly the case this must not flag.
_real_unit_files() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' \) -printf '%f\n' 2>/dev/null
}

# Candidate units, one "scope<0x1f>basename" per line.
_candidate_units() {
  local base
  _real_unit_files "$SYSTEM_UNIT_DIR" | while IFS= read -r base; do
    _is_known_noise "$base" || printf 'system\x1f%s\n' "$base"
  done
  _real_unit_files "$USER_UNIT_DIR" | while IFS= read -r base; do
    printf 'user\x1f%s\n' "$base"
  done
}

# Cross-reference candidate unit basenames against senechal.json's
# footprint targets. Reads "scope<0x1f>basename" on stdin, prints only
# the ones NOT matched by any footprint target. Matching is a fuzzy
# stem-substring compare (not a real glob engine) so that a footprint
# entry covering several units with one wildcard target (e.g.
# bibliothecaire-intake's "bibliothecaire-intake*.{service,timer}")
# still matches each real unit it was meant to cover.
_unmatched_units() {
  # `python3 - <<PY` claims fd0 for the program, so move candidates piped
  # in from stdin to fd 3 first (same fix in _undeclared_local_paths below).
  python3 - "$SENECHAL_CONFIG" 3<&0 <<'PY'
import json, os, re, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
targets = [str(e.get('target', '')) for e in d.get('estate', {}).get('footprint', [])]

def clean(s):
    s = s.rsplit('/', 1)[-1]
    s = re.sub(r'\.\{[^}]*\}$', '', s)
    s = re.sub(r'\.(service|timer|socket|mount|path)$', '', s)
    s = s.replace('*', '').replace('?', '')
    return s

cleaned_targets = [c for c in (clean(t) for t in targets) if c]

for line in os.fdopen(3):
    line = line.rstrip('\n')
    if not line:
        continue
    scope, base = line.split('\x1f', 1)
    stem = clean(base)
    if stem and any(ct in stem or stem in ct for ct in cleaned_targets):
        continue
    print(f'{scope}\x1f{base}')
PY
}

check_units() {
  head_ "Systemd units on-disk but not in senechal.json's estate.footprint"
  local scope base any=0
  while IFS=$'\x1f' read -r scope base; do
    any=1
    warn_ "$scope unit $base is installed but not declared in estate.footprint"
    note "file it: add an entry (kind: systemd-$scope-unit, target: \"$base\", host: \"$THIS_HOST\") once its owner and status are known -- or, if another project put it here, run notify-senechal"
  done < <(_candidate_units | _unmatched_units)
  [ "$any" -eq 1 ] || ok "no undeclared custom systemd units found (system: $SYSTEM_UNIT_DIR, user: $USER_UNIT_DIR)"
}

# Informational only -- see the SCOPE note at top of file for why this
# never counts toward the exit code.
list_ports() {
  head_ "Listening ports (informational -- not counted toward the verdict)"
  command -v ss >/dev/null 2>&1 || { skip "ss not available -- cannot list listening ports"; return; }

  local declared_ports
  declared_ports="$(python3 - "$SENECHAL_CONFIG" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
print(' '.join(str(e.get('target', '')) for e in d.get('estate', {}).get('footprint', [])
                if e.get('kind') == 'listening-port'))
PY
)"

  local line addr port tag p any=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    any=1
    addr="$(printf '%s' "$line" | awk '{print $4}')"
    port="${addr##*:}"
    tag="not in estate.footprint"
    for p in $declared_ports; do
      [ "$p" = "$port" ] && tag="declared (listening-port: $p)" && break
    done
    note "$line -- $tag"
  done < <(ss -ltnp 2>/dev/null | awk 'NR>1{$1=$1; print}')
  [ "$any" -eq 1 ] || note "nothing currently listening"
}

# browser.startup.homepage is pipe-list-valued -- split on '|'.
_firefox_path_prefs() {
  local f
  for f in "$FIREFOX_PROFILES_DIR"/*/prefs.js "$FIREFOX_PROFILES_DIR"/*/user.js; do
    [ -f "$f" ] || continue
    python3 - "$f" <<'PY'
import re, sys
KEYS = {"browser.startup.homepage"}
pat = re.compile(r'user_pref\("([^"]+)",\s*"([^"]*)"\);')
for line in open(sys.argv[1], errors="replace"):
    m = pat.match(line.strip())
    if not m or m.group(1) not in KEYS:
        continue
    for v in m.group(2).split('|'):
        v = v.strip()
        if v.startswith('file://'):
            v = v[len('file://'):]
        if v.startswith('/'):
            print(v)
PY
  done
}

# Exec= naming a local absolute path -- a bare PATH command is not a path.
_autostart_targets() {
  local f target
  for f in "$AUTOSTART_DIR"/*.desktop; do
    [ -f "$f" ] || continue
    target="$(sed -n 's/^Exec=//p' "$f" | head -1)"
    target="${target%% *}"
    case "$target" in /*) printf '%s\n' "$target" ;; esac
  done
}

_kglobalshortcuts_targets() {
  local f="$KGLOBALSHORTCUTS_FILE" section desktop_file target
  [ -f "$f" ] || return 0
  while IFS= read -r section; do
    case "$section" in *.desktop) ;; *) continue ;; esac
    desktop_file="$LOCAL_APPS_DIR/$section"
    [ -f "$desktop_file" ] || continue
    target="$(sed -n 's/^Exec=//p' "$desktop_file" | head -1)"
    target="${target%% *}"
    case "$target" in /*) printf '%s\n' "$target" ;; esac
  done < <(sed -n 's/^\[\(.*\)\]$/\1/p' "$f")
}

_local_bin_real_files() {
  [ -d "$LOCAL_BIN_DIR" ] || return 0
  find "$LOCAL_BIN_DIR" -maxdepth 1 -type f -printf '%p\n' 2>/dev/null
}

# Cross-reference against kind=path footprint targets (fd-3 trick above).
_undeclared_local_paths() {
  local have_dpkg=0
  command -v dpkg >/dev/null 2>&1 && have_dpkg=1
  python3 - "$SENECHAL_CONFIG" "$HOME" "$have_dpkg" 3<&0 <<'PY'
import json, os, subprocess, sys
cfg, home, have_dpkg = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
try:
    d = json.load(open(cfg))
except Exception:
    d = {}
declared = {e.get('target') for e in d.get('estate', {}).get('footprint', [])
            if e.get('kind') == 'path'}

def package_owned(p):
    if not have_dpkg:
        return False
    r = subprocess.run(["dpkg", "-S", p], capture_output=True)
    return r.returncode == 0

seen = set()
for line in os.fdopen(3):
    p = line.rstrip('\n')
    if not p or p in seen:
        continue
    seen.add(p)
    if not p.startswith(home + os.sep) or not os.path.exists(p):
        continue
    if p in declared or package_owned(p):
        continue
    print(p)
PY
}

check_local_paths() {
  head_ "App config pointing at a local path, not in estate.footprint (#456)"
  local any=0 p
  while IFS= read -r p; do
    any=1
    warn_ "$p is referenced by local app config but not declared in estate.footprint"
    note "file it: add an entry (kind: path, target: \"$p\", host: \"$THIS_HOST\") once its owner and status are known -- or, if another project put it here, run notify-senechal"
  done < <({ _firefox_path_prefs; _autostart_targets; _kglobalshortcuts_targets; _local_bin_real_files; } | _undeclared_local_paths)
  [ "$any" -eq 1 ] || ok "no undeclared local path found in Firefox prefs or autostart entries"
}

main() {
  parse_common_args "$@"
  _emit "senechal undeclared-footprint sweep -- $(date '+%Y-%m-%d %H:%M') on $THIS_HOST"
  check_units
  check_local_paths
  list_ports
  finish_verify "OK -- no undeclared custom systemd units found."
}
main "$@"
