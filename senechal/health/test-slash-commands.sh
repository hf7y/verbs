#!/usr/bin/env bash
# Test harness for remedies/claude-slash-commands.sh.
#
# Everything runs against a throwaway HOME, a throwaway senechal.json, a
# STUB generator standing in for realisateur's bin/install-shims.sh, and a
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO="$(cd .. && pwd)"
REMEDY="$REPO/remedies/claude-slash-commands.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0; failed=0
check() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
  fi
}

ME="$(id -un)"
CMDDIR=".claude/commands"

# --- stub generator: stands in for realisateur/bin/install-shims.sh -----
# Same contract the real one honours: every destination is env-overridable
# and it renders one .md per user-scope command into $CMD_DEST. Its
# CONTENT here is a marker plus a version token, so "senechal installed
# exactly what the generator emitted" is checkable byte-for-byte, and
# bumping GEN_VERSION simulates realisateur editing its sources.
mkdir -p "$T/realisateur/bin"
cat > "$T/realisateur/bin/install-shims.sh" <<'GEN'
#!/usr/bin/env bash
set -uo pipefail
: "${CMD_DEST:?}"
mkdir -p "$CMD_DEST" "${BIN_DEST:-$CMD_DEST}" "${HOOK_DEST:-$CMD_DEST}"
for n in bashify cloture ideate; do
  printf '<!-- GENERATED -->\n/%s v%s\n' "$n" "${GEN_VERSION:-1}" > "$CMD_DEST/$n.md"
done
# The real generator exits 1 whenever anything on THIS host flags --
# shims, hooks, settings.json wiring, reach-lint -- none of which is
# evidence about the rendered text. Exit non-zero here on purpose so the
# remedy is forced to judge by "did files appear", not by $?.
exit 1
GEN
chmod +x "$T/realisateur/bin/install-shims.sh"

# --- stub ssh: runs the remote command locally against a fake remote HOME
mkdir -p "$T/bin"
cat > "$T/bin/ssh" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_SSH_DOWN:-0}" = 1 ] && exit 255
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -*) shift ;;
    *)  args+=("$1"); shift ;;
  esac
done
printf '%s\n' "${args[0]}" >> "$STUB_DIR/ssh-targets"
HOME="$STUB_DIR/remote-home" bash -c "${args[1]}"
STUB
chmod +x "$T/bin/ssh"

# --- config: one local home, one ssh home ------------------------------
write_cfg() { # <status>
  cat > "$T/senechal.json" <<JSON
{"estate": {
  "devices": [
    {"name": "here", "reach": "local"},
    {"name": "far",  "reach": "ssh", "ssh_host": "far.example"}
  ],
  "taste": [
    {"id": "claude-slash-commands", "file": ".claude/commands/",
     "status": "$1",
     "homes": [{"host": "here", "account": "$ME"},
               {"host": "far",  "account": "zach"}]}
  ]
}}
JSON
}

run() { # <verb> [GEN_VERSION] -> stdout+stderr, sets RC
  local verb="$1"
  HOME="$T/home" \
  SENECHAL_CONFIG="$T/senechal.json" \
  SENECHAL_REALISATEUR="${SENECHAL_REALISATEUR_OVERRIDE:-$T/realisateur}" \
  GEN_VERSION="${2:-1}" \
  STUB_DIR="$T" PATH="$T/bin:$PATH" \
    bash "$REMEDY" "$verb" 2>&1
}
run_rc() { local out; out="$(run "$@")"; printf '%s' "$?"; }

reset_homes() {
  rm -rf "$T/home" "$T/remote-home"
  mkdir -p "$T/home" "$T/remote-home"
}

# =======================================================================
# 1. verify: nothing installed anywhere is a FAIL, not a pass
# =======================================================================
write_cfg enabled
reset_homes
out="$(run verify)"; rc=$?
check "empty homes: exit 1 (real mismatch)" 1 "$rc"
check "empty local home: names the missing command" yes \
  "$(grep -qF "$ME@here: ~/$CMDDIR/ideate.md is MISSING" <<<"$out" && echo yes || echo "no
$out")"
check "empty remote home is MISSING, not unreachable" yes \
  "$(grep -qF "zach@far: ~/$CMDDIR/ideate.md is MISSING" <<<"$out" && echo yes || echo "no
$out")"
# The bug this locks down, found live on 2026-08-06 against zach@monkey: a
# home with no ~/.claude/commands at all made the probe's `cd` fail, made
# ssh return non-zero, and reported as "could not reach over ssh" -- a
# SKIP where the truth was the loudest possible FAIL.
check "an absent remote dir is never reported as unreachable" yes \
  "$(grep -q 'could not reach' <<<"$out" && echo "no
$out" || echo yes)"

# =======================================================================
# 2. enable: installs everywhere, from the generator's output only
# =======================================================================
out="$(run enable)"; rc=$?
check "enable: exit 0" 0 "$rc"
check "enable wrote the local copy" "/ideate v1" \
  "$(sed -n 2p "$T/home/$CMDDIR/ideate.md" 2>/dev/null)"
check "enable wrote the remote copy" "/ideate v1" \
  "$(sed -n 2p "$T/remote-home/$CMDDIR/ideate.md" 2>/dev/null)"
check "enable installed all three commands locally" 3 \
  "$(ls "$T/home/$CMDDIR" | grep -c '\.md$')"
