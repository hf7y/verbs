#!/usr/bin/env bash
set -uo pipefail  # sandboxed test of #628's cleanup; underscore prefix load-bearing, verify-all.sh globs ./*.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/mimeapps-dead-handlers-cleanup.sh"
fails=0
t() { local want=$1 desc=$2; shift 2
  local out rc; out=$("$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then echo "ok   $desc"
  else echo "FAIL $desc (rc=$rc want $want)"; echo "$out" | sed 's/^/     /'; fails=$((fails+1)); fi
}
grep_out() { local pat=$1 out; shift; out="$("$@" 2>&1)"; case "$out" in *"$pat"*) return 0 ;; *) return 1 ;; esac; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/data/applications" "$tmp/config" "$tmp/backups"
echo '{}' > "$tmp/senechal.json"
run() { HOME="$tmp/home" XDG_DATA_HOME="$tmp/data" XDG_DATA_DIRS="" SENECHAL_CONFIG="$tmp/senechal.json" \
        SENECHAL_BACKUP_ROOT="$tmp/backups" MIMEAPPS_HANDLERS_FILE="$tmp/config/mimeapps.list" \
        bash "$CHECK" "$@"; }
mkdir -p "$tmp/home"

cat > "$tmp/data/applications/good.desktop" <<'EOF'
[Desktop Entry]
Exec=/bin/true
EOF

cat > "$tmp/config/mimeapps.list" <<'EOF'
[Default Applications]
text/plain=good.desktop
x-scheme-handler/mailto=missing.desktop
x-scheme-handler/tel=good.desktop
[Added Associations]
text/plain=missing.desktop;good.desktop;
EOF

t 5 "verify before enable: one dead handler fails" run verify
grep_out "x-scheme-handler/mailto -> missing.desktop (no .desktop anywhere)" run verify \
  && echo "ok   names the dead mime and id" \
  || { echo "FAIL names the dead mime and id"; fails=$((fails+1)); }

enable_out="$(mktemp)"
run enable >"$enable_out" 2>&1
grep -q "dropping x-scheme-handler/mailto -> missing.desktop" "$enable_out" \
  && echo "ok   enable reports the drop" \
  || { echo "FAIL enable reports the drop"; fails=$((fails+1)); }
rm -f "$enable_out"

t 0 "verify after enable: clean" run verify

grep -q "^x-scheme-handler/mailto=missing.desktop$" "$tmp/config/mimeapps.list" \
  && { echo "FAIL the dead line is still in the file"; fails=$((fails+1)); } \
  || echo "ok   the dead line is gone from [Default Applications]"

grep -q "^text/plain=good.desktop$" "$tmp/config/mimeapps.list" \
  && echo "ok   the live [Default Applications] entry survives untouched" \
  || { echo "FAIL the live entry did not survive"; fails=$((fails+1)); }

grep -q "^text/plain=missing.desktop;good.desktop;$" "$tmp/config/mimeapps.list" \
  && echo "ok   an [Added Associations] entry for a dead id is left alone (not graded)" \
  || { echo "FAIL the untouched [Added Associations] section was mutated"; fails=$((fails+1)); }

[ -n "$(find "$tmp/backups" -type f -name 'mimeapps.list' 2>/dev/null)" ] \
  && echo "ok   enable backed up the original file before rewriting it" \
  || { echo "FAIL no backup found under SENECHAL_BACKUP_ROOT"; fails=$((fails+1)); }

out="$(run enable 2>&1)"
case "$out" in *"nothing to do"*) echo "ok   a second enable over already-clean state is a no-op" ;;
  *) echo "FAIL second enable did not report a no-op"; fails=$((fails+1)) ;;
esac

rm -f "$tmp/config/mimeapps.list"
t 0 "no mimeapps.list -- enable no-ops rather than failing" run enable
t 2 "no mimeapps.list -- verify skips rather than failing" run verify

[ "$fails" = 0 ] && echo "PASS" || echo "$fails FAILED"
exit $((fails > 0))
