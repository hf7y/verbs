#!/usr/bin/env bash
# lance-test.sh -- regression test for the same arity-guard exit-code bug
# fixed in `bin/ausculte` 2026-08-01: a leading flag this verb does not
# recognise (`--nonsense`, and `--summon`, which VERB_CAN_SUMMON=0 never
# grants) fell through the `-*) cmd=list` arm to the subcommand listing
# and exited 0 instead of the usage error (2) the shared runtime gives it.
#
# Unlike `ausculte`, `lance`'s subcommands `exec` their backing tool
# directly -- there is no `run_health`-style translation layer, and
# `lance` never calls `verb_blind` anywhere in its own source (checked by
# grep, not assumed). So there is no BLIND-exits-0 case to reproduce here:
# the defect class the task asked about does not exist in this verb,
# because the machinery that would produce a BLIND result does not exist
# in this verb either. That asymmetry with `ausculte` is a real gap
# (`lance` cannot currently report "could not act" as anything other than
# whatever raw code its backing tool happens to return), not a fix --
# see the report, not this file, for that finding.
#
# test/contract-test.sh covers the universal form of the flag bug
# (`--definitely-not-a-real-flag`, `-s`, `-S`). This file adds the
# `--summon` case specific to this verb's own declared position
# (VERB_CAN_SUMMON=0), plus the control that a subcommand's OWN trailing
# flag still reaches its backing tool unmangled -- the concrete regression
# risk of ever making the fix consume every argument through verb_parse
# instead of just the leading one.

set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CMD="${1:-$ROOT/bin/lance}"

pass=0; fail=0
ok() { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }

printf '=== lance: exit-code regression tests\n    command: %s\n\n' "$CMD"

rc() { "$CMD" "$@" >/tmp/lance-test.$$ 2>&1; local r=$?; cat /tmp/lance-test.$$; rm -f /tmp/lance-test.$$; return $r; }

# --- the bug: an unrecognised leading flag must exit 2, not fall into `list`
nonsense_out="$(rc --nonsense)"; nonsense_rc=$?
check "unknown flag: --nonsense exits 2" "$nonsense_rc" 2
case "$nonsense_out" in
  *"subcommands:"*) no "unknown flag: --nonsense fell through to the subcommand list" ;;
  *) ok "unknown flag: --nonsense did not print the subcommand list" ;;
esac

# VERB_CAN_SUMMON=0 here: --summon must be REFUSED, not silently accepted
# into the listing path as just another dash-prefixed argument.
summon_out="$(rc --summon)"; summon_rc=$?
check "--summon (never granted, VERB_CAN_SUMMON=0) exits 2" "$summon_rc" 2
case "$summon_out" in
  *"subcommands:"*) no "--summon fell through to the subcommand list" ;;
  *) ok "--summon did not print the subcommand list" ;;
esac

# --- the control a tautology would miss: a flag this verb DOES claim (per
# its own --help / man page) must keep working.
check "control: --json (a real, documented flag) still exits 0" \
  "$(rc --json >/dev/null 2>&1; printf '%s' "$?")" 0
check "control: --help (a real, documented flag) still exits 0" \
  "$(rc --help >/dev/null 2>&1; printf '%s' "$?")" 0

# --- fully-passing run still exits 0, and a subcommand's own trailing flag
# is not this verb's vocabulary and must still reach the backing tool
# unmangled. Real: `lance browse --where NAME` (see man/lance.1 / tools/
# browse). A fixture stands in for tools/browse so this does not depend on
# a display, a window manager, or senechal.json's window profiles existing
# on the machine running the test.
SANDBOX="$(mktemp -d)"
mkdir -p "$SANDBOX/tools"
cat > "$SANDBOX/tools/browse" <<'EOF'
#!/usr/bin/env bash
printf 'GOT ARGS: %s\n' "$*"
exit 0
EOF
chmod +x "$SANDBOX/tools/browse"

pass_out="$(LANCE_LEGACY_ROOT="$SANDBOX" "$CMD" browse --where gardien 2>&1)"
pass_rc=$?
check "control: fully-passing 'browse --where gardien' still exits 0" "$pass_rc" 0
case "$pass_out" in
  *"GOT ARGS: --where gardien"*) ok "control: '--where gardien' arrived at the backing tool unmangled" ;;
  *) no "control: '--where gardien' did not reach the backing tool: $pass_out" ;;
esac
rm -rf "$SANDBOX"

printf '\n--- lance exit-code regressions: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
