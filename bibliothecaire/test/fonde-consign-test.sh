#!/usr/bin/env bash
# fonde-consign-test.sh -- consign must DEPOSIT, byte-for-byte, on its own.
#
# WHAT THIS SUITE USED TO ASSERT, AND WHY IT NO LONGER CAN. It asserted that
# `fonde consign` ASKED basheur whether a deposit costs anything, instead of
# answering for it -- the right assertion while a contract store existed. It
# proved that with a fake `basheur` on PATH. **basheur was retired on
# 2026-08-05**, so every one of those rows passed against a fixture that
# production could no longer produce: with no basheur anywhere, the real verb
# exited 4 for every caller while this suite stayed green. A fake standing in
# for something that no longer exists is a test of its own fixture.
#
# WHAT IT ASSERTS NOW. The mechanism is carried in lib/consign-prose.sh, so
# the question is no longer "did it ask" but "did it deposit, and is the
# deposit the document". Every row below runs the real implementation against
# a real git repository and a real vault, and the fidelity row hashes the
# bytes back off disk rather than trusting the exit code.
#
# THE POISONED basheur IS THE POINT OF ROW 1. A `basheur` that fails loudly if
# it is ever invoked sits on PATH for the whole run. Nothing may call it. That
# is what keeps a future "fix" from quietly restoring a dependency on a
# retired agent, which is the defect this suite was rewritten for.

set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
VERB="${1:-$ROOT/bin/fonde}"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A vault fonde will accept: present, and under version control (it refuses a
# deposit into an unversioned tree, which is its own assertion below).
VAULT="$TMP/vault"; mkdir -p "$VAULT"
git -C "$VAULT" init -q 2>/dev/null

# A SOURCE REPOSITORY, not a loose file. The deposit records where a document
# came from -- repo, path, commit -- so a document in no repository has no
# provenance to record and is reported blind. The fixture therefore has to be
# a real repo, which the old fake-basheur suite never needed.
SRC="$TMP/src-project"; mkdir -p "$SRC"
git -C "$SRC" init -q 2>/dev/null
git -C "$SRC" config user.email t@example.invalid
git -C "$SRC" config user.name test
printf 'prose\nsecond line\n' > "$SRC/DOC.md"
git -C "$SRC" add DOC.md >/dev/null 2>&1
git -C "$SRC" commit -qm doc >/dev/null 2>&1

# A basheur that must never run.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/basheur" <<'POISON'
#!/usr/bin/env bash
printf 'basheur was invoked with: %s\n' "$*" > "$POISON_MARKER"
printf 'basheur: this is a poisoned fixture and must never be called\n' >&2
exit 99
POISON
chmod +x "$TMP/bin/basheur"
export POISON_MARKER="$TMP/basheur-was-called"
export PATH="$TMP/bin:$PATH"
export BIBLIOTHECAIRE_VAULT="$VAULT"

DEST="$VAULT/src-project/DOC.md"

echo "=== fonde consign: it must deposit, on its own, byte-for-byte"; echo

# --- the deposit itself --------------------------------------------------
OUT="$(cd "$SRC" && "$VERB" consign DOC.md 2>&1)"; RC=$?
check "a plain consign succeeds with no flags" "$RC" "0"

case "$OUT" in
  *DEPOSITED*) ok "it reports what it deposited" ;;
  *) bad "it did not report a deposit" "got: $OUT" ;;
esac

case "$OUT" in
  *"safe to remove"*) ok "it reports what is now safe to remove" ;;
  *) bad "it did not report what is safe to remove" "got: $OUT" ;;
esac

if [ -f "$DEST" ]; then ok "the note exists in the vault at $DEST"
else bad "no note was written" "expected $DEST"; fi

# --- the fidelity witness, hashed back off disk --------------------------
# Not "it exited 0": the bytes between the markers are pulled back out of the
# written file and compared to the original. An archive that edits what it
# archives has destroyed the thing it was protecting.
if [ -f "$DEST" ]; then
  want="$(sha256sum "$SRC/DOC.md" | cut -d' ' -f1)"
  got="$(sed -n '/<!-- consigned: body below/,/<!-- fonde:end-body -->/p' "$DEST" \
         | sed '1d;$d' | sha256sum | cut -d' ' -f1)"
  check "the deposited body is byte-for-byte the original" "$got" "$want"
