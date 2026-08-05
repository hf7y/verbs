#!/usr/bin/env bash
# sync-engine.sh -- carry `joue`'s engine across from the default branch, and
# prove afterwards that the copy is still a copy.
#
# NOT A VERB. It has no man/sync-engine.sh.1 and never will, so the
# declaration rule correctly does not count it (same shape as
# bibliothecaire's bin/page92.py). It is the mechanism that keeps this
# branch's second source of truth from becoming a second ANSWER.
#
# THE PROBLEM IT EXISTS FOR
# -------------------------
# `bashified` carries vim_arcade/ so that a standalone clone of this branch
# is a working joue with no dev clone present. That is two copies of the
# same 21 files in one repository, and BUILD-DISCIPLINE's "config read from
# one source, not retyped per file" applies to code as much as to a
# hostname. Two copies are only tolerable if one of them is DERIVED and the
# derivation is checkable.
#
# So the copy is byte-verbatim, never edited here, and the check is a single
# git tree object id:
#
#     git rev-parse <source-ref>:vim_arcade   ==   git rev-parse HEAD:vim_arcade
#
# A tree id is not a heuristic. If one byte of one file differs, or a file
# was added or removed, the ids differ. And it is recorded in
# ENGINE-PROVENANCE, so half the check -- "has this copy been hand-edited
# since it was carried?" -- runs in a standalone clone that has never heard
# of `main`.
#
# WHY NOT A SUBMODULE, A SUBTREE MERGE, OR A BUILD STEP
#   submodule   a consumer of `bashified` clones ONE ref; a submodule makes
#               that two fetches and a second credential, which is exactly
#               what VERB-DISTRIBUTION §5 collapsed.
#   subtree     merges main's history into bashified. This branch is a total
#               purge whose entire justification (README) is that the purged
#               material is one `git log main` away; merging main back in
#               dissolves the purge.
#   build step  a build that must run before the verb works means the
#               declaration rule's "executable bin/<name>" is not sufficient
#               for the verb to RUN, and the build tag would ship a broken
#               tree. Carrying the output is what makes the checkout usable
#               as checked out.
#
# USAGE
#   bin/sync-engine.sh            carry vim_arcade/ across from origin/main
#   bin/sync-engine.sh --check    verify only; write nothing
#   ENGINE_SOURCE_REF=main bin/sync-engine.sh    carry from a different ref
#
# EXITS
#   0  the carried copy is exactly the source tree (or was just made so)
#   2  usage
#   4  GAP: the source ref has moved on; a newer engine has not been carried
#   5  BROKEN: this branch's copy is not the tree ENGINE-PROVENANCE names,
#      i.e. somebody edited the derived copy
#   6  BLIND: the source ref is not reachable from here, so currency is
#      UNKNOWN. Never reported as "up to date".

set -uo pipefail

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
PROV="$SELF/ENGINE-PROVENANCE"
SRC_REF="${ENGINE_SOURCE_REF:-origin/main}"
PKG=vim_arcade

CHECK=0
case "${1:-}" in
  '')        CHECK=0 ;;
  --check)   CHECK=1 ;;
  -h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'sync-engine.sh: unknown argument: %s (try --check)\n' "$1" >&2; exit 2 ;;
esac

say()   { printf 'sync-engine.sh: %s\n' "$*"; }
fail()  { printf 'sync-engine.sh: %s\n' "$*" >&2; }

git -C "$SELF" rev-parse --git-dir >/dev/null 2>&1 || {
  fail "BLIND: $SELF is not a git checkout, so nothing here can be compared to anything"
  exit 6
}

# ------------------------------------------------- what this branch carries
here_tree="$(git -C "$SELF" rev-parse -q --verify "HEAD:$PKG" 2>/dev/null)"
dirty="$(git -C "$SELF" status --porcelain -- "$PKG" 2>/dev/null)"

recorded=""
[ -f "$PROV" ] && recorded="$(awk '$1=="tree"{print $2}' "$PROV")"

# ---------------------------------------------------------------- integrity
# Runs anywhere, including a standalone clone with no `main`. This is the
# half that catches the failure that actually destroys the design: somebody
# fixing a bug in the DERIVED copy, where main will never see it.
integrity_ok=1
if [ "$CHECK" = 1 ]; then
  if [ -n "$dirty" ]; then
    fail "BROKEN: $PKG/ has uncommitted changes here. This copy is derived; edit it on $SRC_REF and re-run this script."
    printf '%s\n' "$dirty" >&2
    integrity_ok=0
  elif [ -n "$recorded" ] && [ -n "$here_tree" ] && [ "$recorded" != "$here_tree" ]; then
    fail "BROKEN: $PKG/ is tree $here_tree but ENGINE-PROVENANCE names $recorded."
    fail "        The derived copy was edited in place. Whatever was fixed here, main does not have."
    integrity_ok=0
  else
    say "integrity OK -- $PKG/ is the tree ENGINE-PROVENANCE names ($here_tree)"
  fi
  [ "$integrity_ok" = 1 ] || exit 5
fi

# ----------------------------------------------------------------- currency
src_tree="$(git -C "$SELF" rev-parse -q --verify "$SRC_REF:$PKG" 2>/dev/null)"
if [ -z "$src_tree" ]; then
  fail "BLIND: $SRC_REF is not reachable from this checkout, so whether $PKG/ is current is UNKNOWN."
  fail "       This is the normal state of a standalone clone of bashified. It is not 'up to date'."
  exit 6
fi

if [ "$src_tree" = "$here_tree" ]; then
  say "current -- $PKG/ is identical to $SRC_REF ($src_tree)"
  exit 0
fi

if [ "$CHECK" = 1 ]; then
  fail "GAP: $SRC_REF carries $PKG/ tree $src_tree; this branch carries $here_tree."
  fail "     A newer engine exists and has not been carried across. Run bin/sync-engine.sh (no --check)."
  exit 4
fi

# ------------------------------------------------------------------- carry
src_sha="$(git -C "$SELF" rev-parse "$SRC_REF")"
say "carrying $PKG/ from $SRC_REF ($src_sha)"
git -C "$SELF" rm -r -q --ignore-unmatch --cached "$PKG" >/dev/null 2>&1
rm -rf "${SELF:?}/$PKG"
git -C "$SELF" checkout "$SRC_REF" -- "$PKG" || { fail "BROKEN: checkout of $PKG from $SRC_REF failed"; exit 5; }

{
  printf '# Generated by bin/sync-engine.sh. Do not edit by hand, and do not\n'
  printf '# edit %s/ in this branch -- it is a derived copy and the tree id\n' "$PKG"
  printf '# below is what makes that checkable. Fix things on the source ref.\n'
  printf 'source_ref\t%s\n' "$SRC_REF"
  printf 'source_sha\t%s\n' "$src_sha"
  printf 'tree\t%s\n' "$src_tree"
  printf 'synced\t%s\n' "$(date -u +%Y-%m-%d)"
} > "$PROV"

git -C "$SELF" add "$PKG" "$PROV"
say "carried. $PKG/ is now tree $src_tree; ENGINE-PROVENANCE updated and staged."
say "commit it -- an uncommitted carry is indistinguishable from a hand edit."
exit 0
