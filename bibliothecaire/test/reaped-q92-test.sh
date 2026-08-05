#!/usr/bin/env bash
# reaped-q92-test.sh -- what "quatre-vingt-douze has been removed" MEANS,
# as a command.
#
#   ./test/reaped-q92-test.sh [--verbose]
#
# Written 2026-07-31 BEFORE the removal. It fails at the moment it is written.
# That is the point: it is a target, not a description, and it is not edited
# afterwards to match whatever the removal turned out to do. Same discipline
# as the man page written ahead of the utility.
#
# Modelled on reaped-test.sh, which does this for bibliothecaire. The three
# things that must hold AT ONCE, each a named failure mode when alone:
#
#   REMOVED    the project is gone -- checkout, dispatch script, and the
#              scheduler symlinks that pointed into it. Without this the
#              pass did nothing.
#   PRESERVED  nothing was destroyed without a second copy that is reachable
#              WITHOUT this machine. Every prose document is in the vault
#              byte-for-byte, and every commit is on a remote. Without this
#              the pass was a deletion wearing a tidy commit message.
#   ALIVE      the verbs that inherited the work still answer. Without this
#              the fold is a tomb, and "it moved into bibliothecaire" is true
#              in the way an empty room is tidy.
#
# A failure is REPORTED and scored, never fatal: a test that dies on row 1
# tells you nothing about rows 2..n. Exit 0 only if every row passes.

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

PROJECT="quatre-vingt-douze"
CHECKOUT="${Q92_CHECKOUT:-/home/zach/Documents/Projects/$PROJECT}"
VERBS="${BIBLIOTHECAIRE_VERBS:-/home/zach/Documents/Projects/bibliothecaire-verbs}"
VAULT="${BIBLIOTHECAIRE_VAULT:-/home/zach/ecosystem1/ecosystem1}"
SCHED="${SCHEDULER_HOME:-/home/zach/Documents/Projects/scheduler}"
ORIGIN="${Q92_ORIGIN:-https://github.com/hf7y/$PROJECT.git}"
BIN="$HOME/.local/bin"

PASS=0; FAIL=0
declare -a FAILED=()
row_pass() { PASS=$((PASS+1)); printf 'PASS  %-10s %s\n' "$1" "$2"; }
row_fail() { FAIL=$((FAIL+1)); FAILED+=("$1: $2"); printf 'FAIL  %-10s %s\n' "$1" "$2"; }
note()     { [ "$VERBOSE" = 1 ] && printf '        %s\n' "$1"; return 0; }

printf '=== has %s been removed?  %s\n\n' "$PROJECT" "$(date +%Y-%m-%d)"

# ========================================================== REMOVED
printf -- '-- REMOVED: the project is gone\n'

# M1. The working checkout is ABSENT. This is the thing that was asked for,
# and it is checked first because every other row is only meaningful if it
# actually happened.
if [ -e "$CHECKOUT" ]; then
  row_fail 'M1 TREE' "$CHECKOUT still exists"
else
  row_pass 'M1 TREE' 'the working checkout is gone'
fi

# M2. The dispatch script is gone. A loop script left on PATH for a project
# that no longer exists is a live entry point into nothing.
if [ -e "$BIN/$PROJECT-nightly-batch-loop.sh" ]; then
  row_fail 'M2 LOOP' "$BIN/$PROJECT-nightly-batch-loop.sh still exists"
else
  row_pass 'M2 LOOP' 'the nightly dispatch script is off PATH'
fi

