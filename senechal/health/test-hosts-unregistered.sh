#!/usr/bin/env bash
# Test harness for hosts-unregistered.sh. Runs the real script against a
# throwaway ssh config and a throwaway senechal.json, so it never reads
# the real ~/.ssh/config or estate registry.
#
# Exit: 0 all assertions pass / 1 any assertion failed.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# --- ssh config fixture --------------------------------------------------
# declared: matches estate.devices[].name -> must NOT be flagged
# declared-by-ssh-host: matches devices[].ssh_host, not .name -> must NOT
#   be flagged (dexter's real entry is exactly this shape)
# undeclared: no matching device row at all -> must be flagged
# wildcard: not a real single host -> must be skipped entirely
# multi-name line: both names on one "Host a b" line are candidates
cat > "$T/ssh_config" <<'EOF'
Host declaredhost
    HostName 10.0.0.1

Host declared-by-alias
    HostName 10.0.0.2

Host undeclaredhost
    HostName 10.0.0.3

Host *.example.com
    User zach

Host multia multib
    HostName 10.0.0.4

Host github-someproject-deploy
    HostName github.com
    User git
EOF

# --- senechal.json fixture -------------------------------------------------
# declaredhost matched by device name.
# "alias-target" matched by ssh_host, mimicking declared-by-alias.
# footprint: one entry on a device host (fine), one on an undeclared host
# (must be flagged).
cat > "$T/senechal.json" <<'JSON'
{
  "estate": {
    "devices": [
      { "name": "declaredhost", "kind": "laptop", "addr": "10.0.0.1", "reach": "ssh", "owner": "zach", "expect": "intermittent", "ssh_host": "", "os": "linux" },
      { "name": "alias-target", "kind": "vm", "addr": "10.0.0.2", "reach": "ssh", "owner": "zach", "expect": "always-on", "ssh_host": "declared-by-alias", "os": "linux" }
    ],
    "footprint": [
      { "id": "fp-ok", "host": "declaredhost", "owner": "zach", "kind": "systemd-user-unit", "target": "x.service", "status": "live", "retire": "", "notes": "" },
      { "id": "fp-bad", "host": "footprint-only-host", "owner": "zach", "kind": "systemd-user-unit", "target": "y.service", "status": "live", "retire": "", "notes": "" }
    ]
  }
}
JSON

run() {
  SENECHAL_CONFIG="$T/senechal.json" \
  SENECHAL_SSH_CONFIG="$T/ssh_config" \
  bash ./hosts-unregistered.sh "$@"
}

out="$(run 2>&1)"
rc=$?

fails=0
expect_line() { # expect_line <marker> <substring...>
  local marker="$1"; shift
  if grep -qF "  $marker  $*" <<< "$out"; then
    printf 'ok:   %s  %s\n' "$marker" "$*"
  else
    printf 'FAIL: expected "  %s  %s" in output\n' "$marker" "$*"
    fails=$((fails + 1))
  fi
}
expect_absent() { # expect_absent <substring...> -- must not appear anywhere
  if grep -qF "$*" <<< "$out"; then
    printf 'FAIL: did not expect "%s" in output\n' "$*"
    fails=$((fails + 1))
  else
    printf 'ok:   absent  %s\n' "$*"
  fi
}

expect_line "PASS" "declaredhost -- has an estate.devices[] row"
expect_line "PASS" "declared-by-alias -- has an estate.devices[] row"
expect_line "FAIL" "undeclaredhost has an ssh config stanza but no estate.devices[] row"
expect_line "FAIL" "multia has an ssh config stanza but no estate.devices[] row"
expect_line "FAIL" "multib has an ssh config stanza but no estate.devices[] row"
expect_absent "example.com"
expect_absent "github-someproject-deploy"
expect_line "PASS" "declaredhost -- has an estate.devices[] row"
expect_line "FAIL" "footprint names host 'footprint-only-host' but estate.devices[] has no matching row"

if [ "$rc" -ne 1 ]; then
  printf 'FAIL: expected exit 1 (undeclared hosts present), got %s\n' "$rc"
  fails=$((fails + 1))
else
  printf 'ok:   exit code 1\n'
fi

# --- second run: everything declared -> must pass clean -------------------
cat > "$T/senechal-clean.json" <<'JSON'
{
  "estate": {
    "devices": [
      { "name": "declaredhost", "kind": "laptop", "addr": "10.0.0.1", "reach": "ssh", "owner": "zach", "expect": "intermittent", "ssh_host": "", "os": "linux" },
      { "name": "alias-target", "kind": "vm", "addr": "10.0.0.2", "reach": "ssh", "owner": "zach", "expect": "always-on", "ssh_host": "declared-by-alias", "os": "linux" },
      { "name": "undeclaredhost", "kind": "misc", "addr": "10.0.0.3", "reach": "ssh", "owner": "zach", "expect": "intermittent", "ssh_host": "", "os": "linux" },
      { "name": "multia", "kind": "misc", "addr": "10.0.0.4", "reach": "ssh", "owner": "zach", "expect": "intermittent", "ssh_host": "", "os": "linux" },
      { "name": "multib", "kind": "misc", "addr": "10.0.0.4", "reach": "ssh", "owner": "zach", "expect": "intermittent", "ssh_host": "", "os": "linux" }
    ],
    "footprint": [
      { "id": "fp-ok", "host": "declaredhost", "owner": "zach", "kind": "systemd-user-unit", "target": "x.service", "status": "live", "retire": "", "notes": "" }
    ]
  }
}
JSON
clean_out="$(SENECHAL_CONFIG="$T/senechal-clean.json" SENECHAL_SSH_CONFIG="$T/ssh_config" bash ./hosts-unregistered.sh)"
clean_rc=$?
if [ "$clean_rc" -ne 0 ]; then
  printf 'FAIL: expected exit 0 on a fully-declared fixture, got %s\n%s\n' "$clean_rc" "$clean_out"
  fails=$((fails + 1))
else
  printf 'ok:   exit code 0 on fully-declared fixture\n'
fi

# --- third run: unreadable ssh config -> SKIP that source, not a crash ---
skip_out="$(SENECHAL_CONFIG="$T/senechal-clean.json" SENECHAL_SSH_CONFIG="$T/does-not-exist" bash ./hosts-unregistered.sh)"
skip_rc=$?
if grep -qF "SKIP  $T/does-not-exist not readable" <<< "$skip_out" && [ "$skip_rc" -eq 2 ]; then
  printf 'ok:   missing ssh config -> SKIP + exit 2\n'
else
  printf 'FAIL: expected SKIP + exit 2 for a missing ssh config, got rc=%s\n%s\n' "$skip_rc" "$skip_out"
  fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then
  echo "test-hosts-unregistered: all assertions passed"
  exit 0
else
  echo "test-hosts-unregistered: $fails assertion(s) failed"
  exit 1
fi
