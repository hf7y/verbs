#!/usr/bin/env bash
# conf.sh -- read a scheduler conf's PROJECT_REPO_PATH, EXPANDED.
#
# WHY THIS EXISTS
# ---------------
# Every registered project's conf writes its checkout as
#
#     PROJECT_REPO_PATH="$HOME/Documents/Projects/<name>"
#
# and five scripts in this repo read it with the same one-liner:
#
#     grep -oP '(?<=PROJECT_REPO_PATH=")[^"]*'
#
# which returns the LITERAL eleven characters `$HOME/Documents/...`. grep does
# not expand shell variables, and nothing downstream expanded them either. So
# `[ -d "$repo/.git" ]` was false for every project on every host, forever.
#
# WHAT THAT COST, measured 2026-08-06 rather than reasoned about:
#
#     $ bin/restamp-discipline.sh
#     baudin          SKIP -- no git repo at $HOME/Documents/Projects/baudin
#     ... 13 of these ...
#     == 0 in sync / 0 drifted / 13 skipped / 0 failed ==
#     $ echo $?
#     0
#
# restamp-discipline.sh is THE propagation mechanism -- the answer to Zach's
# 2026-07-26 question "how can all projects know about things like the senechal
# cross-write?" -- and it had been propagating the baseline to ZERO projects
# while exiting 0 and printing a tidy summary. Its own header says "Detection
# is not propagation" and "No exit-0 no-op"; it was committing both.
#
# The skip line is the tell and it was printed thirteen times a night: a path
# with a literal `$HOME` in it is not a path anyone typed.
#
# USAGE
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/conf.sh"
#   repo="$(conf_repo_path "$conf")" || continue
#
# THE FOUR THIS HEADER USED TO NAME AS STILL BROKEN are settled (#73), two of
# them by DELETION: milestone-audit.sh and install-silence-audit.sh were
# RETIRED in b3fef3d, closeout-lint.sh was fixed in place, session-marker.sh
# converted here. The sweep found three MORE the list never named --
# reach-lint.sh, stamp-agent.sh, make-bootstrap-branch.sh -- which is the
# argument for a ratchet over a list, so bin/tests/conf.test.sh section C now
# scans the tree for the shape and no prose here has to be kept accurate.

# conf_repo_path <conf-file> -- the checkout path, with $HOME expanded.
# Returns 1 and prints nothing when the conf carries no PROJECT_REPO_PATH, so a
# caller's `|| continue` reads the way it looks.
#
# Expansion is deliberately LIMITED to $HOME and ${HOME}. `eval` would expand
# anything, and a conf is a file this repo does not own on a host it may not
# own either; command substitution inside one must not become code this script
# runs. If a conf ever needs a second variable, add it here by name.
#
# QUOTING: double, single, or none. The first version required a double quote
# -- `(?<=PROJECT_REPO_PATH=")` -- which is true of every conf in scheduler's
# registry today and therefore looked complete. It was the reason
# hf7y/realisateur#143 could not be closed: bashify's six readers could not be
# routed through this function while it would silently return 1 for an
# unquoted value, and "returned nothing" is indistinguishable here from "the
# conf has no such field". A shared reader that cannot represent a legal input
# is not shared -- it is a sixth private reader with better manners.
conf_repo_path() {
  local conf="$1" p
  # The value is everything after the first `=`, minus a trailing comment and
  # surrounding whitespace, minus one matched pair of quotes. Deliberately NOT
  # three lookbehinds for three quote styles: one regex per shape is how the
  # readers multiplied in the first place.
  p="$(grep -E '^[[:space:]]*PROJECT_REPO_PATH=' "$conf" 2>/dev/null | head -1)"
  [ -n "$p" ] || return 1
  p="${p#*=}"
  p="${p%%[[:space:]]#*}"
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  case "$p" in
    '"'*'"') p="${p#\"}"; p="${p%\"}" ;;
    "'"*"'") p="${p#\'}"; p="${p%\'}" ;;
  esac
  [ -n "$p" ] || return 1
  p="${p//\$\{HOME\}/$HOME}"
  p="${p//\$HOME/$HOME}"
  printf '%s\n' "$p"
}
