#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
export SENECHAL_SKIP_CONFIG_CHECK=1
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

new_scratch_repo() {
  local root="$1"
  mkdir -p "$root/remedies" "$root/.githooks" "$root/lib"
  cp ./git-push-guard.sh "$root/remedies/"
  cp ../lib/common.sh "$root/lib/"
  cp ../.githooks/pre-push "$root/.githooks/"
  chmod +x "$root/.githooks/pre-push" "$root/remedies/git-push-guard.sh"
  git -C "$root" init --quiet
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
new_scratch_repo "$TMP_ROOT"

out="$(cd "$TMP_ROOT/remedies" && ./git-push-guard.sh enable 2>&1)"; rc=$?
check "#467: enable from a /tmp tree exits nonzero" "$rc" "1"
printf '%s' "$out" | grep -q "temporary directory" && ok "#467: refusal names the reason" || bad "#467: no ephemeral-path message ($out)"
current="$(git -C "$TMP_ROOT" config --local --get core.hooksPath || true)"
[ -z "$current" ] && ok "#467: core.hooksPath left unset in the ephemeral tree" || bad "#467: core.hooksPath was set to '$current' anyway"

NONTMP_ROOT="$(mktemp -d -p "$HOME")"
trap 'rm -rf "$TMP_ROOT" "$NONTMP_ROOT"' EXIT
new_scratch_repo "$NONTMP_ROOT"

out="$(cd "$NONTMP_ROOT/remedies" && ./git-push-guard.sh enable 2>&1)"; rc=$?
check "enable from a real checkout exits 0" "$rc" "0"
current="$(git -C "$NONTMP_ROOT" config --local --get core.hooksPath || true)"
check "core.hooksPath set to .githooks" "$current" ".githooks"

out="$(cd "$NONTMP_ROOT/remedies" && ./git-push-guard.sh verify -q)"; rc=$?
check "verify passes after a real enable" "$rc" "0"

git -C "$NONTMP_ROOT" config --local core.hooksPath "$NONTMP_ROOT/.githooks"
out="$(cd "$NONTMP_ROOT/remedies" && ./git-push-guard.sh verify 2>&1)"; rc=$?
check "an absolute hooksPath that resolves right WARNs, not FAILs" "$rc" "3"
case "$out" in *"a push to main is refused"*) ok "and the push is still refused" ;;
  *) bad "the behavioural check stopped passing: $out" ;; esac

git -C "$NONTMP_ROOT" config --local core.hooksPath /nonexistent/hooks
out="$(cd "$NONTMP_ROOT/remedies" && ./git-push-guard.sh verify 2>&1)"; rc=$?
check "a hooksPath pointing elsewhere still FAILs" "$rc" "5"

echo "git-push-guard test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
