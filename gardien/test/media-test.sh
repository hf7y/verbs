#!/usr/bin/env bash
# media-test.sh -- exercises garde's real code paths against temp trees.
#
# Never a real mount, never a real host: destinations here are kind=local
# pointed at mktemp dirs, which is the same rule test_gardien.py held on
# main. The copy/verify/collision logic under test is the SAME code the
# ssh path runs -- only the transport differs.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
GARDE="$ROOT/bin/garde"
pass=0; fail=0
ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || { bad "$1 (want $3, got $2)"; }; }

# Mirrors lib/media.sh's media_safe_name. Kept as an independent
# reimplementation on purpose: if the two ever disagree, that is a real
# change in the on-disk naming contract and the suite should say so.
safename() { printf '%s-%s\n' "$(printf '%s' "$1" | md5sum | cut -c1-8)" \
             "$(printf '%s' "$1" | sed 's|%|%25|g; s|/|%2F|g')"; }


TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/src"; DST="$TMP/dst"; mkdir -p "$SRC/Alpha" "$DST"
printf 'one\n'   > "$SRC/Alpha/a.txt"
printf 'two\n'   > "$SRC/Alpha/b.txt"
mkdir -p "$SRC/Alpha/sub"; printf 'three\n' > "$SRC/Alpha/sub/c.txt"
mkdir -p "$SRC/Skipme";    printf 'nope\n'  > "$SRC/Skipme/x.txt"

cat > "$TMP/garde.json" <<JSON
{ "destinations": { "tmp": { "kind": "local", "root": "$DST", "online": true } },
  "sets": [ { "name": "Alpha", "path": "$SRC/Alpha", "copies": ["tmp"],
              "min_copies": 1, "verify": "md5" } ] }
JSON
export GARDE_MANIFEST="$TMP/garde.json"
export GARDE_STATE="$TMP/state"
export VERB_COST_FILE="$TMP/cost"

echo "=== garde media: contract + behaviour"; echo

# --- the SHOULD DO / WON'T DO distinction -----------------------------
"$GARDE" media restore >/dev/null 2>&1
check "refuses restore with exit 7 (WON'T DO), not 4" "$?" 7
out="$("$GARDE" media restore 2>&1)"
case "$out" in *"No --summon exists"*) ok "refusal states that no summon exists" ;;
                *) bad "refusal must say no summon is available" ;; esac
case "$out" in *GAPS.md*) bad "refusal must NOT point at GAPS.md (it is not a gap)" ;;
                *) ok "refusal does not file itself as a gap" ;; esac

# THE load-bearing rule: --summon is available on 4 and FORBIDDEN on 7.
# If --summon could override a refusal it would decay into a general
# "do it anyway" flag, and the SHOULD/WON'T distinction would be cosmetic.
"$GARDE" media sync --summon >/dev/null 2>&1
check "--summon cannot override a refusal (still 7, spends nothing)" "$?" 7
[ -s "$VERB_COST_FILE" ] && bad "a refusal recorded a cost -- it must not have spent" \
  || ok "a refused call spent nothing"

# --- list -------------------------------------------------------------
"$GARDE" media list >/dev/null 2>&1
check "list succeeds when a destination is reachable" "$?" 0
"$GARDE" media list 2>/dev/null | grep -q PENDING \
  && ok "list reports an uncopied set as PENDING" || bad "list should show PENDING"

# --- audit before any copy -------------------------------------------
"$GARDE" media audit >/dev/null 2>&1
check "audit exits 5 while a set is below its floor" "$?" 5

# --- run + verify -----------------------------------------------------
"$GARDE" media run Alpha --quiet >/dev/null 2>&1
check "run copies and verifies a set" "$?" 0
[ -f "$DST/Alpha/a.txt" ] && ok "file landed at the destination" || bad "file did not land"
[ -f "$DST/Alpha/sub/c.txt" ] && ok "nested file landed" || bad "nested file did not land"
[ ! -e "$DST/Skipme" ] && ok "unlisted sibling directory was not copied" || bad "copied something outside the set"

"$GARDE" media audit >/dev/null 2>&1
check "audit exits 0 once the floor is met" "$?" 0

