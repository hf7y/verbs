#!/usr/bin/env bash
# discipline.sh -- print the realisateur baseline: the build-discipline
# checklist and the ecosystem protocols. ONE file, read at the point of use.
#
# KIND: verb
#
# WHAT THIS RETIRES: bin/restamp-discipline.sh, and the stamped
# `realisateur-baseline` region in every project's CLAUDE.md.
#
# WHY (Zach, 2026-08-14: "why are we even stamping at all? if it's stamp worthy
# it should just be in a global file"). The stamped copies were not travelling,
# they were rotting, and the drift detector reported OK throughout:
#   - 11 repos carried a BYTE-IDENTICAL CORRUPTED checklist (the silence-audit
#     row spliced through the middle of the git-commit-F row). Byte-identity
#     across eleven repos proves the generator wrote it, not a hand-edit.
#   - Those 11 were two source-generations behind: no `consulte` protocol, and
#     10 checklist rows where the live rule was 12.
#   - restamp-discipline.sh could not RUN on mandark at all (it discovers
#     projects from $SCHED_ROOT/schedule/*.conf; there is no scheduler checkout
#     there), so propagation had reached zero.
#   - BUILD-DISCIPLINE.md, the declared source, was 36 lines BEHIND its own
#     copies. The source of truth was the stalest copy.
#   - hygiene-lint §7b compared ROW COUNTS only and emitted an advisory NOTE.
#     Both sides had 10 rows, so it passed over all of the above.
#
# The original copy-not-symlink argument was about SILENT ABSENCE: a dangling
# symlink does not error, it just makes the discipline quietly missing. That
# argument is answered better here than by copying. A missing `discipline`
# command is LOUD on any host, in any clone -- and this repo's own protocols
# doctrine already said the right thing: "Each is a command on PATH -- not a
# rule to remember, because prose decays and guards don't."
#
# THE TEXT LIVES IN BUILD-DISCIPLINE.md, in the fenced block under
# "## The baseline". It is not duplicated here -- this script reads it. That is
# the "config read from one source, not retyped per file" row applying to
# itself, which it never did while this was a stamper.
set -euo pipefail

CLI_NAME='discipline'
CLI_SUMMARY='print the realisateur baseline: build-discipline checklist + ecosystem protocols'
CLI_USAGE='  discipline              print the whole baseline
  discipline --checklist  print only the build-discipline checklist
  discipline --protocols  print only the ecosystem protocols
  discipline --path       print the file the text is read from'

# Self-locating, through a SYMLINK. Installed host-wide, this file is reached
# as /usr/local/bin/discipline pointing into the verb build, and BASH_SOURCE is
# then the symlink, whose parent is /usr/local. Without readlink -f, SRC
# becomes /usr/local/BUILD-DISCIPLINE.md and every invocation dies. The text is
# always next to the REAL file, never next to the name it was called by.
# Witness: discipline --path
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SRC="$HERE/BUILD-DISCIPLINE.md"

die()   { printf '%s: FAIL: %s\n' "$CLI_NAME" "$*" >&2; exit 1; }
# 2, not 1. "You typed it wrong" and "I looked and something is wrong" are
# different answers, and a caller that cannot tell them apart retries a
# finding or reports a typo as one. The estate's usage code is 2 (CONTRACT.md).
usage() { printf '%s: %s\n' "$CLI_NAME" "$*" >&2; printf 'usage:\n%s\n' "$CLI_USAGE" >&2; exit 2; }

case "${1:-}" in
  -h|--help)
    printf '%s -- %s\n\nusage:\n%s\n' "$CLI_NAME" "$CLI_SUMMARY" "$CLI_USAGE"; exit 0 ;;
  --path) printf '%s\n' "$SRC"; exit 0 ;;
esac

[ -f "$SRC" ] || die "cannot find BUILD-DISCIPLINE.md at $SRC
  This command reads its text from realisateur's own checkout. If realisateur
  is not present on this host, that is a FINDING, not an inconvenience -- say
  so loudly rather than reciting the checklist from memory."

# Extract the fenced block under "## The baseline". Anchored on the heading
# rather than on the first fence in the file, because BUILD-DISCIPLINE.md is
# 690 lines of prose containing many other fenced examples.
body="$(awk '
  /^## The baseline/        { inseg=1; next }
  inseg && /^```/           { if (infence) { exit } ; infence=1; next }
  infence                   { print }
' "$SRC")"

# FAIL LOUD, and specifically: never print a truncated or empty checklist and
# exit 0. An empty extraction means the heading or the fence moved, and a
# silently empty baseline is precisely the "discipline silently absent" failure
# this whole change exists to prevent.
[ -n "$body" ] || die "extracted an EMPTY baseline from $SRC
  The '## The baseline' heading or its fenced block has moved or been renamed.
  Refusing to print nothing and exit 0."

lines="$(printf '%s\n' "$body" | grep -c '^- \[ \]' || true)"
[ "$lines" -ge 8 ] || die "extracted only $lines checklist rows from $SRC -- expected at least 8.
  Either the block is truncated or the checklist has been gutted. Refusing to
  print a partial discipline as if it were the whole one."

case "${1:-}" in
  '')           printf '%s\n' "$body" ;;
  --checklist)  printf '%s\n' "$body" | awk '/^## Ecosystem protocols/{exit} {print}' ;;
  --protocols)  printf '%s\n' "$body" | awk '/^## Ecosystem protocols/{p=1} p' ;;
  *)            usage "unknown argument: $1" ;;
esac
