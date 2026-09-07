#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/mimeapps-handlers.sh"
fails=0
t() { local want=$1 desc=$2; shift 2
  local out rc; out=$("$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then echo "ok   $desc"
  else echo "FAIL $desc (rc=$rc want $want)"; echo "$out" | sed 's/^/     /'; fails=$((fails+1)); fi
}
grep_out() { local pat=$1 out; shift; out="$("$@" 2>&1)"; case "$out" in *"$pat"*) return 0 ;; *) return 1 ;; esac; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/data/applications" "$tmp/config"
echo '{}' > "$tmp/senechal.json"
run() { XDG_DATA_HOME="$tmp/data" XDG_DATA_DIRS="" SENECHAL_CONFIG="$tmp/senechal.json" \
        MIMEAPPS_HANDLERS_FILE="$tmp/config/mimeapps.list" bash "$CHECK" "$@"; }

cat > "$tmp/data/applications/good.desktop" <<'EOF'
[Desktop Entry]
Exec=/bin/true
EOF
cat > "$tmp/data/applications/dead-exec.desktop" <<'EOF'
[Desktop Entry]
Exec=/nonexistent/binary-xyz
EOF

t 2 "no mimeapps.list -- cannot check" run

cat > "$tmp/config/mimeapps.list" <<'EOF'
[Default Applications]
text/plain=good.desktop
EOF
t 0 "one live handler -> pass" run

cat > "$tmp/config/mimeapps.list" <<'EOF'
[Default Applications]
text/plain=good.desktop
x-scheme-handler/mailto=missing.desktop
EOF
t 5 "an id resolving nowhere -> fail" run
grep_out "DEAD  x-scheme-handler/mailto -> missing.desktop (no .desktop anywhere)" run \
  && echo "ok   names the mime and the missing id" \
  || { echo "FAIL names the mime and the missing id"; fails=$((fails+1)); }

cat > "$tmp/config/mimeapps.list" <<'EOF'
[Default Applications]
x-scheme-handler/tel=dead-exec.desktop
EOF
t 5 "live .desktop, dead Exec binary -> fail" run
grep_out "Exec binary missing" run \
  && echo "ok   names the dead-Exec case distinctly" \
  || { echo "FAIL names the dead-Exec case distinctly"; fails=$((fails+1)); }

cat > "$tmp/config/mimeapps.list" <<'EOF'
[Default Applications]
text/plain=good.desktop
[Added Associations]
text/plain=missing.desktop;good.desktop;
EOF
t 0 "an [Added Associations] entry for a dead id is not graded" run

cat > "$tmp/config/mimeapps.list" <<'EOF'
[Default Applications]
text/plain=good.desktop;missing.desktop;
EOF
t 0 "first id of a ;-list is the one graded" run

cat > "$tmp/config/mimeapps.list" <<'EOF'
[Default Applications]
text/plain=good.desktop
EOF
out="$(run -q 2>&1)"
[ -z "$out" ] && echo "ok   -q is silent on a clean run" \
  || { echo "FAIL -q is silent on a clean run"; fails=$((fails+1)); }

cat > "$tmp/config/mimeapps.list" <<'EOF'
[Default Applications]
x-scheme-handler/mailto=missing.desktop
EOF
out="$(run -q 2>&1)"
[ -n "$out" ] && echo "ok   -q still reports a dead handler" \
  || { echo "FAIL -q still reports a dead handler"; fails=$((fails+1)); }

[ "$fails" = 0 ] && echo "PASS" || echo "$fails FAILED"
exit $((fails > 0))
