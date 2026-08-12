#!/usr/bin/env bash
# arme-apply-diff-witness.sh -- `arme apply` must NAME what it removes and
# what it adds, not just report a count (hf7y/scheduler#48).
#
# The declaratively-regenerated block makes a parked or deleted row's
# crontab line vanish with no runtime trace unless `apply` says so itself.
# 2026-08-05: scheduler#42 parked ecosim-sensors, `arme apply` reconciled
# the block, and the only place the removal was ever announced was that
# commit's message -- not this tool's own output. A survey the next morning
# found a different MONITOR line in its place and opened an issue against
# the wrong project.
#
# usage: ./test/arme-apply-diff-witness.sh [path-to-arme]
set -uo pipefail

ARME="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/arme}"
pass=0; fail=0
ok()  { printf '  PASS: %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL: %s\n' "$*"; fail=$((fail+1)); }
echo "arme-apply-diff-witness"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/schedule" "$WORK/stub"

# A real leaf: no model runner, no handoff, so `check` passes it FREE and
# `apply` never refuses on the spend gate this test is not about.
printf '#!/bin/bash\necho leaf\n' > "$WORK/stub/leaf"
chmod +x "$WORK/stub/leaf"

# A fake `crontab` on PATH: `-l` reads a state file, `-` overwrites it. This
# is the only way to observe what `apply` actually wrote without touching
# this account's real crontab.
CRONTAB_STATE="$WORK/crontab.state"
cat > "$WORK/stub/crontab" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  -l) [ -f "$CRONTAB_STATE" ] && cat "$CRONTAB_STATE"; exit 0 ;;
  -)  cat > "$CRONTAB_STATE"; exit 0 ;;
  *)  echo "crontab-stub: unsupported args: $*" >&2; exit 2 ;;
esac
EOS
chmod +x "$WORK/stub/crontab"

run_apply() {  # $1 = conf body
  printf '%s\n' "$1" > "$WORK/schedule/_monitor.conf"
  PATH="$WORK/stub:$PATH" CRONTAB_STATE="$CRONTAB_STATE" ARME_LEGACY_ROOT="$WORK" bash "$ARME" apply 2>&1
}

L="$WORK/stub/leaf"

# --- 1. first apply, nothing pre-existing -> alpha is ADDED, nothing removed --
# Seed an unrelated, non-arme crontab line to prove it survives untouched.
printf '# a human'\''s own line, not arme'\''s\n17 4 * * * /usr/bin/true\n' > "$CRONTAB_STATE"
out="$(run_apply "alpha|1|30 3 * * *|$L run|")"
case "$out" in
  *"+ added    alpha"*) ok "1a first apply names alpha as added" ;;
  *) bad "1a first apply names alpha as added"; printf '%s\n' "$out" ;;
esac
case "$out" in
  *"- removed"*) bad "1b nothing removed on a first apply" ;;
  *) ok "1b nothing removed on a first apply" ;;
esac
case "$(cat "$CRONTAB_STATE")" in
  *"/usr/bin/true"*) ok "1c the unrelated pre-existing line survives" ;;
  *) bad "1c the unrelated pre-existing line survives" ;;
esac

# --- 2. alpha is parked, beta arrives -> removed AND added named together ---
out="$(run_apply "alpha|0|30 3 * * *|$L run|
beta|1|0 5 * * *|$L run|")"
case "$out" in
  *"- removed  alpha"*) ok "2a parking alpha names it removed" ;;
  *) bad "2a parking alpha names it removed"; printf '%s\n' "$out" ;;
esac
case "$out" in
  *"+ added    beta"*) ok "2b beta arriving is named added" ;;
  *) bad "2b beta arriving is named added"; printf '%s\n' "$out" ;;
esac
case "$(cat "$CRONTAB_STATE")" in
  *"arme:alpha:MONITOR"*) bad "2c alpha's line is actually gone from what was written" ;;
  *) ok "2c alpha's line is actually gone from what was written" ;;
esac
case "$(cat "$CRONTAB_STATE")" in
  *"arme:beta:MONITOR"*) ok "2d beta's line is actually present in what was written" ;;
  *) bad "2d beta's line is actually present in what was written" ;;
esac
case "$(cat "$CRONTAB_STATE")" in
  *"/usr/bin/true"*) ok "2e the unrelated line still survives a second apply" ;;
  *) bad "2e the unrelated line still survives a second apply" ;;
esac

# --- 3. NEGATIVE: unchanged register -> no removed/added noise -------------
out="$(run_apply "beta|1|0 5 * * *|$L run|")"
case "$out" in
  *"- removed"*|*"+ added"*) bad "3a a re-apply with no register change names nothing" ;;
  *) ok "3a a re-apply with no register change names nothing" ;;
esac

printf '\n--- arme apply-diff: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
