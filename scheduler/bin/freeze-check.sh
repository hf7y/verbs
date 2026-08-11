#!/usr/bin/env bash
# freeze-check.sh -- the migration abort handle. ONE definition of "is dispatch
# frozen right now", called by every consumer at DISPATCH time.
#
# Built 2026-07-29, Zach-directed ("initiate the freeze"), as M1(a) of THE PLAY
# (scheduler .scheduler/FOCUS.md; rationale realisateur dd11360 / bde9e62).
# M1(b), the readiness probe, was retired before being built. This is the ONLY
# surviving pre-move mechanism, which is why it is wired rather than documented.
#
# WHY A FILE AND NOT A COMMENTED-OUT CRONTAB: a freeze has to be (a) visible to
# both hosts, (b) revertable by one commit, (c) auditable after the fact. A
# hand-commented crontab is none of those and cannot be reviewed. Zach's call
# 2026-07-28: "a git-tracked file both hosts read and refuse loudly on".
#
# CONTRACT
#   exit 0  -- not frozen (or this project is EXEMPT); the caller may dispatch.
#   exit 1  -- FROZEN. The caller MUST NOT dispatch. Reason goes to stderr.
#   exit 2  -- the freeze file exists but could not be read/parsed. Treated as
#              FROZEN by every caller. An unreadable abort handle is engaged,
#              never disengaged -- failing open here would make the one
#              mechanism that stops a bad run the one that silently does not.
#
# TO ENGAGE:   create schedule/FREEZE with a reason, commit, push. Both hosts
#              pick it up on their next pull (<= 5 min).
#
# EXEMPTIONS:  a line `EXEMPT: <project> [<project>...]` in the freeze file
#              names projects the freeze does NOT stop. This exists because the
#              orchestrator cannot be frozen by the freeze it is running: Zach
#              2026-07-29, "freeze the jobs ... then trigger scheduler
#              manually". Without it, `freeze the jobs` and `run the play` are
#              mutually exclusive instructions.
#              An exemption is GIT-VISIBLE on purpose -- the alternative was an
#              env override, which would put the bypass in a shell history
#              instead of in the repo, where no audit of "why did this run
#              while frozen" could ever find it.
#              Callers pass their project as $1. A caller that passes NOTHING
#              is never exempt -- absence of a name is not a match.
#
#              HOST-SCOPED FORM: `EXEMPT: scheduler@dexter` exempts a project
#              on ONE host only. Added 2026-07-29 within an hour of the plain
#              form, because the plain form was actively dangerous here: a bare
#              `EXEMPT: scheduler` unfroze mandark's scheduler self-dev at the
#              same moment dexter was to be bootstrapped by hand -- and
#              scheduler-dev-cycle.sh "merges into local main AND PUSHES TO
#              ORIGIN IMMEDIATELY, same cycle". Two hosts pushing one scheduler
#              history is the divergence the whole migration ordering exists to
#              avoid, and the exemption had quietly re-created it.
#              Host is $PACED_HOST if set, else `hostname -s` -- the same
#              resolution usage-gate.sh uses, so one host means one thing.
#
# TO RELEASE:  git rm schedule/FREEZE, commit, push.
#
# WHAT THIS DOES NOT COVER -- stated here because M1(a) requires it to, and
# because an unstated gap in an abort handle is worse than a missing one:
#
#   1. svc-vaporwave's fixed-cron jobs (aedile 03:00, vkv-inventory 04:00).
#      Zach 2026-07-29 answered "freeze" to the scope question (7fccdc1 q2),
#      so they are DECLARED in scope. They are NOT mechanically enforced: that
#      crontab lives under a second account, requires sudo, and has never been
#      read by this project (BRIEF-dexter-migration.md sec 0 lists it BLIND).
#      A freeze therefore does NOT stop those two jobs. This is declared
#      coverage without enforcement and must be read as such.
#   2. Anything invoked by a human directly. This checks automated dispatch.
#   3. Work already in flight when the freeze lands. It stops the NEXT
#      dispatch; it does not kill a running job.
#
# Sourceable (`. freeze-check.sh` then `freeze_check`) or runnable standalone.

set -uo pipefail

