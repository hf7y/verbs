#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
fails=0
t() { if "$@"; then echo "ok   $*"; else echo "FAIL $*"; fails=$((fails+1)); fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/systemd" "$tmp/libexec"
echo '{"watch": []}' > "$tmp/cfg.json"

run() { HOME="$tmp/home" SENECHAL_CONFIG="$tmp/cfg.json" \
        SENECHAL_RUNNER_REPAIR_SYSTEMD_DIR="$tmp/systemd" \
        SENECHAL_LIBEXEC="$tmp/libexec" SENECHAL_SUDO_CMD="" \
        bash "$REPO/remedies/selfdev-runner-boot-repair.sh" "$@" 2>&1; }

out=$(run enable); t [ "$?" != 0 ]
out=$(run verify); rc=$?; t [ "$rc" = 2 ]
t grep -qi "SKIP" <<<"$out"

: > "$tmp/systemd/actions.runner.hf7y-senechal.monkey-senechal.service"
: > "$tmp/systemd/actions.runner.hf7y-wtul.monkey-wtul.service"
: > "$tmp/systemd/some-unrelated.service"   # must be ignored entirely

out=$(run enable); rc=$?
t [ "$rc" = 0 ]
t [ -f "$tmp/libexec/selfdev-runner-refusal-classify.sh" ]
t [ -x "$tmp/libexec/selfdev-runner-refusal-classify.sh" ]
t [ -f "$tmp/systemd/selfdev-runner-repair.service" ]
t [ -f "$tmp/systemd/actions.runner.hf7y-senechal.monkey-senechal.service.d/50-selfdev-runner-boot-repair.conf" ]
t [ -f "$tmp/systemd/actions.runner.hf7y-wtul.monkey-wtul.service.d/50-selfdev-runner-boot-repair.conf" ]
t [ ! -e "$tmp/systemd/some-unrelated.service.d" ]

t grep -q "registration has been deleted from the server" "$tmp/libexec/selfdev-runner-refusal-classify.sh"
t grep -q "selfdev-runner-provision.sh --apply" "$tmp/systemd/selfdev-runner-repair.service"
t grep -q "OnFailure=selfdev-runner-repair.service" "$tmp/systemd/actions.runner.hf7y-senechal.monkey-senechal.service.d/50-selfdev-runner-boot-repair.conf"
t grep -q "ExecStopPost=.*selfdev-runner-refusal-classify.sh %n" "$tmp/systemd/actions.runner.hf7y-senechal.monkey-senechal.service.d/50-selfdev-runner-boot-repair.conf"

out=$(run verify); rc=$?
t [ "$rc" = 0 ]
t grep -q "PASS" <<<"$out"

: > "$tmp/systemd/actions.runner.hf7y-gardien.monkey-gardien.service"
out=$(run verify); rc=$?
t [ "$rc" = 5 ]
t grep -q "gardien" <<<"$out"

out=$(run enable); t [ "$?" = 0 ]
t [ -f "$tmp/systemd/actions.runner.hf7y-gardien.monkey-gardien.service.d/50-selfdev-runner-boot-repair.conf" ]
out=$(run verify); t [ "$?" = 0 ]

cat > "$tmp/systemd/actions.runner.hf7y-wtul.monkey-wtul.service.d/50-selfdev-runner-boot-repair.conf" <<'EOF'
[Service]
OnFailure=something-else.service
EOF
out=$(run verify); rc=$?
t [ "$rc" = 5 ]
t grep -q "wtul" <<<"$out"

out=$(run enable) # re-heal the drifted one first
out=$(run disable)
t [ ! -e "$tmp/libexec/selfdev-runner-refusal-classify.sh" ]
t [ ! -e "$tmp/systemd/selfdev-runner-repair.service" ]
t [ ! -e "$tmp/systemd/actions.runner.hf7y-senechal.monkey-senechal.service.d" ]
t [ ! -e "$tmp/systemd/actions.runner.hf7y-wtul.monkey-wtul.service.d" ]
t [ ! -e "$tmp/systemd/actions.runner.hf7y-gardien.monkey-gardien.service.d" ]
t [ -f "$tmp/systemd/actions.runner.hf7y-senechal.monkey-senechal.service" ]   # the vendor unit itself is untouched
t [ -f "$tmp/systemd/some-unrelated.service" ]                                # never touched at all

[ "$fails" = 0 ] && echo "PASS" || echo "$fails FAILED"
exit $((fails > 0))
