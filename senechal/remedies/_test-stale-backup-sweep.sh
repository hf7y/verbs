#!/usr/bin/env bash
# Tests remedies/stale-backup-sweep.sh against a throwaway HOME and a
# stubbed `snap`/`date` on PATH -- never the real machine, never sudo.
#
# The tests that matter most are the two that are not about exit codes:
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

SCRIPT="$PWD/stale-backup-sweep.sh"

pass=0; fail=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi
}

# A HOME holding every path the script knows about, so a run has
# something to find. $1: today's date for the stubbed `date`.
make_home() {
  local h; h="$(mktemp -d)"
  mkdir -p "$h/.claude/backups" "$h/.config/senechal" "$h/.config/gardien" \
           "$h/.config/nicotine" "$h/.local/share" "$h/.ssh" "$h/Downloads" \
           "$h/Downloads/thunderbird.tmp" "$h/.senechal-remedy-backups" \
           "$h/.mozilla/firefox/6z5w2rl8.default" \
           "$h/chromium-migration-2026-08-15" \
           "$h/chromium-profile-backup-20260815" \
           "$h/.local/share/Trash"
  : >"$h/.claude/settings.json.bak"
  : >"$h/.config/senechal/senechal.json.senechal-backup.20260805-234315"
  : >"$h/.config/gardien/garde.json.senechal-backup.20260813-112337"
  : >"$h/.config/gardien/garde.json.senechal-backup.20260813-110900"
  : >"$h/.local/share/user-places.xbel.bak"
  : >"$h/.config/nicotine/config.old"
  : >"$h/.ssh/known_hosts.old"
  : >"$h/Downloads/backup_codes.txt"
  : >"$h/.mozilla/firefox/6z5w2rl8.default/domain_to_categories.sqlite-journal"
  ln -s "$h/snapdir" "$h/.config/chromium"
  # One remedy backup well past the 30-day window, one from today.
  mkdir -p "$h/.senechal-remedy-backups/20250101-000000" \
           "$h/.senechal-remedy-backups/fresh"
  touch -d '2025-01-01' "$h/.senechal-remedy-backups/20250101-000000"
  echo "$h"
}

# $1: HOME, $2: date to report, $3: chromium snap present (yes/no)
stub_path() {
  local s; s="$(mktemp -d)"
  cat >"$s/date" <<EOF
#!/usr/bin/env bash
[ "\$1" = "+%F" ] && { echo "$2"; exit 0; }
exec /usr/bin/date "\$@"
EOF
  cat >"$s/snap" <<EOF
#!/usr/bin/env bash
[ "\$1" = list ] || exit 0
[ "${3:-no}" = yes ] && exit 0
exit 1
EOF
  chmod +x "$s"/*
  echo "$s"
}

run() { # run <verb> <home> <date> <snap-present> [args...]
  local verb="$1" h="$2" d="$3" sp="$4"; shift 4
  local s; s="$(stub_path "$h" "$d" "$sp")"
  env -i HOME="$h" PATH="$s:/usr/bin:/bin" \
      SENECHAL_SKIP_CONFIG_CHECK=1 \
      SENECHAL_CONFIG="$h/nonexistent.json" \
      bash "$SCRIPT" "$verb" "$@" >/dev/null 2>&1
  local rc=$?
  rm -rf "$s"
  return $rc
}

echo "stale-backup-sweep"

# --- verify, dirty tree ------------------------------------------------
H="$(make_home)"
run verify "$H" 2026-08-30 yes -q; rc=$?
check "verify FAILs while the junk is present" 1 "$rc"

# --- enable then verify, past the hold date ----------------------------
run enable "$H" 2026-08-30 no
run verify "$H" 2026-08-30 no -q; rc=$?
check "verify WARNs after enable (2FA file still there)" 3 "$rc"

check "removed .claude/backups"        absent "$([ -e "$H/.claude/backups" ] && echo present || echo absent)"
check "removed known_hosts.old"        absent "$([ -e "$H/.ssh/known_hosts.old" ] && echo present || echo absent)"
check "removed thunderbird.tmp"        absent "$([ -e "$H/Downloads/thunderbird.tmp" ] && echo present || echo absent)"
check "removed the chromium symlink"   absent "$([ -L "$H/.config/chromium" ] && echo present || echo absent)"
check "removed migration staging"      absent "$([ -e "$H/chromium-migration-2026-08-15" ] && echo present || echo absent)"
check "removed profile backup"         absent "$([ -e "$H/chromium-profile-backup-20260815" ] && echo present || echo absent)"
check "pruned the 30-day-old backup"   absent "$([ -e "$H/.senechal-remedy-backups/20250101-000000" ] && echo present || echo absent)"

# The whole point of NEVER_DELETE, and of keeping an undo path.
check "KEPT backup_codes.txt"          present "$([ -e "$H/Downloads/backup_codes.txt" ] && echo present || echo absent)"
check "KEPT the fresh remedy backup"   present "$([ -e "$H/.senechal-remedy-backups/fresh" ] && echo present || echo absent)"
check "KEPT Trash"                     present "$([ -e "$H/.local/share/Trash" ] && echo present || echo absent)"

# --- re-running enable is safe ----------------------------------------
run enable "$H" 2026-08-30 no; rc=$?
check "enable is safe to re-run" 0 "$rc"
rm -rf "$H"

# --- the hold: before KEEP_UNTIL the Chromium data must survive --------
H="$(make_home)"
run enable "$H" 2026-08-16 yes
check "held migration staging before KEEP_UNTIL" present \
  "$([ -e "$H/chromium-migration-2026-08-15" ] && echo present || echo absent)"
check "held profile backup before KEEP_UNTIL" present \
  "$([ -e "$H/chromium-profile-backup-20260815" ] && echo present || echo absent)"
check "still swept the non-Chromium junk" absent \
  "$([ -e "$H/.ssh/known_hosts.old" ] && echo present || echo absent)"
run verify "$H" 2026-08-16 yes -q; rc=$?
check "held Chromium data is not a verify FAIL" 3 "$rc"

# --- --force overrides the hold ---------------------------------------
run enable "$H" 2026-08-16 no --force
check "--force removes the held data" absent \
  "$([ -e "$H/chromium-migration-2026-08-15" ] && echo present || echo absent)"
rm -rf "$H"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
