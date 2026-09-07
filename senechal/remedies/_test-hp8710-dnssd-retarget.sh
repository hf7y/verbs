#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="./hp8710-dnssd-retarget.sh"
PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

OLD_URI='ipp://192.168.0.119/ipp/print'
NEW_URI='dnssd://HP%20OfficeJet%20Pro%208710%20%5BF3466A%5D._ipp._tcp.local/?uuid=1c852a4d-b800-1f08-abcd-705a0ff3466a'

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/.config/senechal"
printf '{"estate":{"devices":[]},"health":{}}\n' > "$SCRATCH/.config/senechal/senechal.json"

FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
QUEUES_FILE="$SCRATCH/queues"        # "name<TAB>uri" per line
GROUPS_FILE="$SCRATCH/groups"        # words `id -nG` should print
printf 'lpadmin\n' > "$GROUPS_FILE"

cat > "$FAKEBIN/lpstat" <<EOF
#!/usr/bin/env bash
QUEUES_FILE="$QUEUES_FILE"
case "\$1" in
  -v) name="\$2"; uri="\$(awk -F'\t' -v n="\$name" '\$1==n{print \$2}' "\$QUEUES_FILE" 2>/dev/null)"
      [ -n "\$uri" ] || exit 1
      echo "device for \$name: \$uri"; exit 0 ;;
  *) echo "fake-lpstat: unsupported: \$*" >&2; exit 1 ;;
esac
EOF

cat > "$FAKEBIN/lpadmin" <<EOF
#!/usr/bin/env bash
QUEUES_FILE="$QUEUES_FILE"
case "\$1" in
  -p) name="\$2"; uri="\$4"
      grep -v "^\$name	" "$QUEUES_FILE" > "$QUEUES_FILE.tmp" 2>/dev/null || true
      mv "$QUEUES_FILE.tmp" "$QUEUES_FILE"
      printf '%s\t%s\n' "\$name" "\$uri" >> "\$QUEUES_FILE"
      exit 0 ;;
  *) echo "fake-lpadmin: unsupported: \$*" >&2; exit 1 ;;
esac
EOF

cat > "$FAKEBIN/id" <<EOF
#!/usr/bin/env bash
case "\$1" in
  -nG) tr '\n' ' ' < "$GROUPS_FILE"; echo ;;
  -un) echo testuser ;;
  *) echo "fake-id: unsupported: \$*" >&2; exit 1 ;;
esac
EOF

printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/avahi-resolve-host-name"  # absent by default
chmod +x "$FAKEBIN"/lpstat "$FAKEBIN"/lpadmin "$FAKEBIN"/id "$FAKEBIN"/avahi-resolve-host-name

run() {
  env HOME="$SCRATCH" PATH="$FAKEBIN:$PATH" \
      SENECHAL_CONFIG="$SCRATCH/.config/senechal/senechal.json" \
      "$SCRIPT" "$@"
}

echo "=== enable refuses when the queue does not exist ==="
: > "$QUEUES_FILE"
out="$(run enable 2>&1)"; rc=$?
check "exits nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo 0)" "nonzero"
grep -qF "does not exist" <<<"$out" && ok "names the reason" || bad "silent about why: $out"

echo "=== enable refuses when not in the lpadmin group ==="
printf 'HP8710_BROKEN_K\t%s\n' "$OLD_URI" > "$QUEUES_FILE"
printf 'sudo\n' > "$GROUPS_FILE"
out="$(run enable 2>&1)"; rc=$?
check "exits nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo 0)" "nonzero"
grep -qF "not in the lpadmin group" <<<"$out" && ok "names the reason" || bad "silent about why: $out"
printf 'lpadmin\n' > "$GROUPS_FILE"

echo "=== enable refuses when the queue points somewhere unrecognised ==="
printf 'HP8710_BROKEN_K\tsocket://10.0.0.1:9100\n' > "$QUEUES_FILE"
out="$(run enable 2>&1)"; rc=$?
check "exits nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo 0)" "nonzero"
grep -qF "refusing to guess" <<<"$out" && ok "refuses rather than guessing" || bad "did not refuse: $out"

echo "=== enable retargets from the known old value ==="
printf 'HP8710_BROKEN_K\t%s\n' "$OLD_URI" > "$QUEUES_FILE"
out="$(run enable 2>&1)"; rc=$?
check "exits 0" "$rc" "0"
check "queue now points at the mDNS URI" "$(awk -F'\t' '$1=="HP8710_BROKEN_K"{print $2}' "$QUEUES_FILE")" "$NEW_URI"
grep -qF "print a test page" <<<"$out" && ok "reminds to test-print" || bad "no test-print reminder: $out"

echo "=== enable is idempotent once already retargeted ==="
out="$(run enable 2>&1)"; rc=$?
check "exits 0" "$rc" "0"
grep -qF "nothing to do" <<<"$out" && ok "says nothing to do" || bad "did not recognise it was already done: $out"
check "queue unchanged" "$(awk -F'\t' '$1=="HP8710_BROKEN_K"{print $2}' "$QUEUES_FILE")" "$NEW_URI"

echo "=== verify ==="
printf 'HP8710_BROKEN_K\t%s\n' "$OLD_URI" > "$QUEUES_FILE"
out="$(run verify 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "verify fails while still pinned to the IP" || bad "verify passed while still pinned: $out"
grep -qF "FAIL" <<<"$out" && ok "reports FAIL" || bad "no FAIL line: $out"

printf 'HP8710_BROKEN_K\t%s\n' "$NEW_URI" > "$QUEUES_FILE"
out="$(run verify 2>&1)"; rc=$?
check "verify exits 0 once retargeted" "$rc" "0"

: > "$QUEUES_FILE"
out="$(run verify 2>&1)"; rc=$?
check "verify exits 2 (incomplete/skip) when the queue is absent" "$rc" "2"
grep -qF "SKIP" <<<"$out" && ok "reports SKIP, not a pass or fail" || bad "no SKIP line: $out"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
