#!/usr/bin/env bash
# debarrasse-test.sh -- contract test for `debarrasse`.
#
# test/contract-test.sh already covers the universal assertions (--help,
# unknown flag, the --summon cost boundary). This file covers what only
# debarrasse's own contract can assert: the exit-code TRANSLATION from
# tools/home-declutter.py's dialect (0/1/2/3) into this ecosystem's (0/6/8/9),
# and the one safety property CONTRACT.md promises -- purge is refused
# without --force, and quarantine --dry-run changes nothing on disk.
#
# Every run happens inside a sandboxed DEBARRASSE_LEGACY_ROOT and HOME. A
# test for a tool whose whole purpose is deciding what is safe to lose off
# $HOME must be provably incapable of touching the real one.
#
# NOT attempted here: the full SYNOPSIS/subcommand-table cross-check "THE
# PAGE TEST" methodology installe-test.sh and recense-test.sh use. Recorded
# as a stated gap in GAPS.md rather than silently skipped.

set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CMD="${1:-$ROOT/bin/debarrasse}"
PAGE="$ROOT/man/debarrasse.1"

pass=0; fail=0
ok() { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }

SANDBOX=""
sandbox() {
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/legacyroot/tools" "$SANDBOX/home"
  cp "$ROOT/../senechal/tools/home-declutter.py" "$SANDBOX/legacyroot/tools/" 2>/dev/null \
    || cp "/home/zach/Documents/Projects/senechal/tools/home-declutter.py" "$SANDBOX/legacyroot/tools/"
  chmod +x "$SANDBOX/legacyroot/tools/home-declutter.py"
  export DEBARRASSE_LEGACY_ROOT="$SANDBOX/legacyroot"
  export HOME="$SANDBOX/home"
}
write_config() {
  cat > "$SANDBOX/legacyroot/senechal.json" <<EOF
{"declutter":{"quarantine_root":"$HOME/.senechal-quarantine","purge_after_days":30,"exclude":[],"regenerable":{"roots":["$1"],"patterns":["__pycache__"]},"stale_downloads":{"roots":[],"stale_days":90,"extensions":[]}}}
EOF
}
rc() { "$CMD" "$@" >/tmp/debarrasse-test-out.$$ 2>&1; local r=$?; LAST_OUT="$(cat /tmp/debarrasse-test-out.$$)"; rm -f /tmp/debarrasse-test-out.$$; printf '%s' "$r"; }

trap '[ -n "$SANDBOX" ] && rm -rf "$SANDBOX"' EXIT
printf '=== debarrasse contract test\n    command: %s\n\n' "$CMD"

# --- man page sanity --------------------------------------------------------
name_line="$(awk '/^\.SH NAME/{getline; print; exit}' "$PAGE")"
case "$name_line" in
  *" and "*) no "NAME contains 'and': $name_line" ;;
  *\\-*)     ok "NAME is one clause" ;;
  *)         no "malformed NAME: $name_line" ;;
esac

# --- 0 kept: scan with nothing to find --------------------------------------
sandbox
mkdir -p "$SANDBOX/home/empty"
write_config "$SANDBOX/home/empty"
r="$(rc scan)"
[ "$r" = 0 ] && ok "scan with no candidates exits 0" || no "scan with no candidates exited $r"

# --- 6 blind: verify with no quarantine dir yet -----------------------------
sandbox
write_config "$SANDBOX/home"
r="$(rc verify)"
[ "$r" = 6 ] && ok "verify with no quarantine dir exits 6 (blind)" || no "verify exited $r, wanted 6"

# --- 7 refused: purge without --force ---------------------------------------
sandbox
write_config "$SANDBOX/home"
r="$(rc purge)"
[ "$r" = 7 ] && ok "purge without --force exits 7 (refused)" || no "purge without --force exited $r, wanted 7"
r="$(rc purge --force)"
# no quarantine dir at all -- home-declutter.py's purge still runs cleanly
# (0 items past grace period) once past the --force gate.
[ "$r" = 0 ] && ok "purge --force with nothing to purge exits 0" || no "purge --force exited $r, wanted 0"

