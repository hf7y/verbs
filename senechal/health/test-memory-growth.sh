#!/usr/bin/env bash
# Test harness for memory-growth.sh. PATH-stubs `ps` (so the two samples
# are scripted, not real) and `sleep` (so the window is instant), which
# makes every verdict deterministic and the suite fast.
#
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat > "$T/bin/ps" <<'STUB'
#!/usr/bin/env bash
n=$(cat "$T_DIR/count" 2>/dev/null || echo 0)
n=$((n + 1)); echo "$n" > "$T_DIR/count"
cat "$T_DIR/ps-$n"
STUB

# sleep must not actually sleep, or the suite takes as long as a window.
cat > "$T/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$T/bin/ps" "$T/bin/sleep"

fails=0
run() { # run <label> <before-ps> <after-ps> <min_kb>; echoes exit code
  printf '%s\n' "$2" > "$T/ps-1"
  printf '%s\n' "$3" > "$T/ps-2"
  rm -f "$T/count"
  T_DIR="$T" PATH="$T/bin:$PATH" \
    bash ./memory-growth.sh 5 "$4" > "$T/out-$1" 2>&1
  echo "$?"
}

check() { # check <label> <expected-rc> <actual-rc> <expected-substring>
  local label="$1" want_rc="$2" got_rc="$3" want_txt="$4"
  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL $label: expected rc $want_rc, got $got_rc"; cat "$T/out-$label"; fails=$((fails + 1)); return
  fi
  if ! grep -q -- "$want_txt" "$T/out-$label"; then
    echo "FAIL $label: output missing '$want_txt'"; cat "$T/out-$label"; fails=$((fails + 1)); return
  fi
  echo "ok   $label"
}

# --- flat RSS is a PASS, not a leak. This is the row that matters:
# settled-large must never be reported as growing.
rc=$(run flat "100 338228 kded5
200  10000 kitty" "100 338228 kded5
200  10000 kitty" 2048)
check flat 0 "$rc" "PASS: no process grew"

# --- growth past the threshold is RC_WARN (3), naming the process.
rc=$(run grew "100 100000 leaky
200  10000 kitty" "100 200000 leaky
200  10000 kitty" 2048)
check grew 3 "$rc" "leaky"

# --- growth BELOW the threshold stays quiet, so the check does not cry
# wolf over ordinary churn.
rc=$(run under "100 100000 quiet" "100 100500 quiet" 2048)
check under 0 "$rc" "PASS: no process grew"

# --- biggest GROWTH sorts first, even when a different process has the
# larger absolute RSS. This is the bug the first draft shipped with.
rc=$(run order "100 900000 big_but_stable
200  10000 small_but_growing" "100 910000 big_but_stable
200 500000 small_but_growing" 2048)
if [ "$rc" = 3 ] && [ "$(sed -n 2p "$T/out-order" | awk '{print $2}')" = "small_but_growing" ]; then
  echo "ok   order"
else
  echo "FAIL order: expected small_but_growing listed first"; cat "$T/out-order"; fails=$((fails + 1))
fi

# --- a comm containing spaces must not shift the columns or truncate
# the label ("Isolated Web Co" is a real Firefox process name).
rc=$(run spaces "100 100000 Isolated Web Co" "100 200000 Isolated Web Co" 2048)
check spaces 3 "$rc" "Isolated_Web_Co"

# --- a process that appears only in the second sample is skipped rather
# than counted as infinite growth.
rc=$(run newproc "100 100000 old" "100 100000 old
300  50000 newborn" 2048)
check newproc 0 "$rc" "PASS: no process grew"

if [ "$fails" -eq 0 ]; then echo "PASS: all memory-growth.sh assertions"; exit 0; fi
echo "FAIL: $fails assertion(s)"; exit 1
