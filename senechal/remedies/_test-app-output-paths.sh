#!/usr/bin/env bash
# Tests for remedies/app-output-paths.sh.
#
#   ./_test-app-output-paths.sh
#
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
REMEDY="$(pwd)/app-output-paths.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0; failed=0
check() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
  fi
}

H="$T/home"
CFG="$H/.config/senechal/senechal.json"
APPCFG="$H/.config/cura/5.13/cura.cfg"

write_registry() { # <section>
  mkdir -p "$(dirname "$CFG")"
  cat > "$CFG" <<JSON
{"app_output_paths": {"apps": [
  {"name": "cura", "extension": ".gcode",
   "config_file": "~/.config/cura/5.13/cura.cfg",
   "section": "$1", "key": "dialog_save_path",
   "canonical_dir": "~/Documents/3DPrints"}]}}
JSON
}

# A cura.cfg shaped like the real one: several sections, the save path
# under [local_file], a neighbouring key that must survive untouched.
write_app_cfg() { # <"set"|"unset">
  mkdir -p "$(dirname "$APPCFG")"
  {
    printf '[general]\n'
    printf 'visible_settings = a;b;c\n'
    printf 'last_run_version = 5.13.0\n\n'
    printf '[cura]\n'
    printf 'active_machine = Creality Ender-3 Pro\n\n'
    printf '[local_file]\n'
    [ "$1" = set ] && printf 'dialog_save_path = /home/zach\n'
    printf 'dialog_load_path = \n\n'
    printf '[tool]\n'
  } > "$APPCFG"
}

fresh() { # <"set"|"unset"> [section]
  rm -rf "$H"
  mkdir -p "$H"
  write_registry "${2:-local_file}"
  write_app_cfg "$1"
}

R() { # <verb...>
  OUT="$(HOME="$H" XDG_CONFIG_HOME="$H/.config" SENECHAL_CONFIG="$CFG" \
         SENECHAL_BACKUP_ROOT="$H/.backups" bash "$REMEDY" "$@" 2>&1)"
  RC=$?
}

saved_path() { # what the app would actually read, section-aware
  python3 - "$APPCFG" <<'PY'
import configparser, sys
c = configparser.ConfigParser()
c.read(sys.argv[1])
print(c.get('local_file', 'dialog_save_path', fallback=''))
PY
}

# --- the regression: an unset key must not kill the run ---------------
fresh unset
R verify
check "unset key: verify still prints a report"       yes \
  "$(case "$OUT" in *"app output paths"*) echo yes ;; *) echo no ;; esac)"
check "unset key: verify FAILs by name, not by crash" yes \
  "$(case "$OUT" in *"dialog_save_path=<unset>"*) echo yes ;; *) echo no ;; esac)"
check "unset key: verify exits 1"                     1 "$RC"

R enable
check "unset key: enable does not abort"              0 "$RC"
check "unset key: enable reports the section"         yes \
  "$(case "$OUT" in *"[local_file] dialog_save_path"*) echo yes ;; *) echo no ;; esac)"
check "unset key: the app would now read the new path" \
  "$H/Documents/3DPrints" "$(saved_path)"
R verify
check "unset key: verify passes after enable"         0 "$RC"

# --- the section is load-bearing --------------------------------------
# The registry points at [general]; the key really lives in
# [local_file]. This is the exact row senechal shipped. enable must
# REFUSE rather than create a second copy in [general] that the app
# never reads, and verify must FAIL rather than pass on whichever copy
# it was pointed at.
fresh set general
R enable
check "wrong section: enable refuses"                 yes \
  "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "wrong section: enable names the real section"  yes \
  "$(case "$OUT" in *"local_file"*) echo yes ;; *) echo no ;; esac)"
check "wrong section: nothing was written"            "/home/zach" "$(saved_path)"
check "wrong section: no copy created in [general]"   no \
  "$(grep -A2 '^\[general\]' "$APPCFG" | grep -q dialog_save_path && echo yes || echo no)"
R verify
check "wrong section: verify FAILs"                   1 "$RC"
check "wrong section: verify names the other section" yes \
  "$(case "$OUT" in *"also defined under [local_file]"*) echo yes ;; *) echo no ;; esac)"

