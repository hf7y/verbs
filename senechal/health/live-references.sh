#!/usr/bin/env bash
# senechal: live-references check over ONE path. Non-AI, cron-safe,
# READ-ONLY (never mutates anything, on any host).
#
#   ./live-references.sh /path/to/directory
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

DIR=""
for a in "$@"; do
  case "$a" in
    -q|--quiet) QUIET=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    -*) die "unknown flag: $a" ;;
    *)  [ -z "$DIR" ] && DIR="$a" || die "unexpected extra argument: $a" ;;
  esac
done

if [ -z "$DIR" ]; then
  sed -n '2,14p' "$0"
  exit 2
fi

if [ ! -d "$DIR" ]; then
  head_ "live-references: $DIR"
  skip "target does not exist or is not a directory: $DIR"
  finish_verify
fi

# Canonicalise once. Every probe compares against THIS, not the raw
# argument, so a symlinked checkout or a trailing slash cannot make a
# real reference silently fail to match.
RESOLVED_DIR="$(cd "$DIR" && pwd -P)"

# --- probe 1: systemd, both scopes ---------------------------------------
_systemd_service_units() { # <scope> -> unit names, one per line
  local scope="$1" sctl=(systemctl)
  [ "$scope" = user ] && sctl=(systemctl --user)
  "${sctl[@]}" list-unit-files --no-legend --type=service 2>/dev/null | awk '{print $1}'
}

# One unit's exec-family properties plus enough context to explain the
# hit to a human: which timer triggers it, and where its unit file lives.
# Properties with no value are OMITTED by `systemctl show` (not printed
# as `Key=`), so a plain grep for our path is safe against false splits.
_systemd_unit_block() { # <scope> <unit>
  local scope="$1" unit="$2" sctl=(systemctl)
  [ "$scope" = user ] && sctl=(systemctl --user)
  "${sctl[@]}" show "$unit" \
    -p ExecStart -p ExecStartPre -p ExecStartPost \
    -p ExecStop -p ExecStopPost -p ExecReload \
    -p TriggeredBy -p FragmentPath 2>/dev/null
}

probe_systemd_scope() { # <scope> <label>
  local scope="$1" label="$2" sctl=(systemctl) units unit found=0
  [ "$scope" = user ] && sctl=(systemctl --user)

  command -v systemctl >/dev/null 2>&1 || {
    skip "systemd ($label scope): systemctl not available"
    return
  }
  "${sctl[@]}" list-unit-files >/dev/null 2>&1 || {
    skip "systemd ($label scope): systemctl${scope:+ --user} is not reachable here (no systemd? no session?)"
    return
  }

  units="$(_systemd_service_units "$scope")"
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    local block execline trig
    block="$(_systemd_unit_block "$scope" "$unit")"
    [ -n "$block" ] || continue
    execline="$(printf '%s\n' "$block" | grep -E '^Exec[A-Za-z]*=' | grep -F -- "$RESOLVED_DIR/" | head -1)"
    [ -n "$execline" ] || continue
    found=1
    trig="$(printf '%s\n' "$block" | grep '^TriggeredBy=' | cut -d= -f2-)"
    fail "systemd $label unit $unit -- $execline$([ -n "$trig" ] && printf ' (triggered by: %s)' "$trig")"
  done <<< "$units"

  [ "$found" -eq 1 ] || ok "no $label-scope systemd service unit execs a path under $RESOLVED_DIR"
}

# --- probe 2: crontab, this account and (best-effort) others ------------
CRON_SPOOL_DIRS="${SENECHAL_CRON_SPOOL_DIRS:-/var/spool/cron/crontabs /var/spool/cron}"

