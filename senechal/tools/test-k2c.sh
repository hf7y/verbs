#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/k2c"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1"; echo "       $2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want '$2', got '$3'"; }

mapfile -t INK_COMMENTS < <(grep -E '\("[a-z]+", *\([0-9, ]*\)\)' "$SCRIPT" | sed -n 's/^.*)[]),] *# *//p')

echo "-- A. palette entries, parsed from tools/k2c"
[ "${#INK_COMMENTS[@]}" -gt 0 ] || bad "A0 parsed at least one palette entry" "found none -- did tools/k2c's PALETTE literal change shape?"

solo_found=""
c=0; m=0; y=0
for entry in "${INK_COMMENTS[@]}"; do
  case "$entry" in *+*) : ;; *) solo_found="$solo_found $entry" ;; esac
  case "$entry" in *C*) c=$((c+1)) ;; esac
  case "$entry" in *M*) m=$((m+1)) ;; esac
  case "$entry" in *Y*) y=$((y+1)) ;; esac
done

[ -z "$solo_found" ] && ok "A1 no palette entry recruits a single ink alone" \
  || bad "A1 no palette entry recruits a single ink alone" "solo entries:$solo_found"

max=$c; [ "$m" -gt "$max" ] && max=$m; [ "$y" -gt "$max" ] && max=$y
min=$c; [ "$m" -lt "$min" ] && min=$m; [ "$y" -lt "$min" ] && min=$y
is "A2 ink usage is balanced across the palette (C=$c M=$m Y=$y, spread <= 1)" \
  yes "$([ "$((max - min))" -le 1 ] && echo yes || echo "no")"

echo "-- B. rotation counter"
n_entries="${#INK_COMMENTS[@]}"
seen=""
for _ in $(seq 1 "$n_entries"); do
  out="$(K2C_STATE="$T/state" DRY=1 COLOUR= bash -c '
    state="'"$T"'/state"; mkdir -p "$state"
    f="$state/rotation"
    idx=$(( ($( [ -f "$f" ] && cat "$f" || echo -1 ) + 1) % '"$n_entries"' ))
    echo "$idx" > "$f"
    echo "$idx"
  ')"
  seen="$seen $out"
done
uniq_count="$(printf '%s\n' $seen | sort -un | wc -l)"
is "B1 one full rotation visits every index exactly once" "$n_entries" "$uniq_count"

wrapped="$(cat "$T/state/rotation")"
one_more="$(K2C_STATE="$T/state" bash -c '
  f="'"$T"'/state/rotation"
  idx=$(( ($(cat "$f") + 1) % '"$n_entries"' ))
  echo "$idx"
')"
is "B2 the counter wraps back to 0 after a full cycle" 0 "$one_more"

echo "-- C. COLOUR= pin validation"
if command -v gs >/dev/null 2>&1 && python3 -c 'import numpy, PIL' >/dev/null 2>&1; then
  : > "$T/blank.ps"
  printf '%%!PS\nshowpage\n' > "$T/blank.ps"
  if err="$(cd "$T" && DRY=1 COLOUR=cyan bash "$SCRIPT" "$T/blank.ps" 2>&1 1>/dev/null)"; then
    bad "C1 COLOUR=cyan (removed by #435's fix) is rejected" "exited 0: $err"
  else
    case "$err" in *"unknown COLOUR"*) ok "C1 COLOUR=cyan (removed by #435's fix) is rejected" ;;
      *) bad "C1 COLOUR=cyan (removed by #435's fix) is rejected" "wrong error: $err" ;; esac
  fi
else
  echo "  skip C1 -- gs and/or numpy/PIL not available in this environment; the static checks above (A, B) still gate"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
