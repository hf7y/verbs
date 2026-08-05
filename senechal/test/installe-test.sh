#!/usr/bin/env bash
# installe-test.sh -- THE PAGE TEST, mechanized for `installe`.
#
# installe WRITES. So beyond the nine rows, this file asserts the two safety
# properties the page promises, because a guard nobody provokes is a guard
# nobody has:
#
#   - a dry run changes nothing on disk (checked by inspecting the disk, not
#     by trusting the exit code)
#   - retire removes the link and never the target
#
# Every run happens in a sandbox install directory. This test never touches
# ~/.local/bin, and a test for a tool that removes things from PATH must be
# provably incapable of removing anything from the real one.

set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CMD="${1:-$ROOT/bin/installe}"
PAGE="$ROOT/man/installe.1"

pass=0; fail=0
ok() { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }

SANDBOX=""
sandbox() {
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/src"
  printf '#!/bin/sh\necho hi\n' > "$SANDBOX/src/hi"; chmod +x "$SANDBOX/src/hi"
  printf '#!/bin/sh\n:\n'      > "$SANDBOX/bin/handmade"; chmod +x "$SANDBOX/bin/handmade"
  ln -s /nonexistent/gone "$SANDBOX/bin/deadlink"
  printf 'x\n' > "$SANDBOX/bin/crt-nightly-batch-loop.sh"; chmod +x "$SANDBOX/bin/crt-nightly-batch-loop.sh"
  printf 'x\n' > "$SANDBOX/bin/thing.bak.2026-07-28"
  export INSTALLE_BIN="$SANDBOX/bin" INSTALLE_MANIFEST="$SANDBOX/manifest.tsv"
  # A suite that installs and retires dozens of times must not file dozens of
  # notes with the estate. Declining is the documented, deliberate act; the
  # exit-8 path is provoked explicitly below rather than left to chance.
  export INSTALLE_NOTIFY=0
}
rc() { "$CMD" "$@" >/dev/null 2>&1; printf '%s' "$?"; }

trap '[ -n "$SANDBOX" ] && rm -rf "$SANDBOX"' EXIT
sandbox
printf '=== THE PAGE TEST: installe\n    command: %s\n\n' "$CMD"

# --- row 1 ------------------------------------------------------------------
name_line="$(awk '/^\.SH NAME/{getline; print; exit}' "$PAGE")"
case "$name_line" in
  *" and "*) no "row 1: NAME contains 'and': $name_line" ;;
  *\\-*)     ok "row 1: NAME is one clause" ;;
  *)         no "row 1: malformed NAME: $name_line" ;;
esac

# --- row 2: every SYNOPSIS form runs ---------------------------------------
while IFS= read -r form; do
  # shellcheck disable=SC2086
  r="$(rc $form)"
  case "$r" in 0|1|9) ok "row 2: \`installe $form\` runs (exit $r)" ;;
               *)   no "row 2: \`installe $form\` exited $r" ;; esac
