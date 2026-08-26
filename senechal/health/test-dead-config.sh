#!/usr/bin/env bash
# Test harness for dead-config.sh. Runs the real script against a
# throwaway footprint registry with PATH-stubbed `systemctl` and `ss`,
# so every verdict cell in the status x probe matrix is exercised
# deterministically and no real unit is ever queried.
#
# Exit: 0 all assertions pass / 1 any assertion failed.
# Safe anywhere: touches only its own mktemp dir and $HOME-substitute.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/.ssh"

# --- stub systemctl: answers `show -p PROP --value UNIT` and
# `is-active`/`is-enabled` from per-unit files in $STUB_DIR. A unit with
# no file at all answers LoadState=not-found, i.e. absent.
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
scope=system
args=()
for a in "$@"; do
  case "$a" in --user) scope=user ;; *) args+=("$a") ;; esac
done
verb="${args[0]:-}"
get() { # get <unit> <prop> ; empty if unset
  local f="$STUB_DIR/unit-$scope-$1"
  [ -f "$f" ] || return 0
  sed -n "s/^$2=//p" "$f"
}
case "$verb" in
  show)
    prop=""; unit=""
    i=1
    while [ $i -lt ${#args[@]} ]; do
      case "${args[$i]}" in
        -p) prop="${args[$((i + 1))]}"; i=$((i + 2)) ;;
        --value) i=$((i + 1)) ;;
        *) unit="${args[$i]}"; i=$((i + 1)) ;;
      esac
    done
    if [ "$prop" = LoadState ] && [ ! -f "$STUB_DIR/unit-$scope-$unit" ]; then
      echo "not-found"; exit 0
    fi
    get "$unit" "$prop"
    ;;
  is-active|is-enabled)
    unit="${args[1]}"
    v="$(get "$unit" "${verb#is-}")"
    printf '%s\n' "${v:-unknown}"
    ;;
esac
exit 0
STUB

# --- stub ss: replays a canned listener table
cat > "$T/bin/ss" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_DIR/ss-out" 2>/dev/null
exit 0
STUB
chmod +x "$T/bin/systemctl" "$T/bin/ss"

# --- unit fixtures ------------------------------------------------------
# live + running
printf 'LoadState=loaded\nactive=active\nenabled=enabled\n' > "$T/unit-system-live-ok.service"
# live but installed, inactive, last exited non-zero -> suspected dead
printf 'LoadState=loaded\nactive=inactive\nenabled=enabled\nExecMainStatus=1\nResult=exit-code\n' \
  > "$T/unit-system-live-corpse.service"
# a unit whose exit code IS its report: SuccessExitStatus=1 2 3, so it
# exits 1 on a perfectly correct run and systemd calls that success.
# senechal-health.service is exactly this, and reading ExecMainStatus
# alone made this script call senechal's own timer a corpse.
printf 'LoadState=loaded\nactive=active\nenabled=enabled\nUnit=reporter.service\n' \
  > "$T/unit-user-reporter.timer"
printf 'LoadState=loaded\nactive=inactive\nenabled=static\nExecMainStatus=1\nResult=success\n' \
  > "$T/unit-user-reporter.service"
# and the same shape standing alone, not behind a timer
printf 'LoadState=loaded\nactive=inactive\nenabled=enabled\nExecMainStatus=3\nResult=success\nInactiveEnterTimestamp=%s\n' \
  "$(date '+%a %Y-%m-%d %H:%M:%S %Z')" > "$T/unit-system-reporter-solo.service"
# no Result property at all (stub / older systemd): a missing verdict
# must fall back to the exit code, never read as a pass
printf 'LoadState=loaded\nactive=inactive\nenabled=enabled\nExecMainStatus=1\n' \
  > "$T/unit-system-noresult.service"
# live, inactive, never ran at all -> suspected dead (installed and never used)
printf 'LoadState=loaded\nactive=inactive\nenabled=enabled\nExecMainStatus=0\n' \
  > "$T/unit-system-live-neverran.service"
# live, inactive, but only just now -> still fine, a oneshot between runs
printf 'LoadState=loaded\nactive=inactive\nenabled=enabled\nExecMainStatus=0\nInactiveEnterTimestamp=%s\n' \
  "$(date '+%a %Y-%m-%d %H:%M:%S %Z')" > "$T/unit-system-live-recent.service"
# a timer that is perfectly healthy while the service it fires fails
printf 'LoadState=loaded\nactive=active\nenabled=enabled\nUnit=rot.service\n' \
  > "$T/unit-user-rot.timer"
printf 'LoadState=loaded\nactive=inactive\nenabled=static\nExecMainStatus=1\nResult=exit-code\n' \
  > "$T/unit-user-rot.service"
# a timer whose service is fine
printf 'LoadState=loaded\nactive=active\nenabled=enabled\nUnit=fine.service\n' \
  > "$T/unit-user-fine.timer"
printf 'LoadState=loaded\nactive=inactive\nenabled=static\nExecMainStatus=0\nResult=success\n' \
  > "$T/unit-user-fine.service"
# still-installed thing that was agreed retiring
printf 'LoadState=loaded\nactive=active\nenabled=enabled\n' > "$T/unit-system-zombie.service"
# a retired unit that came back
printf 'LoadState=loaded\nactive=active\nenabled=enabled\n' > "$T/unit-system-revenant.service"

printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\nLISTEN 0 128 0.0.0.0:8991 0.0.0.0:* users:(("python",pid=1,fd=3))\n' \
  > "$T/ss-out"

touch "$T/home/present-file"
printf 'ssh-ed25519 AAAA old-deploy-key\n' > "$T/home/.ssh/authorized_keys"

# --- throwaway registry: one entry per matrix cell ----------------------
cat > "$T/senechal.json" <<JSON
{
  "estate": { "footprint": [
    { "id": "live-ok",       "host": "testhost", "owner": "o", "kind": "systemd-system-unit", "target": "live-ok.service",       "status": "live" },
    { "id": "live-corpse",   "host": "testhost", "owner": "o", "kind": "systemd-system-unit", "target": "live-corpse.service",   "status": "live",     "retire": "RETIRE-CORPSE" },
    { "id": "live-neverran", "host": "testhost", "owner": "o", "kind": "systemd-system-unit", "target": "live-neverran.service", "status": "live" },
    { "id": "live-recent",   "host": "testhost", "owner": "o", "kind": "systemd-system-unit", "target": "live-recent.service",   "status": "live" },
    { "id": "live-gone",     "host": "testhost", "owner": "o", "kind": "systemd-system-unit", "target": "vanished.service",      "status": "live" },
    { "id": "rot-timer",     "host": "testhost", "owner": "o", "kind": "systemd-user-unit",   "target": "rot.timer",             "status": "live" },
    { "id": "reporter-timer",  "host": "testhost", "owner": "o", "kind": "systemd-user-unit",   "target": "reporter.timer",        "status": "live" },
    { "id": "reporter-solo",   "host": "testhost", "owner": "o", "kind": "systemd-system-unit", "target": "reporter-solo.service", "status": "live" },
    { "id": "noresult",        "host": "testhost", "owner": "o", "kind": "systemd-system-unit", "target": "noresult.service",      "status": "live" },
    { "id": "fine-timer",    "host": "testhost", "owner": "o", "kind": "systemd-user-unit",   "target": "fine.timer",            "status": "live" },
    { "id": "zombie",        "host": "testhost", "owner": "o", "kind": "systemd-system-unit", "target": "zombie.service",        "status": "retiring", "retire": "RETIRE-ZOMBIE" },
    { "id": "done",          "host": "testhost", "owner": "o", "kind": "systemd-system-unit", "target": "vanished.service",      "status": "retiring", "retire": "RETIRE-DONE" },
    { "id": "revenant",      "host": "testhost", "owner": "o", "kind": "systemd-system-unit", "target": "revenant.service",      "status": "retired",  "retire": "RETIRE-REVENANT" },
    { "id": "staydead",      "host": "testhost", "owner": "o", "kind": "systemd-system-unit", "target": "vanished.service",      "status": "retired" },
    { "id": "open-port",     "host": "testhost", "owner": "o", "kind": "listening-port",      "target": "8991",                  "status": "retiring", "retire": "RETIRE-PORT" },
    { "id": "closed-port",   "host": "testhost", "owner": "o", "kind": "listening-port",      "target": "9999",                  "status": "retiring" },
    { "id": "old-file",      "host": "testhost", "owner": "o", "kind": "path",                "target": "$T/home/present-file",  "status": "retiring", "retire": "RETIRE-FILE" },
    { "id": "gone-file",     "host": "testhost", "owner": "o", "kind": "path",                "target": "$T/home/absent-file",   "status": "retiring" },
    { "id": "old-key",       "host": "testhost", "owner": "o", "kind": "authorized-keys",     "target": "old-deploy-key",        "status": "retiring", "retire": "RETIRE-KEY" },
    { "id": "elsewhere",     "host": "otherbox", "owner": "o", "kind": "systemd-system-unit", "target": "remote.service",        "status": "retiring", "retire": "RETIRE-REMOTE" },
    { "id": "weird-kind",    "host": "testhost", "owner": "o", "kind": "haunted-grove",       "target": "x",                     "status": "retiring" },
    { "id": "weird-status",  "host": "testhost", "owner": "o", "kind": "systemd-system-unit", "target": "live-ok.service",       "status": "probably?" }
  ]}
}
JSON

out="$(STUB_DIR="$T" PATH="$T/bin:$PATH" \
       HOME="$T/home" \
       SENECHAL_HOSTNAME=testhost \
       SENECHAL_CONFIG="$T/senechal.json" \
       bash ./dead-config.sh 2>&1)"
rc=$?

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
expect_text() { # a line that must appear somewhere
  if grep -qF "$1" <<< "$out"; then
    printf 'ok:   text %s\n' "$1"
  else
    printf 'MISS: text %s\n' "$1"
    fails=$((fails + 1))
  fi
}

# --- declared live ------------------------------------------------------
expect_line PASS "live-ok -- live as declared"
expect_line WARN "live-corpse -- SUSPECTED DEAD: live-corpse.service is installed, inactive, and last failed (1)"
expect_line WARN "live-neverran -- SUSPECTED DEAD: live-neverran.service is installed but inactive and has no recorded run"
expect_line PASS "live-recent -- live as declared"
expect_line FAIL "live-gone -- declared live but ABSENT"
# the gardien shape: an alive timer whose service dies nightly
expect_line WARN "rot-timer -- SUSPECTED DEAD: rot.timer is active/enabled but rot.service last failed (1)"
expect_line PASS "fine-timer -- live as declared"
# a unit whose exit code IS its report must not read as a corpse: systemd
# already accounted for SuccessExitStatus, so Result is the verdict.
expect_line PASS "reporter-timer -- live as declared"
expect_line PASS "reporter-solo -- live as declared"
# ...but a MISSING verdict falls back to the exit code rather than
# quietly passing everything.
expect_line WARN "noresult -- SUSPECTED DEAD: noresult.service is installed, inactive, and last failed (1)"

# --- declared retiring: nag until gone ----------------------------------
expect_line WARN "zombie -- agreed retiring, STILL INSTALLED"
expect_text "RETIRE-ZOMBIE"
expect_line PASS "done -- retirement complete"
expect_line WARN "open-port -- agreed retiring, STILL INSTALLED: something is listening on 8991"
expect_line PASS "closed-port -- retirement complete (nothing is listening on port 9999)"
expect_line WARN "old-file -- agreed retiring, STILL INSTALLED"
expect_line PASS "gone-file -- retirement complete"
expect_line WARN "old-key -- agreed retiring, STILL INSTALLED: a line labelled 'old-deploy-key' is in"

# --- declared retired ---------------------------------------------------
expect_line FAIL "revenant -- declared RETIRED but it is back"
expect_line PASS "staydead -- retired and still gone"

# --- honest gaps: never silently a pass ---------------------------------
expect_line SKIP "elsewhere (otherbox, owner: o) -- on another host, and this check does not probe remotely yet (senechal#111)"
expect_text "RETIRE-REMOTE"
expect_line SKIP "weird-kind -- no probe implemented for kind 'haunted-grove'"
expect_line SKIP "weird-status -- unrecognised status 'probably?'"

# --- exit contract ------------------------------------------------------
# FAILs present, so severity must land on 1 even though there are plenty
# of WARNs and SKIPs -- 1 > 2 > 3, not numeric order.
if [ "$rc" -ne 1 ]; then
  printf 'MISS: expected rc=1 with FAILs present, got %s\n' "$rc"; fails=$((fails + 1))
else
  printf 'ok:   rc=1 with FAILs present\n'
fi

# --- an empty/unparseable registry is INCOMPLETE, never a clean pass ----
printf '{ "estate": { "footprint": [] } }\n' > "$T/empty.json"
out2="$(PATH="$T/bin:$PATH" HOME="$T/home" SENECHAL_HOSTNAME=testhost \
        STUB_DIR="$T" SENECHAL_CONFIG="$T/empty.json" bash ./dead-config.sh 2>&1)"
rc2=$?
if [ "$rc2" -eq 2 ] && grep -qF "no footprint entries readable" <<< "$out2"; then
  printf 'ok:   empty registry is INCOMPLETE (rc=2), not a pass\n'
else
  printf 'MISS: empty registry gave rc=%s\n' "$rc2"; fails=$((fails + 1))
fi

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'all assertions passed\n'; exit 0
fi
printf '%d assertion(s) failed\n' "$fails"
exit 1
