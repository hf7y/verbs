#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
. ../lib/common.sh

DEFAULT_KEEP="kitty,firefox,signal-desktop,synergy"
KEEP="$DEFAULT_KEEP"
OUT=""

usage() {
  cat <<'EOF'
usage: os-rebuild-witness.sh [--keep NAME[,NAME...]] [--out FILE]

Read-only, apt --simulate only -- see hf7y/senechal#344. Derives what
`apt-get remove --auto-remove` would drop for every installed
KDE/Plasma/Studio-desktop meta-package, and flags any --keep target
(default: kitty,firefox,signal-desktop,synergy) whose own dependency
closure would go with it.

--keep NAME[,NAME...]   commands that must keep working
--out FILE              witness log path (default: mktemp)

Exit: 0 clean, 2 could not derive (no KDE-ish package here, or apt
refused -- run on the target host for a real witness), 3 conflict found.
EOF
}

for a in "$@"; do
  case "$a" in
    --keep=*) KEEP="${a#*=}" ;;
    --keep) die "--keep needs a value, e.g. --keep=kitty,firefox" ;;
    --out=*) OUT="${a#*=}" ;;
    --out) die "--out needs a path" ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $a (try --help)" ;;
  esac
done

command -v apt-get >/dev/null 2>&1 || {
  echo "SKIP  no apt-get on this host -- not a Debian/Ubuntu family system (could not check -- not a pass)"
  exit "$RC_INCOMPLETE"
}
command -v dpkg >/dev/null 2>&1 || die "dpkg missing on a host that has apt-get -- broken install"

[ -n "$OUT" ] || OUT="$(mktemp -t os-rebuild-witness-XXXXXX.log)"

{
  printf '# os-rebuild-witness -- %s -- host %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)"
  printf '# hf7y/senechal#344 -- read-only, apt --simulate only, nothing installed/removed\n\n'
} > "$OUT"

log_raw() { printf '%s\n' "$*" >> "$OUT"; }

mapfile -t kde_meta < <(dpkg -l 2>/dev/null | awk '$1=="ii"{print $2}' \
  | grep -Ei '^(kde-|plasma-desktop|plasma-workspace|kubuntu-desktop|ubuntustudio-desktop)' || true)

log_raw "## detected KDE/Plasma/Studio-desktop meta-packages"
if [ "${#kde_meta[@]}" -eq 0 ]; then
  log_raw "(none found -- dpkg -l has no kde-*/plasma-desktop/plasma-workspace/kubuntu-desktop/ubuntustudio-desktop package)"
  echo "SKIP  no KDE/Plasma/Studio-desktop meta-package installed on this host -- run this on mandark itself for a real witness (could not check -- not a pass)"
  echo "      witness log: $OUT"
  exit "$RC_INCOMPLETE"
fi
printf '%s\n' "${kde_meta[@]}" >> "$OUT"
log_raw ""

log_raw "## --keep targets"
declare -a keep_pkgs=()
IFS=',' read -r -a keep_names <<< "$KEEP"
for name in "${keep_names[@]}"; do
  [ -n "$name" ] || continue
  bin="$(command -v "$name" 2>/dev/null || true)"
  if [ -z "$bin" ]; then
    log_raw "$name: no binary on PATH -- not installed here"
    continue
  fi
  pkg="$(dpkg -S "$(readlink -f "$bin")" 2>/dev/null | head -1 | cut -d: -f1)"
  if [ -z "$pkg" ]; then
    log_raw "$name: $bin -- not owned by any dpkg package (foreign install)"
    continue
  fi
  log_raw "$name: $bin -> $pkg"
  keep_pkgs+=("$pkg")
done
log_raw ""

log_raw "## apt-get remove --simulate --auto-remove ${kde_meta[*]}"
sim_out="$(apt-get remove --simulate --auto-remove "${kde_meta[@]}" 2>&1)"
sim_rc=$?
log_raw "$sim_out"
log_raw ""

if [ "$sim_rc" -ne 0 ]; then
  echo "SKIP  apt-get --simulate itself failed (exit $sim_rc) -- see $OUT (could not check -- not a pass)"
  exit "$RC_INCOMPLETE"
fi

mapfile -t would_remove < <(printf '%s\n' "$sim_out" | awk '/^Remv /{print $2}')
log_raw "## packages apt would remove: ${#would_remove[@]}"

declare -A wr_set=()
for wr in "${would_remove[@]:-}"; do
  [ -n "$wr" ] && wr_set["$wr"]=1
done

declare -a conflicts=()
for kp in "${keep_pkgs[@]:-}"; do
  [ -n "$kp" ] || continue
  if [ -n "${wr_set[$kp]:-}" ]; then
    conflicts+=("$kp itself is in the would-remove list")
  fi
  mapfile -t deps < <(apt-cache depends --recurse --no-recommends --no-suggests \
    --no-conflicts --no-breaks --no-replaces --no-enhances "$kp" 2>/dev/null \
    | grep -E '^[A-Za-z0-9]')
  for d in "${deps[@]:-}"; do
    if [ -n "${wr_set[$d]:-}" ]; then
      conflicts+=("$kp depends on $d, which apt would remove")
    fi
  done
done

log_raw "## conflicts: ${#conflicts[@]}"
printf '%s\n' "${conflicts[@]:-}" >> "$OUT"

echo "witness log: $OUT"
echo "would-remove: ${#would_remove[@]} package(s)"
if [ "${#conflicts[@]}" -gt 0 ]; then
  echo "WARN  ${#conflicts[@]} keep-target dependency conflict(s) -- read $OUT before trusting the removal list"
  printf '  %s\n' "${conflicts[@]}"
  exit "$RC_WARN"
fi

echo "PASS  clean derivation, no keep-target conflict -- ${#would_remove[@]} package(s) removable per apt's own solver"
exit "$RC_PASS"
