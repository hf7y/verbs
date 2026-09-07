#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/lib" "$tmp/remedies"
cp "$HERE/../lib/common.sh" "$tmp/lib/"
cp "$HERE/verify-all.sh" "$tmp/remedies/"

fixture() {
  cat > "$tmp/remedies/$1" <<EOF
#!/usr/bin/env bash
HOSTS=($2)
REACHES=($3)
case "\$1" in
  verify) echo "EXECUTED:$1"; exit 0 ;;
esac
EOF
  chmod +x "$tmp/remedies/$1"
}

fixture local-match.sh    "here"  ""
fixture wrong-host.sh     "there" ""
fixture reaches-remote.sh "there" "ssh"

run() { SENECHAL_HOSTNAME=here SENECHAL_SKIP_CONFIG_CHECK=1 bash "$tmp/remedies/verify-all.sh" "$@"; }

fails=0
out="$(run)"; rc=$?
check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi
}

check "a remedy whose HOSTS matches this host runs (#637)" \
  '[[ "$out" == *"local-match.sh (exit 0)"* ]]'
check "a remedy for a different host with no REACHES is skipped, not run (#637)" \
  '[[ "$out" == *"wrong-host.sh (exit 2)"* && "$out" != *"EXECUTED:wrong-host.sh"* ]]'
check "a remedy for a different host that declares REACHES still runs (#637)" \
  '[[ "$out" == *"reaches-remote.sh (exit 0)"* ]]'
check "the skip is never read as a pass (aggregate exit reflects the worst, here incomplete)" \
  '[ "$rc" = 2 ]'

echo "-- mute (remedies/verify-all.muted, MUTED-CHECKS.md)"
tmp2="$(mktemp -d)"; trap 'rm -rf "$tmp" "$tmp2"' EXIT
mkdir -p "$tmp2/lib" "$tmp2/remedies"
cp "$HERE/../lib/common.sh" "$tmp2/lib/"
cp "$HERE/verify-all.sh" "$tmp2/remedies/"

mkfix() {  # mkfix <dir> <name> <output> <rc>
  cat > "$1/remedies/$2" <<EOF
#!/usr/bin/env bash
HOSTS=(here)
REACHES=()
case "\$1" in
  verify) echo "$3"; exit $4 ;;
esac
EOF
  chmod +x "$1/remedies/$2"
}

mkfix "$tmp2" clean.sh      "clean"            0
mkfix "$tmp2" muted-fail.sh "MUTED-FAIL-OUTPUT" 5
printf 'muted-fail.sh\thf7y/senechal#1\ttest reason\n' > "$tmp2/remedies/verify-all.muted"

run2() { SENECHAL_HOSTNAME=here SENECHAL_SKIP_CONFIG_CHECK=1 bash "$tmp2/remedies/verify-all.sh" "$@"; }

out2="$(run2)"; rc2=$?
check "a muted FAIL still runs and prints in the full report" \
  '[[ "$out2" == *"muted-fail.sh (exit 5, MUTED"* && "$out2" == *"MUTED-FAIL-OUTPUT"* ]]'
check "a muted FAIL does not become the aggregate worst exit" \
  '[ "$rc2" = 0 ]'
check "a muted FAIL is named in the muted-not-surfaced summary" \
  '[[ "$out2" == *"muted, not surfaced:"*"muted-fail.sh"* ]]'

out2q="$(run2 -q)"; rc2q=$?
check "-q stays silent when the only bad exit is a muted one" \
  '[ -z "$out2q" ] && [ "$rc2q" = 0 ]'

mkfix "$tmp2" muted-fail.sh "now passes" 0
out2p="$(run2)"
check "a muted entry that starts passing is flagged stale, not forgiven silently" \
  '[[ "$out2p" == *"mute entry is stale"* ]]'

[ "$fails" = 0 ] && echo "PASS" || echo "$fails FAILED"
exit $((fails > 0))