else
  bad "the deposited body is byte-for-byte the original" "no note to read back"
fi

# --- provenance: the whole reason a copy counts as an archive ------------
for field in source_repo: source_path: source_commit: source_sha256: consigned:; do
  if grep -q "^$field" "$DEST" 2>/dev/null; then ok "the note carries $field"
  else bad "the note carries $field" "not in $DEST"; fi
done

if grep -q "^source_commit: [0-9a-f]\{40\}$" "$DEST" 2>/dev/null; then
  ok "source_commit is a real commit, not 'unknown'"
else
  bad "source_commit is a real commit, not 'unknown'" "got: $(grep '^source_commit:' "$DEST" 2>/dev/null)"
fi

# --- nothing was routed through a retired agent --------------------------
if [ -e "$POISON_MARKER" ]; then
  bad "basheur was never invoked" "$(cat "$POISON_MARKER")"
else
  ok "basheur was never invoked"
fi

case "$OUT" in
  *basheur*) bad "the caller is not told about a retired agent" "said: $OUT" ;;
  *) ok "the caller is not told about a retired agent" ;;
esac

case "$OUT" in
  *"needs a summon"*|*"no mechanism"*)
    bad "free work is not gated behind a cost flag" "said: $OUT" ;;
  *) ok "free work is not gated behind a cost flag" ;;
esac

# --- idempotence ---------------------------------------------------------
OUT="$(cd "$SRC" && "$VERB" consign DOC.md 2>&1)"; RC=$?
check "re-consigning an unchanged document is idempotent, not a refusal" "$RC" "0"

# --- the overwrite refusal, which must survive every change here ---------
printf '\nsomebody annotated this note by hand\n' >> "$DEST"
before="$(sha256sum "$DEST" | cut -d' ' -f1)"
OUT="$(cd "$SRC" && "$VERB" consign DOC.md 2>&1)"; RC=$?
check "a note that differs is REFUSED (7), not overwritten" "$RC" "7"
after="$(sha256sum "$DEST" | cut -d' ' -f1)"
check "the annotated note is still on disk untouched" "$after" "$before"

# --- --summon: accepted, buys nothing, and says so -----------------------
# `fauche` prints `fonde consign --summon <file>` as the remedy for
# unconsigned prose. The flag must not have become a usage error, and it must
# not have become a way to spend: there is nothing left to spend on.
printf 'another\n' > "$SRC/TWO.md"
git -C "$SRC" add TWO.md >/dev/null 2>&1
git -C "$SRC" commit -qm two >/dev/null 2>&1
OUT="$(cd "$SRC" && "$VERB" consign --summon TWO.md 2>&1)"; RC=$?
check "--summon is still accepted and still deposits" "$RC" "0"
case "$OUT" in
  *"nothing was spent"*) ok "--summon says plainly that nothing was spent" ;;
  *) bad "--summon did not say nothing was spent" "got: $OUT" ;;
esac
if [ -e "$POISON_MARKER" ]; then
  bad "--summon reached no agent" "$(cat "$POISON_MARKER")"
else
  ok "--summon reached no agent"
fi

# --- refusals that predate this change and must survive it ---------------
OUT="$(cd "$SRC" && "$VERB" consign NOSUCH.md 2>&1)"; RC=$?
check "a missing path is a usage error (2), before anything is written" "$RC" "2"

UNVERSIONED="$TMP/bare"; mkdir -p "$UNVERSIONED"
OUT="$(cd "$SRC" && BIBLIOTHECAIRE_VAULT="$UNVERSIONED" "$VERB" consign DOC.md 2>&1)"; RC=$?
check "a vault with no git history is REFUSED (7), not deposited into" "$RC" "7"

OUT="$(cd "$SRC" && "$VERB" consign --briefs DOC.md 2>&1)"; RC=$?
check "a corpus flag on consign is a usage error (2)" "$RC" "2"

OUT="$("$VERB" --summon 2>&1)"; RC=$?
check "--summon with no subcommand requests nothing and exits 2" "$RC" "2"

# --- a document outside any repository has no provenance to record -------
printf 'orphan\n' > "$TMP/ORPHAN.md"
OUT="$(cd "$TMP" && "$VERB" consign ORPHAN.md 2>&1)"; RC=$?
check "a document in no repository is reported BLIND (6), not deposited" "$RC" "6"

echo
printf -- '--- fonde consign: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
