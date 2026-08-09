#!/usr/bin/env bash
# reaped-test.sh -- what "bibliothecaire has been reaped" MEANS, as a command.
#
#   ./test/reaped-test.sh [--verbose]
#
# Written 2026-07-31 BEFORE the reaping, at Zach's instruction ("first write a
# test defining what success would be"). It fails today. That is the point: it
# is a target, not a description. Same discipline as the man page written ahead
# of the utility -- the reaping is judged against this file, and this file is
# not edited to match whatever the reaping turned out to do.
#
# THE THREE THINGS THAT MUST HOLD AT ONCE. Any one alone is a failure mode
# with a name:
#
#   REAPED     the agent is gone -- registration, loop script, machine
#              footprint, and every agent-shaped file. Without this the pass
#              did nothing.
#   PRESERVED  nothing was destroyed without a deposit. Every prose document
#              removed is in the vault, byte-for-byte, and the archive commit
#              it came from is still reachable. Without this the pass was a
#              deletion wearing a tidy commit message.
#   ALIVE      the verbs still answer. Without this the repo is a tomb, and
#              "only verbs remain" is true in the way an empty room is tidy.
#
# A failure is REPORTED and scored, never fatal: a test that dies on row 1
# tells you nothing about rows 2..n. Exit 0 only if every row passes.

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

LIBRARY="${BIBLIOTHECAIRE_HOME:-$HOME/Documents/Projects/bibliothecaire}"
VERBS="${BIBLIOTHECAIRE_VERBS:-$HOME/Documents/Projects/bibliothecaire-verbs}"
VAULT="${BIBLIOTHECAIRE_VAULT:-$HOME/ecosystem1/ecosystem1}"
SCHED="${SCHEDULER_HOME:-$HOME/Documents/Projects/scheduler}"
BIN="$HOME/.local/bin"

# The manifest the reaping must leave behind: one line per document removed,
# `<sha256><TAB><path-relative-to-the-library>`. It is the reaping's own record
# of what it took, and row P2 checks it is COMPLETE rather than trusting it.
MANIFEST="$VERBS/REAPED.tsv"

PASS=0; FAIL=0
declare -a FAILED=()
row_pass() { PASS=$((PASS+1)); printf 'PASS  %-10s %s\n' "$1" "$2"; }
row_fail() { FAIL=$((FAIL+1)); FAILED+=("$1: $2"); printf 'FAIL  %-10s %s\n' "$1" "$2"; }
note()     { [ "$VERBOSE" = 1 ] && printf '        %s\n' "$1"; return 0; }

printf '=== has bibliothecaire been reaped?  %s\n\n' "$(date +%Y-%m-%d)"

# =========================================================== REAPED
printf -- '-- REAPED: the agent is gone\n'

# R1. The scheduler no longer dispatches this project at all. Not disabled --
# ABSENT. `enabled=0` is a pause, and a pause is what this project has been in
# since before the retirement was decided; it proves nothing.
if [ -e "$SCHED/schedule/bibliothecaire.conf" ]; then
  row_fail 'R1 CONF' 'schedule/bibliothecaire.conf still exists; the project is still registered'
else
  row_pass 'R1 CONF' 'no scheduler registration'
fi

if grep -qE '^bibliothecaire\|' "$SCHED/schedule/_paced.conf" 2>/dev/null; then
  row_fail 'R2 PACED' '_paced.conf still carries a bibliothecaire row'
else
  row_pass 'R2 PACED' 'no row in the paced roster'
fi

# R3. The loop script. 420 bytes, executable, on PATH, tracked in no repo --
# the contract's own open row. Under a retirement it is RETIRED, not adopted.
if [ -e "$BIN/bibliothecaire-nightly-batch-loop.sh" ]; then
  row_fail 'R3 LOOP' "$BIN/bibliothecaire-nightly-batch-loop.sh is still on PATH"
else
  row_pass 'R3 LOOP' 'the nightly-batch loop script is off PATH'
fi

