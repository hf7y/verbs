#!/usr/bin/env bash
# reach-lint.sh -- offline-first (zero AI), writes nothing, and exits 0 except
# for its own --strict mode and the BLIND case (exit 3) where it could not
# reach a single registered repo. The mechanization of BUILD-DISCIPLINE.md
# pattern 13b along the axis hygiene-lint's [dispatch-parity] NOTE cannot
# see: not "which command files name this script", but "can the executor
# reading this file actually reach what it names".
#
# GUARD: can the executor reading a command file actually reach what that file names?
# RUNNER: bin/tests/reach-lint.test.sh
# GUARD-TEST: bin/tests/reach-lint.test.sh
# GATE: strict
# VERIFIED: 2026-08-07 via bash bin/reach-lint.sh (0 FLAGs) and its suite
#
# The 2026-07-27 failure it exists to prevent: /ideate and /cloture lived in
# realisateur/.claude/commands only, and six of the nine scripts they told a
# session to run had no PATH shim. Nothing flagged it, because a
# project-scoped command that works in its own repo emits no signal at all.
# The gap was an UNASKED QUESTION, not drift.
#
# Two checks:
#
#   A. SCOPE DECLARATION -- every command file must state, in frontmatter,
#      `scope: project` or `scope: user`. Nobody ever decided /ideate should
#      be realisateur-only; the question was never posed. This check does not
#      judge which answer is right -- it refuses to let silence stand in for
#      one, same stance as the `# verified <date> via <cmd>` stamp.
#
#   B. REACH -- for every `scope: user` file (and everything already
#      installed under ~/.claude/commands), every command it names must
#      resolve from a neutral cwd. A user-level command runs in repos that
#      have no realisateur checkout and no relative bin/, so a name that only
#      resolves from inside this repo is a broken instruction there.
#
# Candidate command tokens, chosen for zero false positives rather than
# coverage: (1) the first word of a line inside a fenced code block, and
# (2) a backticked bare token that matches a realisateur bin/<tok>.sh, with
# or without the .sh. Prose words like `parked` or `active` match neither.
#
# Usage:
#   reach-lint.sh                scan every registered project + ~/.claude/commands
#   reach-lint.sh --strict       exit 1 if ANY check FLAGged (for hooks)
#   reach-lint.sh --strict-reach exit 1 only if check B FLAGged. Check A is a
#                                new convention other repos have not adopted
#                                yet, so a caller that only cares whether its
#                                own instructions are reachable must not be
#                                held hostage by another project frontmatter.
set -uo pipefail

CLI_NAME='reach-lint.sh'
CLI_SUMMARY='can the executor reading a command file actually reach what it names?'
CLI_USAGE='  reach-lint.sh                scan every registered project + ~/.claude/commands
  reach-lint.sh --strict       exit 1 if ANY check FLAGged (for hooks)
  reach-lint.sh --strict-reach exit 1 only if the reach check (B) FLAGged'
CLI_FLAGS='--strict --strict-reach'
CLI_EXITS='  0  scanned; no FLAGs, or FLAGs found but no --strict mode asked for
  1  --strict/--strict-reach was given and the corresponding check FLAGged
  3  BLIND: no registered project resolved to a directory that exists, so
     nothing was scanned. Never reported as 0.'
CLI_POSITIONAL=none
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
# shellcheck source=lib/conf.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/conf.sh"
cli_guard "$@"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable for bin/tests/reach-lint.test.sh only -- real callers (install-
# shims.sh, hygiene-lint.sh) never set these, so behavior is unchanged.
SCHED_ROOT="${SCHED_ROOT:-${INSTALLE_PROJECTS:-$HOME/Documents/Projects}/scheduler}"
USER_CMD_DIR="${USER_CMD_DIR:-$HOME/.claude/commands}"

STRICT=0
case "${1:-}" in
  --strict)       STRICT=all ;;
  --strict-reach) STRICT=reach ;;
esac

