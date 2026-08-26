#!/usr/bin/env bash
# senechal: is mandark done being a self-dev host? Non-AI, cron-safe,
# READ-ONLY.
#
#   ./no-self-dev.sh          # full report
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

VERBOSE=0
for a in "$@"; do
  case "$a" in
    -q|--quiet) QUIET=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  esac
done

# The host this inventory describes. An inventory written for mandark
# probed on another machine answers confidently and wrongly -- the same
# trap dead-config.sh guards against -- so a mismatch is INCOMPLETE, not
# a pass.
THIS_HOST="${SENECHAL_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
TARGET_HOST="$(cfg self_dev.host mandark)"

# Roots are overridable so the test harness can point the whole check at
# a fixture tree without touching the real machine.
SD_HOME="${SENECHAL_SELFDEV_HOME:-$HOME}"
SD_SETTINGS="${SENECHAL_CLAUDE_SETTINGS:-$SD_HOME/.claude/settings.json}"
# `crontab -l` on a fixture run would read Zach's real crontab, so the
# harness substitutes a file instead.
SD_CRONTAB_FILE="${SENECHAL_CRONTAB_FILE:-}"

# --- probes -------------------------------------------------------------
# Every probe echoes exactly one word:
#   present   -- it is there
#   absent    -- it is not there
#   unknown   -- could not tell (never a pass; see the exit contract)
# plus, on the same line after a space, a human-readable detail. Nothing
# below runs a command that mutates state.

# Expand a leading ~ against SD_HOME. Deliberately NOT `eval`: targets
# come from a config file, and one containing a backtick or $( would
# execute during a read-only check -- the exact "backticks inside double
# quotes execute" footgun BUILD-DISCIPLINE calls out for commit messages.
_expand() {
  case "$1" in
    "~/"*) printf '%s/%s\n' "$SD_HOME" "${1#\~/}" ;;
    *)     printf '%s\n' "$1" ;;
  esac
}

# One path: file, directory or symlink. -e follows symlinks and so
# reports a dangling one as absent, which would be wrong here -- a
# symlink pointing into an archived repo is very much still present and
# is the specific hazard scheduler-path-entries is about. Hence -e OR -L.
probe_path() {
  local p; p="$(_expand "$1")"
  if [ -e "$p" ] || [ -L "$p" ]; then
    if [ -L "$p" ]; then
      printf 'present symlink -> %s\n' "$(readlink "$p")"
    elif [ -d "$p" ]; then
      printf 'present directory\n'
    else
      printf 'present file\n'
    fi
  else
    printf 'absent %s\n' "$p"
  fi
}

# Expand ONE level of brace alternation: a/{x,y}.z -> a/x.z a/y.z.
# Written out by hand rather than leaning on bash's own brace expansion,
# because brace expansion happens BEFORE parameter expansion -- so a
# `{a,b}` that arrives inside a variable is never expanded by bash at
#   [rest: vault:senechal/header-archaeology-20260818.md]
_brace_expand() {
  local s="$1" pre body post alt
  case "$s" in
    *'{'*'}'*) ;;
    *) printf '%s\n' "$s"; return ;;
  esac
  pre="${s%%\{*}"
  body="${s#*\{}"; body="${body%%\}*}"
  post="${s#*\}}"
  local IFS=','
  for alt in $body; do
    printf '%s%s%s\n' "$pre" "$alt" "$post"
  done
}