# R4. No agent-shaped file survives in the tree that remains. The doctrine is
# that a bashified repo keeps its man page, its contract, its test and its
# GAPS.md -- nothing else. Prose left behind is unreaped agency.
agentish=0
for f in .scheduler .claude CLAUDE.md nightly-batch.md; do
  if [ -e "$VERBS/$f" ]; then
    row_fail 'R4 PURGE' "the verb tree still holds $f"
    agentish=1
  fi
done
if [ -d "$VERBS/briefs" ] || [ -e "$VERBS/SOURCES.md" ]; then
  row_fail 'R4 PURGE' 'the verb tree still holds prose (briefs/ or SOURCES.md)'
  agentish=1
fi
[ "$agentish" = 0 ] && row_pass 'R4 PURGE' 'no agent-shaped file in the verb tree'

# R5. The declared mandark footprint. The table in FOCUS.md said a retired
# entry is removed from the list AND actually uninstalled; this is the half
# that checks the second clause, because the list cannot check itself.
foot=0
if systemctl list-unit-files 2>/dev/null | grep -q '^bibliothecaire-'; then
  row_fail 'R5 UNITS' 'systemd still knows bibliothecaire-* units'; foot=1
fi
if [ -e /etc/samba/conf.d/bibliothecaire-intake.conf ]; then
  row_fail 'R5 SMB' 'the bibintake samba share is still installed'; foot=1
fi
if id bibscan >/dev/null 2>&1; then
  # Deliberately NOT auto-deleted by the installer: it may still own unreaped
  # scans. So this row is a REPORT that must be answered, not an assumption.
  row_fail 'R5 USER' 'the bibscan service account still exists (may still own unreaped scans -- decide, do not default)'; foot=1
fi
if crontab -l 2>/dev/null | grep -q bibliothecaire; then
  row_fail 'R5 CRON' 'a crontab entry still names bibliothecaire'; foot=1
fi
[ "$foot" = 0 ] && row_pass 'R5 FOOT' 'no declared mandark footprint remains'

# =========================================================== PRESERVED
printf -- '\n-- PRESERVED: nothing was destroyed without a deposit\n'

# P1. The vault must be under version control AND have somewhere else to be.
# A deposit into an unbacked single disk is not a backup, and this pass is
# about to make the vault the only copy of every document it moves.
if [ ! -d "$VAULT/.git" ]; then
  row_fail 'P1 VAULT' "$VAULT is not a git repository"
elif ! git -C "$VAULT" remote 2>/dev/null | grep -q .; then
  row_fail 'P1 VAULT' 'the vault has no remote; a deposit there is a single-disk copy'
else
  row_pass 'P1 VAULT' "vault under version control with a remote ($(git -C "$VAULT" remote | head -1))"
fi

# P2. The manifest must be COMPLETE, not merely present. A reaping that
# records what it felt like recording is how a document goes missing quietly:
# every prose path tracked at the archive commit must appear in it.
if [ ! -r "$MANIFEST" ]; then
  row_fail 'P2 MANIFEST' "no reaping manifest at $MANIFEST"
else
  missing=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    grep -qF "	$p" "$MANIFEST" || { note "unrecorded: $p"; missing=$((missing+1)); }
  done < <(git -C "$LIBRARY" ls-tree -r --name-only HEAD 2>/dev/null \
           | grep -E '^(briefs/|archive/|\.scheduler/)|^(README|SOURCES|CLAUDE)\.md$')
  if [ "$missing" -gt 0 ]; then
    row_fail 'P2 MANIFEST' "$missing prose path(s) tracked in the library appear in no manifest line"
  else
    row_pass 'P2 MANIFEST' "manifest accounts for every tracked prose path ($(wc -l < "$MANIFEST") entries)"
  fi
fi

# P3. THE ROW THIS WHOLE PASS TURNS ON. Every manifest entry must be findable
# in the vault with its bytes intact. Not "a file of that name exists" -- the
# recorded sha256 must appear in the deposited note, which is what makes the
# deposit a copy rather than a paraphrase.
if [ ! -r "$MANIFEST" ]; then
  row_fail 'P3 DEPOSIT' 'no manifest, so no deposit can be verified'
elif [ ! -d "$VAULT" ]; then
  row_fail 'P3 DEPOSIT' "no vault at $VAULT"
