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
  # NB: candidates arrive on stdin (piped from _candidate_units), but the
  # heredoc below is ALSO delivered on fd0 as python's program text --
  # `python3 - <<'PY'` would silently read the program from stdin and
  # leave sys.stdin exhausted, so `for line in sys.stdin` would see
  # nothing and every unit would read as "matched" no matter what's on
  # disk. Duplicate the real pipe onto fd 3 first, then let the heredoc
  # claim fd0 for the program; the script reads candidates from fd 3.
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

main() {
  parse_common_args "$@"
  _emit "senechal undeclared-footprint sweep -- $(date '+%Y-%m-%d %H:%M') on $THIS_HOST"
  check_units
  list_ports
  finish_verify "OK -- no undeclared custom systemd units found."
}
main "$@"
