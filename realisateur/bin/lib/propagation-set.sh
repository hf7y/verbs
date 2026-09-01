#!/usr/bin/env bash
# propagation-set.sh -- THE DEV/PROD CONTRACT, in one place.
#
# THE DECISION (#134, Zach-directed). Self-dev accounts do NOT pull fresh
# clones of realisateur. `main` IS NOT A DEPLOY REF; everything they use
# reaches them through the nightly verb build. The argument is what it buys the
# DEV side: if live accounts pull `main` on a tick, every commit is a
# deployment and `main` must turn conservative to protect them.
#
# PULL, NOT PUSH. The clock lives on the CONSUMER, in the account's own
# crontab, running as the account. bin/tests/propagation.test.sh asserts this
# mechanically -- the tick must contain no `sudo -u` and no `ssh` on its apply
# path -- so the doctrine is enforced, not merely written here.
#
# BOOTSTRAP AND PAYLOAD. A build cannot deliver its own installer, so a small,
# near-immutable bootstrap is installed once per account by
# setup-selfdev-project.sh. It is bounded and asserted to stay bounded
# (PROP_LEAK_BOUND); everything else is payload and arrives versioned.
#
# TRAP: the PROP_*_SCRIPTS values are newline-separated STRINGS consumed by
#   `for s in $LIST`, not shell code. A `#` comment placed INSIDE the quotes
#   does not comment anything -- it CLOSES the string and the rest of the list
#   executes as commands. The first draft of that very comment did this and
#   propagation.test.sh caught it as 20 lines of "command not found".
#   Comments go ABOVE the assignment.
#
# TRAP: a comment line whose FIRST word is `shellcheck` is parsed as a
#   `shellcheck` directive -- SC1072/SC1073, a parse error on the whole file.
#   Spell the path as `bin/shellcheck-lint.sh`, never bare.
#
# TRAP: PAYLOAD without a man page ships nothing, silently (#85).

if [ -n "${BASH_SOURCE:-}" ]; then
  . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/estate-set.sh"
fi
PROP_RELEASE_REPO="$GH_ESTATE_OWNER/verbs"
PROP_RELEASE_REMOTE="https://github.com/$GH_ESTATE_OWNER/verbs.git"

# A version is a UTC-timestamp build id, so lexical sort is chronological.
# ONE pin per HOST since #180: /usr/local/share/verb-builds/current. This path
# is the LEGACY per-account shape, kept because --survey still has to
# recognise it; prop_current_pin() resolves either.
PROP_PIN_PATH=".local/share/verb-builds/current"

# The HOST-WIDE pin, in one place. A reader that needs it on ANOTHER host --
# ausculte asks two of them whether they adopted the build the channel cut --
# builds its remote command from this rather than retyping the layout.
PROP_HOST_PIN="${VERB_HOST_BUILD_ROOT:-/usr/local/share/verb-builds}/current"

# STAMPING -- THREE STATES, NEVER TWO. Every stamper calls
# prop_build_trailer().
#
#   Verb-Build: <build id>   stamped, and the build is known
#   Verb-Build: unknown      stamped, and the producer honestly did not know
#   (no trailer at all)      UNSTAMPED: predates or bypasses the mechanism
#
# TRAP: an unstamped artifact must stay distinguishable from one stamped
#   "unknown" -- they mean opposite things about the mechanism. The second
#   proves the stamper ran and told the truth; the first proves nothing ran.
#   NEVER guess a plausible build id ("the latest one", "the one in the
#   manifest"); that destroys exactly this distinction.
#
# It is a git TRAILER so it travels with a clone, a cherry-pick and a patch.

# prop_current_pin -- the adopted build id, or nothing. Never a guess.
#
# TRAP: TWO ROOTS, in the order the account resolves them -- the private pin
#   first (its ~/.local/bin shims shadow the host-wide directory), the
#   host-wide root second. `unknown` is right for an unreadable pin and wrong
#   for a pin that moved.
prop_current_pin() {
  local p t
  for p in "${VERB_BUILD_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/verb-builds}/current" \
           "${VERB_HOST_BUILD_ROOT:-/usr/local/share/verb-builds}/current"; do
    t="$(readlink "$p" 2>/dev/null)" || continue
    [ -n "$t" ] || continue
    basename "$t"
    return 0
  done
  return 1
}

