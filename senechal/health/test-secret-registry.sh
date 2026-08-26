#!/usr/bin/env bash
# Test harness for secret-registry.sh. Runs the real script against a
# throwaway credential registry and a throwaway gardien set list, in a
# $HOME-substitute, so every verdict is exercised deterministically and
# no real credential is ever touched.
#
# Exit: 0 all assertions pass / 1 any assertion failed.
# Safe anywhere: touches only its own mktemp dir.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.config/thing" "$T/home/backed-up/creds" "$T/home/private"

# --- fixtures -----------------------------------------------------------
# a credential in no backup set, correct mode
printf 'SECRET-CANARY-ALPHA\n' > "$T/home/private/lonely.token"
chmod 600 "$T/home/private/lonely.token"

# a credential sitting INSIDE a gardien set -- the egress case
printf 'SECRET-CANARY-BRAVO\n' > "$T/home/backed-up/creds/leaky.pem"
chmod 600 "$T/home/backed-up/creds/leaky.pem"

# same, but the entry says that is allowed
printf 'SECRET-CANARY-CHARLIE\n' > "$T/home/backed-up/creds/deliberate.pem"
chmod 600 "$T/home/backed-up/creds/deliberate.pem"

# mode drift: wider than declared
printf 'SECRET-CANARY-DELTA\n' > "$T/home/private/wide.key"
chmod 644 "$T/home/private/wide.key"

# a retired credential that came back
printf 'SECRET-CANARY-ECHO\n' > "$T/home/private/revenant.pem"
chmod 600 "$T/home/private/revenant.pem"

# registered with no mint runbook
printf 'SECRET-CANARY-FOXTROT\n' > "$T/home/private/norunbook.token"
chmod 600 "$T/home/private/norunbook.token"

# THE INVARIANT FIXTURE: a FIFO where a credential should be. `test -e`
# and `stat` answer instantly on a fifo; anything that tries to READ its
# contents blocks forever. So if this script ever grows a `cat`, the
# suite hangs and `timeout` below turns that into a hard failure. A
# promise in a comment cannot do that.
mkfifo "$T/home/private/nevercat.pem"
chmod 600 "$T/home/private/nevercat.pem"

# ~/.config/thing/backed.token is inside the ".config" set below
printf 'SECRET-CANARY-GOLF\n' > "$T/home/.config/thing/backed.token"
chmod 600 "$T/home/.config/thing/backed.token"

# --- throwaway gardien set list ----------------------------------------
# Two sets, one of them a PREFIX TRAP: "backed-up" must not swallow
# "backed-up-elsewhere", so path matching has to respect a boundary.
mkdir -p "$T/garde"
cat > "$T/garde/garde.json" <<JSON
{ "sets": [
  { "name": "creds-set", "path": "$T/home/backed-up",
    "exclude": ["creds/excluded.pem", "wholedir"] },
  { "name": ".config",   "path": "~/.config" }
]}
JSON

# A credential the set EXCLUDES is not leaving the host, and must not be
# reported as if it were. rsync feeds `exclude` straight to --exclude=.
printf 'SECRET-CANARY-HOTEL\n' > "$T/home/backed-up/creds/excluded.pem"
chmod 600 "$T/home/backed-up/creds/excluded.pem"
# ...and an exclude names a directory: everything under it is excluded too
mkdir -p "$T/home/backed-up/wholedir/nested"
printf 'SECRET-CANARY-INDIA\n' > "$T/home/backed-up/wholedir/nested/deep.pem"
chmod 600 "$T/home/backed-up/wholedir/nested/deep.pem"

