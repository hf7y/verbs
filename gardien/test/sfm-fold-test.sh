#!/usr/bin/env bash
# sfm-fold-test.sh -- gardien#28: a filename byte one filesystem cannot
# store natively gets remapped into the Unicode private-use area (the
# "SFM extended characters" scheme Samba/NTFS-3G use) and round-tripped
# back to the literal byte by a filesystem that CAN store it. Same file,
# same content, two different filename encodings -- a permanent false
# BROKEN on the set this happened to (`Abecedarian`, proven in the field:
# identical md5s, only four path lines "different", all four a bare CR
# on the destination vs U+F00D on this (ext4) host).
#
# No `kind: local` test can reproduce the filesystem-level remapping
# itself (both "sides" of a temp-dir test live on the same ext4), so
# this sources lib/*.sh directly rather than only driving the compiled
# `bin/garde`: `media_fold_sfm` is unit-tested against the exact byte
# sequences the incident produced, and `media_verify_set` -- the real
# function, not a reimplementation -- is called directly against a
# fixture standing in for "the destination side already round-tripped
# this name back to a literal control byte".
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
pass=0; fail=0
ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (want $3, got $2)"; }

VERB_NAME=garde
VERB_QUIET=1
. "$ROOT/lib/verb.sh"
. "$ROOT/lib/manifest.sh"
. "$ROOT/lib/media.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "=== media_fold_sfm: unit"; echo

# CR (0x0d): GNU md5sum escapes a LITERAL CR to the two ASCII characters
# `\r`, with the whole line marked by one leading `\` -- it never appears
# as a raw byte in md5sum's own output. So the private-use side must fold
# to that SAME two-character text, not to a raw 0x0d, or the two sides
# could never compare equal.
f="$TMP/u.md5"; printf 'abc123  Icon\xef\x80\x8d\n' > "$f"
media_fold_sfm "$f"
check "U+F00D (CR's private-use form) folds to the literal text \\r" \
  "$(xxd -p "$f")" "$(printf 'abc123  Icon\\r\n' | xxd -p)"

# The genuinely-escaped side of the same real file: md5sum hashing an
# actual CR-named file escapes the WHOLE LINE with one leading `\`,
# shifting the 32-hex hash off its usual offset 0 -- exactly the lines
# the classification below is keyed to misread unless that marker goes.
printf 'icon data\n' > "$TMP/Icon"$'\r'
realhash="$(cd "$TMP" && md5sum -z Icon$'\r' | cut -c1-32)"
f="$TMP/e.md5"; ( cd "$TMP" && md5sum Icon$'\r' ) > "$f"
media_fold_sfm "$f"
check "the leading whole-line \\ escape marker is stripped" "$(cut -c1-32 "$f")" "$realhash"

# Range boundaries: n=1 (lowest control byte) and n=31/0x1f (highest) --
# neither is CR or LF, so both fold straight to the raw byte.
f="$TMP/b.md5"; printf 'q  a\xef\x80\x81z\xef\x80\x9fb\n' > "$f"
media_fold_sfm "$f"
check "U+F001 and U+F01F (range boundaries) fold to their raw bytes" \
  "$(xxd -p "$f")" "$(printf 'q  a\x01z\x1fb\n' | xxd -p)"

# n=10 (LF): folds to the literal text `\n`, never a raw 0x0a -- this
# file is one record per line, and a raw newline here would split one
# record into two for every step downstream (sort, diff, the
# classification awk keyed by line).
f="$TMP/lf.md5"; printf 'zzz  a\xef\x80\x8ab\n' > "$f"
media_fold_sfm "$f"
check "U+F00A (LF's private-use form) folds to the literal text \\n" \
  "$(xxd -p "$f")" "$(printf 'zzz  a\\nb\n' | xxd -p)"

# A file with none of these codepoints, and no CR/LF/`\`, must come
# through completely untouched.
f="$TMP/plain.md5"; printf 'x  plain/file name.txt\n' > "$f"
before="$(xxd -p "$f")"
media_fold_sfm "$f"
check "a filename with no SFM round-trip bytes is left untouched" "$(xxd -p "$f")" "$before"

echo; echo "=== media_verify_set: the real incident, end to end"; echo

# Local (this host, ext4): the file already carries the private-use
# codepoint -- the shape the real Abecedarian set was actually found in.
SRC="$TMP/src/Abecedarian"; mkdir -p "$SRC"
printf 'icon data\n' > "$SRC/Icon"$'\xef\x80\x8d'
# "Destination" (standing in for NTFS): the same content, round-tripped
# back to a literal CR -- which is what NTFS actually did in the field.
DST="$TMP/dst"; mkdir -p "$DST/Abecedarian"
printf 'icon data\n' > "$DST/Abecedarian/Icon"$'\r'

cat > "$TMP/garde.json" <<JSON
{ "destinations": { "tmp": { "kind": "local", "root": "$DST", "online": true } },
  "sets": [ { "name": "Abecedarian", "path": "$SRC", "copies": ["tmp"],
              "min_copies": 1, "verify": "md5" } ] }
JSON
export GARDE_MANIFEST="$TMP/garde.json"
export GARDE_STATE="$TMP/state"

media_verify_set Abecedarian tmp >/dev/null 2>"$TMP/verify.err"; rc=$?
check "a lossless CR/U+F00D round-trip verifies clean, not BROKEN" "$rc" "0"
case "$(cat "$TMP/verify.err")" in
  *BROKEN*) bad "verify's own stderr still says BROKEN: $(cat "$TMP/verify.err")" ;;
  *)        ok "verify's stderr names no BROKEN set" ;;
esac

echo
printf -- '--- sfm-fold: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