# The undetectable half, stated so nobody mistakes it for covered: if
# the key exists in NO section, a wrong registered section cannot be
# caught from the file alone -- enable writes it where it was told and
# verify agrees. Only re-probing the app's own docs/behaviour catches
# that, which is why the registry says each row is hand-checked.
fresh unset general
R enable
check "unset key + wrong section: enable proceeds (nothing to compare)" 0 "$RC"

# --- ordinary case: the key is set, to the wrong value ----------------
fresh set
R verify
check "misconfigured: verify exits 1"                 1 "$RC"
R enable
check "enable exits 0"                                0 "$RC"
check "enable set the real setting"                   "$H/Documents/3DPrints" "$(saved_path)"
check "enable created the canonical dir"              yes \
  "$([ -d "$H/Documents/3DPrints" ] && echo yes || echo no)"
check "enable backed the file up first"               1 \
  "$(find "$H/.backups" -name cura.cfg | wc -l)"

# unrelated settings survive
check "unrelated key in another section survives"     "Creality Ender-3 Pro" \
  "$(python3 -c "
import configparser,sys
c=configparser.ConfigParser(); c.read(sys.argv[1])
print(c.get('cura','active_machine'))" "$APPCFG")"
check "neighbouring key in the SAME section survives" yes \
  "$(grep -q '^dialog_load_path' "$APPCFG" && echo yes || echo no)"
check "the file still parses as INI"                  ok \
  "$(python3 -c "
import configparser,sys
c=configparser.ConfigParser(); c.read(sys.argv[1]); print('ok')" "$APPCFG")"
check "every original section is still there"         4 \
  "$(grep -c '^\[' "$APPCFG")"

# --- idempotency -------------------------------------------------------
R enable
check "second enable says already correct"            yes \
  "$(case "$OUT" in *"already has"*) echo yes ;; *) echo no ;; esac)"
check "second enable makes no second backup"          1 \
  "$(find "$H/.backups" -name cura.cfg | wc -l)"
R verify
check "verify still passes after re-enable"           0 "$RC"

# --- the loose-file witness is a WARN, never a silent pass ------------
touch "$H/CE3PRO_thing.gcode"
R verify
check "loose .gcode in \$HOME: exits 3 (warn), not 0" 3 "$RC"
check "loose .gcode in \$HOME: says so"               yes \
  "$(case "$OUT" in *"still loose directly in"*) echo yes ;; *) echo no ;; esac)"
rm "$H/CE3PRO_thing.gcode"

# --- the canonical dir vanishing is a FAIL, not a pass ----------------
rmdir "$H/Documents/3DPrints"
R verify
check "canonical dir gone: verify exits 1"            1 "$RC"

# --- an app that has never run: SKIP, never a false pass --------------
fresh set
rm "$APPCFG"
R verify
check "no app config at all: exits 2 (could not check)" 2 "$RC"
R enable
check "no app config at all: enable does not crash"   0 "$RC"
check "no app config: enable still made the canonical dir" yes \
  "$([ -d "$H/Documents/3DPrints" ] && echo yes || echo no)"
check "no app config: enable did not invent a config" no \
  "$([ -f "$APPCFG" ] && echo yes || echo no)"

# --- fresh machine: nothing under $HOME at all ------------------------
rm -rf "$H"; mkdir -p "$H"; write_registry local_file
R verify
check "fresh machine: verify exits 2, not 0"          2 "$RC"
R enable
check "fresh machine: enable exits 0"                 0 "$RC"

# --- registry problems are loud ---------------------------------------
printf '{"app_output_paths": {"apps": []}}\n' > "$CFG"
R verify
check "empty registry: exits 2"                       2 "$RC"

printf 'not json\n' > "$CFG"
R verify
check "unparseable config: exits 2"                   2 "$RC"
check "unparseable config: says CANNOT SEE"           yes \
  "$(case "$OUT" in *"CANNOT SEE"*) echo yes ;; *) echo no ;; esac)"

# --- verb contract -----------------------------------------------------
fresh set
R
check "no verb prints usage and exits 64"             64 "$RC"
R nonsense
check "unknown verb exits 64"                         64 "$RC"

printf '\n%s passed, %s failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