# --- throwaway registry -------------------------------------------------
cat > "$T/senechal.json" <<JSON
{
  "estate": { "secrets": [
    { "id": "lonely",     "host": "testhost", "owner": "o", "path": "$T/home/private/lonely.token",
      "purpose": "P-LONELY", "mode": "600", "recovery": "remint", "reprovision": "MINT-LONELY", "offhost": "forbid" },
    { "id": "leaky",      "host": "testhost", "owner": "o", "path": "$T/home/backed-up/creds/leaky.pem",
      "purpose": "P-LEAKY", "mode": "600", "recovery": "remint", "reprovision": "MINT-LEAKY", "offhost": "forbid" },
    { "id": "deliberate", "host": "testhost", "owner": "o", "path": "$T/home/backed-up/creds/deliberate.pem",
      "purpose": "P-DELIB", "mode": "600", "recovery": "escrow", "reprovision": "MINT-DELIB", "offhost": "allow" },
    { "id": "excluded",   "host": "testhost", "owner": "o", "path": "$T/home/backed-up/creds/excluded.pem",
      "purpose": "P-EXCL", "mode": "600", "recovery": "remint", "reprovision": "MINT-EXCL", "offhost": "forbid" },
    { "id": "excludeddir","host": "testhost", "owner": "o", "path": "$T/home/backed-up/wholedir/nested/deep.pem",
      "purpose": "P-EXCLDIR", "mode": "600", "recovery": "remint", "reprovision": "MINT-EXCLDIR", "offhost": "forbid" },
    { "id": "wide",       "host": "testhost", "owner": "o", "path": "$T/home/private/wide.key",
      "purpose": "P-WIDE", "mode": "600", "recovery": "remint", "reprovision": "MINT-WIDE", "offhost": "forbid" },
    { "id": "vanished",   "host": "testhost", "owner": "o", "path": "$T/home/private/absent.token",
      "purpose": "P-VANISHED", "mode": "600", "recovery": "remint", "reprovision": "MINT-VANISHED", "offhost": "forbid" },
    { "id": "lostforever","host": "testhost", "owner": "o", "path": "$T/home/private/absent2.pem",
      "purpose": "P-LOST", "mode": "600", "recovery": "escrow", "reprovision": "MINT-LOST", "offhost": "forbid" },
    { "id": "revenant",   "host": "testhost", "owner": "o", "path": "$T/home/private/revenant.pem",
      "purpose": "P-REV", "mode": "600", "recovery": "remint", "reprovision": "MINT-REV", "offhost": "forbid", "status": "retired" },
    { "id": "staydead",   "host": "testhost", "owner": "o", "path": "$T/home/private/gone.pem",
      "purpose": "P-STAYDEAD", "mode": "600", "recovery": "remint", "reprovision": "MINT-STAYDEAD", "offhost": "forbid", "status": "retired" },
    { "id": "norunbook",  "host": "testhost", "owner": "o", "path": "$T/home/private/norunbook.token",
      "purpose": "P-NORUNBOOK", "mode": "600", "recovery": "remint", "reprovision": "", "offhost": "forbid" },
    { "id": "nevercat",   "host": "testhost", "owner": "o", "path": "$T/home/private/nevercat.pem",
      "purpose": "P-NEVERCAT", "mode": "600", "recovery": "remint", "reprovision": "MINT-NEVERCAT", "offhost": "forbid" },
    { "id": "tilde",      "host": "testhost", "owner": "o", "path": "~/.config/thing/backed.token",
      "purpose": "P-TILDE", "mode": "600", "recovery": "remint", "reprovision": "MINT-TILDE", "offhost": "forbid" },
    { "id": "costlyreissue","host": "testhost", "owner": "o", "path": "$T/home/private/lonely.token",
      "purpose": "P-COSTLY", "mode": "600", "recovery": "remint", "reprovision": "REISSUE-COSTLY",
      "reprovision_cost": "high", "offhost": "allow", "notes": "N-COSTLY" },
    { "id": "uncosted",   "host": "testhost", "owner": "o", "path": "$T/home/private/lonely.token",
      "purpose": "P-UNCOSTED", "mode": "600", "recovery": "remint", "reprovision": "REISSUE-UNCOSTED",
      "offhost": "allow" },
    { "id": "elsewhere",  "host": "otherbox", "owner": "o", "path": "/wherever/remote.pem",
      "purpose": "P-ELSEWHERE", "mode": "600", "recovery": "remint", "reprovision": "MINT-ELSEWHERE", "offhost": "forbid" }
  ]}
}
JSON

run() { # run <garde-config> -> sets $out/$rc
  out="$(timeout 20 env HOME="$T/home" \
         SENECHAL_HOSTNAME=testhost \
         SENECHAL_CONFIG="$T/senechal.json" \
         GARDE_CONFIG="$1" \
         bash ./secret-registry.sh 2>&1)"
  rc=$?
}

fails=0
expect_line() { # expect_line <marker> <substring...>
  local marker="$1"; shift
  if grep -qF "  $marker  $*" <<< "$out"; then
    printf 'ok:   %s  %s\n' "$marker" "$*"
  else
    printf 'MISS: %s  %s\n' "$marker" "$*"
    fails=$((fails + 1))
  fi
}
expect_text() {
  if grep -qF "$1" <<< "$out"; then printf 'ok:   text %s\n' "$1"
  else printf 'MISS: text %s\n' "$1"; fails=$((fails + 1)); fi
}
refute_text() {
  if grep -qF "$1" <<< "$out"; then printf 'MISS: must NOT appear: %s\n' "$1"; fails=$((fails + 1))
  else printf 'ok:   absent %s\n' "$1"; fi
}
expect_rc() {
  if [ "$rc" = "$1" ]; then printf 'ok:   exit %s\n' "$1"
  else printf 'MISS: exit %s (got %s)\n' "$1" "$rc"; fails=$((fails + 1)); fi
}