# Runtime witness (lib/check-witness.sh + bin/check-witness-lint.sh). Sourced
# here, CALLED inside freeze_check() below -- deliberately, because this file
# is sourceable as well as runnable, and being sourced is not the same as
# having been consulted. The witness must mean "a caller asked whether
# dispatch is frozen", which is exactly the moment freeze_check() runs.
#
# Added 2026-07-29: without it, check-witness-lint reported freeze-check.sh
# "NEVER RUN" indefinitely, while ~/.local/share/scheduler-paced-runner/run.log
# showed it refusing realisateur by name at 11:30 the same day. A lint that
# permanently cries wolf about the one abort handle teaches its reader to
# skip its findings, which is worse than not having it.
# Guarded and never fatal, per that lib's own contract -- bookkeeping must
# not be able to break the mechanism that stops a bad run.
_FREEZE_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -n "${_FREEZE_SELF_DIR:-}" ] && [ -r "$_FREEZE_SELF_DIR/../lib/check-witness.sh" ]; then
  # shellcheck disable=SC1091
  source "$_FREEZE_SELF_DIR/../lib/check-witness.sh"
fi

_freeze_file() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  printf '%s\n' "${SCHEDULER_FREEZE_FILE:-$here/../schedule/FREEZE}"
}

freeze_check() {
  local f reason proj exempt
  # FIRST act, before every early return: a freeze check that came back
  # "not frozen" still ran, and that is what this witness is about.
  command -v check_witness >/dev/null 2>&1 && check_witness freeze-check.sh
  proj="${1:-}"
  f="$(_freeze_file)"

  [ -e "$f" ] || return 0          # the common case: no file, not frozen

  if [ ! -r "$f" ]; then
    printf 'FROZEN (unreadable) -- %s exists but cannot be read. Treating as
FROZEN: an abort handle that fails open is not an abort handle.\n' "$f" >&2
    return 2
  fi

  # EXEMPT lines are matched on whole words only, so "scheduler" never
  # accidentally exempts "scheduler-run" or a project whose name contains it.
  if [ -n "$proj" ]; then
    exempt="$(grep -E '^[[:space:]]*EXEMPT:' "$f" 2>/dev/null | sed -E 's/^[[:space:]]*EXEMPT:[[:space:]]*//')"
    local host
    host="${PACED_HOST:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)}"
    for e in $exempt; do
      # bare name = every host; name@host = that host only
      if [ "$e" = "$proj" ] || [ "$e" = "$proj@$host" ]; then
        printf 'FROZEN, but %s is EXEMPT in %s (host=%s, rule=%s) -- proceeding.\n' \
          "$proj" "$f" "$host" "$e" >&2
        return 0
      fi
    done
  fi

  reason="$(grep -vE '^[[:space:]]*(#|EXEMPT:|$)' "$f" 2>/dev/null | head -5)"
  [ -n "$reason" ] || reason='(no reason recorded in the freeze file)'

  printf 'FROZEN -- dispatch refused by %s\n%s\nRelease: git rm %s && commit && push (both hosts pick it up within 5 min).\nNOT covered by this freeze: svc-vaporwave fixed-cron (aedile 03:00, vkv-inventory 04:00) -- declared in scope, NOT enforced; and jobs already running.\n' \
    "$f" "$reason" "$f" >&2
  return 1
}