done < <(awk '
  /^\.SH SYNOPSIS/ { in_syn=1; next }
  /^\.SH /         { in_syn=0 }
  !in_syn          { next }
  /^\.\\" bashify: norun/ { skip=1; next }
  /^\.B installe /        { if (skip) { skip=0; next }
                            if ($0 ~ /\\f/) next
                            sub(/^\.B installe /, ""); print }
' "$PAGE")

# --- row 3: bidirectional ---------------------------------------------------
page_subs="$(grep -oE '^\.B installe [a-z]+' "$PAGE" | awk '{print $3}' | sort -u)"
code_subs="$(awk '/^  [a-z]+\)/ {sub(/\).*/,""); gsub(/ /,""); print}' "$CMD" | sort -u)"
check "row 3: page subcommands == code subcommands" "$page_subs" "$code_subs"
for f in --dry-run --force --json --quiet --help --version; do
  if grep -q -- "$f" "$ROOT/lib/verb.sh" "$CMD"; then ok "row 3: $f exists in code"
  else no "row 3: $f is on the page and not in the code"; fi
done

# --- row 4: every documented exit code is reachable -------------------------
sandbox
check "row 4: exit 0 (install)"                "$(rc "$SANDBOX/src/hi")"      0
check "row 4: exit 0 (retire what we own)"     "$(rc retire hi)"              0
check "row 4: exit 9 (retire an absent name)"  "$(rc retire nothere)"         9
check "row 4: exit 9 (list, nothing owned)"    "$(rc list)"                   9
check "row 4: exit 2 (no subcommand)"          "$(rc)"                        2
check "row 4: exit 2 (unknown subcommand)"     "$(rc bogus)"                  2
check "row 4: exit 2 (retire without a name)"  "$(rc retire)"                 2
check "row 4: exit 5 (install dir absent)"     "$(INSTALLE_BIN=$SANDBOX/nope rc audit)" 5
check "row 4: exit 7 (retire what we do not own)" "$(rc retire handmade)"     7
check "row 4: exit 7 (overwrite what we do not own)" "$(rc "$SANDBOX/bin/handmade")" 7

# Exit 8: the change succeeds and the estate cannot be told. Provoked with a
# PATH that has no notify-senechal on it, which is the real failure mode.
sandbox
# PATH is trimmed to the system directories, not emptied: installe needs awk,
# ln and mktemp to do the work whose declaration is what must fail. An empty
# PATH gets 127 from the first helper and proves nothing.
undeclared="$(INSTALLE_NOTIFY=1 PATH="/usr/bin:/bin" "$CMD" "$SANDBOX/src/hi" >/dev/null 2>&1; printf '%s' "$?")"
check "row 4: exit 8 (change made, estate not told)" "$undeclared" 8
if [ -L "$SANDBOX/bin/hi" ]; then ok "SAFETY: exit 8 left the change standing"
else no "SAFETY: exit 8 unmade the change -- 8 means told-nobody, not failed"; fi

sandbox
unreadable="$SANDBOX/unreadable"; mkdir -p "$unreadable"; chmod 000 "$unreadable"
blind="$(INSTALLE_BIN="$unreadable" "$CMD" audit >/dev/null 2>&1; printf '%s' "$?")"
chmod 755 "$unreadable"
check "row 4: exit 6 (install dir unreadable)" "$blind" 6

# --- the `verb` form, against a real repository -----------------------------
# This fixture exists because `verb` shipped broken: it was the one form no
# test invoked, so the one form whose unbound-variable bug survived a suite
# that was otherwise green. A subcommand that is hard to fixture is the
# subcommand most likely to be wrong.
sandbox
if command -v git >/dev/null 2>&1; then
  fake="$SANDBOX/projects/toy"
  mkdir -p "$fake/bin"
  git -C "$fake" init -q 2>/dev/null
  git -C "$fake" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
  git -C "$fake" checkout -q -b bashified 2>/dev/null
  printf '#!/bin/sh\necho toy\n' > "$fake/bin/toyverb"; chmod +x "$fake/bin/toyverb"
  git -C "$fake" add -A 2>/dev/null
  git -C "$fake" -c user.email=t@t -c user.name=t commit -q -m verb 2>/dev/null
  git -C "$fake" checkout -q -

  r="$(INSTALLE_PROJECTS="$SANDBOX/projects" "$CMD" verb toy toyverb >/dev/null 2>&1; printf '%s' "$?")"
  check "verb: installs from a bashified branch" "$r" 0
  if [ -L "$SANDBOX/bin/toyverb" ]; then ok "verb: the link exists"
  else no "verb: no link was created"; fi
  if [ -d "$SANDBOX/projects/toy-verbs" ]; then ok "verb: pinned the branch as a worktree"
  else no "verb: no worktree was checked out"; fi
  r="$(INSTALLE_PROJECTS="$SANDBOX/projects" "$CMD" verb toy nosuchverb >/dev/null 2>&1; printf '%s' "$?")"
  check "verb: a name the branch does not carry is usage" "$r" 2
  git -C "$fake" worktree remove --force "$SANDBOX/projects/toy-verbs" 2>/dev/null
else
  no "verb: git is unavailable, so the verb form is UNTESTED"
fi

# --- the safety properties --------------------------------------------------
sandbox
"$CMD" -n "$SANDBOX/src/hi" >/dev/null 2>&1
if [ -e "$SANDBOX/bin/hi" ] || [ -L "$SANDBOX/bin/hi" ]; then
  no "SAFETY: --dry-run created a link"
elif [ -s "${INSTALLE_MANIFEST:-}" ]; then
  no "SAFETY: --dry-run wrote the manifest"
else ok "SAFETY: --dry-run changed nothing on disk"; fi

"$CMD" "$SANDBOX/src/hi" >/dev/null 2>&1
"$CMD" -n retire hi >/dev/null 2>&1
if [ -L "$SANDBOX/bin/hi" ]; then ok "SAFETY: --dry-run retire removed nothing"
else no "SAFETY: --dry-run retire removed the link"; fi

"$CMD" retire hi >/dev/null 2>&1
if [ -x "$SANDBOX/src/hi" ]; then ok "SAFETY: retire left the target alone"
else no "SAFETY: retire deleted the target -- the one thing it must never do"; fi
if [ -L "$SANDBOX/bin/hi" ]; then no "SAFETY: retire left the link behind"
else ok "SAFETY: retire removed the link"; fi

if [ -e "$SANDBOX/bin/handmade" ]; then ok "SAFETY: a refused retire left the file in place"
else no "SAFETY: a refused retire removed the file anyway"; fi

# --- --force adoption, and the line it must not cross -----------------------
# Until 2026-08-02 link_it refused an unowned name with a message ending
# "--force overwrites it" and then never read VERB_FORCE -- that variable was
# consulted only by do_retire. So the documented escape hatch printed its own
# name and exited 7 unchanged. A flag advertised at its own refusal and wired
# to nothing is worse than no flag: the caller does the documented thing, is
# told no, and cannot tell a guard from a bug.
#
# Found while adopting a hand-made `garde` symlink that predated installe --
# a link that was CORRECT but unowned, so `installe audit` called it repo-link
# and `retire` would have refused it forever. Adoption has to be possible or
# the manifest can never become complete.
sandbox
# `installe <path>` takes the name from the basename, so the source must be
# called `adoptme` for it to collide with the unowned link below.
printf '#!/bin/sh\n:\n' > "$SANDBOX/src/adoptme"; chmod +x "$SANDBOX/src/adoptme"
ln -sfn /nonexistent/somewhere-else "$SANDBOX/bin/adoptme"   # unowned SYMLINK
check "FORCE: an unowned link is refused without --force" "$(rc "$SANDBOX/src/adoptme")" 7
if [ "$(readlink "$SANDBOX/bin/adoptme")" = "/nonexistent/somewhere-else" ]; then
  ok "FORCE: the refused install left the link pointing where it was"
else no "FORCE: a refused install moved the link anyway"; fi

# --force --dry-run must offer and write nothing. Checked on a FRESH sandbox so
# no earlier real install can leave a manifest row this then blames on the dry
# run -- the first draft of this assertion did exactly that and failed itself.
sandbox
printf '#!/bin/sh\n:\n' > "$SANDBOX/src/adoptme"; chmod +x "$SANDBOX/src/adoptme"
ln -sfn /nonexistent/somewhere-else "$SANDBOX/bin/adoptme"
"$CMD" --force -n "$SANDBOX/src/adoptme" >/dev/null 2>&1
if grep -q '^adoptme' "${INSTALLE_MANIFEST}" 2>/dev/null; then
  no "FORCE: --force --dry-run wrote the manifest"
elif [ "$(readlink "$SANDBOX/bin/adoptme")" != "/nonexistent/somewhere-else" ]; then
  no "FORCE: --force --dry-run replaced the link"
else ok "FORCE: --force --dry-run changed nothing on disk"; fi

# And the real thing: adoption re-points the name AND takes ownership, which is
# the whole point -- an unowned link can never be retired.
sandbox
printf '#!/bin/sh\n:\n' > "$SANDBOX/src/adoptme"; chmod +x "$SANDBOX/src/adoptme"
ln -sfn /nonexistent/somewhere-else "$SANDBOX/bin/adoptme"
check "FORCE: --force adopts the unowned link" "$(rc --force "$SANDBOX/src/adoptme")" 0
if [ "$(readlink -f "$SANDBOX/bin/adoptme")" = "$(readlink -f "$SANDBOX/src/adoptme")" ]; then
  ok "FORCE: the adopted link points at the new target"
else no "FORCE: the adopted link points somewhere else"; fi
if grep -q '^adoptme' "${INSTALLE_MANIFEST}" 2>/dev/null; then
  ok "FORCE: installe now OWNS it (so retire will work)"
else no "FORCE: adopted the link but never recorded ownership"; fi
check "FORCE: and it can now be retired" "$(rc retire adoptme)" 0

# The guard itself: a REGULAR FILE is somebody's content. --force re-points a
# name; it never deletes a file a human wrote. This is the assertion that keeps
# --force from becoming rm.
sandbox
before="$(md5sum < "$SANDBOX/bin/handmade")"
fc="$("$CMD" --force verb nosuchproject handmade >/dev/null 2>&1; printf '%s' "$?")"
if [ "$(md5sum < "$SANDBOX/bin/handmade")" = "$before" ]; then
  ok "FORCE: a regular file is byte-identical after a --force attempt"
else no "FORCE: --force damaged a regular file -- it must re-point names, never delete content"; fi
if [ -e "$SANDBOX/bin/handmade" ]; then ok "FORCE: the regular file still exists"
else no "FORCE: --force deleted a human's file"; fi

# --- audit classifies ------------------------------------------------------
sandbox
audit="$("$CMD" -q audit 2>/dev/null)"
for want in "broken     deadlink" "unknown    handmade" "generated  crt-nightly-batch-loop.sh" "backup     thing.bak.2026-07-28"; do
  if printf '%s\n' "$audit" | grep -qF "$want"; then ok "audit: ${want}"
  else no "audit: expected '$want'"; fi
done

# --- row 5: EXAMPLES execute -----------------------------------------------
sandbox
bindir="$(dirname "$(readlink -f "$CMD")")"
while IFS= read -r ex; do
  ex="${ex#\$ }"
  PATH="$bindir:$PATH" bash -c "$ex" >/dev/null 2>&1
  r=$?
  case "$r" in 0|1|9|141) ok "row 5: example runs: $ex" ;;
               *)       no "row 5: example failed (exit $r): $ex" ;; esac
done < <(awk '
  /^\.SH EXAMPLES/ { in_ex=1; next }
  /^\.SH /         { in_ex=0 }
  !in_ex           { next }
  /^\.\\" bashify: norun/ { skip=1; next }
  /^\$ installe/   { if (skip) { skip=0; next }; gsub(/\\-/, "-"); print }
' "$PAGE")

# --- rows 6-9 ---------------------------------------------------------------
if grep -q 'cannot spend money' "$PAGE"; then ok "row 6: page states it cannot spend"
else no "row 6: page silent on cost"; fi
check "row 6: --summon refused by name" "$(rc --summon)" 2
if grep -qE 'update\\-alternatives|stow|\bln \(1\)|BR ln' "$PAGE"; then ok "row 7: lineage named"
else no "row 7: no lineage named"; fi
if grep -rqiE 'anthropic|claude|openai|copilot|\bllm\b|\bagent\b|agentic' "$PAGE" "$CMD"; then
  no "row 8: a vendor or agent name is present"
else ok "row 8: clean"; fi
if grep -qiE 'will |going to |not yet|planned|TODO|coming soon' "$PAGE"; then
  no "row 9: aspirational sentence in the page"
else ok "row 9: present tense only"; fi

printf '\n--- installe: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