probe_crontab() {
  local out rc hits line

  out="$(crontab -l 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    if printf '%s' "$out" | grep -qi 'no crontab for'; then
      ok "no crontab installed for $(id -un)"
    else
      skip "crontab ($(id -un)): could not read -- $out"
    fi
  else
    hits="$(printf '%s\n' "$out" | grep -vE '^[[:space:]]*(#|$)' | grep -F -- "$RESOLVED_DIR/" || true)"
    if [ -n "$hits" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        fail "crontab ($(id -un)) -- $line"
      done <<< "$hits"
    else
      ok "no active line in $(id -un)'s crontab references $RESOLVED_DIR"
    fi
  fi

  # Other accounts. Best-effort and SAYS SO when it cannot see: a spool
  # directory this account cannot list must not read as "no other
  # crontabs exist" -- that would be exactly the silent-default failure
  # senechal_blind exists to prevent for senechal.json, applied here to
  # crontabs instead.
  local d f user
  for d in $CRON_SPOOL_DIRS; do
    [ -d "$d" ] || continue
    if [ ! -r "$d" ] || [ ! -x "$d" ]; then
      skip "crontab (other accounts): cannot list $d (permission denied) -- other accounts' crontabs are invisible from here"
      continue
    fi
    for f in "$d"/*; do
      [ -e "$f" ] || continue
      [ -f "$f" ] || continue
      user="$(basename "$f")"
      [ "$user" = "$(id -un)" ] && continue
      if [ ! -r "$f" ]; then
        skip "crontab ($user): $f exists but is not readable from here"
        continue
      fi
      hits="$(grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | grep -F -- "$RESOLVED_DIR/" || true)"
      [ -n "$hits" ] || continue
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        fail "crontab ($user) -- $line"
      done <<< "$hits"
    done
  done
}

# --- probe 3: installe-managed verb delegations --------------------------
probe_installe() {
  command -v installe >/dev/null 2>&1 || {
    skip "installe: not on PATH -- cannot check verb delegations"
    return
  }

  local json rc hits name target resolved
  json="$(installe list --json 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$json" ]; then
    skip "installe list --json failed (rc=$rc) -- cannot check verb delegations"
    return
  fi

  # Resolve through any symlink chain (a verb build's `current` pointer
  # included) so a shim pointing INTO this directory is caught even when
  # the manifest's raw target string is one hop away from it.
  hits="$(printf '%s' "$json" | python3 -c '
import json, sys, os
dirpath = sys.argv[1]
try:
    entries = json.load(sys.stdin)
except Exception:
    sys.exit(9)
for e in entries:
    name = e.get("name", "")
    target = e.get("target", "")
    if not name or not target:
        continue
    resolved = os.path.realpath(target)
    if resolved == dirpath or resolved.startswith(dirpath + "/"):
        print("\x1f".join((name, target, resolved)))
' "$RESOLVED_DIR" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    skip "installe list --json: output did not parse -- cannot check verb delegations"
    return
  fi

  if [ -z "$hits" ]; then
    ok "no installed verb delegates into $RESOLVED_DIR"
    return
  fi
  while IFS=$'\x1f' read -r name target resolved; do
    [ -n "$name" ] || continue
    fail "installed verb '$name' -> $target (resolves to $resolved)"
  done <<< "$hits"
}

# --- main -----------------------------------------------------------------
_emit "senechal live-references -- $(date '+%Y-%m-%d %H:%M') -- $RESOLVED_DIR"

head_ "systemd (user scope)"
probe_systemd_scope user user

head_ "systemd (system scope)"
probe_systemd_scope system system

head_ "crontab"
probe_crontab

head_ "installed-verb delegations (installe)"
probe_installe

head_ "Verdict"
if [ "$_fail_count" -eq 0 ] && [ "$_incomplete_count" -eq 0 ]; then
  note "REMOVABLE -- $RESOLVED_DIR has no live references found by any probe run here."
elif [ "$_fail_count" -gt 0 ]; then
  note "NOT-REMOVABLE -- $_fail_count live reference(s) into $RESOLVED_DIR found above. fauche must not certify this directory REMOVABLE."
else
  note "UNKNOWN -- $_incomplete_count probe(s) could not check $RESOLVED_DIR and none found a confirmed reference. Not proven removable from this alone -- do not certify REMOVABLE."
fi

finish_verify "REMOVABLE -- $RESOLVED_DIR has no live references found by any probe run here."
