#!/usr/bin/env bash
# dose-subcommand-collision-witness.sh -- a discovered subcommand name that
# ALSO names a live/parked schedule/ROSTER project must still be reachable
# in its project form.
#
# Found 2026-08-13: "scheduler" is both a discovered subcommand (bin/scheduler,
# the status report) and this account's own ROSTER row. is_subcommand() alone
# always picked the report, so `dose scheduler --check` -- the exact call
# hf7y/scheduler#79's retirement needs once ROSTER is authoritative -- could
# never reach dose-project.sh. Hermetic: fake `gh` only, real (carried)
# `bin/verdict.sh` stands in for the colliding name so this does not need a
# LEGACY_ROOT checkout or `bin/scheduler`'s own dependencies.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOSE="$HERE/../bin/dose"
pass=0; fail=0
ok()  { printf '  PASS: %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL: %s\n' "$*"; fail=$((fail+1)); }
echo "dose-subcommand-collision-witness"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
FAKEBIN="$W/fakebin"; mkdir -p "$FAKEBIN"

# roster row's host never matches this machine, so a successful reroute
# stops at dose-project.sh's step-3 host check (exit 7, REFUSED) -- before
# any crontab/sudo access, so nothing else needs faking.
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  */contents/*) printf '%s' "$FAKE_ROSTER_CONTENT" | base64 -w0 ;;
  *)            echo "scheduler"; exit 0 ;;
esac
EOF
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"

WITH_COLLISION='ecosim  | ecosim@monkey  | 2h | live
verdict | verdict@no-such-host | 2h | live
'
WITHOUT_COLLISION='ecosim | ecosim@monkey | 2h | live
'

# --- 1. subcommand name IS a roster row + --check -> reroutes -------------
export FAKE_ROSTER_CONTENT="$WITH_COLLISION"
out="$("$DOSE" verdict --check 2>&1)"; rc=$?
grep -q "REFUSED: roster says 'verdict' runs on 'no-such-host'" <<<"$out" \
  && ok "dose verdict --check reroutes to dose-project.sh when verdict is also a roster row" \
  || bad "did not reroute (rc=$rc): $out"
[ "$rc" -eq 7 ] && ok "reroute surfaces dose-project.sh's own exit code (7, REFUSED)" \
  || bad "expected rc=7 from dose-project.sh, got $rc"

# --- 2. same collision, but no --check/--apply -> subcommand still wins ---
out="$("$DOSE" verdict --help 2>&1)"; rc=$?
grep -q "REFUSED: roster says" <<<"$out" \
  && bad "dose verdict --help rerouted even though it is not --check/--apply: $out" \
  || ok "dose verdict --help stays the subcommand even though verdict is also a roster row"
out="$("$DOSE" verdict 2>&1)"; rc=$?
grep -q "REFUSED: roster says" <<<"$out" \
  && bad "bare 'dose verdict' rerouted with no --check/--apply present: $out" \
  || ok "bare 'dose verdict' stays the subcommand"

# --- 3. --check present, but the name is NOT actually in the roster -------
# Proves the roster is consulted, not just the presence of the flag.
export FAKE_ROSTER_CONTENT="$WITHOUT_COLLISION"
out="$("$DOSE" verdict --check 2>&1)"; rc=$?
grep -q "REFUSED: roster says" <<<"$out" \
  && bad "dose verdict --check rerouted even though the roster carries no 'verdict' row: $out" \
  || ok "dose verdict --check does not reroute when the roster has no colliding row"

# --- 4. a genuinely non-subcommand project name is unaffected (regression) -
export FAKE_ROSTER_CONTENT='freshproj | freshproj@no-such-host | 2h | live
'
out="$("$DOSE" freshproj --check 2>&1)"; rc=$?
[ "$rc" -eq 7 ] && grep -q "REFUSED: roster says 'freshproj' runs on 'no-such-host'" <<<"$out" \
  && ok "a project name that is not also a subcommand still routes to dose-project.sh as before" \
  || bad "regression: plain project-form routing broke (rc=$rc): $out"

printf '\ndose-subcommand-collision-witness: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