run "$T/garde/garde.json"

echo "--- with a readable gardien set list"

# THE INVARIANT, FIRST: the run completed at all. A `cat` of the fifo
# would have hung until `timeout` killed it at 20s -> rc 124.
if [ "$rc" = 124 ]; then
  printf 'MISS: TIMED OUT -- something read a credential rather than stat-ing it\n'
  fails=$((fails + 1))
else
  printf 'ok:   never reads a secret'"'"'s contents (fifo fixture did not block)\n'
fi
# and no canary value ever reached the report
for c in ALPHA BRAVO CHARLIE DELTA ECHO FOXTROT GOLF HOTEL INDIA; do
  refute_text "SECRET-CANARY-$c"
done

# --- present, correct, not copied anywhere ------------------------------
expect_line PASS "lonely -- present, mode 600, no backup set copies it (remint)"

# --- the finding this exists for ----------------------------------------
expect_line FAIL "leaky -- PLAINTEXT LEAVES THE HOST: declared offhost=forbid, but gardien set 'creds-set' copies it"
expect_text "P-LEAKY"
# ...and the same shape through a ~ path, resolved against HOME
expect_line FAIL "tilde -- PLAINTEXT LEAVES THE HOST: declared offhost=forbid, but gardien set '.config' copies it"
# an entry that says the copy is intended is not a finding
expect_line PASS "deliberate -- present, mode 600, offhost=allow (gardien set 'creds-set' copies it, as declared)"

# REGRESSION: a credential the set EXCLUDES is not leaving the host. Without
# this, secret-plaintext-egress.sh could fix reality and the check would keep
# failing -- which is exactly what happened on 2026-08-13 when the remedy
# landed and all three FAILs stayed up. A check that cannot see its own
# remedy working trains you to ignore it.
expect_line PASS "excluded -- present, mode 600, no backup set copies it (remint)"
refute_text "excluded -- PLAINTEXT LEAVES THE HOST"
# an exclude naming a directory covers everything beneath it, as rsync does
expect_line PASS "excludeddir -- present, mode 600, no backup set copies it (remint)"

# --- least privilege ----------------------------------------------------
expect_line FAIL "wide -- MODE DRIFT: $T/home/private/wide.key is 644, declared 600"
expect_text "chmod 600 $T/home/private/wide.key"

# --- missing, and the runbook is what gets printed ----------------------
expect_line FAIL "vanished -- MISSING: $T/home/private/absent.token does not exist"
expect_text "MINT-VANISHED"
expect_line FAIL "lostforever -- MISSING: $T/home/private/absent2.pem does not exist, and it is NOT re-mintable"
expect_text "MINT-LOST"

# --- retired: gone is the pass, back is the finding ---------------------
expect_line FAIL "revenant -- declared RETIRED but it is BACK"
expect_line PASS "staydead -- retired and still gone"

# --- REISSUING MUST BE RECORDED, AND HONEST ABOUT ITS COST --------------
# This is the gate that makes "we do not back credentials up" a strategy
# rather than a shrug: if nothing says how to issue another one, the
# credential is unrecoverable no matter how many copies exist.
expect_line WARN "norunbook -- NO reprovision runbook: nothing here says how to issue another one"
# A recorded runbook is NOT the same as a cheap one. ~/.ssh/id_ed25519 is
# one ssh-keygen away and still expensive, because nothing records which
# hosts trust it -- so "straightforward" is asserted, not assumed.
expect_line WARN "costlyreissue -- reissuing is recorded but NOT straightforward (reprovision_cost=high)"
expect_text "N-COSTLY"
# ...and an unrecorded cost is itself untested, so it must not read as cheap
expect_line WARN "uncosted -- reissue cost unrecorded, so 'we can just make another' is untested"

# --- another host is could-not-look, never a pass -----------------------
expect_line SKIP "elsewhere (otherbox, owner: o) -- no ssh_host for 'otherbox' in estate.devices, so it cannot be reached"

# broken (1) outranks could-not-look (2) outranks warn (3)
expect_rc 1

# --- gardien unreadable: egress must SKIP, never PASS -------------------
echo "--- with NO gardien set list"
run "$T/garde/does-not-exist.json"
expect_line SKIP "lonely -- present and mode 600, but gardien's set list is unreadable so egress could not be checked"
expect_text "gardien set list unreadable"
# the leak we already know about must NOT silently become a pass here.
# It SKIPs (could-not-look), and the skip line legitimately contains
# "leaky -- present ...", so assert on the verdict marker, not the text.
refute_text "PASS  leaky"
expect_line SKIP "leaky -- present and mode 600, but gardien's set list is unreadable so egress could not be checked"
# Still 1, not 2: mode drift and missing credentials are findings that do
# not depend on gardien being readable, and broken outranks could-not-look.
expect_rc 1

