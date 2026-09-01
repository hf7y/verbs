#!/usr/bin/env bash
# vault-spool-drain.sh -- the privileged half of THE SPOOL in man/consigne.1,
# which is the contract this implements (#742).
#
# TRAP: consign-prose runs `git -C <source dir>` on a repo root does not own, so
# git refuses it and consign-prose reads that as "not a git repository" -- an
# exit 6 naming the wrong cause. Hence safe.directory, per process, below.
set -uo pipefail

CLI_NAME='vault-spool-drain.sh'
CLI_SUMMARY='deposit every spooled request into the vault and commit it -- the privileged half of `consigne` on a host where the vault is closed to the accounts that deposit into it (#742)'
CLI_USAGE='  vault-spool-drain.sh             --check (default): report the queue, write nothing
  vault-spool-drain.sh --apply     deposit every request, commit, and clear the queue'
CLI_FLAGS='--check --apply --spool --vault'
CLI_POSITIONAL=any   # --spool/--vault take a value; cli_guard sees it as positional
CLI_EXITS='  0  nothing queued, or every queued request was deposited
  1  at least one request could not be deposited -- it is kept as .failed
  5  refused: --apply without a readable vault, or without write access to it
  6  BLIND: no spool directory, so the queue could not be measured at all --
     a 0-request pass on a missing spool is NOT a clean result'
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/cli-guard.sh"
cli_guard "$@"

MODE=--check
SPOOL="${CONSIGNE_SPOOL:-/srv/vault-spool}"
VAULT="${BIBLIOTHECAIRE_VAULT:-/srv/ecosystem1-vault}"
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--apply) MODE="$1" ;;
    --spool) shift; SPOOL="${1:-}" ;;
    --vault) shift; VAULT="${1:-}" ;;
    *) cli_die "unexpected argument: $1" ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit "${2:-5}"; }

[ -d "$SPOOL" ] || {
  printf '%s: BLIND: no spool at %s -- the queue was not measured, which is NOT the same as empty.\n' \
    "$CLI_NAME" "$SPOOL" >&2
  printf '%s: provision it with `sudo vault-group-provision.sh --apply`.\n' "$CLI_NAME" >&2
  exit 6
}

mapfile -t REQS < <(find "$SPOOL" -maxdepth 1 -type f -name 'req-*' 2>/dev/null | sort)

say "== vault-spool-drain ($MODE) -- $(hostname -s), spool $SPOOL, vault $VAULT =="
say "   ${#REQS[@]} request(s) queued"

if [ "${#REQS[@]}" -eq 0 ]; then
  say "$CLI_NAME: nothing queued."
  exit 0
fi

for r in "${REQS[@]}"; do
  acct="$(sed -n 's/^account\t//p' "$r" | head -1)"
  n="$(grep -c '^path\t' "$r" 2>/dev/null)" || n=0
  say "   .. $(basename "$r")  account=${acct:-?}  paths=$n"
done

if [ "$MODE" = --check ]; then
  say
  say "Next: sudo $CLI_NAME --apply"
  exit 1
fi

# --apply from here. The vault must be readable AND writable by THIS process;
# a drainer that cannot commit turns the spool into a silent backlog.
[ -r "$VAULT" ] && [ -x "$VAULT" ] || die "cannot read $VAULT -- run --apply as the account that owns the vault (root, or its owner)" 5
[ -w "$VAULT" ] || die "cannot write $VAULT -- nothing would be deposited" 5

IMPL="${CONSIGNE_IMPL:-}"
if [ -z "$IMPL" ]; then
  fonde_bin="$(command -v fonde 2>/dev/null)" || fonde_bin=''
  [ -n "$fonde_bin" ] && IMPL="$(cd "$(dirname "$(readlink -f "$fonde_bin")")/.." && pwd)/lib/consign-prose.sh"
fi
[ -n "$IMPL" ] && [ -r "$IMPL" ] \
  || die "cannot find lib/consign-prose.sh (looked through the installed \`fonde\`; set CONSIGNE_IMPL). Nothing was deposited." 5

export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'

OK=0; FAILED=0
for r in "${REQS[@]}"; do
  acct="$(sed -n 's/^account\t//p' "$r" | head -1)"
  mapfile -t paths < <(sed -n 's/^path\t//p' "$r")
  if [ "${#paths[@]}" -eq 0 ]; then
    mv -- "$r" "$r.failed" && printf 'no path rows\n' > "$r.failed.why"
    say "  BAD     $(basename "$r") -- no path rows; kept as $(basename "$r").failed"
    FAILED=$((FAILED+1)); continue
  fi

  say "  ..      $(basename "$r") ($acct): ${#paths[@]} path(s)"
  if flock -w 60 "$VAULT/.consigne.lock" bash "$IMPL" "$VAULT" "${paths[@]}"; then
    rm -f -- "$r"
    OK=$((OK+1))
  else
    rc=$?
    mv -- "$r" "$r.failed" && printf 'consign-prose exit %s\n' "$rc" > "$r.failed.why"
    say "  BAD     $(basename "$r") -- consign-prose exited $rc; kept as $(basename "$r").failed"
    FAILED=$((FAILED+1))
  fi
done

if [ "$OK" -gt 0 ]; then
  if [ -n "$(git -C "$VAULT" status --porcelain 2>/dev/null)" ]; then
    git -C "$VAULT" add -A \
      && git -C "$VAULT" \
           -c user.name='vault-spool-drain' \
           -c user.email='vault-spool-drain@localhost' \
           commit -q -m "consigne: drain $OK spooled request(s) ($(hostname -s))" \
      && say "  OK      committed $OK drained request(s)" \
      || { say "  BAD     the deposits landed but could not be committed -- they are UNCOMMITTED in $VAULT"; FAILED=$((FAILED+1)); }
  fi
fi

up="$(git -C "$VAULT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
if [ -n "$up" ]; then
  ahead="$(git -C "$VAULT" rev-list --count "$up..HEAD" 2>/dev/null)"
  case "$ahead" in ''|*[!0-9]*) ahead=0 ;; esac
  [ "$ahead" -gt 0 ] && say "  NOT PUSHED -- $VAULT is $ahead commit(s) ahead of $up; this does not push (PROSE-REAPING.md 5.6)"
fi

say
printf '%s (--apply): %d deposited, %d failed\n' "$CLI_NAME" "$OK" "$FAILED"
[ "$FAILED" -eq 0 ] && exit 0
exit 1
