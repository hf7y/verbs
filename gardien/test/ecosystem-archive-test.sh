#!/usr/bin/env bash
# ecosystem-archive-test.sh -- exercises the removable-drive mount guard.
#
# gardien#151: DEST_ROOT already existing (a prior run's leftover
# directory) must not be trusted as "the removable drive is still
# mounted" -- it can just as easily be an ordinary directory on whatever
# filesystem now owns that path (drive unplugged, directory never
# cleaned up). Only the guard is exercised here; nothing downstream
# (real $HOME, real tar sets) is -- every scenario below fails, or is
# expected to progress past the guard, before any archiving starts.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SCRIPT="$ROOT/bin/ecosystem-archive.sh"
pass=0; fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (output lacked: $3)" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 (output contained: $3)" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- DEST_ROOT exists but is an ordinary directory, not a mountpoint ----
mkdir -p "$TMP/stale-mount/gardien-ecosystem"
OUT="$(bash "$SCRIPT" "$TMP/stale-mount/gardien-ecosystem" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok "an existing DEST_ROOT that is no longer a real mountpoint fails (exit 1)" \
                 || bad "an existing DEST_ROOT that is no longer a real mountpoint fails (exit 1) (got $RC)"
has "...and names DEST_ROOT as the reason" "$OUT" "not itself a mountpoint"
[ ! -e "$TMP/stale-mount/gardien-ecosystem/$(date +%Y-%m-%d)" ] \
  && ok "...and nothing was written under the stale directory" \
  || bad "...and nothing was written under the stale directory"

# --- DEST_ROOT does not exist yet: the guard above does not fire; the ----
# --- parent-based check further down is what a first run relies on -----
# ($TMP itself sits on this sandbox's one real filesystem, so the
# parent-based fallback correctly rejects it too -- that is the OTHER
# guard's job, not this test's. This only asserts the new guard stayed
# out of the way for a DEST_ROOT that has never existed.)
mkdir -p "$TMP/fresh"
OUT="$(bash "$SCRIPT" "$TMP/fresh/gardien-ecosystem" 2>&1)"
hasnt "a first run (DEST_ROOT absent) is not rejected by the mountpoint guard" "$OUT" "not itself a mountpoint"
has   "...the parent-based fallback still runs and rejects it on its own terms" "$OUT" "not a removable drive"

printf '\n--- ecosystem-archive: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
