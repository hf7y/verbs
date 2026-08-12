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

# --- THE POINTER TO THE NEW DOOR -----------------------------------------
# Zach, 2026-08-10: "have fonde consign loudly point to consigne as the new
# correct approach." LOUD is the operative word in an estate whose recurring
# defect is the silent no-op, so the assertion is not that a page mentions it
# -- it is that no invocation of this subcommand can avoid saying it. Every
# row below re-runs a case already asserted above and checks the pointer came
# with it, because "on the happy path only" is exactly how a deprecation gets
# missed by the people still using the old door wrong.
# A FRESH document, because DOC.md was annotated above and now REFUSES. The
# success rows below have to be genuinely successful or the stdout-cleanliness
# assertion is reading an empty report and calling it clean.
printf 'pointer fixture\n' > "$SRC/THREE.md"
git -C "$SRC" add THREE.md >/dev/null 2>&1
git -C "$SRC" commit -qm three >/dev/null 2>&1

OUT="$(cd "$SRC" && "$VERB" consign THREE.md 2>&1)"; RC=$?
check "the pointer does not disturb a successful deposit" "$RC" "0"
case "$OUT" in
  *"is the OLD door"*) ok "a successful consign says it is the old door" ;;
  *) bad "a successful consign did not say it is the old door" "got: $OUT" ;;
esac
case "$OUT" in
  *consigne*) ok "...and names consigne as the new one" ;;
  *) bad "...but did not name consigne" "got: $OUT" ;;
esac
case "$OUT" in
  *"consigne status"*) ok "...and names what the new door adds" ;;
  *) bad "...but did not name consigne status" "got: $OUT" ;;
esac

# The failing paths too. A caller who typed a bad path is still a caller of
# the old door.
OUT="$(cd "$SRC" && "$VERB" consign NOSUCH.md 2>&1)"
case "$OUT" in
  *consigne*) ok "a consign that fails on its arguments still points" ;;
  *) bad "a failing consign did not point" "got: $OUT" ;;
esac
OUT="$(cd "$SRC" && "$VERB" consign 2>&1)"
case "$OUT" in
  *consigne*) ok "a consign with no arguments at all still points" ;;
  *) bad "an empty consign did not point" "got: $OUT" ;;
esac

# ON STDERR, NOT STDOUT. The impl's DEPOSITED / "safe to remove" report is the
# caller's machine-readable output; a pointer mixed into it would break every
# reader that parses those lines -- which is the whole basis for deleting an
# original.
STDOUT_ONLY="$(cd "$SRC" && "$VERB" consign THREE.md 2>/dev/null)"
case "$STDOUT_ONLY" in
  *consigne*) bad "the pointer is on stderr, not stdout" "it contaminated stdout: $STDOUT_ONLY" ;;
  *) ok "the pointer is on stderr, leaving stdout's report clean" ;;
esac
case "$STDOUT_ONLY" in
  *DEPOSITED*) ok "...and stdout still carries the deposit report" ;;
  *) bad "stdout lost the deposit report" "got: $STDOUT_ONLY" ;;
esac

# --help carries it as well, so the pointer is reachable before a run and not
# only after one.
OUT="$("$VERB" --help 2>&1)"
case "$OUT" in
  *DEPRECATED*) ok "--help marks consign deprecated" ;;
  *) bad "--help does not mark consign deprecated" "got: $OUT" ;;
esac

# IT MUST NOT NAME A COMMAND THAT MIGHT NOT EXIST WITHOUT SAYING SO. `consigne`
# reaches a host through the dated verb build, so there is a window where the
# new door is named and not installed. realisateur#112 is that defect already
# paid for once -- `consulte` mandated while absent from mandark's build. Both
# branches are exercised, with a PATH that decides which.
mkdir -p "$TMP/withnew"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/withnew/consigne"
chmod +x "$TMP/withnew/consigne"
OUT="$(cd "$SRC" && PATH="$TMP/withnew:$PATH" "$VERB" consign THREE.md 2>&1)"
case "$OUT" in
  *"installed here; prefer it"*) ok "with consigne on PATH it says to prefer it" ;;
  *) bad "with consigne on PATH it did not say to prefer it" "got: $OUT" ;;
esac
# $TMP/bin holds only the poisoned basheur, so consigne is genuinely absent.
OUT="$(cd "$SRC" && PATH="$TMP/bin:/usr/bin:/bin" "$VERB" consign THREE.md 2>&1)"
case "$OUT" in
  *"NOT on this host yet"*) ok "without consigne on PATH it says so plainly" ;;
  *) bad "without consigne it still pointed at an absent command" "got: $OUT" ;;
esac
case "$OUT" in
  *"still the working one"*) ok "...and says this door is still the working one" ;;
  *) bad "...but did not say this door still works" "got: $OUT" ;;
esac

# The pointer must not resurrect the two things this suite exists to keep out.
OUT="$(cd "$SRC" && "$VERB" consign THREE.md 2>&1)"
case "$OUT" in
  *basheur*) bad "the pointer does not mention a retired agent" "said: $OUT" ;;
  *) ok "the pointer does not mention a retired agent" ;;
esac
if [ -e "$POISON_MARKER" ]; then
  bad "the pointer reached no agent" "$(cat "$POISON_MARKER")"
else
  ok "the pointer reached no agent"
fi

# --- the vault knob: flag beats env beats default ---------------------------
# One fact, three sources, so the ORDER is what is asserted.
VAULT2="$TMP/vault2"; mkdir -p "$VAULT2"; git -C "$VAULT2" init -q 2>/dev/null
( cd "$SRC" && BIBLIOTHECAIRE_VAULT="$VAULT" "$VERB" consign --vault "$VAULT2" DOC.md ) >/dev/null 2>&1
[ -f "$VAULT2/src-project/DOC.md" ] && ok "--vault beats BIBLIOTHECAIRE_VAULT" \
                                    || bad "--vault did not redirect the deposit"
OUT="$(cd "$SRC" && "$VERB" consign --vault 2>&1)"; RC=$?
[ "$RC" = 2 ] && ok "--vault with no path is a usage error" \
              || bad "--vault with no path exited $RC, expected 2"
grep -q 'VAULT_DEFAULT=/srv/ecosystem1-vault' "$VERB" \
  && ok "the default vault is /srv/ecosystem1-vault" \
  || bad "the default vault is not /srv/ecosystem1-vault"
grep -v '^[[:space:]]*#' "$VERB" | grep -q 'ecosystem1/ecosystem1' \
  && bad "a vault path under a home directory remains" \
  || ok "no vault path under a home directory remains"

echo
printf -- '--- fonde consign: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
