#!/usr/bin/env bash
# carried-lints-witness.sh -- the verbs carried onto this branch actually work
# here, with no realisateur checkout, AND through the symlink they are
# installed as.
#
# HERMETICITY: full. Runs the carried verbs from a directory that is not a
# checkout and asserts only on their argument handling, never on findings --
# what they report depends on the estate, whether they can be INVOKED does not.
#
# THE FAILURE THIS EXISTS FOR, made while writing the carry: the libs were
# copied to lib/ when every script sources bin/lib/. `. missing-file` does not
# abort under `set -uo pipefail`, so cli_guard was simply never defined,
# execution fell through the guard, and `--help` exited 3 (BLIND) instead of 0
# while printing a registry error. A silently ungated script that still looks
# like it ran is the exact shape a carry can introduce and a reader cannot see.
#
# AND THE ONE CASE 2 CANNOT SEE, found 2026-08-18. A verb is installed as
# /usr/local/bin/<name> -> <build>/realisateur/bin/<name>. Under a symlink,
# ${BASH_SOURCE[0]} is the SYMLINK, so `dirname` yields /usr/local: six of
# these resolved their own location that way and would have failed on every
# host while passing every case here. Section 4 invokes through a symlink,
# which is the only shape that catches it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../bin"
pass=0; fail=0
ok()  { printf '  PASS: %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL: %s\n' "$*"; fail=$((fail+1)); }
echo "carried-lints-witness"

# Every verb this branch declares: executable bin/<n> WITH a man/<n>.1.
mapfile -t CARRIED < <(
  for f in "$BIN"/*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    n="$(basename "$f")"
    [ -f "$HERE/../man/$n.1" ] && printf '%s\n' "$n"
  done
)
[ "${#CARRIED[@]}" -gt 0 ] \
  && ok "the branch declares ${#CARRIED[@]} verb(s): ${CARRIED[*]}" \
  || bad "no verb is declared here -- bin/<n> + man/<n>.1 is the whole rule"

OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT

# --- 1. the libs are where the scripts look for them ----------------------
for l in cli-guard.sh body-grammar.sh; do
  [ -r "$BIN/lib/$l" ] && ok "bin/lib/$l is present" \
    || bad "bin/lib/$l missing -- sourcing it fails SILENTLY and every guard goes undefined"
done

# --- 2. --help works from somewhere that is not a checkout ----------------
# Run from a temp dir so nothing resolves by accident of cwd.
for s in "${CARRIED[@]}"; do
  case "$s" in gh) continue ;; esac   # passes --help through to the real gh
  ( cd "$OUT" && timeout 30 bash "$BIN/$s" --help >/dev/null 2>&1 )
  rc=$?
  [ "$rc" -eq 0 ] && ok "$s --help exits 0 with no checkout" \
    || bad "$s --help exited $rc -- help must never depend on the estate"
done

# --- 3. THE GUARD IS LIVE, not merely quiet -------------------------------
# The load-bearing case. If cli_guard were undefined again, --help would still
# reach the usage text by luck in some scripts, but a bad flag would sail
# through. Rejecting one proves the guard actually ran.
for s in "${CARRIED[@]}"; do
  case "$s" in gh|consigne) continue ;; esac   # deliberately pass flags onward
  ( cd "$OUT" && timeout 30 bash "$BIN/$s" --nonsense-flag >/dev/null 2>&1 )
  rc=$?
  [ "$rc" -eq 2 ] && ok "$s rejects an unknown flag (exit 2) -- cli_guard is defined" \
    || bad "$s returned $rc for a bad flag, want 2 -- the guard is not running"
done

# --- 4. THROUGH A SYMLINK, which is how every host invokes them -----------
LINKS="$OUT/bin"; mkdir -p "$LINKS"
for s in "${CARRIED[@]}"; do
  case "$s" in gh) continue ;; esac
  ln -sfn "$BIN/$s" "$LINKS/$s"
  ( cd "$OUT" && timeout 30 "$LINKS/$s" --help >/dev/null 2>&1 )
  rc=$?
  [ "$rc" -eq 0 ] && ok "$s --help exits 0 THROUGH A SYMLINK" \
    || bad "$s --help exited $rc through a symlink -- it resolves its own path without readlink -f"
done

# 4b. discipline names its own text, and must find it through the symlink.
if [ -x "$BIN/discipline" ]; then
  p="$( cd "$OUT" && timeout 30 "$LINKS/discipline" --path 2>/dev/null )"
  [ -f "$p" ] && ok "discipline --path resolves to a real file through a symlink ($p)" \
              || bad "discipline --path gave '$p', which is not a file -- /usr/local/BUILD-DISCIPLINE.md is the failure shape"
fi

printf '\ncarried-lints-witness: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