# prop_build_trailer -- the trailer line, always emitted, honest when unknown.
prop_build_trailer() {
  local pin; pin="$(prop_current_pin 2>/dev/null)"
  printf 'Verb-Build: %s\n' "${pin:-unknown}"
}

# --- BOOTSTRAP: small, near-immutable, installed once per account -----------
# Every entry is a file a consumer must hold BEFORE any payload can arrive.
# Adding one is a review event, not a convenience -- the bound is asserted in
# bin/tests/propagation.test.sh.
#
# TRAP: the bound is spent. selfdev-gh-app.sh takes the fourth and last slot,
#   as the git CREDENTIAL HELPER: an account with no payload cannot
#   authenticate to git and therefore cannot FETCH a payload, so it must be
#   present before anything else can arrive. Classifying it PAYLOAD would be
#   circular -- the build delivering the credential needed to fetch the build.
#   That argument depends on hf7y/verbs being PRIVATE; it went public later,
#   so the classification is now re-openable (#108).
PROP_BOOTSTRAP_SCRIPTS="
install-verb-build.sh
selfdev-release-tick.sh
release-ledger.sh
selfdev-gh-app.sh
"

# Files the bootstrap scripts need alongside them. A missed dependency staged
# into a 0700 home presents as "Permission denied", not "file not found".
#
# THE FLOOR, not the whole set: prop_support_libs() below DERIVES the rest by
# reading what the shipped scripts actually source. These four stay written
# down because propagation-set.sh is itself one of them -- a derivation cannot
# bootstrap the file that defines it.
PROP_BOOTSTRAP_SUPPORT="
lib/cli-guard.sh
lib/host-check.sh
lib/propagation-set.sh
lib/selfdev-app-key.sh
"

# prop_support_libs <bin-dir> -- every lib/ FILE the bootstrap and host-tool
# sets name, whatever its extension, derived by reading them, plus the floor.
#
# WHY DERIVED, AND WHY NO EXTENSION WHITELIST. Hand-typed, the list said four
# and seven were missing: decision-rot.sh walked ZERO repos and exited 0. Its
# replacement matched only `.sh|.tsv`, so `lib/answered.jq` -- the predicate
# itself -- still never shipped and rot went BLIND on monkey. An extension list
# is that second source of truth in a smaller costume; `-f` below is the guard.
prop_support_libs() {
  local bindir="${1:-}" s f
  if [ ! -d "$bindir" ]; then printf '%s\n' $PROP_BOOTSTRAP_SUPPORT; return 0; fi
  {
    printf '%s\n' $PROP_BOOTSTRAP_SUPPORT
    for s in $PROP_BOOTSTRAP_SCRIPTS $(prop_host_tools); do
      f="$bindir/$s"; [ -f "$f" ] || continue
      grep -ohE 'lib/[a-z0-9-]+\.[a-z0-9]+' "$f" 2>/dev/null
    done
    # That filter is also why `lib/verb.sh` -- etalon's runtime, on its own
    # channel, never a file in this bin/ -- does not read as a missing dep.
  } | sort -u | while read -r l; do [ -f "$bindir/$l" ] && printf '%s\n' "$l"; done
}

# --- PROVISIONING: root-side, deployed to the host, invoked there by a -----
# --- human. Not bootstrap: these stand an account UP, once, and they run
# --- on nobody's clock.
#
PROP_PROVISION_SCRIPTS="
dresse.sh
land-selfdev.sh
provision-selfdev-user.sh
setup-selfdev-project.sh
enrole-selfdev.sh
wire-selfdev-git.sh
wire-release-channel.sh
selfdev-app-key.sh
selfdev-claude-token.sh
selfdev-permissions-provision.sh
selfdev-hooks-provision.sh
unland-realisateur-clone.sh
install-verbs.sh
stamp-verb-build.sh
vault-group-provision.sh
"