# M3. NO DANGLING SYMLINKS. scheduler/focus/<p>.md and questions/<p>.md are
# symlinks INTO the project's .scheduler/. Removing the tree without sweeping
# them leaves two broken links, and nothing in the ecosystem checks. This has
# happened on BOTH previous reaps -- one went unnoticed for a day -- which is
# why it is a scored row here and not a note.
dangling=0
for f in "$SCHED"/focus/*.md "$SCHED"/questions/*.md; do
  [ -e "$f" ] || { dangling=$((dangling+1)); note "DANGLING: $f"; }
done
if [ "$dangling" = 0 ]; then
  row_pass 'M3 LINKS' 'no dangling symlink anywhere in scheduler focus/ or questions/'
else
  row_fail 'M3 LINKS' "$dangling dangling symlink(s) in scheduler focus/ or questions/ (run with --verbose)"
fi

# ========================================================== PRESERVED
printf -- '\n-- PRESERVED: nothing was destroyed without a second copy\n'

# P1. Every commit survives ON A REMOTE, not merely somewhere on this disk.
# The whole purge doctrine rests on "it is one `git log` away" -- if the only
# copy was the checkout that was just deleted, that sentence is false.
if ! timeout 60 git ls-remote "$ORIGIN" >/tmp/q92-lsremote.$$ 2>/dev/null; then
  row_fail 'P1 REMOTE' "cannot reach $ORIGIN to prove the history survives"
else
  if grep -q 'refs/heads/main' /tmp/q92-lsremote.$$ && grep -q 'refs/heads/bashified' /tmp/q92-lsremote.$$; then
    row_pass 'P1 REMOTE' 'main and bashified both present on the origin remote'
    note "$(cat /tmp/q92-lsremote.$$)"
  else
    row_fail 'P1 REMOTE' 'origin is missing main or bashified'
  fi
fi
rm -f /tmp/q92-lsremote.$$

# P2. Every prose document is in the vault, and its body still hashes to the
# source bytes. Checked by re-extracting the body, NOT by trusting the
# frontmatter's self-reported hash -- a note that recorded its own corruption
# faithfully would pass a self-report and fail this.
missing=0; corrupt=0
for f in README.md CLAUDE.md .scheduler/FOCUS.md .scheduler/QUESTIONS.md .scheduler/nightly-batch.md; do
  note_path="$VAULT/$PROJECT/$f"
  if [ ! -r "$note_path" ]; then missing=$((missing+1)); note "MISSING: $note_path"; continue; fi
  body=$(awk '/^<!-- consigned: body below is byte-for-byte the original -->$/{f=1;next} /^<!-- fonde:end-body -->$/{f=0} f' "$note_path" | sha256sum | cut -d' ' -f1)
  fm=$(awk -F': ' '/^source_sha256: /{print $2; exit}' "$note_path")
  [ "$body" = "$fm" ] || { corrupt=$((corrupt+1)); note "BODY != RECORDED HASH: $note_path"; }
done
if [ "$missing" = 0 ] && [ "$corrupt" = 0 ]; then
  row_pass 'P2 PROSE' 'all 5 prose documents in the vault, bodies hash as recorded'
else
  row_fail 'P2 PROSE' "$missing missing, $corrupt body/hash mismatches in the vault"
fi

# P3. The MATERIAL survives -- the harvested pages themselves. These are the
# product, not a build artifact: rebuilding them costs 20 polite fetches
# against a public archive, and the corpus is popularity-ordered, so a rebuild
# is not guaranteed to return the same 20 books.
pages=$(ls "$VERBS"/pages/*-p92.txt 2>/dev/null | wc -l)
if [ "$pages" -ge 18 ] && [ -r "$VERBS/pages/manifest.json" ]; then
  row_pass 'P3 PAGES' "$pages harvested pages and the manifest carried into the verb tree"
else
  row_fail 'P3 PAGES' "only $pages harvested page(s) in $VERBS/pages, or no manifest"
fi

# ========================================================== ALIVE
printf -- '\n-- ALIVE: the verbs that inherited the work still answer\n'

# A1/A2. Each verb answers a question that requires it to READ something,
# not merely --version. `rule` prints the pagination rule; `status` counts
# what is on disk. A verb that only prints its own name proves nothing.
for pair in "glane:rule" "glane:status" "accroche:order" "accroche:status"; do
  v=${pair%%:*}; sub=${pair##*:}
  if out=$(timeout 30 "$VERBS/bin/$v" "$sub" 2>&1) && [ -n "$out" ]; then
    row_pass "A $v" "$v $sub answers"
    note "$out"
  else
    row_fail "A $v" "$v $sub did not answer (exit $?)"
  fi
done

# A3. THE CONSTRAINT SURVIVED THE MOVE. The folded project's standing rule was
# that user judgment IS the product and the arranging is never automated. A
# fold that quietly dropped it would pass every row above. So it is asserted
# as behaviour: asking accroche to arrange must be REFUSED as a usage error
# (exit 2), not deferred as a gap (exit 4) -- exit 4 would promise it later.
timeout 30 "$VERBS/bin/accroche" sort >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then
  row_pass 'A CONSTRAINT' 'accroche refuses to arrange (exit 2, a refusal -- not exit 4, a promise)'
else
  row_fail 'A CONSTRAINT' "accroche sort exited $rc; the never-automate-the-arranging rule did not survive the fold"
fi

# ========================================================== verdict
printf '\n'
if [ "$FAIL" = 0 ]; then
  printf -- '--- REMOVED: %d rows passed. The project is gone, nothing was lost, the verbs answer.\n' "$PASS"
  exit 0
fi
printf -- '--- %d passed, %d FAILED\n' "$PASS" "$FAIL"
printf '  - %s\n' "${FAILED[@]}"
exit 1