# --selftest: the negative-test bar every mechanism here is held to. A freeze
# that has never been observed to refuse has not been shown able to refuse.
if [ "${1:-}" = "--selftest" ]; then
  fails=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/schedule"

  SCHEDULER_FREEZE_FILE="$tmp/schedule/FREEZE"
  export SCHEDULER_FREEZE_FILE

  freeze_check >/dev/null 2>&1
  [ $? -eq 0 ] || { echo "FAIL: absent freeze file should exit 0"; fails=$((fails+1)); }

  printf '# comment only\n\nmigration wave 1 rollback\n' > "$SCHEDULER_FREEZE_FILE"
  out="$(freeze_check 2>&1)"; rc=$?
  [ $rc -eq 1 ] || { echo "FAIL: present freeze file should exit 1, got $rc"; fails=$((fails+1)); }
  case "$out" in *"migration wave 1 rollback"*) ;; *)
    echo "FAIL: reason not surfaced (comments/blanks must be stripped)"; fails=$((fails+1));; esac
  case "$out" in *"svc-vaporwave"*) ;; *)
    echo "FAIL: refusal must state what it does not cover"; fails=$((fails+1));; esac

  chmod 000 "$SCHEDULER_FREEZE_FILE" 2>/dev/null
  if [ ! -r "$SCHEDULER_FREEZE_FILE" ]; then
    freeze_check >/dev/null 2>&1
    [ $? -eq 2 ] || { echo "FAIL: unreadable freeze file must exit 2 (fail closed)"; fails=$((fails+1)); }
  fi
  chmod 644 "$SCHEDULER_FREEZE_FILE" 2>/dev/null

  printf '\n# nothing but comments\n' > "$SCHEDULER_FREEZE_FILE"
  out="$(freeze_check 2>&1)"; rc=$?
  [ $rc -eq 1 ] || { echo "FAIL: reasonless freeze still freezes, got $rc"; fails=$((fails+1)); }
  case "$out" in *"no reason recorded"*) ;; *)
    echo "FAIL: reasonless freeze must say so rather than printing an empty reason"; fails=$((fails+1));; esac

  # --- exemptions. The dangerous direction is a freeze that lets the wrong
  # project through, so every assertion here is "does it still refuse".
  printf 'wave 1 in progress\nEXEMPT: scheduler\n' > "$SCHEDULER_FREEZE_FILE"

  freeze_check scheduler >/dev/null 2>&1
  [ $? -eq 0 ] || { echo "FAIL: exempt project must be allowed through"; fails=$((fails+1)); }

  freeze_check ecosim >/dev/null 2>&1
  [ $? -eq 1 ] || { echo "FAIL: NON-exempt project must still be refused"; fails=$((fails+1)); }

  freeze_check >/dev/null 2>&1
  [ $? -eq 1 ] || { echo "FAIL: no project name must never be exempt"; fails=$((fails+1)); }

  freeze_check scheduler-run >/dev/null 2>&1
  [ $? -eq 1 ] || { echo "FAIL: 'scheduler' must not substring-match 'scheduler-run'"; fails=$((fails+1)); }

  out="$(freeze_check ecosim 2>&1)"
  case "$out" in *"EXEMPT:"*) echo "FAIL: EXEMPT line leaked into the reason text"; fails=$((fails+1));; esac

  printf 'wave 1\nEXEMPT: scheduler crt\n' > "$SCHEDULER_FREEZE_FILE"
  freeze_check crt >/dev/null 2>&1
  [ $? -eq 0 ] || { echo "FAIL: second name on an EXEMPT line must also be exempt"; fails=$((fails+1)); }
  freeze_check wtul >/dev/null 2>&1
  [ $? -eq 1 ] || { echo "FAIL: unlisted project must be refused when others are exempt"; fails=$((fails+1)); }

  # --- host-scoped exemptions. Every assertion checks that the OTHER host
  # stays frozen, because that is the direction that caused the incident.
  printf 'wave 1\nEXEMPT: scheduler@dexter\n' > "$SCHEDULER_FREEZE_FILE"

  PACED_HOST=dexter freeze_check scheduler >/dev/null 2>&1
  [ $? -eq 0 ] || { echo "FAIL: scheduler@dexter must be exempt ON dexter"; fails=$((fails+1)); }

  PACED_HOST=mandark freeze_check scheduler >/dev/null 2>&1
  [ $? -eq 1 ] || { echo "FAIL: scheduler@dexter must NOT exempt scheduler on mandark"; fails=$((fails+1)); }

  PACED_HOST=dexter freeze_check crt >/dev/null 2>&1
  [ $? -eq 1 ] || { echo "FAIL: host-scoped rule must not exempt a different project"; fails=$((fails+1)); }

  printf 'wave 1\nEXEMPT: scheduler\n' > "$SCHEDULER_FREEZE_FILE"
  PACED_HOST=mandark freeze_check scheduler >/dev/null 2>&1
  [ $? -eq 0 ] || { echo "FAIL: BARE name must still exempt on every host"; fails=$((fails+1)); }

  if [ "$fails" -eq 0 ]; then echo "ok -- 17 assertions, 0 failure(s)"; else
    echo "$fails failure(s)"; exit 1; fi
  exit 0
fi

# Standalone invocation.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  freeze_check "${1:-}"
  exit $?
fi