# A whitespace-separated list of globs, each of which may use one level
# of brace alternation. Absent means EVERY glob matched zero paths.
# The spec is vetted first: anything that could reach the shell's parser
# as code is refused as `unknown` rather than expanded. This is the one
# place config text becomes a glob, and `unknown` is not a pass, so a
# refused pattern shows up as INCOMPLETE instead of a silent all-clear.
probe_glob() {
  local spec="$1" pat expanded hits=0 shown="" p
  case "$spec" in
    *[\`\$\;\&\|\<\>\(\)]*)
      printf 'unknown target contains shell metacharacters, refusing to expand\n'
      return ;;
  esac
  # Split the spec into patterns with `read -ra`, NOT `for pat in $spec`.
  # Unquoted word splitting also performs pathname expansion, so with
  # nullglob set every pattern that happens not to match relative to the
  # CWD is silently DELETED from the list before the loop body sees it --
  #   [rest: vault:senechal/header-archaeology-20260818.md]
  local -a pats=()
  read -ra pats <<<"$spec"
  local old_nullglob; old_nullglob="$(shopt -p nullglob)"
  shopt -s nullglob
  for pat in "${pats[@]}"; do
    while IFS= read -r expanded; do
      # Unquoted so bash globs it. Word-splitting means a glob target
      # containing a space cannot be matched this way; none do, and the
      # `path` kind handles single paths that need quoting.
      expanded="$(_expand "$expanded")"
      # shellcheck disable=SC2206  # deliberate pathname expansion
      for p in $expanded; do
        [ -e "$p" ] || [ -L "$p" ] || continue
        hits=$((hits + 1))
        [ "$hits" -le 4 ] && shown+="${shown:+, }$(basename "$p")"
      done
    done < <(_brace_expand "$pat")
  done
  eval "$old_nullglob"
  if [ "$hits" -gt 0 ]; then
    if [ "$hits" -gt 4 ]; then
      printf 'present %d match(es): %s, +%d more\n' "$hits" "$shown" $((hits - 4))
    else
      printf 'present %d match(es): %s\n' "$hits" "$shown"
    fi
  else
    printf 'absent no matches for: %s\n' "$spec"
  fi
}

# Uncommented crontab lines matching an ERE. A commented-out line is
# absent on purpose: realisateur left the mandark crontab as a block of
# comments explaining the removal, and that documentation must not read
# as a live dispatcher.
probe_crontab_active() {
  local ere="$1" out rc
  if [ -n "$SD_CRONTAB_FILE" ]; then
    [ -f "$SD_CRONTAB_FILE" ] || { printf 'unknown crontab fixture missing: %s\n' "$SD_CRONTAB_FILE"; return; }
    out="$(cat "$SD_CRONTAB_FILE")"
  else
    command -v crontab >/dev/null 2>&1 || { printf 'unknown no crontab command on this host\n'; return; }
    out="$(crontab -l 2>/dev/null)"; rc=$?
    # rc 1 with empty output is "no crontab for user" -- a real absent.
    if [ $rc -ne 0 ] && [ -n "$out" ]; then
      printf 'unknown crontab -l failed\n'; return
    fi
  fi
  local matched
  matched="$(printf '%s\n' "$out" | grep -vE '^[[:space:]]*(#|$)' | grep -cE "$ere")" || matched=0
  if [ "${matched:-0}" -gt 0 ]; then
    printf 'present %s active line(s) match %s\n' "$matched" "$ere"
  else
    printf 'absent no active crontab line matches %s\n' "$ere"
  fi
}

# A systemd unit FILE, not a running unit. An installed-but-stopped unit
# is still footprint: it survives a reboot, it can be started by anything
# that knows its name, and `is-active` reporting inactive is precisely
# how crt's two dead services sat unnoticed for days (ESTATE.md).
probe_systemd_user_unit() {
  local unit="$1" f
  for f in "$SD_HOME/.config/systemd/user/$unit" \
           "/usr/lib/systemd/user/$unit" "/etc/systemd/user/$unit"; do
    [ -e "$f" ] && { printf 'present unit file %s\n' "$f"; return; }
  done
  printf 'absent no unit file for %s\n' "$unit"
}

probe_systemd_system_unit() {
  local unit="$1"
  [ -e "/etc/systemd/system/$unit" ] \
    && { printf 'present /etc/systemd/system/%s\n' "$unit"; return; }
  [ -e "/usr/lib/systemd/system/$unit" ] \
    && { printf 'present /usr/lib/systemd/system/%s\n' "$unit"; return; }
  printf 'absent no unit file for %s\n' "$unit"
}

# A substring in ~/.claude/settings.json. Substring rather than a JSON
# path because a hook can be attached under several event names and the
# thing that matters is whether that command string is still wired
# anywhere at all.
probe_claude_hook() {
  local needle="$1"
  [ -f "$SD_SETTINGS" ] || { printf 'unknown settings file missing: %s\n' "$SD_SETTINGS"; return; }
  if grep -qF -- "$needle" "$SD_SETTINGS"; then
    printf 'present %s is wired in %s\n' "$needle" "$SD_SETTINGS"
  else
    printf 'absent %s not referenced in %s\n' "$needle" "$SD_SETTINGS"
  fi
}

probe() {
  case "$1" in
    path)                 probe_path "$2" ;;
    glob)                 probe_glob "$2" ;;
    crontab-active)       probe_crontab_active "$2" ;;
    systemd-user-unit)    probe_systemd_user_unit "$2" ;;
    systemd-system-unit)  probe_systemd_system_unit "$2" ;;
    claude-hook)          probe_claude_hook "$2" ;;
    # The reason a deferred item is deferred is item-specific and lives in
    # its `retire` field, printed as the `next:` line below. This used to
    # hardcode "not decidable until the destination host is named" -- true
    # for both deferred items until Zach named monkey on 2026-08-06, and
    # then quietly false while still being printed. A SKIP that states a
    # stale reason is worse than one that states none: it reads as a
    # live judgement nobody has revisited.
    deferred-note)        printf 'unknown deferred -- no verdict yet, see next:\n' ;;
    # An unrecognised kind must never read as a pass: a typo in the
    # config would otherwise silently drop an item from the definition.
    *)                    printf 'unknown unrecognised kind: %s\n' "$1" ;;
  esac
}

# --- report -------------------------------------------------------------
head_ "self-dev teardown -- $TARGET_HOST"

if [ "$THIS_HOST" != "$TARGET_HOST" ]; then
  skip "inventory is for $TARGET_HOST, running on $THIS_HOST"
  note "Nothing was probed. Run this on $TARGET_HOST, or set"
  note "SENECHAL_SELFDEV_HOME/SENECHAL_HOSTNAME to point it at a fixture."
  finish_verify
fi

items=0 gone=0 remaining=0 kept=0 lost=0 deferred=0
last_section=""

while IFS=$'\x1f' read -r id kind target owner phase verdict why retire; do
  [ -n "${id:-}" ] || continue
  items=$((items + 1))

  section="$verdict"
  if [ "$section" != "$last_section" ]; then
    case "$section" in
      must-be-absent) head_ "MUST BE GONE" ;;
      must-remain)    head_ "MUST SURVIVE (a teardown that removes these overshot)" ;;
      deferred)       head_ "NOT YET DECIDABLE" ;;
      *)              head_ "UNKNOWN VERDICT: $section" ;;
    esac
    last_section="$section"
  fi

  read -r state detail <<<"$(probe "$kind" "$target")"

  case "$verdict:$state" in
    must-be-absent:absent)
      gone=$((gone + 1)); ok "[p$phase] $id -- gone" ;;
    must-be-absent:present)
      remaining=$((remaining + 1))
      fail "[p$phase] $id -- STILL HERE ($detail)"
      note "owner: $owner"
      note "retire: $retire" ;;
    must-remain:present)
      kept=$((kept + 1)); ok "$id -- still here, as it must be" ;;
    must-remain:absent)
      lost=$((lost + 1))
      fail "$id -- GONE, and it was supposed to stay ($detail)"
      note "owner: $owner -- ask $owner to reinstall; senechal does not"
      note "why it must remain: $why" ;;
    deferred:*)
      deferred=$((deferred + 1))
      skip "[p$phase] $id -- $detail"
      note "owner: $owner"
      note "next: $retire" ;;
    *)
      # state=unknown on a real verdict: could not look. Never a pass.
      skip "[p$phase] $id -- $detail" ;;
  esac

  [ "$VERBOSE" -eq 1 ] && note "why: $why"
done < <(cfg_self_dev)

if [ "$items" -eq 0 ]; then
  head_ "inventory"
  fail "self_dev.items is empty or unreadable in $SENECHAL_CONFIG"
  note "An empty inventory would otherwise report a clean pass -- which is"
  note "the exact no-op-exits-0 failure this contract exists to prevent."
fi

head_ "tally"
note "$items item(s): $gone gone, $remaining still installed, \
$kept kept, $lost wrongly removed, $deferred undecided"

finish_verify "SELF-DEV IS OFF $TARGET_HOST -- every straggler gone, every keeper intact."
