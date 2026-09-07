#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SCRIPT="./print-black-via-colour.sh"
PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/.config/senechal"
printf '{"estate":{"devices":[]},"health":{}}\n' > "$SCRATCH/.config/senechal/senechal.json"

FAKEBIN="$SCRATCH/fakebin"  # fake CUPS: a flat queue table + default-file stand in for cupsd
mkdir -p "$FAKEBIN"
QUEUES_FILE="$SCRATCH/queues"        # "name<TAB>uri" per line
DEFAULT_FILE="$SCRATCH/default"
printf 'HP8710_BROKEN_K\tsocket://10.0.0.1:9100\n' > "$QUEUES_FILE"
: > "$DEFAULT_FILE"

cat > "$FAKEBIN/lpstat" <<EOF
#!/usr/bin/env bash
QUEUES_FILE="$QUEUES_FILE"; DEFAULT_FILE="$DEFAULT_FILE"
case "\$1" in
  -v) name="\$2"; uri="\$(awk -F'\\t' -v n="\$name" '\$1==n{print \$2}' "\$QUEUES_FILE")"
      [ -n "\$uri" ] || exit 1
      echo "device for \$name: \$uri"; exit 0 ;;
  -r) exit 0 ;;
  -d) d="\$(cat "\$DEFAULT_FILE")"
      [ -n "\$d" ] && echo "system default destination: \$d"
      exit 0 ;;
  *) echo "fake-lpstat: unsupported: \$*" >&2; exit 1 ;;
esac
EOF

cat > "$FAKEBIN/lpadmin" <<EOF
#!/usr/bin/env bash
QUEUES_FILE="$QUEUES_FILE"
case "\$1" in
  -p) name="\$2"; uri="\$4"
      grep -qF "\$name\$(printf '\\t')" "\$QUEUES_FILE" 2>/dev/null && exit 0
      printf '%s\\t%s\\n' "\$name" "\$uri" >> "\$QUEUES_FILE"; exit 0 ;;
  -x) name="\$2"
      grep -vF "\$name\$(printf '\\t')" "\$QUEUES_FILE" > "\$QUEUES_FILE.tmp" 2>/dev/null
      mv "\$QUEUES_FILE.tmp" "\$QUEUES_FILE"; exit 0 ;;
  *) echo "fake-lpadmin: unsupported: \$*" >&2; exit 1 ;;
esac
EOF

cat > "$FAKEBIN/lpoptions" <<EOF
#!/usr/bin/env bash
DEFAULT_FILE="$DEFAULT_FILE"
case "\$1" in
  -d) echo "\$2" > "\$DEFAULT_FILE"; exit 0 ;;
  *) echo "fake-lpoptions: unsupported: \$*" >&2; exit 1 ;;
esac
EOF

printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/cupsenable"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/cupsaccept"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/chown"
printf '#!/usr/bin/env bash\ncase "$1 $2" in\n  restart\\ cups) exit 0 ;;\nesac\nexit 0\n' > "$FAKEBIN/systemctl"

REAL_PYTHON3="$(command -v python3)"  # stub only the numpy/PIL check do_verify needs
cat > "$FAKEBIN/python3" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"import numpy, PIL"*) exit 0 ;;
  *) exec "$REAL_PYTHON3" "\$@" ;;
esac
EOF
chmod +x "$FAKEBIN"/lpstat "$FAKEBIN"/lpadmin "$FAKEBIN"/lpoptions \
         "$FAKEBIN"/cupsenable "$FAKEBIN"/cupsaccept "$FAKEBIN"/chown \
         "$FAKEBIN"/systemctl "$FAKEBIN"/python3

run() {
  env HOME="$SCRATCH" PATH="$FAKEBIN:$PATH" \
      SENECHAL_CONFIG="$SCRATCH/.config/senechal/senechal.json" \
      SENECHAL_BACKUP_ROOT="$SCRATCH/backups" \
      SENECHAL_SUDO_CMD="" \
      SENECHAL_K2C_BACKEND="$SCRATCH/backend" \
      SENECHAL_K2C_TOOL="$SCRATCH/tool" \
      SENECHAL_K2C_STATE_DIR="$SCRATCH/state" \
      "$SCRIPT" "$@"
}

echo "=== enable ==="
out="$(run enable 2>&1)"; rc=$?
check "enable exits 0" "$rc" "0"
[ -x "$SCRATCH/tool" ]        && ok "tool installed"           || bad "tool missing"
[ -e "$SCRATCH/backend" ]     && ok "backend installed"        || bad "backend missing"
[ -d "$SCRATCH/state" ]       && ok "state dir created"        || bad "state dir missing"
grep -qF "HP8710_K2CMY	k2c:/HP8710_BROKEN_K" "$QUEUES_FILE" && ok "queue created pointing at the broken-K queue" || bad "queue not created correctly"
check "default destination set to the new queue" "$(cat "$DEFAULT_FILE")" "HP8710_K2CMY"

echo "=== disable ==="
out="$(run disable 2>&1)"; rc=$?
check "disable exits 0" "$rc" "0"
[ -e "$SCRATCH/tool" ]     && bad "tool survived disable"     || ok "tool removed by disable"
[ -e "$SCRATCH/backend" ]  && bad "backend survived disable"  || ok "backend removed by disable"
[ -e "$SCRATCH/state" ]    && bad "state dir survived disable" || ok "state dir removed by disable"
grep -qF "HP8710_K2CMY" "$QUEUES_FILE" && bad "queue survived disable" || ok "queue removed by disable"
grep -q "did NOT undo" <<<"$out" && ok "disable is honest about what it left alone" || bad "disable output missing the not-undone caveat"

echo "=== disable again: idempotent, no error on an already-clean tree ==="
check "second disable exits 0" "$(run disable >/dev/null 2>&1; echo $?)" "0"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
