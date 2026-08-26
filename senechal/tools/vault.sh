#!/usr/bin/env bash
# vault.sh -- run a vault-touching command against a checkout that cannot drift.
#
# GUARD: none. This is a front door, not a check.
# RUNNER: called by hand and by remedies; nothing schedules it.
# GUARD-TEST: tools/test-vault.sh
#
# WHY THIS EXISTS. `fauche`, `consigne` and `fonde consign` all default to
# /srv/ecosystem1-vault, which does not exist on mandark and needs root to
# create (hf7y/senechal#312). The three obvious fixes are each worse than the
# problem:
#
#   an API backend      -- the tools stat a filesystem; teaching all three to
#                          speak HTTP is realisateur's rewrite, not a fix
#   a permanent clone   -- a second copy of the estate's record, stale by
#                          default, silently answering "is this consigned?"
#                          from whenever it was last pulled
#   a symlink into /srv -- still root, and still that same permanent clone
#
# WHAT THIS DOES INSTEAD. The checkout exists only for the duration of one
# command. Clone shallow, run, push what changed, delete. There is no local
# vault between invocations, so there is nothing to go stale and nothing to
# forget to pull. Drift is not managed here; it is made impossible.
#
# The tools are unmodified and unaware. They still receive a filesystem path,
# because that is what they take.
#
# THE ONE BUG IT MUST NOT HAVE. A deposit that is written and not pushed is
# worse than a deposit that never happened: `consigne` prints "safe to remove
# from the source repository", the caller deletes the source, and the only
# copy dies with the temp directory. So the push is not best-effort. If the
# command wrote anything and the push does not land, this exits 1 and says so
# loudly, and the temp directory is KEPT and named so the work is recoverable.
set -uo pipefail

CLI_NAME='vault.sh'
CLI_SUMMARY='run a command against an ephemeral, always-fresh vault checkout'
CLI_USAGE='  vault.sh run <command> [arg...]   run <command> with $BIBLIOTHECAIRE_VAULT set
  vault.sh slug                     print the vault repository and exit'
CLI_FLAGS='  --repo <owner/name>  vault repository (default: vault.repo in senechal.json)'
CLI_EXITS='  0  the command succeeded and anything it wrote is pushed
  1  the command failed, or it wrote something that could not be pushed
  2  could not look -- no gh, not authenticated, or the clone failed'
CLI_POSITIONAL=any
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
# Guard the LEADING argument only. cli_guard scans every argument it is
# given, and everything after `run` belongs to the command being wrapped --
# `vault.sh run fauche list --vault X` must not have `--vault` read as ours.
cli_guard "${1:-}"

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# common.sh's die() always exits 1; this contract needs 2 for could-not-look.
quit() { local rc="$1"; shift; printf '%s: %s\n' "$CLI_NAME" "$*" >&2; exit "$rc"; }

REPO="$(cfg vault.repo 'hf7y/ecosystem1-vault')"
[ "${1:-}" = "--repo" ] && { REPO="$2"; shift 2; }
# A subcommand, not `--`: tools/lib/cli-guard.sh rejects a bare `--`
# outright, which is also why `consigne lock -- <cmd>` cannot be called on
# this host (filed to realisateur).
[ "${1:-}" = "slug" ] && { printf '%s\n' "$REPO"; exit 0; }
[ "${1:-}" = "run" ] && shift
[ $# -gt 0 ] || quit "$RC_INCOMPLETE" "nothing to run -- see --help"

command -v gh   >/dev/null 2>&1 || quit "$RC_INCOMPLETE" "gh is not on PATH"
command -v git  >/dev/null 2>&1 || quit "$RC_INCOMPLETE" "git is not on PATH"
case "$REPO" in */*/*|/*|.*|*:*) : ;; *) gh auth status >/dev/null 2>&1 \
  || quit "$RC_INCOMPLETE" "gh is not authenticated -- cannot reach $REPO" ;; esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-XXXXXX")" || quit "$RC_INCOMPLETE" "cannot make a temp directory"
KEEP=0
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$TMP"; }
trap cleanup EXIT

# --depth=1: the vault is an archive, not a history to browse. A shallow
# clone still pushes correctly because the push is a fast-forward from the
# tip we just fetched -- and if it is not, we lost a race and say so.
# An owner/name slug goes through gh, which carries the auth a private vault
# needs. Anything that looks like a path or URL is cloned directly -- that is
# what makes the push path testable against a local bare repo instead of
# against the estate's real record.
case "$REPO" in
  */*/*|/*|.*|*:*) CLONE=(git clone --depth=1 --quiet "$REPO" "$TMP/vault") ;;
  */*)             CLONE=(gh repo clone "$REPO" "$TMP/vault" -- --depth=1 --quiet) ;;
  *)               quit "$RC_INCOMPLETE" "vault.repo is not owner/name or a path: $REPO" ;;
esac
"${CLONE[@]}" 2>/dev/null \
  || quit "$RC_INCOMPLETE" "cannot clone $REPO -- no network, or no access"

BEFORE="$(git -C "$TMP/vault" rev-parse HEAD)"

BIBLIOTHECAIRE_VAULT="$TMP/vault" "$@"
rc=$?

# Did the command write anything? Untracked counts: a deposit is a new file.
if [ -z "$(git -C "$TMP/vault" status --porcelain)" ]; then
  exit "$rc"
fi

git -C "$TMP/vault" add -A
git -C "$TMP/vault" commit -q -m "vault: $* (via $(hostname), $(date -u +%Y-%m-%dT%H:%MZ))" \
  || quit "$RC_FAIL" "wrote to the vault but could not commit it -- work is in $TMP/vault"

if ! git -C "$TMP/vault" push -q origin HEAD:main 2>/dev/null; then
  # One retry: somebody else pushed between our clone and our push. Shallow
  # clones cannot rebase against history they do not have, so re-fetch deep
  # enough to replay onto the new tip.
  git -C "$TMP/vault" fetch -q --unshallow origin main 2>/dev/null \
    || git -C "$TMP/vault" fetch -q origin main 2>/dev/null
  if ! git -C "$TMP/vault" rebase -q origin/main 2>/dev/null \
     || ! git -C "$TMP/vault" push -q origin HEAD:main 2>/dev/null; then
    KEEP=1
    quit "$RC_FAIL" "wrote to the vault and COULD NOT PUSH. The only copy of that
work is $TMP/vault (kept deliberately -- push it by hand). Do NOT treat any
\"safe to remove from the source repository\" line above as true.
Vault head at clone: $BEFORE"
  fi
fi

say "vault: pushed $(git -C "$TMP/vault" rev-parse --short HEAD) to $REPO"
exit "$rc"