# --- the proof is real, not rsync's opinion ---------------------------
printf 'CORRUPTED\n' > "$DST/Alpha/a.txt"
"$GARDE" media run Alpha --quiet >/dev/null 2>&1
rc=$?
# rsync repairs it, so a passing run here proves verify ran on real bytes.
check "a corrupted destination file is repaired and re-proven" "$rc" 0
grep -q one "$DST/Alpha/a.txt" && ok "repaired content matches source" || bad "content not repaired"

# verify must FAIL when the remote genuinely diverges and rsync cannot see it
"$GARDE" media run Alpha --quiet >/dev/null 2>&1
printf 'ghost\n' > "$DST/Alpha/extra-unknown.txt"
"$GARDE" media list 2>/dev/null | grep -q Alpha \
  && ok "list still reports the set after remote drift" || bad "list lost the set"

# --- EXTRA is STALE, not BROKEN (added 2026-08-02) --------------------
# `extra-unknown.txt` above exists ONLY at the destination. Until today the
# verify was a symmetric `diff -u` of the two hash lists, so that file was
# reported as a hash mismatch and the set was BROKEN.
#
# This is the shape that failed the first ever nightly run, on `Projects`:
# a concurrent session's `.git/logs/refs/stash` was copied at 03:39:48 and
# gone locally by 03:40:00. And because garde never passes `--delete`
# (deliberately -- a backup that deletes propagates an accidental `rm` to the
# only copy you have), the file stays at the destination and the set would
# have failed EVERY subsequent night, permanently.
#
# The promise is asymmetric -- "everything I have is copied and proven", not
# "the destination is identical to me" -- so the verdict must be too.
"$GARDE" media run Alpha --quiet >/dev/null 2>&1
check "a destination-only file is STALE, not BROKEN" "$?" 0
out="$("$GARDE" media run Alpha 2>&1)"
case "$out" in *STALE*extra-unknown.txt*)
       ok "the stale path is named on stderr, not swallowed" ;;
     *) bad "a destination-only file must be reported by name, not silently ignored" ;; esac

# ...and STALE must not be reported when there is nothing stale.
rm -f "$DST/Alpha/extra-unknown.txt"
out="$("$GARDE" media run Alpha 2>&1)"
case "$out" in *STALE*) bad "clean run must not report STALE" ;;
                *"(0 stale"*) bad "clean run must not print a zero stale count" ;;
                *) ok "a clean run says nothing about stale paths" ;; esac

# --- DIFFERENT is still BROKEN, and md5 beats rsync's heuristic -------
# rsync runs -rt: it decides by SIZE + MTIME, not content. Corrupt the
# destination while preserving both and rsync skips the file entirely --
# `rsync exited 0` while the copy is wrong. This is the whole reason the md5
# proof exists, and it doubles as proof that classification did not soften
# real breakage into a warning.
printf 'ONE\n' > "$DST/Alpha/a.txt"          # same 4 bytes as "one\n"
touch -r "$SRC/Alpha/a.txt" "$DST/Alpha/a.txt"
"$GARDE" media run Alpha --quiet >/dev/null 2>&1
check "same-size same-mtime corruption is still BROKEN (5)" "$?" 5
out="$("$GARDE" media run Alpha 2>&1)"
case "$out" in *BROKEN*"1 differing"*)
       ok "BROKEN names how many differ, not just that something did" ;;
     *) bad "BROKEN must report the differing count" ;; esac
# Repair for the tests that follow: force content-based comparison once.
rm -f "$DST/Alpha/a.txt"
"$GARDE" media run Alpha --quiet >/dev/null 2>&1
check "the set is clean again after repair" "$?" 0

# --- missing source is loud ------------------------------------------
cat > "$TMP/bad.json" <<JSON
{ "destinations": { "tmp": { "kind": "local", "root": "$DST", "online": true } },
  "sets": [ { "name": "Ghost", "path": "$TMP/nope", "copies": ["tmp"],
              "min_copies": 1, "verify": "md5" } ] }
JSON
GARDE_MANIFEST="$TMP/bad.json" "$GARDE" media run Ghost >/dev/null 2>&1
check "a missing source directory is BROKEN (5), not exit 0" "$?" 5

# --- blindness is not emptiness --------------------------------------
cat > "$TMP/blind.json" <<JSON
{ "destinations": { "gone": { "kind": "local", "root": "$TMP/not-mounted",
                              "marker": ".mounted", "online": true } },
  "sets": [ { "name": "Alpha", "path": "$SRC/Alpha", "copies": ["gone"],
              "min_copies": 1, "verify": "md5" } ] }
