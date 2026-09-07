#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
REMEDY="$(pwd)/audio-purged-by-snap-removal.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

CFG="$T/senechal.json"
printf '{}\n' > "$CFG"

pass=0; failed=0
check() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
  fi
}
has() { case "$OUT" in *"$1"*) echo yes ;; *) echo no ;; esac; }

STUB="$T/stub"

write_stubs() { # <MISSING> <FORBIDDEN_INSTALLED> <ACTIVE_UNITS> <KNOWN_UNITS> <FAILED_UNITS> <SINKS> <GROUPS_LIST> <AUTO_PKGS> <KPKG_RC> <SVC_PID>
  mkdir -p "$STUB"

  cat > "$STUB/dpkg-query" <<EOF
#!/usr/bin/env bash
pkg="\${!#}"
case "\$pkg" in
  ubuntustudio-desktop|ubuntustudio-audio|ubuntustudio-audio-core)
    case " $2 " in *" \$pkg "*) echo installed; exit 0 ;; esac
    exit 1 ;;
esac
case " $1 " in *" \$pkg "*) exit 1 ;; esac
echo installed
EOF

  cat > "$STUB/apt-mark" <<EOF
#!/usr/bin/env bash
[ "\$1" = showauto ] || exit 0
shift
for p in "\$@"; do
  case " $8 " in *" \$p "*) echo "\$p" ;; esac
done
EOF

  cat > "$STUB/systemctl" <<EOF
#!/usr/bin/env bash
shift
case "\$1" in
  show)
    case " $3 " in *" \$2 "*) echo "${10}" ;; *) echo 0 ;; esac ;;
  is-active)
    unit="\${@: -1}"
    case " $3 " in *" \$unit "*) exit 0 ;; *) exit 1 ;; esac ;;
  is-failed)
    case " $5 " in *" \$2 "*) echo failed ;; *) echo active ;; esac ;;
  cat)
    case " $4 " in *" \$2 "*) exit 0 ;; *) exit 1 ;; esac ;;
  *) exit 0 ;;
esac
EOF

  cat > "$STUB/pactl" <<EOF
#!/usr/bin/env bash
[ "\$1" = list ] || exit 0
i=0
while [ "\$i" -lt "${6:-0}" ]; do echo "sink-\$i"; i=\$((i + 1)); done
EOF

  cat > "$STUB/id" <<EOF
#!/usr/bin/env bash
case "\$1" in
  -nG) echo "${7:-audio plugdev}" ;;
  -un) echo testuser ;;
esac
EOF

  cat > "$STUB/kpackagetool5" <<EOF
