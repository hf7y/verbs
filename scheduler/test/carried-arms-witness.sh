#!/usr/bin/env bash
# carried-arms-witness.sh -- `dose`'s carried arms work with NO scheduler
# checkout, and do not quietly fall back to one.
#
# Zach, 2026-08-11: "scheduler should not need to exist as a check out on monkey
# for the verbs to work ... that's true for all verbs actually, they should be
# functional independent of their underlying repos."
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOSE="$HERE/../bin/dose"
pass=0; fail=0
ok()  { printf '  PASS: %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL: %s\n' "$*"; fail=$((fail+1)); }
echo "carried-arms-witness"

CARRIED="freeze-check verdict usage-paced-runner"

# --- 1. every carried script is actually ON this branch -------------------
for c in $CARRIED; do
  [ -x "$HERE/../bin/$c.sh" ] && ok "bin/$c.sh travels on this branch" \
    || bad "bin/$c.sh is NOT here -- its dose arm points at \$SELF and would GAP on every host"
done

# --- 2. a carried arm runs with NO checkout anywhere ----------------------
# The whole claim, exercised rather than asserted.
out="$(DOSE_LEGACY_ROOT=/nonexistent "$DOSE" freeze-check --help 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "dose freeze-check runs with LEGACY_ROOT pointed at nothing" \
  || bad "carried arm failed without a checkout (rc=$rc): $out"

# --- 3. a carried arm must NOT fall back to a checkout --------------------
# THE ONE THAT MATTERS. If a carried arm silently used LEGACY_ROOT when $SELF
# was incomplete, the clone dependency would return wherever a build was short,
# and it would look like it worked. Build a decoy checkout that WOULD satisfy
# the old path, hide the carried script, and require a GAP anyway.
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
printf '#!/usr/bin/env bash\necho DECOY-FROM-CHECKOUT\n' > "$W/bin/freeze-check.sh"
chmod +x "$W/bin/freeze-check.sh"
HID="$HERE/../bin/freeze-check.sh.hidden"
mv "$HERE/../bin/freeze-check.sh" "$HID"
out="$(DOSE_LEGACY_ROOT="$W" "$DOSE" freeze-check 2>&1)"; rc=$?
mv "$HID" "$HERE/../bin/freeze-check.sh"
grep -q 'DECOY-FROM-CHECKOUT' <<<"$out" \
  && bad "a carried arm FELL BACK to the checkout -- the clone dependency is still live" \
  || ok "a carried arm does not fall back to a checkout even when one would satisfy it"
[ "$rc" -eq 4 ] && ok "it GAPs (exit 4) instead" || bad "expected exit 4, got $rc: $out"
grep -q 'BUILD' <<<"$out" \
  && ok "the GAP blames the BUILD, not a missing checkout" \
  || bad "the GAP message still sends the reader looking for a clone: $out"

# --- 4. legacy arms still GAP honestly, they do not lie -------------------
# The half-and-half state is only safe because the uncarried half fails loud.
out="$(DOSE_LEGACY_ROOT=/nonexistent "$DOSE" token-usage 2>&1)"; rc=$?
[ "$rc" -eq 4 ] && ok "an uncarried arm GAPs (exit 4) with no checkout" \
  || bad "uncarried arm exited $rc, want 4 -- a facade that does not say so"

printf '\ncarried-arms-witness: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
