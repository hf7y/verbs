#!/usr/bin/env bash
# ssh-media-test.sh -- exercises the SSH transport itself (gardien#35,
# option (c)): "a local sshd / loopback fixture, so the ssh path runs in
# CI with no remote host."
#
# gardien#35's hole: every destination in media-test.sh is `kind: local`,
# where the copy/verify body calls `cp`/`md5sum` and neither reads stdin.
# The collision-rescue loop's stdin-consumption bug (fixed, guarded only
# STRUCTURALLY by a grep over lib/media.sh's source text -- see
# media-test.sh's "nothing may iterate collisions via stdin" section) is
# therefore invisible to every behavioural test that exists: a grep over
# source catches a regression that looks the same and misses one that
# does not.
#
# This spins up a REAL sshd, listening on 127.0.0.1 on an unprivileged
# port with a throwaway ed25519 host/client keypair, and runs the actual
# rsync-over-ssh and ssh-exec code paths in lib/media.sh against it. It is
# not a remote host: no network egress, no credential that outlives this
# process, torn down in the EXIT trap every time. Every destination below
# names its own `known_hosts` (a new, opt-in manifest field this suite
# added to dest_ssh_opts) so nothing here ever reads or writes this
# account's real ~/.ssh/known_hosts -- `ssh` resolves `~` from the passwd
# entry, not from $HOME, so exporting HOME could not have redirected it.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
GARDE="$ROOT/bin/garde"
pass=0; fail=0; skip=0
ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (want $3, got $2)"; }

command -v sshd >/dev/null 2>&1 || { printf 'SKIP  no sshd on PATH -- the ssh transport cannot be exercised here\n'; exit 0; }

safename() { printf '%s-%s\n' "$(printf '%s' "$1" | md5sum | cut -c1-8)" \
             "$(printf '%s' "$1" | sed 's|%|%25|g; s|/|%2F|g')"; }

TMP="$(mktemp -d)"
SSHD_PID=""
cleanup() {
  [ -n "$SSHD_PID" ] && kill "$SSHD_PID" 2>/dev/null
  chmod -R u+rwX "$TMP" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

FAKEHOME="$TMP/fakehome"; mkdir -p "$FAKEHOME/.ssh"; chmod 700 "$FAKEHOME/.ssh"
ssh-keygen -t ed25519 -N '' -q -f "$TMP/host_key"
ssh-keygen -t ed25519 -N '' -q -f "$TMP/client_key"
cp "$TMP/client_key.pub" "$TMP/authorized_keys"; chmod 600 "$TMP/authorized_keys"

# A port in the high, rarely-registered range, offset by our own PID so two
# concurrent runs of this suite do not collide with each other.
PORT=$((20000 + ($$ % 10000)))

cat > "$TMP/sshd_config" <<EOF
ListenAddress 127.0.0.1
Port $PORT
HostKey $TMP/host_key
AuthorizedKeysFile $TMP/authorized_keys
PidFile $TMP/sshd.pid
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
StrictModes no
LogLevel ERROR
EOF

/usr/sbin/sshd -f "$TMP/sshd_config" -D -e >"$TMP/sshd.log" 2>&1 &
SSHD_PID=$!

printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cut -d' ' -f1-2 "$TMP/host_key.pub")" \
  > "$FAKEHOME/.ssh/known_hosts"

KH="$FAKEHOME/.ssh/known_hosts"
up=0
for _ in $(seq 1 20); do
  if ssh -o BatchMode=yes -o UserKnownHostsFile="$KH" -p "$PORT" -i "$TMP/client_key" \
       127.0.0.1 true >/dev/null 2>&1; then
    up=1; break
  fi
  sleep 0.25
done

if [ "$up" != 1 ]; then
  printf 'SKIP  loopback sshd on port %s never came up (log follows) -- environment cannot run this suite\n' "$PORT"
  sed 's/^/SKIP    /' "$TMP/sshd.log"
  exit 0
fi

echo "=== garde media over a real (loopback) ssh transport"; echo

DST="$TMP/dst"; mkdir -p "$DST"

# --- plain sanity: copy + md5 verify actually over ssh -------------------
SRC="$TMP/src/Plain"; mkdir -p "$SRC"
printf 'one\n' > "$SRC/a.txt"; printf 'two\n' > "$SRC/b.txt"
mkdir -p "$SRC/sub"; printf 'three\n' > "$SRC/sub/c.txt"
cat > "$TMP/plain.json" <<JSON
{ "destinations": { "loop": { "kind": "ssh", "user": "$(id -un)", "host": "127.0.0.1",
    "port": $PORT, "identity": "$TMP/client_key", "known_hosts": "$KH", "root": "$DST", "online": true } },
  "sets": [ { "name": "Plain", "path": "$SRC", "copies": ["loop"],
              "min_copies": 1, "verify": "md5" } ] }
JSON
out="$(GARDE_MANIFEST="$TMP/plain.json" GARDE_STATE="$TMP/state" "$GARDE" media run Plain 2>&1)"; rc=$?
check "a plain set copies and proves over a REAL ssh transport" "$rc" 0
[ -f "$DST/Plain/a.txt" ] && [ -f "$DST/Plain/sub/c.txt" ] \
  && ok "files landed at the expected remote path over ssh" \
  || bad "files did not land where expected over ssh"

out="$(GARDE_MANIFEST="$TMP/plain.json" GARDE_STATE="$TMP/state" "$GARDE" media list 2>&1)"
case "$out" in *"ok x1"*) ok "media list finds the ssh destination reachable and proven" ;;
               *) bad "media list did not report the ssh copy as proven: $out" ;; esac

# --- the actual regression: MANY collisions over ssh ----------------------
# Two members reliably survives even the buggy stdin-consuming loop by
# accident -- the real incident was "only the first FEW of 8 files were
# processed". Five groups (10 files) gives the consuming command (ssh, in
# the loop body) five separate chances to swallow the rest of the list.
CSRC="$TMP/csrc/Coll"; mkdir -p "$CSRC"
for i in 1 2 3 4 5; do
  printf 'upper-%d\n' "$i" > "$CSRC/File${i}.DAT"
  printf 'lower-%d\n' "$i" > "$CSRC/file${i}.dat"
done
cat > "$TMP/coll.json" <<JSON
{ "destinations": { "loop": { "kind": "ssh", "user": "$(id -un)", "host": "127.0.0.1",
    "port": $PORT, "identity": "$TMP/client_key", "known_hosts": "$KH", "root": "$DST",
    "case_insensitive": true, "online": true } },
  "sets": [ { "name": "Coll", "path": "$CSRC", "copies": ["loop"],
              "min_copies": 1, "verify": "md5" } ] }
JSON
out="$(GARDE_MANIFEST="$TMP/coll.json" GARDE_STATE="$TMP/state" "$GARDE" media run Coll 2>&1)"; rc=$?
check "a 5-group (10-file) collision set copies and verifies over ssh" "$rc" 0

landed=0
for i in 1 2 3 4 5; do
  hu="$(safename "File${i}.DAT")"; hl="$(safename "file${i}.dat")"
  [ -f "$DST/Coll.case-collisions/$hu" ] && [ -f "$DST/Coll.case-collisions/$hl" ] \
    && landed=$((landed + 1))
done
check "every one of the 5 collision groups was rescued over ssh, not just the first" \
  "$landed" "5"

total="$(find "$DST/Coll.case-collisions" -type f 2>/dev/null | wc -l)"
check "all 10 colliding files landed in .case-collisions/ (none swallowed by ssh's stdin)" \
  "$total" "10"

echo
printf -- '--- ssh-media: %d passed, %d failed (%d skipped)\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