# --- an empty registry is could-not-look, not a clean bill --------------
echo "--- with an empty registry"
printf '{ "estate": { "secrets": [] } }\n' > "$T/empty.json"
out="$(timeout 20 env HOME="$T/home" SENECHAL_HOSTNAME=testhost \
       SENECHAL_CONFIG="$T/empty.json" GARDE_CONFIG="$T/garde/garde.json" \
       bash ./secret-registry.sh 2>&1)"; rc=$?
expect_line SKIP "no estate.secrets entries readable from $T/empty.json"
expect_rc 2

# --- --verify: does the credential actually WORK ------------------------
# Presence is the weak question; this is the check that makes choosing
# NOT to back a credential up a real strategy instead of a shrug.
echo "--- --verify"
cat > "$T/senechal-verify.json" <<JSON
{
  "estate": { "secrets": [
    { "id": "works",      "host": "testhost", "owner": "o", "path": "$T/home/private/lonely.token",
      "purpose": "P", "mode": "600", "recovery": "remint", "mint": "M", "offhost": "allow",
      "verify": "true", "reprovision": "REISSUE-WORKS" },
    { "id": "revoked",    "host": "testhost", "owner": "o", "path": "$T/home/private/lonely.token",
      "purpose": "P", "mode": "600", "recovery": "remint", "mint": "M", "offhost": "allow",
      "verify": "false", "reprovision": "REISSUE-REVOKED" },
    { "id": "unverifiable","host": "testhost", "owner": "o", "path": "$T/home/private/lonely.token",
      "purpose": "P", "mode": "600", "recovery": "remint", "mint": "M", "offhost": "allow",
      "verify": "", "reprovision": "R" },
    { "id": "stdineater", "host": "testhost", "owner": "o", "path": "$T/home/private/lonely.token",
      "purpose": "P", "mode": "600", "recovery": "remint", "mint": "M", "offhost": "allow",
      "verify": "cat >/dev/null", "reprovision": "R" },
    { "id": "afterthem",  "host": "testhost", "owner": "o", "path": "$T/home/private/lonely.token",
      "purpose": "P", "mode": "600", "recovery": "remint", "mint": "M", "offhost": "allow",
      "verify": "true", "reprovision": "R" },
    { "id": "deadkey",    "host": "testhost", "owner": "o", "path": "$T/home/private/gone.pem",
      "purpose": "P", "mode": "600", "recovery": "remint", "mint": "M", "offhost": "allow",
      "verify": "true", "reprovision": "R", "status": "retired" }
  ]}
}
JSON
out="$(timeout 20 env HOME="$T/home" SENECHAL_HOSTNAME=testhost \
       SENECHAL_CONFIG="$T/senechal-verify.json" GARDE_CONFIG="$T/garde/garde.json" \
       bash ./secret-registry.sh --verify 2>&1)"; rc=$?

expect_line PASS "works -- verified working"
# a credential that exists but no longer authenticates -- the whole point
expect_line FAIL "revoked -- PRESENT BUT NOT WORKING"
expect_text "REISSUE-REVOKED"
expect_line SKIP "unverifiable -- no verify command recorded"
# REGRESSION, found on the first real run: a verify command that reads
# stdin (any `ssh`) consumed the loop's input and every later credential
# was silently never checked -- while the report still exited cleanly.
expect_line PASS "afterthem -- verified working"
# a retired credential has nothing to authenticate with
refute_text "deadkey"

echo "--- --reprovision"
out="$(timeout 20 env HOME="$T/home" SENECHAL_HOSTNAME=testhost \
       SENECHAL_CONFIG="$T/senechal-verify.json" GARDE_CONFIG="$T/garde/garde.json" \
       bash ./secret-registry.sh --reprovision revoked 2>&1)"; rc=$?
expect_text "REISSUE-REVOKED"
expect_text "cost   :"
expect_text "Nothing above was executed"
refute_text "REISSUE-WORKS"
expect_rc 0

# an unknown id must not silently print nothing and exit 0
out="$(timeout 20 env HOME="$T/home" SENECHAL_HOSTNAME=testhost \
       SENECHAL_CONFIG="$T/senechal-verify.json" GARDE_CONFIG="$T/garde/garde.json" \
       bash ./secret-registry.sh --reprovision no-such-id 2>&1)"; rc=$?
expect_text "no credential registered as 'no-such-id'"
expect_rc 1

echo
if [ "$fails" -eq 0 ]; then
  echo "test-secret-registry: all assertions passed"
  exit 0
fi
echo "test-secret-registry: $fails assertion(s) failed"
exit 1