JSON
GARDE_MANIFEST="$TMP/blind.json" "$GARDE" media list >/dev/null 2>&1
check "unreachable destination is BLIND (6), not an empty success" "$?" 6

GARDE_MANIFEST="$TMP/missing.json" "$GARDE" media list >/dev/null 2>&1
check "a missing manifest is BLIND (6)" "$?" 6

# --- the manifest must outlive the code it is read by (2026-08-05) ----
# GARDE_MANIFEST defaulted to "$SELF/garde.json" -- beside the code. The live
# manifest is untracked, so no branch or build carries it, and a verb build is
# a disposable directory `current` is repointed away from on every upgrade.
# Both together already destroyed it once: it existed only inside the
# gardien-garde worktree, the migration off dev clones deleted that worktree,
# and mandark could not prove a single backup until it was reconstructed.
#
# Asserted on the DEFAULT, with the override deliberately unset, because the
# rest of this suite only ever exercises the override -- which is exactly why
# the bad default survived unnoticed. Read from a subshell that sources the
# library the way garde does.
default_manifest="$(
  unset GARDE_MANIFEST
  SELF="$ROOT"; VERB_NAME=garde
  # shellcheck source=/dev/null
  . "$ROOT/lib/manifest.sh" 2>/dev/null
  printf '%s\n' "$GARDE_MANIFEST"
)"
case "$default_manifest" in
  "$HOME"/.config/gardien/garde.json) ok "default manifest is XDG config, not the code tree" ;;
  *) bad "default manifest should be ~/.config/gardien/garde.json, got '$default_manifest'" ;;
esac