# --- PAYLOAD: reaches user paths as a verb, inside a dated build ------------
PROP_PAYLOAD_SCRIPTS="
defere.sh
etiquette.sh
check-project-busy.sh
notify-senechal.sh
gh-sign.sh
consigne
ausculte.sh
"

# --- THE LEAK, with a bound on it -------------------------------------------
# PAYLOAD-class scripts that are NOT yet declared on any bashified branch.
PROP_PAYLOAD_PENDING="
"
PROP_LEAK_BOUND=7

# --- LOCAL: never leaves this repo ------------------------------------------
# "NEVER LEAVES THIS REPO" IS NOT "NEVER RUNS ANYWHERE ELSE", and reading it
# that way cost the estate its only outside observer. A LOCAL script reaches a
# machine by a THIRD path, neither verb build nor libexec: a plain checkout the
# host pulls itself. dexter's crontab does exactly that every ten minutes --
#   cd $HOME/realisateur && git pull --ff-only && bin/monkey-watch.sh --apply
# -- so monkey-watch.sh is LOCAL by channel and load-bearing by function.
# #511's reachability scan read .github/workflows/ and this repo's bin/, saw no
# caller, and deleted it; the caller was a crontab line on another machine.
# Before cutting anything in this list, ask what invokes it FROM SOMEWHERE ELSE.
PROP_LOCAL_SCRIPTS="
ausculte-cadence.sh
dexter-liveness.sh
monkey-watch.sh
monkey-status-collect.py
repose.sh
decision-rot.sh
vault-spool-drain.sh
stale-paths.sh
cut-verb-build.sh
registry-standup.sh
branch-protection-provision.sh
unarmed.sh
publish-release-verdict.sh
selfdev-credentials.sh
shellcheck-lint.sh
comment-claims.sh
verb-kind-lint.sh
verbs-refresh.sh
run-suites.sh
carry.sh
reprise.sh
"
# carry.sh and reprise.sh are LOCAL: they write to a BRANCH of this repo, not a
# host, so per-account copies would be many writers racing one force-with-lease.
# reprise also reads bin/lib/handoffs.tsv, THIS repo's ledger, empty elsewhere.
# registry-standup.sh, unarmed.sh, branch-protection-provision.sh: LOCAL. FLEET subjects; unarmed rides prop_host_tools.
# publish-release-verdict.sh is LOCAL because it runs in the release pipeline.

# prop_host_tools -- what a provisioned host carries under
# /usr/local/libexec/selfdev beyond the bootstrap: the verb a human types and
# every step it runs. DERIVED, so a step added to the provisioning set arrives
# on the host without a second list agreeing to it.
prop_host_tools() {
  # The probes ausculte composes are LOCAL-class and ride here, or it is
  # BLIND about them on a host.
  printf 'dresse.sh\nausculte-cadence.sh\ndexter-liveness.sh\ndecision-rot.sh\nvault-spool-drain.sh\nunarmed.sh\n'
  local s; for s in $PROP_PROVISION_SCRIPTS; do [ "$s" = dresse.sh ] || printf '%s\n' "$s"; done
}

# prop_channel <script-basename> -- prints bootstrap|provision|payload|local,
# or nothing (rc 1) when the script is unclassified. Callers MUST treat rc 1
# as a finding: an unclassified script has no propagation path at all.
prop_channel() {
  local n="$1" s
  for s in $PROP_BOOTSTRAP_SCRIPTS; do [ "$s" = "$n" ] && { echo bootstrap; return 0; }; done
  for s in $PROP_PROVISION_SCRIPTS; do [ "$s" = "$n" ] && { echo provision; return 0; }; done
  for s in $PROP_PAYLOAD_SCRIPTS;   do [ "$s" = "$n" ] && { echo payload;   return 0; }; done
  for s in $PROP_LOCAL_SCRIPTS;     do [ "$s" = "$n" ] && { echo local;     return 0; }; done
  return 1
}