flags=0
reach_flags=0
flag() {
  echo "  FLAG [$1] $2"
  flags=$((flags+1))
  case "$1" in unreachable) reach_flags=$((reach_flags+1)) ;; esac
}

# Names realisateur ships as bin/<name>.sh -- the vocabulary check B treats
# as command tokens when it sees them backticked in prose.
own_cmds="$(cd "$REPO/bin" && ls -1 *.sh 2>/dev/null | sed 's|\.sh$||' | sort -u)"

# --- token extraction -------------------------------------------------------
# Prints one candidate command token per line for the given file.
named_commands() {
  local f="$1"
  {
    # (1) first word of each line inside ``` fences (skip the fence lines,
    #     continuations, comments, and shell keywords/redirect noise).
    awk '
      /^```/ { infence = !infence; next }
      !infence { next }
      /^[[:space:]]*[#|>]/ { next }
      { w = $1 }
      w ~ /^[a-z][a-z0-9._-]*$/ { print w }
    ' "$f"
    # (2) backticked bare tokens that match one of realisateur own commands.
    grep -o '`[a-z][a-z0-9._/-]*`' "$f" 2>/dev/null \
      | tr -d '`' | sed 's|^bin/||; s|\.sh$||'
  } | sort -u | while read -r tok; do
      [ -n "$tok" ] || continue
      case "$tok" in ''|*/*) continue ;; esac
      # Keep it if it is one of ours, or it came from a code fence.
      if printf '%s\n' "$own_cmds" | grep -qx "$tok"; then
        echo "$tok"
      elif grep -qE '^```' "$f" && awk -v t="$tok" '
             /^```/ { infence = !infence; next }
             infence && $1 == t { found = 1 }
             END { exit !found }' "$f"; then
        echo "$tok"
      fi
    done | sort -u
}

# Resolves a token from a neutral cwd -- the condition that actually matters
# for a user-level command, which never runs with this repo as cwd.
resolves_anywhere() {
  ( cd / && command -v "$1" >/dev/null 2>&1 )
}

# Reads `scope:` out of a markdown frontmatter block. Prints the value, or
# nothing if there is no frontmatter or no scope key.
scope_of() {
  awk '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { infm = 1; next }
    infm && $0 == "---" { exit }
    infm && /^scope:[[:space:]]*/ { sub(/^scope:[[:space:]]*/, ""); gsub(/[[:space:]]/, ""); print; exit }
  ' "$1"
}

echo "reach-lint -- $(date '+%Y-%m-%d %H:%M')"
echo "(offline-first: no claude calls, writes nothing. Mechanizes"
echo " BUILD-DISCIPLINE.md pattern 13b on the reach axis -- see the header"
echo " of this script for the failure it was written after.)"