#!/usr/bin/env bash
exit "${9:-1}"
EOF

  chmod +x "$STUB"/*
}

V() { # same 10 args as write_stubs
  write_stubs "$@"
  OUT="$(PATH="$STUB:$PATH" SENECHAL_CONFIG="$CFG" \
         bash "$REMEDY" verify -q 2>&1)"
  RC=$?
}

UNITS="pipewire pipewire-pulse wireplumber"

prlimit --pid $$ --rttime=200000:200000
V "" "" "$UNITS" "$UNITS" "" 2 "audio plugdev" "" 1 $$
check "nonzero realtime budget: names the value"      yes \
  "$(has 'realtime budget is 200000, not 0')"

check "healthy: packages present"                     yes "$(has 'PASS  audio packages are installed')"
check "healthy: no firefox-coupling metapackage back"  yes "$(has 'PASS  ubuntustudio-desktop is absent')"
check "healthy: units active"                          yes "$(has 'PASS  pipewire is active')"
check "healthy: sinks present"                         yes "$(has 'PASS  pipewire is serving 2 sink(s)')"
check "healthy: in @audio"                             yes "$(has 'PASS  testuser is in @audio')"
check "healthy: pinned manual"                         yes "$(has 'PASS  installed audio stack is marked manual')"
check "healthy: only the applet check (needs real KDE) fails" 1 \
  "$(printf '%s\n' "$OUT" | grep -c '^  FAIL')"
check "healthy: overall rc is FAIL only via the applet check" 5 "$RC"

V "pipewire wireplumber" "" "$UNITS" "$UNITS" "" 2 "audio plugdev" "" 1 $$
check "missing packages: verify FAILs"                5 "$RC"
check "missing packages: names both"                  yes \
  "$(has 'purged audio packages still missing: pipewire wireplumber')"

V "" "ubuntustudio-desktop" "$UNITS" "$UNITS" "" 2 "audio plugdev" "" 1 $$
check "forbidden metapackage back: verify FAILs"      5 "$RC"
check "forbidden metapackage back: names the risk"    yes \
  "$(has 'ubuntustudio-desktop is back -- it Recommends firefox')"

V "" "" "" "" "" 2 "audio plugdev" "" 1 $$
check "unit does not exist: verify FAILs"             5 "$RC"
check "unit does not exist: says so, not just stopped" yes \
  "$(has 'user unit pipewire does not exist -- the package is gone, not just stopped')"

V "" "" "" "$UNITS" "pipewire" 2 "audio plugdev" "" 1 $$
check "failed unit: verify FAILs"                     5 "$RC"
check "failed unit: names reset-failed"               yes \
  "$(has 'reset-failed pipewire && systemctl --user start pipewire')"

V "" "" "$UNITS" "$UNITS" "" 0 "audio plugdev" "" 1 $$
check "no sinks: verify FAILs"                        5 "$RC"
check "no sinks: says pactl sees nothing"             yes \
  "$(has 'no audio sinks -- pactl sees nothing to play to')"

V "" "" "$UNITS" "$UNITS" "" 2 "plugdev" "" 1 $$
check "not in @audio: verify FAILs"                   5 "$RC"
check "not in @audio: names usermod"                  yes \
  "$(has 'NOT in @audio -- limits.d grants rtprio')"

V "" "" "$UNITS" "$UNITS" "" 2 "audio plugdev" "pipewire" 1 $$
check "still marked auto: verify FAILs"               5 "$RC"
check "still marked auto: names 2026-08-23"           yes \
  "$(has 'a future removal will repeat 2026-08-23')"

prlimit --pid $$ --rttime=0:0
V "" "" "$UNITS" "$UNITS" "" 2 "audio plugdev" "" 1 $$
check "zero realtime budget: verify FAILs"            5 "$RC"
check "zero realtime budget: names the SIGKILL trap"  yes \
  "$(has 'RLIMIT_RTTIME=0 -- the kernel SIGKILLs it')"

OUT="$(PATH="$STUB:$PATH" SENECHAL_CONFIG="$CFG" bash "$REMEDY" 2>&1)"; RC=$?
check "no verb prints usage and exits 1"              1 "$RC"
OUT="$(PATH="$STUB:$PATH" SENECHAL_CONFIG="$CFG" bash "$REMEDY" nonsense 2>&1)"; RC=$?
check "unknown verb exits 1"                          1 "$RC"

# rt_patch: sourced, not subshelled, so check() shares pass/failed above.
RT_T="$T/rt"
mkdir -p "$RT_T"
head -n "$(( $(grep -n '^case ' "$REMEDY" | tail -1 | cut -d: -f1) - 1 ))" \
  "$REMEDY" > "$RT_T/src.sh"
export SENECHAL_SKIP_CONFIG_CHECK=1 XDG_CONFIG_HOME="$RT_T/config"
# shellcheck source=/dev/null
. "$RT_T/src.sh" >/dev/null 2>&1

check "pipewire config maps under XDG_CONFIG_HOME/pipewire" \
  "$RT_T/config/pipewire/pipewire.conf" \
  "$(rt_conf_dst /usr/share/pipewire/pipewire.conf)"
check "wireplumber config maps under XDG_CONFIG_HOME/wireplumber" \
  "$RT_T/config/wireplumber/wireplumber.conf" \
  "$(rt_conf_dst /usr/share/wireplumber/wireplumber.conf)"

cat > "$RT_T/upstream.conf" <<'EOF'
context.modules = [
    { name = libpipewire-module-rt
        args = {
            nice.level    = -11
            rt.prio       = 88
            #rt.time.soft = -1
            #rt.time.hard = -1
        }
        flags = [ ifexists nofail ]
    }
]
EOF
rt_patch "$RT_T/upstream.conf" "$RT_T/out.conf"; rc=$?
check "patching an upstream-shaped config exits 0" 0 "$rc"
check "rt.time.soft is set, not left commented" 1 \
  "$(grep -c '^[[:space:]]*rt\.time\.soft = 200000$' "$RT_T/out.conf")"
check "rt.time.hard is set" 1 \
  "$(grep -c '^[[:space:]]*rt\.time\.hard = 200000$' "$RT_T/out.conf")"
check "RTKit is taken out of the path" 1 \
  "$(grep -c '^[[:space:]]*rtkit\.enabled = false$' "$RT_T/out.conf")"
check "module-rt sets the rlimits itself" 1 \
  "$(grep -c '^[[:space:]]*rlimits\.enabled = true$' "$RT_T/out.conf")"
check "no commented rt.time survives" 0 \
  "$(grep -c '#rt\.time' "$RT_T/out.conf")"
check "the rest of the file is carried through" 1 \
  "$(grep -c 'nice.level    = -11' "$RT_T/out.conf")"

printf 'context.modules = [\n    { name = libpipewire-module-other }\n]\n' \
  > "$RT_T/unpatchable.conf"
rt_patch "$RT_T/unpatchable.conf" "$RT_T/out2.conf"; rc=$?
check "a config with no rt.time lines is refused" 1 "$rc"

check "no write escaped XDG_CONFIG_HOME" 0 \
  "$(find "$RT_T" -name '*.conf' -newer "$RT_T/src.sh" -not -path "$RT_T/*" 2>/dev/null | grep -c .)"

printf '\n%s passed, %s failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