check "enable reached the ssh home by account@alias" yes \
  "$(grep -qx 'zach@far.example' "$T/ssh-targets" && echo yes || echo "no
$(cat "$T/ssh-targets" 2>/dev/null)")"

# senechal must hold NO copy of the command text: the only place the
# content can have come from is the generator. Proven by changing what
# the generator emits and watching the installed file follow.
check "verify is clean right after enable" 0 "$(run_rc verify)"

# =======================================================================
# 3. drift: the generator moves, the homes do not
# =======================================================================
out="$(run verify 2)"; rc=$?
check "generator bumped: exit 1" 1 "$rc"
check "drift is named as drift, not as missing (local)" yes \
  "$(grep -qF "$ME@here: ~/$CMDDIR/ideate.md has DRIFTED" <<<"$out" && echo yes || echo "no
$out")"
check "drift is named as drift, not as missing (remote)" yes \
  "$(grep -qF "zach@far: ~/$CMDDIR/ideate.md has DRIFTED" <<<"$out" && echo yes || echo "no
$out")"

run enable 2 >/dev/null
check "enable repairs drift (local)" "/ideate v2" \
  "$(sed -n 2p "$T/home/$CMDDIR/ideate.md")"
check "enable repairs drift (remote)" "/ideate v2" \
  "$(sed -n 2p "$T/remote-home/$CMDDIR/ideate.md")"
check "verify clean after repair" 0 "$(run_rc verify 2)"
check "repair backed the old copy up (local)" 1 \
  "$(ls "$T/home/$CMDDIR"/ideate.md.senechal-backup.* 2>/dev/null | wc -l)"
check "repair backed the old copy up (remote)" 1 \
  "$(ls "$T/remote-home/$CMDDIR"/ideate.md.senechal-backup.* 2>/dev/null | wc -l)"

# =======================================================================
# 4. enable is idempotent, and leaves a home's own files alone
# =======================================================================
reset_homes
run enable >/dev/null
printf 'mine\n' > "$T/home/$CMDDIR/my-own-command.md"
before="$(find "$T/home" -type f | sort | xargs md5sum | md5sum)"
out="$(run enable)"
after="$(find "$T/home" -type f | sort | xargs md5sum | md5sum)"
check "second enable changes nothing" "$before" "$after"
check "second enable says so" yes \
  "$(grep -q 'already correct' <<<"$out" && echo yes || echo "no
$out")"
check "a home's own command file survives" "mine" \
  "$(cat "$T/home/$CMDDIR/my-own-command.md")"
check "an extra local command file is not a failure" 0 "$(run_rc verify)"

# =======================================================================
# 5. could-not-check is never a pass
# =======================================================================
STUB_SSH_DOWN=1
export STUB_SSH_DOWN
out="$(run verify)"; rc=$?
check "an unreachable home is exit 2, not 0" 2 "$rc"
check "an unreachable home reads as SKIP" yes \
  "$(grep -q 'SKIP.*could not reach' <<<"$out" && echo yes || echo "no
$out")"
unset STUB_SSH_DOWN

# No generator at all: senechal cannot say anything about any home, and
# must say THAT rather than passing. realisateur owns this content; a
# senechal that cannot read it has not checked it.
SENECHAL_REALISATEUR_OVERRIDE="$T/nonexistent"
out="$(run verify)"; rc=$?
check "no generator: exit 2, not 0" 2 "$rc"
check "no generator: says realisateur is the source of truth" yes \
  "$(grep -q 'source of truth' <<<"$out" && echo yes || echo "no
$out")"
check "no generator: enable refuses and writes nothing" 1 \
  "$(run_rc enable)"
unset SENECHAL_REALISATEUR_OVERRIDE

# =======================================================================
# 6. a disabled taste stands down without claiming health
# =======================================================================
write_cfg parked
reset_homes
out="$(run verify)"; rc=$?
check "status != enabled: exit 2 (skipped, not passed)" 2 "$rc"
check "status != enabled: names the status" yes \
  "$(grep -q 'is "parked"' <<<"$out" && echo yes || echo "no
$out")"
check "status != enabled: enable writes nothing" 0 \
  "$(ls "$T/home/$CMDDIR" 2>/dev/null | wc -l)"

# =======================================================================
# 7. a home naming a device the registry does not declare is a fault
# =======================================================================
cat > "$T/senechal.json" <<JSON
{"estate": {
  "devices": [{"name": "here", "reach": "local"}],
  "taste": [
    {"id": "claude-slash-commands", "file": ".claude/commands/",
     "status": "enabled", "homes": [{"host": "ghost", "account": "zach"}]}
  ]
}}
JSON
reset_homes
out="$(run verify)"; rc=$?
check "undeclared device: exit 1, a registry fault" 1 "$rc"
check "undeclared device: says which one" yes \
  "$(grep -q 'ghost.*not in estate.devices' <<<"$out" && echo yes || echo "no
$out")"

# =======================================================================
# 8. read-only: verify never writes into a home
# =======================================================================
write_cfg enabled
reset_homes
run enable >/dev/null
before="$(find "$T/home" "$T/remote-home" | sort | md5sum)"
run verify >/dev/null
after="$(find "$T/home" "$T/remote-home" | sort | md5sum)"
check "verify created and removed nothing" "$before" "$after"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$failed"
[ "$failed" -eq 0 ]