# --- collect command files --------------------------------------------------
# Read through lib/conf.sh: the raw `grep -oP` this replaces returned the
# LITERAL `$HOME/Documents/Projects/<name>`, so `[ -d "$repo" ]` was false for
# every project on every host and this loop collected NOTHING -- after which
# check A printed "(no project command files found)" and the script exited 0.
# A lint that scanned zero files and reported clean. Same defect as #73's
# named scripts; this one the issue never named, found by sweeping for the
# shape instead of working from the list.
cmd_files=()
confs=0    # confs that carry a PROJECT_REPO_PATH at all
repos=0    # ...of those, how many name a directory that exists
for conf in "$SCHED_ROOT"/schedule/*.conf; do
  [ -f "$conf" ] || continue
  name="$(basename "$conf" .conf)"
  case "$name" in _*) continue ;; esac
  repo="$(conf_repo_path "$conf")" || continue
  confs=$((confs + 1))
  [ -d "$repo" ] || continue
  repos=$((repos + 1))
  for d in "$repo/.claude/commands" "$repo/.scheduler/commands"; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do [ -n "$f" ] && cmd_files+=("$f"); done \
      < <(find "$d" -maxdepth 1 -name '*.md' | sort)
  done
done

# BLIND, and exit 3 rather than 0 -- but ONLY on `confs>0 && repos==0`, which
# is the #73 shape exactly: every conf readable, every path a literal, every
# match impossible. Two neighbouring states are deliberately NOT blind:
#   confs==0  no scheduler registry on this host at all. install-shims.sh runs
#             this on such hosts (and CI is one), where check B still means
#             something because it reads ~/.claude/commands, not the registry.
#             Calling that blind broke install-shims.test.sh D5 -- caught in CI
#             by the first version of this guard, which tested `repos==0` alone.
#   repos>0, no command files
#             a real, clean answer about a real set; check A below says so.
#
# 3 matches bin/hygiene-lint.sh and bin/silence-audit.sh. Deliberately not 1
# (which means "--strict and something FLAGged") and not 2 (lib/cli-guard.sh's
# usage error): "I could not look" is a third answer and needs a third code.
if [ "$confs" -gt 0 ] && [ "$repos" -eq 0 ]; then
  echo
  echo "  BLIND: $confs registered project(s) under $SCHED_ROOT/schedule/ carry a"
  echo "  PROJECT_REPO_PATH and NOT ONE resolves to a directory that exists, so"
  echo "  there was nothing to scan. This is 'I could not look', NOT 'nothing"
  echo "  to report'."
  exit 3
fi

echo
echo "== A. SCOPE DECLARATION =="
echo "(every command file states scope: project | user -- the question that"
echo " went unasked. This check does not judge WHICH answer is correct.)"
if [ "${#cmd_files[@]}" -eq 0 ]; then
  echo "  (no project command files found)"
else
  a_clean=1
  for f in "${cmd_files[@]}"; do
    s="$(scope_of "$f")"
    case "$s" in
      project|user) ;;
      "") flag scope-undeclared "${f/#$HOME/\~} has no \`scope:\` in frontmatter"; a_clean=0 ;;
      *)  flag scope-invalid "${f/#$HOME/\~} has scope: '$s' (want project|user)"; a_clean=0 ;;
    esac
  done
  [ "$a_clean" = 1 ] && echo "  clean -- all ${#cmd_files[@]} command file(s) declare a scope"
fi

echo
echo "== B. REACH =="
echo "(every command named by a scope:user file resolves from cwd / -- a"
echo " user-level command runs in repos with no realisateur checkout.)"

# scope:user sources, plus whatever is actually installed at user level.
reach_files=()
for f in "${cmd_files[@]:-}"; do
  [ -n "${f:-}" ] || continue
  [ "$(scope_of "$f")" = "user" ] && reach_files+=("$f")
done
if [ -d "$USER_CMD_DIR" ]; then
  while IFS= read -r f; do [ -n "$f" ] && reach_files+=("$f"); done \
    < <(find "$USER_CMD_DIR" -maxdepth 1 -name '*.md' | sort)
fi

if [ "${#reach_files[@]}" -eq 0 ]; then
  echo "  (no scope:user command files and nothing installed at user level)"
else
  b_clean=1
  for f in "${reach_files[@]}"; do
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      resolves_anywhere "$tok" && continue
      flag unreachable "${f/#$HOME/\~} names \`$tok\` but it does not resolve from cwd /"
      b_clean=0
    done < <(named_commands "$f")
  done
  [ "$b_clean" = 1 ] && echo "  clean -- every command named by ${#reach_files[@]} user-level file(s) resolves"
fi

echo
echo "== $flags FLAG(s) =="
if [ "$flags" -gt 0 ]; then
  echo "scope-undeclared -> add 'scope: project' or 'scope: user' to frontmatter."
  echo "unreachable      -> shim it: realisateur bin/install-shims.sh"
fi
case "$STRICT" in
  all)   [ "$flags" -gt 0 ] && exit 1 ;;
  reach) [ "$reach_flags" -gt 0 ] && exit 1 ;;
esac
exit 0