# The load-bearing half: wherever it points, it must not be under a directory
# that a build adoption or a worktree removal can take away.
case "$default_manifest" in
  *"/verb-builds/"*|*"-verbs/"*|*"-garde/"*|"$ROOT"/*)
    bad "default manifest lives in a disposable tree ('$default_manifest') -- an upgrade would orphan it" ;;
  *) ok "default manifest is outside any build, worktree or checkout" ;;
esac

# --- marker file gates a local mount ---------------------------------
mkdir -p "$TMP/not-mounted"
GARDE_MANIFEST="$TMP/blind.json" "$GARDE" media list >/dev/null 2>&1
check "directory without its marker still counts as unmounted" "$?" 6

# --- nothing pending is the GOAL STATE, not a usage error (2026-08-02) -
# garde-nightly.service runs exactly `garde media run --all-pending`. An empty
# pending list used to fall through to the usage error below, so the unit
# exited 2 and systemd marked it failed AT THE MOMENT EVERY SET WAS PROVEN --
# telling the caller to pass the flag it had just passed. Found by re-running
# the real unit after the STALE/BROKEN fix cleared the last PENDING set.
"$GARDE" media run --all-pending >/dev/null 2>&1
check "--all-pending with nothing pending is success (0), not a usage error" "$?" 0
out="$("$GARDE" media run --all-pending 2>&1)"
case "$out" in *"nothing pending"*"already copied and proven"*)
       ok "an empty pending list states the goal positively" ;;
     *) bad "an empty pending list must state the goal state, not report a fault" ;; esac

# --- usage errors ----------------------------------------------------
"$GARDE" media run >/dev/null 2>&1
check "run with no set and no --all-pending is a usage error (2)" "$?" 2
"$GARDE" media run NoSuchSet >/dev/null 2>&1
check "run with an unknown set is a usage error (2)" "$?" 2
"$GARDE" media triage Alpha >/dev/null 2>&1
check "triage with no recorded mismatch refuses to invent one" "$?" 2

# --- #36: triage must not gate on --summon itself (only basheur knows) -
# `media triage` used to call `verb_need_summon` before ever asking basheur
# whether the contract is still AGENT-backed, so it charged/refused
# unconditionally -- the exact shape `coverage` was fixed out of in a748abc,
# which its own comment says not to repeat. With a real mismatch recorded
# and no GARDE_BASHEUR override (basheur is absent in this sandbox), the
# fixed arm must reach the "basheur is not at ..." GAP (4), never the old
# "this needs a summon" refusal (3) -- that would mean the unconditional
# gate is still there, deciding a question only basheur can answer.
printf 'diff --git a/x b/x\n-old\n+new\n' > "$GARDE_STATE/Alpha.md5diff"
unset GARDE_BASHEUR
out="$("$GARDE" media triage Alpha 2>&1)"; rc=$?
check "triage with a real mismatch and no --summon reaches basheur, not the old gate" "$rc" 4
case "$out" in *"needs a summon"*)
       bad "triage still gates on --summon itself instead of letting basheur decide" ;;
     *) ok "triage did not refuse on its own -- it let basheur (absent) answer" ;; esac
rm -f "$GARDE_STATE/Alpha.md5diff"

# --- case collisions: the failure that actually lost a file -----------
# Homily.pdf/homily.pdf were ONE file on drvfs and rsync silently
# overwrote the first (2026-07-30). The guard must fire from the
# DESTINATION's declared case_insensitive property, not from a caller
# remembering to ask for it.
CSRC="$TMP/csrc/Coll"; CDST="$TMP/cdst"; mkdir -p "$CSRC" "$CDST"
printf 'upper\n' > "$CSRC/Homily.pdf"
printf 'lower\n' > "$CSRC/homily.pdf"
printf 'plain\n' > "$CSRC/other.txt"
# A NESTED collision. The first version of this suite tested only the
# top-level case above, and so AGREED WITH a real bug: the flattener used
# '~' as its separator, which rsync and the remote shell both expand, so a
# nested path became '.../Brass Charts/home/zachEris/...' and killed the
# real Project Archive transfer with rsync code 3. A top-level collision
# never inserts a separator, so it can never surface this class of bug.
mkdir -p "$CSRC/Brass Charts/Eris/Book of Five"
printf 'nested-upper\n' > "$CSRC/Brass Charts/Eris/Book of Five/BOOK OF 5.mp3"
printf 'nested-lower\n' > "$CSRC/Brass Charts/Eris/Book of Five/Book of 5.mp3"
cat > "$TMP/coll.json" <<JSON
{ "destinations": { "ci": { "kind": "local", "root": "$CDST",
                            "case_insensitive": true, "online": true } },
  "sets": [ { "name": "Coll", "path": "$CSRC", "copies": ["ci"],
              "min_copies": 1, "verify": "md5" } ] }
JSON
out="$(GARDE_MANIFEST="$TMP/coll.json" "$GARDE" media run Coll 2>&1)"; rc=$?
case "$out" in *"case-collision scan"*) ok "case-collision pre-flight runs on a case-insensitive destination" ;;
                *) bad "pre-flight scan did not run" ;; esac
case "$out" in *"would be silently"*) ok "collision is reported before the copy, not after" ;;
                *) bad "collision was not announced" ;; esac
check "a set with collisions still copies and verifies" "$rc" 0
# BOTH members must be rescued, not just the shadowed one: on NTFS the
# surviving name and the surviving content come from different writes.
hu="$(safename Homily.pdf)"; hl="$(safename homily.pdf)"
if [ -f "$CDST/Coll.case-collisions/$hu" ] && [ -f "$CDST/Coll.case-collisions/$hl" ]; then
  ok "every member of the collision group was rescued, not just one"
else
  bad "collision group incompletely rescued into .case-collisions/"
fi
grep -q upper "$CDST/Coll.case-collisions/$hu" 2>/dev/null \
  && grep -q lower "$CDST/Coll.case-collisions/$hl" 2>/dev/null \
  && ok "each rescued file kept its own distinct content" \
  || bad "rescued files do not hold their original distinct contents"

# The nested pair, flattened. No path component may survive as a directory,
# and nothing may be tilde-expanded into a home directory.
nuf="$(safename "Brass Charts/Eris/Book of Five/BOOK OF 5.mp3")"
nlf="$(safename "Brass Charts/Eris/Book of Five/Book of 5.mp3")"
if [ -f "$CDST/Coll.case-collisions/$nuf" ] && [ -f "$CDST/Coll.case-collisions/$nlf" ]; then
  ok "a NESTED collision pair is flattened into single non-colliding names"
else
  bad "nested collision pair not rescued (flattening is broken)"
fi
grep -q nested-upper "$CDST/Coll.case-collisions/$nuf" 2>/dev/null \
  && grep -q nested-lower "$CDST/Coll.case-collisions/$nlf" 2>/dev/null \
  && ok "nested rescued files kept their distinct contents" \
  || bad "nested rescued files lost their contents"

# THE regression that a real migration found: two rescued names must not
# collide with EACH OTHER once lowercased. Flattening removed the separator
# problem but preserved case -- and case was the original problem, so the
# rescue directory reproduced the bug it exists to prevent (8 in, 4 out).
lc_all="$(find "$CDST/Coll.case-collisions" -type f -printf '%P\n' | tr '[:upper:]' '[:lower:]' | sort)"
lc_uniq="$(printf '%s\n' "$lc_all" | sort -u)"
check "no two rescued names collide case-insensitively" \
  "$(printf '%s\n' "$lc_all" | wc -l)" "$(printf '%s\n' "$lc_uniq" | wc -l)"
check "every colliding file survived the rescue (none overwrote another)" \
  "$(find "$CDST/Coll.case-collisions" -type f | wc -l)" "4"
[ -d "$CDST/Coll.case-collisions/Brass Charts" ] \
  && bad "flattening leaked a real directory into .case-collisions/" \
  || ok "no path component leaked out as a directory"
find "$CDST/Coll.case-collisions" -path '*home*zach*' 2>/dev/null | grep -q . \
  && bad "a separator was expanded into a home directory (the '~' bug)" \
  || ok "no separator was expanded into a home path"
# Round-trip: the flat name must decode back to the original path.
back="$(printf '%s' "${nuf#*-}" | sed 's|%2F|/|g; s|%25|%|g')"
check "flattening is reversible" "$back" "Brass Charts/Eris/Book of Five/BOOK OF 5.mp3"

# and the guard must NOT fire where it is not needed
out2="$(GARDE_MANIFEST="$TMP/garde.json" "$GARDE" media run Alpha 2>&1)"
case "$out2" in *"case-collision scan"*) bad "scan ran on a case-SENSITIVE destination" ;;
                 *) ok "no collision scan on a case-sensitive destination" ;; esac

# --- a broken set must not kill the batch -----------------------------
# The real failure this encodes: Project Archive failed mid-migration and
# verb_broke's exit 5 tore down the whole run, so Videos/Teaching/Audacity/
# vkv/Pd were never attempted. The batch must degrade to "one set is
# broken", never to "the batch stopped".
BSRC="$TMP/bsrc"; BDST="$TMP/bdst"; mkdir -p "$BSRC/Good" "$BDST"
printf 'good\n' > "$BSRC/Good/g.txt"
cat > "$TMP/batch.json" <<JSON
{ "destinations": { "b": { "kind": "local", "root": "$BDST", "online": true } },
  "sets": [ { "name": "Ghost", "path": "$TMP/does-not-exist", "copies": ["b"],
              "min_copies": 1, "verify": "md5" },
            { "name": "Good",  "path": "$BSRC/Good", "copies": ["b"],
              "min_copies": 1, "verify": "md5" } ] }
JSON
GARDE_MANIFEST="$TMP/batch.json" "$GARDE" media run Ghost Good >/dev/null 2>&1
check "a batch with one broken set still exits 5" "$?" 5
[ -f "$BDST/Good/g.txt" ] \
  && ok "the healthy set was still copied after an earlier set broke" \
  || bad "a broken set aborted the batch (verb_broke exit-5 regression)"

# --- structural: nothing may iterate collisions via stdin --------------
# This assertion is structural rather than behavioural on purpose. The bug
# it guards is invisible to every test above: those use kind=local, where
# the loop body calls cp/md5sum, and NEITHER consumes stdin. Only the ssh
# path does -- so a functional test on a local destination passes whether
# or not the bug is present. The suite could not have caught it, and did
# not. What CAN be checked cheaply is the shape: if the collision list is
# iterated from stdin, anything in the body that reads stdin (ssh, rsync)
# can eat the rest of the list, and files silently drop out of the
# comparison. Real consequence: 3 of 8 stranded in the local md5 list and
# reported as a hash mismatch on a transfer that had actually succeeded.
# Strip comments first: the comment explaining this bug necessarily quotes
# the bad pattern, and matching it would be a false positive that makes the
# guard fire on its own documentation.
if sed 's/[[:space:]]*#.*$//' "$ROOT/lib/media.sh" \
   | grep -qE 'done[[:space:]]*<<<[[:space:]]*"\$(collisions|MEDIA_COLLISIONS)"'; then
  bad "collision list is iterated from stdin (ssh/rsync in the body can consume it)"
else
  ok "collision list is not iterated from stdin"
fi
if grep -n 'ssh "\${DEST_SSH_OPTS\[@\]}"' "$ROOT/lib/media.sh" | grep -q 'md5sum'; then
  bad "an ssh that reads stdin sits on the collision path without -n"
else
  ok "ssh on the collision verify path does not read stdin"
fi

# --- an empty pending list has two causes, and they are opposites ------
# `media run --all-pending` builds its targets from pending_sets, which skips
# an unreachable destination. So "nothing is pending" and "no destination
# could be looked at" produced the SAME empty list, and therefore the same
# "every set is already copied and proven", exit 0 -- a backup reporting
# success for being blind, on the code path garde-nightly.service runs
# unattended. Observed live 2026-08-03 03:34 with dexter down; the last real
# copy had been 2026-08-02 21:34.
#
# BOTH directions are asserted. Testing only the BLIND case would also pass
# on a build that had simply made the command always fail.
PROVEN="$TMP/proven"; mkdir -p "$PROVEN/reachable" "$PROVEN/nolocal"
touch "$PROVEN/reachable/.marker"
cat > "$TMP/proven.json" <<JSON
{ "destinations": { "here": { "kind": "local", "root": "$PROVEN/reachable",
                              "marker": ".marker", "online": true } },
  "sets": [ { "name": "empty", "path": "$PROVEN/nolocal", "copies": ["here"],
              "min_copies": 1 } ] }
JSON
# Same shape, but the destination root does not exist -- it cannot be looked at.
cat > "$TMP/blind.json" <<JSON
{ "destinations": { "gone": { "kind": "local", "root": "$PROVEN/absent",
                              "marker": ".marker", "online": true } },
  "sets": [ { "name": "empty", "path": "$PROVEN/nolocal", "copies": ["gone"],
              "min_copies": 1 } ] }
JSON

GARDE_MANIFEST="$TMP/proven.json" "$GARDE" media run --all-pending >/dev/null 2>&1
check "all-pending, destination reachable, nothing to do -> 0" "$?" "0"

GARDE_MANIFEST="$TMP/blind.json" "$GARDE" media run --all-pending >/dev/null 2>&1
check "all-pending, NO destination reachable -> 6 (BLIND, not success)" "$?" "6"

# --- #27: set NAME diverging from its path's basename ------------------
# Every set until 2026-07-30 was named after its own basename ('Music' ->
# ~/Music), so `media_copy_set` (lands at $root/basename($src), rsync's own
# behaviour) and `media_verify_set`/`media_remote_files` (hardcoded
# $root/$name) agreed by coincidence. A set named 'config' for path
# ~/.config copied correctly to $root/.config and then failed verify with
# "remote hashing produced nothing", because it looked for $root/config --
# a successful backup reported as a broken one.
NSRC="$TMP/nsrc/.config"; NDST="$TMP/ndst"; mkdir -p "$NSRC" "$NDST"
printf 'settings\n' > "$NSRC/app.conf"
cat > "$TMP/nameskew.json" <<JSON
{ "destinations": { "n": { "kind": "local", "root": "$NDST", "online": true } },
  "sets": [ { "name": "config", "path": "$NSRC", "copies": ["n"],
              "min_copies": 1, "verify": "md5" } ] }
JSON
out="$(GARDE_MANIFEST="$TMP/nameskew.json" "$GARDE" media run config --quiet 2>&1)"; rc=$?
check "a set whose name differs from its path's basename still verifies" "$rc" 0
case "$out" in *"remote hashing produced nothing"*)
       bad "verify looked in \$root/\$name instead of \$root/basename(path)" ;;
     *) ok "verify looked in the same directory the copy actually landed at" ;; esac
[ -f "$NDST/.config/app.conf" ] \
  && ok "the set landed at basename(path), not at the manifest name" \
  || bad "set did not land where expected"
GARDE_MANIFEST="$TMP/nameskew.json" "$GARDE" media list 2>/dev/null | grep -q 'config.*ok x' \
  && ok "list also agrees on where the set landed (media_remote_files)" \
  || bad "list's file count did not find the set at basename(path)"

echo
printf -- '--- media: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