else
  gone=0; checked=0
  while IFS=$'\t' read -r sha path; do
    [ -n "${sha:-}" ] && [ -n "${path:-}" ] || continue
    checked=$((checked+1))
    grep -rqlF "$sha" "$VAULT" --include='*.md' 2>/dev/null \
      || { note "no vault note carries the sha of $path"; gone=$((gone+1)); }
  done < "$MANIFEST"
  if [ "$checked" = 0 ]; then
    row_fail 'P3 DEPOSIT' 'the manifest is empty, which is not the same as nothing needing deposit'
  elif [ "$gone" -gt 0 ]; then
    row_fail 'P3 DEPOSIT' "$gone of $checked reaped document(s) are in NO vault note -- destroyed, not moved"
  else
    row_pass 'P3 DEPOSIT' "all $checked reaped document(s) present in the vault by content hash"
  fi
fi

# P4. The archive that justifies a total purge. The purge is only safe because
# everything removed is one `git log` away in the same repository; if the
# default branch is gone, the safety argument is gone with it.
if git -C "$LIBRARY" rev-parse --verify -q main >/dev/null 2>&1 \
   || git -C "$LIBRARY" rev-parse --verify -q origin/main >/dev/null 2>&1; then
  row_pass 'P4 ARCHIVE' "the library's default branch is still reachable"
else
  row_fail 'P4 ARCHIVE' 'the default branch is gone; nothing justifies the purge any more'
fi

# =========================================================== ALIVE
printf -- '\n-- ALIVE: the verbs still answer\n'

for v in fonde verse cueille; do
  if ! command -v "$v" >/dev/null 2>&1; then
    row_fail "A1 $v" "$v is not on PATH"
  elif ! "$v" --version >/dev/null 2>&1; then
    row_fail "A1 $v" "$v is on PATH but does not answer --version"
  else
    row_pass "A1 $v" "$(command -v "$v")"
  fi
done

# A2. The corpus is data the verbs act on, and it survives the reaping by
# Zach's decision. Wherever it ends up living, the test is the same: the verb
# can still reach it and reports on it. That keeps this row honest about the
# invariant without pinning an implementation the reaping has not chosen yet.
if command -v fonde >/dev/null 2>&1; then
  if out="$(fonde 2>&1)" && printf '%s' "$out" | grep -q 'quotes'; then
    row_pass 'A2 CORPUS' "fonde reads the corpus: $(printf '%s' "$out" | tail -1 | cut -c1-60)"
  else
    row_fail 'A2 CORPUS' 'fonde cannot report on the corpus; the data path did not survive'
  fi
else
  row_fail 'A2 CORPUS' 'fonde is not on PATH, so the corpus cannot be reached through a verb'
fi

# A3. What this project leaves reachable from a prompt is exactly its verbs.
# `installe` owns the manifest, so this asks it rather than globbing ~/.local/bin.
if command -v installe >/dev/null 2>&1; then
  stray="$(installe list 2>/dev/null | grep -E 'bibliothecaire' | grep -vE '/bibliothecaire-verbs/bin/(fonde|verse|cueille)$' || true)"
  if [ -n "$stray" ]; then
    row_fail 'A3 PATH' "something of this project other than its verbs is on PATH: $(printf '%s' "$stray" | head -1)"
  else
    row_pass 'A3 PATH' 'only this project'"'"'s verbs are reachable from a prompt'
  fi
else
  row_fail 'A3 PATH' 'installe is not on PATH, so what is reachable cannot be audited'
fi

# =========================================================== verdict
printf '\n'
if [ "$FAIL" = 0 ]; then
  printf -- '--- REAPED: %d rows passed. The agent is gone, nothing was lost, the verbs answer.\n' "$PASS"
  exit 0
fi
printf -- '--- NOT REAPED: %d of %d rows failed\n' "$FAIL" "$((PASS+FAIL))"
for f in "${FAILED[@]}"; do printf '    %s\n' "$f"; done
printf '\nThis test is a TARGET written before the work, not a description of it.\n'
printf 'A failing row is the work remaining, not a defect in the test.\n'
exit 1