# --- 8 found: verify against tampered quarantine content --------------------
sandbox
write_config "$SANDBOX/home"
qdir="$HOME/.senechal-quarantine/2026-01-01/item"
mkdir -p "$qdir"
printf 'original\n' > "$qdir/f.txt"
hash="$(sha256sum "$qdir/f.txt" | cut -d' ' -f1)"
cat > "$HOME/.senechal-quarantine/manifest.json" <<EOF
[{"quarantined_at":"2026-08-01T00:00:00","original_path":"$HOME/item/f.txt","quarantine_path":"$qdir","class":"regenerable","reason":"t","evidence":[],"file_hashes":{"f.txt":"$hash"},"size_bytes":9,"purged_at":null}]
EOF
printf 'tampered\n' > "$qdir/f.txt"
r="$(rc verify)"
[ "$r" = 8 ] && ok "verify against tampered quarantine content exits 8 (found)" || no "verify (tampered) exited $r, wanted 8"

# --- 9 warn: verify against an item past its grace period -------------------
sandbox
write_config "$SANDBOX/home"
qdir="$HOME/.senechal-quarantine/2020-01-01/old"
mkdir -p "$qdir"
printf 'x\n' > "$qdir/f.txt"
hash="$(sha256sum "$qdir/f.txt" | cut -d' ' -f1)"
cat > "$HOME/.senechal-quarantine/manifest.json" <<EOF
[{"quarantined_at":"2020-01-01T00:00:00","original_path":"$HOME/old/f.txt","quarantine_path":"$qdir","class":"regenerable","reason":"t","evidence":[],"file_hashes":{"f.txt":"$hash"},"size_bytes":2,"purged_at":null}]
EOF
r="$(rc verify)"
[ "$r" = 9 ] && ok "verify against a past-grace-period item exits 9 (warn)" || no "verify (warn) exited $r, wanted 9"

# --- safety property: quarantine --dry-run changes nothing on disk ---------
sandbox
mkdir -p "$SANDBOX/home/proj/__pycache__"
printf 'x\n' > "$SANDBOX/home/proj/__pycache__/a.pyc"
write_config "$SANDBOX/home/proj"
rc quarantine --dry-run >/dev/null
if [ -e "$SANDBOX/home/proj/__pycache__/a.pyc" ] && [ ! -d "$HOME/.senechal-quarantine" ]; then
  ok "quarantine --dry-run left the candidate in place and created no quarantine dir"
else
  no "quarantine --dry-run changed disk state"
fi

# --- safety property: purge only deletes past-grace-period entries ---------
sandbox
write_config "$SANDBOX/home"
old="$HOME/.senechal-quarantine/2020-01-01/old"; mkdir -p "$old"; printf 'x\n' > "$old/f.txt"
recent="$HOME/.senechal-quarantine/2026-08-01/recent"; mkdir -p "$recent"; printf 'y\n' > "$recent/f.txt"
oh="$(sha256sum "$old/f.txt" | cut -d' ' -f1)"; rh="$(sha256sum "$recent/f.txt" | cut -d' ' -f1)"
cat > "$HOME/.senechal-quarantine/manifest.json" <<EOF
[
 {"quarantined_at":"2020-01-01T00:00:00","original_path":"$HOME/old/f.txt","quarantine_path":"$old","class":"regenerable","reason":"t","evidence":[],"file_hashes":{"f.txt":"$oh"},"size_bytes":2,"purged_at":null},
 {"quarantined_at":"2026-08-01T00:00:00","original_path":"$HOME/recent/f.txt","quarantine_path":"$recent","class":"regenerable","reason":"t","evidence":[],"file_hashes":{"f.txt":"$rh"},"size_bytes":2,"purged_at":null}
]
EOF
rc purge --force >/dev/null
if [ ! -e "$old" ] && [ -e "$recent" ]; then
  ok "purge --force removed only the past-grace-period entry"
else
  no "purge --force touched the wrong entries"
fi

printf '\n--- debarrasse: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
