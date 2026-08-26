#!/usr/bin/env bash
# Test harness for the alert-severity gate (lib/common.sh's
# should_alert) and remedies/estate-health-timer.sh's enable/verify/
# disable verbs. Everything runs against a throwaway HOME and a
# throwaway senechal.json -- no unit is ever installed into the real
# ~/.config/systemd/user, and no notification is ever sent.
#
# Exit: 0 all assertions pass / 1 any assertion failed.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO="$(cd .. && pwd)"

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

write_cfg() { # <alert_min_severity value, or "" to omit> [interval]
  local sev="$1" interval="${2:-1h}"
  if [ -n "$sev" ]; then
    printf '{"health": {"alert_min_severity": "%s", "check_interval": "%s"}}\n' \
      "$sev" "$interval" > "$T/senechal.json"
  else
    printf '{"health": {"check_interval": "%s"}}\n' "$interval" > "$T/senechal.json"
  fi
}

# --- should_alert: the full fail/incomplete/warn matrix per threshold ---
alerts() { # <sev> <fail> <incomplete> <warn> -> "yes"/"no"
  write_cfg "$1"
  SENECHAL_CONFIG="$T/senechal.json" bash -c \
    ". '$REPO/lib/common.sh'; should_alert $2 $3 $4" 2>/dev/null \
    && echo yes || echo no
}

# default ("warn"): fail or warn pages; incomplete-only does not
check "default: clean run is silent"        no  "$(alerts '' 0 0 0)"
check "default: fail pages"                 yes "$(alerts '' 1 0 0)"
check "default: warn pages"                 yes "$(alerts '' 0 0 1)"
check "default: incomplete-only is silent"  no  "$(alerts '' 0 3 0)"
check "default: fail+incomplete pages"      yes "$(alerts '' 1 2 0)"
check "explicit warn == default"            no  "$(alerts warn 0 5 0)"
check "explicit warn: warn pages"           yes "$(alerts warn 0 1 2)"

# "fail": only a real failure pages
check "fail: warn is silent"                no  "$(alerts fail 0 0 4)"
check "fail: incomplete is silent"          no  "$(alerts fail 0 4 0)"
check "fail: warn+incomplete still silent"  no  "$(alerts fail 0 2 2)"
check "fail: fail pages"                    yes "$(alerts fail 1 0 0)"

# "incomplete": the loudest setting -- any non-PASS run pages
check "incomplete: incomplete-only pages"   yes "$(alerts incomplete 0 1 0)"
check "incomplete: warn pages"              yes "$(alerts incomplete 0 0 1)"
check "incomplete: clean run still silent"  no  "$(alerts incomplete 0 0 0)"

# a typo must not silently disable alerting -- it falls back to default
check "typo falls back to warn (warn pages)" yes "$(alerts wrn 0 0 1)"
check "typo falls back to warn (incomplete silent)" no "$(alerts wrn 0 1 0)"
write_cfg wrn
typo_msg="$(SENECHAL_CONFIG="$T/senechal.json" bash -c \
  ". '$REPO/lib/common.sh'; should_alert 0 1 0" 2>&1 >/dev/null)"
case "$typo_msg" in
  *unrecognised*) check "typo warns loudly on stderr" yes yes ;;
  *) check "typo warns loudly on stderr" yes "no ($typo_msg)" ;;
esac

# a caller bug (non-numeric counts) must page, not silently swallow
write_cfg ''
check "non-numeric counts alert anyway" yes \
  "$(SENECHAL_CONFIG="$T/senechal.json" bash -c \
     ". '$REPO/lib/common.sh'; should_alert x 0 0" 2>/dev/null && echo yes || echo no)"
check "empty counts are a clean run, not a bug" no \
  "$(SENECHAL_CONFIG="$T/senechal.json" bash -c \
     ". '$REPO/lib/common.sh'; should_alert" 2>/dev/null && echo yes || echo no)"

# --- _alert_owners: parse the Owner: clause without being fooled by a
# comma embedded inside a role note -------------------------------------
owners() { # <finding line> -> space-joined owner list
  SENECHAL_SKIP_CONFIG_CHECK=1 bash -c \
    ". '$REPO/lib/common.sh'; _alert_owners '$1'" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}
check "no Owner: clause -> no external owners (senechal's own)" "" \
  "$(owners '  WARN  / at 94%, 30G free')"
check "senechal alone in the tag -> empty (self, not external)" "" \
  "$(owners '  WARN  something. Owner: senechal (gap -- no project owns network gear)')"
check "a comma inside a role note is not a second owner" "crt gardien" \
  "$(owners '  FAIL  dexter: unit failed. Owner: crt (console app), gardien (backup), senechal (host health)')"
check "slash-separated owners both parse, senechal still excluded" "realisateur" \
  "$(owners '  WARN  x. Owner: realisateur (generates and owns the command content) / senechal (owns knowing which homes need them)')"
check "an owner note with an internal comma parses whole (regression)" "realisateur scheduler" \
  "$(owners '  FAIL  x. Owner: realisateur (accounts, see MONKEY.md), scheduler (dispatch + rotation), senechal (host health)')"

# --- alert_if_changed: route findings, don't page (2026-08-11) ---------
# The regression the flap guard below locks down: should_alert alone made
# every hourly run of a continuously-non-clean estate page, and even
# after that was fixed (page only on CHANGE), Zach's own report was that
#   [rest: vault:senechal/header-archaeology-20260818.md]
STATE="$T/state"
printf '{}\n' > "$T/senechal.json"
alert_run() { # <report-body> <fail> <warn> -> stub output, one line/event
  local body="$1" f="$2" w="$3"
  SENECHAL_CONFIG="$T/senechal.json" XDG_STATE_HOME="$STATE" \
    body="$body" f="$f" w="$w" bash -c '
      . "'"$REPO"'/lib/common.sh"
      notify_alert() { printf "NOTIFY[%s]: %s\n" "${3:-critical}" "$1"; }
      route_to_owner() { printf "ROUTE[%s]: %s\n" "$1" "$2"; }
      sync_senechal_issue() { printf "ISSUE: %s\n" "$(printf "%s" "$1" | tr "\n" ";")"; }
      _out="$body"; _fail_count="$f"; _warn_count="$w"; _incomplete_count=0
      alert_if_changed /dev/null
    ' 2>/dev/null
}

rm -rf "$STATE"
BODY_A='  FAIL  system unit failed: bibliothecaire-intake.service
  WARN  / at 92% (>= 85% warn threshold), 40G free'

# first sight of senechal-owned findings (no Owner: tag) syncs the
# tracking issue -- it does NOT page, and does NOT route anywhere
out="$(alert_run "$BODY_A" 1 1)"
check "senechal-owned findings sync the tracking issue" yes \
  "$(case "$out" in *ISSUE:*bibliothecaire-intake.service*) echo yes ;; *) echo "no ($out)" ;; esac)"
check "senechal-owned findings never page" yes \
  "$(case "$out" in *NOTIFY*) echo "no ($out)" ;; *) echo yes ;; esac)"
check "senechal-owned findings are not routed to a project" yes \
  "$(case "$out" in *ROUTE*) echo "no ($out)" ;; *) echo yes ;; esac)"

# THE WHOLE POINT: the identical run an hour later says nothing at all
check "an unchanged run is silent" "" "$(alert_run "$BODY_A" 1 1)"
check "still silent on the third run" "" "$(alert_run "$BODY_A" 1 1)"

# numeric jitter is the same finding -- 92% -> 91%, 40G -> 41G must not
# re-sync, or the disk warning alone would churn the issue every hour
BODY_JITTER='  FAIL  system unit failed: bibliothecaire-intake.service
  WARN  / at 91% (>= 85% warn threshold), 41G free'
check "numeric jitter does not re-sync" "" "$(alert_run "$BODY_JITTER" 1 1)"

# a genuinely new finding re-syncs the issue with the FULL current set --
# it always reflects CURRENT state, not just the delta
BODY_B="$BODY_A"'
  FAIL  user unit failed: gardien-nightly.service'
out="$(alert_run "$BODY_B" 2 1)"
check "a genuinely new finding re-syncs the issue" yes \
  "$(case "$out" in *ISSUE:*gardien-nightly*) echo yes ;; *) echo "no ($out)" ;; esac)"
check "the resync still carries the earlier findings too" yes \
  "$(case "$out" in *ISSUE:*bibliothecaire-intake.service*gardien-nightly*) echo yes ;; *) echo "no ($out)" ;; esac)"

# a finding clearing resyncs the issue too -- but only after two
# CONSECUTIVE misses (the flap guard), so the first run it goes missing
# is silent (grace) ...
check "a finding's first miss is silent (grace)" "" "$(alert_run "$BODY_A" 1 1)"
# ... and only the second consecutive miss actually confirms the clear
out="$(alert_run "$BODY_A" 1 1)"
check "a cleared finding resyncs on the second miss" yes \
  "$(case "$out" in *ISSUE:*) echo yes ;; *) echo "no ($out)" ;; esac)"
check "the resync no longer carries the cleared finding" yes \
  "$(case "$out" in *gardien-nightly*) echo "no ($out)" ;; *) echo yes ;; esac)"

# --- external ownership: file to the owner, never the issue, never a page
rm -rf "$STATE"
BODY_OWNED='  FAIL  dexter: systemd unit failed: getty@tty1.service  (ssh in and check journalctl -u getty@tty1.service). Owner: crt (console app), gardien (backup), senechal (host health)'
out="$(alert_run "$BODY_OWNED" 1 0)"
check "an externally-owned finding routes to each named owner" yes \
  "$(case "$out" in *'ROUTE[crt]'*) case "$out" in *'ROUTE[gardien]'*) echo yes ;; *) echo "no ($out)" ;; esac ;; *) echo "no ($out)" ;; esac)"
check "senechal is excluded from routing even though it's tagged too" yes \
  "$(case "$out" in *'ROUTE[senechal]'*) echo "no ($out)" ;; *) echo yes ;; esac)"
check "an externally-owned finding does not sync the senechal issue" yes \
  "$(case "$out" in *ISSUE:*) echo "no ($out)" ;; *) echo yes ;; esac)"
check "an externally-owned finding does not page" yes \
  "$(case "$out" in *NOTIFY*) echo "no ($out)" ;; *) echo yes ;; esac)"

# a mixed run routes each finding by its own ownership, independently
rm -rf "$STATE"
BODY_MIXED="$BODY_A
$BODY_OWNED"
out="$(alert_run "$BODY_MIXED" 2 1)"
check "mixed run: senechal-owned findings sync the issue" yes \
  "$(case "$out" in *ISSUE:*bibliothecaire-intake.service*) echo yes ;; *) echo "no ($out)" ;; esac)"
check "mixed run: the issue body excludes the externally-owned finding" yes \
  "$(case "$out" in *ISSUE:*getty*) echo "no ($out)" ;; *) echo yes ;; esac)"
check "mixed run: the externally-owned finding still routes" yes \
  "$(case "$out" in *'ROUTE[crt]'*) echo yes ;; *) echo "no ($out)" ;; esac)"

# --- the flap guard, now proven against ROUTING not paging --------------
# THE ACTUAL FIX for 2026-08-11's report: dexter/monkey SSH reachability
# blips for exactly one hourly run and comes back the next, flipping a
# batch of downstream checks FAIL<->SKIP each time. A finding that
# disappears and reappears within a single miss must trigger NOTHING for
# it -- no re-route, no issue resync.
rm -rf "$STATE"
BODY_FLAP_UP="$BODY_A
$BODY_OWNED"
BODY_FLAP_DOWN="$BODY_A"
alert_run "$BODY_FLAP_UP" 2 1 >/dev/null                 # first sight: routes once, expected
check "flap: externally-owned check vanishes for one run -- silent" "" \
  "$(alert_run "$BODY_FLAP_DOWN" 1 1)"                   # miss #1: grace, nothing
check "flap: comes back before 2nd miss -- silent, not re-routed" "" \
  "$(alert_run "$BODY_FLAP_UP" 2 1)"                     # back before confirming: silent
check "flap: another one-run blip is still silent" "" \
  "$(alert_run "$BODY_FLAP_DOWN" 1 1)"                   # miss #1 again (fresh): grace
check "flap: and recovers silently again" "" \
  "$(alert_run "$BODY_FLAP_UP" 2 1)"
# only a SUSTAINED absence (two consecutive runs) is real news
check "flap: first of two consecutive misses is silent" "" \
  "$(alert_run "$BODY_FLAP_DOWN" 1 1)"
out="$(alert_run "$BODY_FLAP_DOWN" 1 1)"
check "flap: second consecutive miss resyncs but does NOT re-route" yes \
  "$(case "$out" in *ROUTE*) echo "no ($out)" ;; *) echo yes ;; esac)"

# recovery is the ONE thing that still pages, and it also closes the
# senechal issue out (empty findings)
rm -rf "$STATE"
alert_run "$BODY_A" 1 1 >/dev/null
out="$(alert_run '  PASS  everything fine' 0 0)"
check "recovery pages" yes \
  "$(case "$out" in *NOTIFY*recovered*) echo yes ;; *) echo "no ($out)" ;; esac)"
check "recovery closes the senechal issue (empty findings)" yes \
  "$(printf '%s\n' "$out" | grep -qx 'ISSUE: ' && echo yes || echo "no ($out)")"
check "a second clean run is silent" "" "$(alert_run '  PASS  everything fine' 0 0)"
out="$(alert_run "$BODY_A" 1 1)"
check "a finding after recovery syncs again" yes \
  "$(case "$out" in *ISSUE:*) echo yes ;; *) echo "no ($out)" ;; esac)"

# a SKIP is a known ESTATE.md gap, not a finding, at the default
# threshold -- so a run whose only change is a SKIP must trigger nothing
rm -rf "$STATE"
alert_run '  FAIL  system unit failed: x.service' 1 0 >/dev/null
check "a new SKIP alone triggers nothing at default severity" "" \
  "$(alert_run '  FAIL  system unit failed: x.service
  SKIP  /dev/nvme0n1 -- smartctl needs root (could not check -- not a pass)' 1 0)"

# --- deploy_state: is the merged code the code that RUNS? --------------
# Every assertion above tested a gate that, on 2026-08-05, was not
# running. PR #85 merged to origin/main; the checkout that
# senechal-health.timer executes stayed two commits behind on its local
#   [rest: vault:senechal/header-archaeology-20260818.md]
GITROOT="$T/git"
git_env() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }
setup_repo() { # -> $GITROOT/clone, one commit behind $GITROOT/origin
  rm -rf "$GITROOT"; mkdir -p "$GITROOT"
  git_env init -q --bare "$GITROOT/origin.git"
  git_env clone -q "$GITROOT/origin.git" "$GITROOT/seed" 2>/dev/null
  echo one > "$GITROOT/seed/f"; git_env -C "$GITROOT/seed" add f
  git_env -C "$GITROOT/seed" commit -qm one
  git_env -C "$GITROOT/seed" push -q origin main
  git_env clone -q "$GITROOT/origin.git" "$GITROOT/clone" 2>/dev/null
}
advance_n=0
advance_origin() { # add a commit to origin, then fetch it into the clone
  advance_n=$((advance_n + 1))
  # Distinct content every time: an identical write is not a commit, and
  # a silent no-op here would make the "behind" assertions test nothing.
  printf 'advance %s\n' "$advance_n" > "$GITROOT/seed/f"
  git_env -C "$GITROOT/seed" commit -qam "advance $advance_n" >/dev/null
  git_env -C "$GITROOT/seed" push -q origin main
  git_env -C "$GITROOT/clone" fetch -q origin
}
state() { # <root> [ref] -> the deploy_state line
  printf '{}\n' > "$T/senechal.json"
  SENECHAL_CONFIG="$T/senechal.json" bash -c \
    ". '$REPO/lib/common.sh'; deploy_state '$1' '${2:-origin/main}'" 2>/dev/null
}
kind() { set -- $(state "$@"); printf '%s' "${1:-}"; }

setup_repo
check "a checkout at the ref is current"        current "$(kind "$GITROOT/clone")"

# THE REGRESSION: origin moves, the checkout does not. This is the exact
# shape of the 2026-08-05 outage and it must FAIL, not pass quietly.
advance_origin
check "a checkout behind the ref is behind"     behind  "$(kind "$GITROOT/clone")"
check "and it says how far behind"              "behind 1" \
  "$(set -- $(state "$GITROOT/clone"); printf '%s %s' "$1" "$2")"

# Ancestry, not equality: this repo lives on feature branches, and one
# rebased on the mainline IS running the merged code. Failing those
# would be new noise in a change whose whole point is less noise.
git_env -C "$GITROOT/clone" merge -q --ff-only origin/main
git_env -C "$GITROOT/clone" checkout -q -b feature
echo three > "$GITROOT/clone/f"; git_env -C "$GITROOT/clone" commit -qam three
check "a feature branch ahead of the ref is current" current "$(kind "$GITROOT/clone")"
# ...but a feature branch off a STALE base is still behind, because the
# merged fix genuinely is not in it
advance_origin
check "a feature branch on a stale base is behind"   behind  "$(kind "$GITROOT/clone")"

# The two answers that are not a verdict. Neither may read as a pass:
# "I could not look" is the RC_INCOMPLETE half of the exit contract.
check "a non-repo reports nogit"                nogit   "$(kind "$T")"
check "an unknown ref reports noref"            noref   "$(kind "$GITROOT/clone" origin/nonesuch)"
check "nogit is not current"                    no \
  "$(case "$(kind "$T")" in current) echo yes ;; *) echo no ;; esac)"
check "noref is not current"                    no \
  "$(case "$(kind "$GITROOT/clone" origin/nonesuch)" in current) echo yes ;; *) echo no ;; esac)"

# A dirty tree is reported but is not, by itself, drift -- concurrent
# agents edit this repo mid-session (registry/standing-answers.json) and a FAIL for that would
# be exactly the noise being removed.
git_env -C "$GITROOT/clone" checkout -q main
git_env -C "$GITROOT/clone" merge -q --ff-only origin/main
check "a clean current checkout reports 0 dirty" "current 0" \
  "$(set -- $(state "$GITROOT/clone"); printf '%s %s' "$1" "$4")"
echo dirt > "$GITROOT/clone/untracked"
check "an uncommitted change is counted"        "current 1" \
  "$(set -- $(state "$GITROOT/clone"); printf '%s %s' "$1" "$4")"
check "a dirty tree is still current, not behind" current "$(kind "$GITROOT/clone")"

# --- transient app scopes are not services -----------------------------
# The other half of the noise: KDE/snapd mint a .scope per app window
# with a fresh random id, so a crashed browser tab both reported as
# estate breakage AND could never dedupe against its own past selves.
scope() { # <unit> -> yes/no
  printf '{}\n' > "$T/senechal.json"
  SENECHAL_CONFIG="$T/senechal.json" bash -c \
    ". '$REPO/lib/common.sh'; is_transient_scope '$1'" 2>/dev/null \
    && echo yes || echo no
}
check "KDE app scope is transient"    yes "$(scope 'app-org.kde.konsole-8e88dfdf600d44a0803977f7d33ce481.scope')"
check "snap app scope is transient"   yes "$(scope 'snap.chromium.chromium-144e20bc-3aea-46cc-9006-5ae6cd0076d0.scope')"
check "session scope is transient"    yes "$(scope 'session-3.scope')"
check "vte spawn scope is transient"  yes "$(scope 'vte-spawn-abc.scope')"
# The guard that matters: a real service can never be filtered away, no
# matter how its name reads. Hiding a service failure is the one bug
# this feature could plausibly introduce.
check "a real service is never transient"       no "$(scope 'bibliothecaire-intake.service')"
check "a service named like an app is not"      no "$(scope 'app-org.kde.konsole.service')"
check "a snap-named service is not"             no "$(scope 'snap.chromium.chromium.service')"
check "a timer is not"                          no "$(scope 'senechal-health.timer')"
# .scope alone is not enough either -- an unmatched scope stays visible
check "an unrecognised scope stays a failure"   no "$(scope 'init.scope')"

# and the patterns come from config, not from the code
printf '{"health": {"transient_unit_patterns": ["weird-*.scope"]}}\n' > "$T/senechal.json"
custom_yes="$(SENECHAL_CONFIG="$T/senechal.json" bash -c \
  ". '$REPO/lib/common.sh'; is_transient_scope 'weird-1.scope'" 2>/dev/null && echo yes || echo no)"
custom_no="$(SENECHAL_CONFIG="$T/senechal.json" bash -c \
  ". '$REPO/lib/common.sh'; is_transient_scope 'app-x.scope'" 2>/dev/null && echo yes || echo no)"
check "configured patterns are honoured"        yes "$custom_yes"
check "configured patterns replace the defaults" no "$custom_no"
# even a config that tries to swallow services cannot
printf '{"health": {"transient_unit_patterns": ["*"]}}\n' > "$T/senechal.json"
check "a wildcard config still cannot match a service" no \
  "$(SENECHAL_CONFIG="$T/senechal.json" bash -c \
     ". '$REPO/lib/common.sh'; is_transient_scope 'bibliothecaire-intake.service'" 2>/dev/null && echo yes || echo no)"

# --- a config that cannot be read is LOUD, not a set of defaults -------
# Until 2026-08-05 (hf7y/senechal#67) `cfg` answered a MISSING or
# UNPARSEABLE config exactly the way it answered an absent key: print the
# caller's hardcoded default and exit 0. So a senechal that could not see
#   [rest: vault:senechal/header-archaeology-20260818.md]
rm -f "$T/nope.json"
printf '{oops' > "$T/malformed.json"

SENECHAL_CONFIG="$T/nope.json" bash -c ". '$REPO/lib/common.sh'" 2>/dev/null
check "a missing config is INCOMPLETE (2), not defaults" 2 "$?"

SENECHAL_CONFIG="$T/malformed.json" bash -c ". '$REPO/lib/common.sh'" 2>/dev/null
check "an unparseable config is INCOMPLETE (2)" 2 "$?"

# It must refuse BEFORE the caller gets a plausible-looking value back,
# not after -- an emptier report that still exits 0/1/3 is the bug.
missing_out="$(SENECHAL_CONFIG="$T/nope.json" bash -c \
  ". '$REPO/lib/common.sh'; echo REACHED-BODY: \$(cfg health.disk_warn_pct 85)" 2>/dev/null)"
check "a missing config never reaches the caller's body" "" "$missing_out"

missing_msg="$(SENECHAL_CONFIG="$T/nope.json" bash -c \
  ". '$REPO/lib/common.sh'" 2>&1 >/dev/null)"
case "$missing_msg" in
  *CANNOT\ SEE*"$T/nope.json"*) check "it says it cannot see, and names the file" yes yes ;;
  *) check "it says it cannot see, and names the file" yes "no ($missing_msg)" ;;
esac
case "$missing_msg" in
  *mkdir*cp*chmod*) check "it prints the command that creates the file" yes yes ;;
  *) check "it prints the command that creates the file" yes "no ($missing_msg)" ;;
esac

# An estate with no devices and an estate we cannot see must not produce
# the same bytes. cfg_devices used to print nothing and exit 0 for both.
printf '{"estate": {"devices": []}}\n' > "$T/nodevices.json"
empty_devs="$(SENECHAL_CONFIG="$T/nodevices.json" bash -c \
  ". '$REPO/lib/common.sh'; cfg_devices" 2>/dev/null)"; empty_rc=$?
check "a genuinely empty device list is silent and clean (0)" 0 "$empty_rc"
check "a genuinely empty device list prints nothing" "" "$empty_devs"

# The runtime half: the config can vanish AFTER the source-time check,
# and cfg_devices runs inside "$(...)" where a bare `exit` would end only
# the subshell and hand the caller an empty registry.
cp "$T/nodevices.json" "$T/vanishing.json"
SENECHAL_CONFIG="$T/vanishing.json" bash -c \
  ". '$REPO/lib/common.sh'; rm -f \"\$SENECHAL_CONFIG\"; devs=\"\$(cfg_devices)\"; exit 0" \
  2>/dev/null
check "a config deleted mid-run is INCOMPLETE (2), not an empty estate" 2 "$?"

# --- the config must outlive the code that reads it (2026-08-05) -------
# SENECHAL_CONFIG defaulted to "$SENECHAL_ROOT/senechal.json" -- beside
# the code. senechal.json is untracked, so no branch or build carries it,
# and a verb build is a disposable directory `current` is repointed away
#   [rest: vault:senechal/header-archaeology-20260818.md]
default_config="$(
  unset SENECHAL_CONFIG
  SENECHAL_SKIP_CONFIG_CHECK=1
  export SENECHAL_SKIP_CONFIG_CHECK
  # shellcheck source=/dev/null
  . "$REPO/lib/common.sh" 2>/dev/null
  printf '%s\n' "$SENECHAL_CONFIG"
)"
check "default config is XDG config, not the code tree" \
  "$HOME/.config/senechal/senechal.json" "$default_config"

# The load-bearing half: wherever it points, it must not be under a
# directory that a build adoption or a worktree removal can take away.
case "$default_config" in
  *"/verb-builds/"*|*"-verbs/"*|"$REPO"/*)
    check "default config is outside any build, worktree or checkout" \
      yes "no (disposable tree: '$default_config')" ;;
  *)
    check "default config is outside any build, worktree or checkout" yes yes ;;
esac

# The override is the seam tests and second estates use -- it must keep
# winning over the new default.
override_config="$(
  SENECHAL_CONFIG="$T/senechal.json" SENECHAL_SKIP_CONFIG_CHECK=1 bash -c \
    ". '$REPO/lib/common.sh'; printf '%s\n' \"\$SENECHAL_CONFIG\"" 2>/dev/null
)"
check "SENECHAL_CONFIG still overrides the default" "$T/senechal.json" "$override_config"

# --- the timer remedy, against a throwaway unit dir ---------------------
UNITS="$T/units"
write_cfg warn 30m

# A unit's ExecStart is refused unless it names the declared build root
# (lib/common.sh refuse_undeployable_path -- a temp checkout baked into
# both --user timers on 2026-08-22 is why). A hermetic test declares its
# own build root; without this the rows below can only ever observe the
# refusal, which says nothing about whether enable works.
BUILD="$T/build"
mkdir -p "$BUILD/health"
cp "$REPO/health/estate-health.sh" "$BUILD/health/"
chmod +x "$BUILD/health/estate-health.sh"

run_remedy() {
  SENECHAL_CONFIG="$T/senechal.json" SENECHAL_HEALTH_UNIT_DIR="$UNITS" \
    SENECHAL_DEPLOYED_ROOT="$BUILD" \
    "$REPO/remedies/estate-health-timer.sh" "$@" 2>&1
}

out="$(run_remedy enable)"; rc=$?
check "enable exits 0"        0    "$rc"
check "service unit written"  yes  "$([ -f "$UNITS/senechal-health.service" ] && echo yes || echo no)"
check "timer unit written"    yes  "$([ -f "$UNITS/senechal-health.timer" ] && echo yes || echo no)"
check "test mode says so"     yes  "$(case "$out" in *'test mode'*) echo yes ;; *) echo no ;; esac)"

# interval comes from senechal.json, not retyped in the unit
check "interval read from config" yes \
  "$(grep -q 'OnUnitActiveSec=30m' "$UNITS/senechal-health.timer" && echo yes || echo no)"
# the self-referential-failed-unit guard is present
check "SuccessExitStatus guard present" yes \
  "$(grep -q '^SuccessExitStatus=1 2 3' "$UNITS/senechal-health.service" && echo yes || echo no)"
check "ExecStart points at the real check" yes \
  "$(grep -q "ExecStart=$BUILD/health/estate-health.sh --quiet" "$UNITS/senechal-health.service" && echo yes || echo no)"
# ...and at the DEPLOYED copy, never this checkout. The unit outlives the
# clone; that is the whole 2026-08-22 lesson.
check "ExecStart does not name the working clone" yes \
  "$(grep -q "ExecStart=$REPO/" "$UNITS/senechal-health.service" && echo no || echo yes)"

# enable is idempotent
out2="$(run_remedy enable)"
check "second enable is a no-op" yes \
  "$(case "$out2" in *'already correct'*) echo yes ;; *) echo no ;; esac)"

# verify in test mode: units match, but no live systemd -> INCOMPLETE (2),
# never a pass. This is the "could not look" contract.
out="$(run_remedy verify)"; rc=$?
check "verify exits 2 in test mode (could-not-check, not pass)" 2 "$rc"
check "verify confirms unit content matches" yes \
  "$(case "$out" in *"matches this script's content"*) echo yes ;; *) echo no ;; esac)"

# drift: an interval changed in senechal.json but never re-enabled must FAIL
write_cfg warn 4h
out="$(run_remedy verify)"; rc=$?
check "config drift fails (1)" 1 "$rc"
check "drift names the new interval" yes \
  "$(case "$out" in *'senechal.json says 4h'*) echo yes ;; *) echo no ;; esac)"
write_cfg warn 30m

# disable removes both units and is the documented undo
out="$(run_remedy disable)"
check "disable removes service" no "$([ -f "$UNITS/senechal-health.service" ] && echo yes || echo no)"
check "disable removes timer"   no "$([ -f "$UNITS/senechal-health.timer" ] && echo yes || echo no)"

# verify after disable: not installed at all -> FAIL (1), and it must
# say how to fix it rather than just "missing"
out="$(run_remedy verify)"; rc=$?
check "verify after disable fails (1)" 1 "$rc"
check "verify names the fix" yes \
  "$(case "$out" in *'run: ./estate-health-timer.sh enable'*) echo yes ;; *) echo no ;; esac)"

# a malformed interval must be refused at enable time, not written into
# a unit systemd will never fire on
write_cfg warn "every hour"
run_remedy enable >/dev/null 2>&1; rc=$?
check "malformed interval refuses to enable" 1 "$rc"
check "malformed interval writes no unit" no \
  "$([ -f "$UNITS/senechal-health.timer" ] && echo yes || echo no)"
write_cfg warn 2d
run_remedy enable >/dev/null 2>&1
check "valid 2d interval accepted" yes \
  "$(grep -q 'OnUnitActiveSec=2d' "$UNITS/senechal-health.timer" && echo yes || echo no)"
run_remedy disable >/dev/null 2>&1
write_cfg warn 30m

# unknown verb fails loudly rather than exiting 0 doing nothing
run_remedy bogus >/dev/null 2>&1; rc=$?
check "unknown verb exits nonzero" 1 "$rc"

# --- memory pressure, as EVENTS ----------------------------------------
# The regression these lock down: on 2026-08-05 the 20:09 hourly run
# PASSED while mandark thrashed -- swap 3.8Gi of 4.0Gi, two OOM kills in
# 24h, plasma-discover holding 209MB of swap idle since July 27 -- and
#   [rest: vault:senechal/header-archaeology-20260818.md]
mem() { # <shell snippet using the mem_* helpers> -> stdout
  printf '{}\n' > "$T/senechal.json"
  SENECHAL_CONFIG="$T/senechal.json" bash -c ". '$REPO/lib/common.sh'; $1" 2>/dev/null
}

# mem_swap_band: which band a percentage falls in. 0 == below all bands.
check "swap 0% is below every band"      0 "$(mem 'mem_swap_band 0 50 75 90')"
check "swap 47% is below every band"     0 "$(mem 'mem_swap_band 47 50 75 90')"
check "swap 50% enters band 1 exactly"   1 "$(mem 'mem_swap_band 50 50 75 90')"
check "swap 76% is band 2"               2 "$(mem 'mem_swap_band 76 50 75 90')"
# tonight's real reading: 3.8Gi of 4.0Gi
check "swap 95% is the top band"         3 "$(mem 'mem_swap_band 95 50 75 90')"
check "swap 100% is the top band"        3 "$(mem 'mem_swap_band 100 50 75 90')"
# bands are counted, not scanned in order, so a config listed out of
# order cannot silently produce a nonsense band
check "band count is order-independent"  3 "$(mem 'mem_swap_band 95 90 50 75')"
check "a non-numeric percentage is rc 2, not band 0" 2 \
  "$(mem 'mem_swap_band x 50 75 90 >/dev/null; echo $?')"

# mem_swap_transition: the crossing detector. Verdict, band, prev, hours.
SF="$T/swapband"
trans() { # <pct> <sustained_h> <now> -> "<verdict> <band> <prev> <hours>"
  mem "mem_swap_transition '$SF' $1 $2 $3 50 75 90" | tr '\t' ' '
}
rm -f "$SF"
check "first sight of a band is news" "first 3 -1 0" "$(trans 95 24 1000000)"
# THE WHOLE POINT: the same 95% an hour later is not news. A plain
# "swap > 75%" rule would have fired here, every hour, for weeks.
check "an unchanged band is silent"   "steady 3 3 1" "$(trans 95 24 1003600)"
check "still steady two hours later"  "steady 3 3 2" "$(trans 95 24 1007200)"
# numbers inside a band do not matter; crossing OUT of it does
check "moving within a band is steady" "steady 3 3 3" "$(trans 91 24 1010800)"
check "dropping a band reads as fall"  "fall 2 3 0"   "$(trans 80 24 1010800)"
check "climbing back is a rise"        "rise 3 2 0"   "$(trans 95 24 1010800)"

# the anti-silence guard: pure crossing detection would go quiet forever
# on a machine that climbed and stayed, which is how you get back to a
# health check that PASSES during a thrash
check "sustained fires once past the floor" "sustained 3 3 25" "$(trans 95 24 1100800)"
check "and does not fire again"             "steady 3 3 26"    "$(trans 95 24 1104400)"
# a fall resets the residency, so the next climb can report sustained again
trans 10 24 1104400 >/dev/null
trans 95 24 1104400 >/dev/null
check "sustained rearms after a fall" "sustained 3 3 25" "$(trans 95 24 1194400)"

rm -f "$SF"
check "band 0 never reports sustained" "steady 0 0 100" \
  "$(trans 10 24 1000000 >/dev/null; trans 10 24 1360000)"
rm -f "$SF"
check "sustained_hours=0 disables the guard" "steady 3 3 100" \
  "$(trans 95 0 1000000 >/dev/null; trans 95 0 1360000)"

# mem_oom_parse, against the REAL kernel lines from mandark's journal on
# 2026-08-05 (journalctl -k -o short-iso), not a hand-written fixture.
OOMREAL='2026-08-05T04:12:08-05:00 mandark kernel: Out of memory: Killed process 3209820 (chrome) total-vm:1518601884kB, anon-rss:37840kB, file-rss:0kB, shmem-rss:1996kB, UID:1000 pgtables:2408kB oom_score_adj:300
2026-08-05T15:28:01-05:00 mandark kernel: Out of memory: Killed process 4049379 (python3) total-vm:2548304kB, anon-rss:2530376kB, file-rss:384kB, shmem-rss:0kB, UID:1000 pgtables:5036kB oom_score_adj:200'
oom() { mem "mem_oom_parse <<'EOF'
$OOMREAL
EOF"; }
check "both real OOM kills are found" 2 "$(oom | grep -c .)"
check "the chrome kill parses whole" \
  "2026-08-05T04:12:08-05:00	3209820	chrome	37840" "$(oom | head -1)"
check "the 2.5GB python3 kill parses whole" \
  "2026-08-05T15:28:01-05:00	4049379	python3	2530376" "$(oom | tail -1)"

# a journal with no OOM kills yields nothing -- and the caller
# distinguishes that from "the parser matched nothing" by counting raw
# lines, which is why this must be empty rather than a zero record
check "a quiet journal parses to nothing" 0 \
  "$(mem "printf 'kernel: usb 1-2: new device\n' | mem_oom_parse" | grep -c .)"
# the oom-killer INVOCATION line is not a kill -- counting it would
# double every event, since the kernel prints both
check "the oom-killer invocation line is not counted" 0 \
  "$(mem "printf '%s\n' '2026-08-05T04:12:07-05:00 mandark kernel: gdbus invoked oom-killer: gfp_mask=0x140cca, order=0, oom_score_adj=0' | mem_oom_parse" | grep -c .)"
# a line the parser half-understands must yield NOTHING, not a record with
# an empty pid. The caller counts raw OOM lines against parsed records and
# turns that mismatch into a SKIP -- which only works if a half-parse is
# dropped here rather than passed off as a real kill.
check "a truncated OOM line yields no half-parsed record" 0 \
  "$(mem "printf '%s\n' '2026-08-05T04:12:08-05:00 mandark kernel: Out of memory: Killed process' | mem_oom_parse" | grep -c .)"

# mem_swap_squatters: <pid> <swap_kb> <elapsed_s> <cpu_s> <comm>
# Row 1 is tonight's real plasma-discover: 209MB of swap, alive since
# July 27 (nine days), essentially no CPU. It is the case that started
# all of this and it must match.
SQUAT='2001 214016 777600 12 plasma-discover
2002 214016 172800 12 young-but-fat
2003 10240 777600 12 old-but-small
2004 214016 777600 600000 old-fat-and-busy'
squat() { mem "mem_swap_squatters ${1:-50} ${2:-7} ${3:-1} <<'EOF'
$SQUAT
EOF"; }
check "only the real squatter matches" 1 "$(squat | grep -c .)"
check "plasma-discover is reported with size and idle age" \
  "2001	209	9	plasma-discover" "$(squat)"
check "a young process is not a squatter"    0 "$(squat | grep -c 'young-but-fat')"
check "a small process is not a squatter"    0 "$(squat | grep -c 'old-but-small')"
check "a busy process is not a squatter"     0 "$(squat | grep -c 'old-fat-and-busy')"
# the thresholds really are the config, not decoration
check "raising min_mb drops the squatter"    0 "$(squat 300 7 1 | grep -c .)"
check "raising min_idle_days drops it"       0 "$(squat 50 30 1 | grep -c .)"
check "raising max_cpu_pct admits the busy one" yes \
  "$(squat 50 7 99 | grep -q 'old-fat-and-busy' && echo yes || echo no)"
# --- ini_get / ini_set: section-aware, and no pipeline landmines ------
# These are lib/common.sh's INI helpers, used by every remedy that edits
# a KDE- or ConfigParser-style config. Both properties below were real
# defects: the reader used to be a `grep | head | sed` pipeline (whose
# no-match exit 1 killed the caller under `set -euo pipefail`), and the
# writer used to match keys FILE-WIDE, so it happily edited or created a
# key in a section the app does not read from.
INI="$T/sample.ini"
ini() { # <helper> <args...> -- run one helper against a throwaway config
  SENECHAL_SKIP_CONFIG_CHECK=1 bash -c ". '$REPO/lib/common.sh'; $*"
}
write_ini() {
  cat > "$INI" <<'EOF'
[general]
last_run_version = 5.13.0

[cura]
active_machine = Creality Ender-3 Pro

[local_file]
dialog_save_path = /home/zach
dialog_load_path =

[tool]
EOF
}

write_ini
check "ini_get reads its own section" "/home/zach" \
  "$(ini "ini_get '$INI' local_file dialog_save_path")"
check "ini_get does NOT read another section's key" "" \
  "$(ini "ini_get '$INI' general dialog_save_path")"
check "ini_get on an absent key is empty, not an error" "" \
  "$(ini "ini_get '$INI' general nosuchkey")"
check "ini_get on an absent key exits 0" 0 \
  "$(ini "ini_get '$INI' general nosuchkey" >/dev/null; echo $?)"
check "ini_get on an absent file exits 0" 0 \
  "$(ini "ini_get '$T/nope.ini' general k" >/dev/null; echo $?)"
# the landmine itself: under set -e, an absent key must not abort
check "ini_get under set -e survives an absent key" reached \
  "$(SENECHAL_SKIP_CONFIG_CHECK=1 bash -c "set -euo pipefail
    . '$REPO/lib/common.sh'
    v=\"\$(ini_get '$INI' general nosuchkey)\"
    echo reached")"

ini "ini_set '$INI' local_file dialog_save_path /home/zach/Documents/3DPrints"
check "ini_set updates the key in its section" "/home/zach/Documents/3DPrints" \
  "$(ini "ini_get '$INI' local_file dialog_save_path")"
check "ini_set left the neighbouring key alone" yes \
  "$(grep -q '^dialog_load_path' "$INI" && echo yes || echo no)"
check "ini_set left other sections alone" "Creality Ender-3 Pro" \
  "$(ini "ini_get '$INI' cura active_machine")"
check "ini_set kept every section" 4 "$(grep -c '^\[' "$INI")"

# a key absent from the target section goes INTO that section, and
# nowhere else -- the case that used to land in whichever section
# happened to match first
write_ini
ini "ini_set '$INI' general dialog_save_path /tmp/elsewhere"
check "ini_set creates the key in the named section" "/tmp/elsewhere" \
  "$(ini "ini_get '$INI' general dialog_save_path")"
check "ini_set did not touch the same key elsewhere" "/home/zach" \
  "$(ini "ini_get '$INI' local_file dialog_save_path")"
check "ini_sections_with_key finds both" "cura-style: general local_file" \
  "cura-style: $(ini "ini_sections_with_key '$INI' dialog_save_path" | tr '\n' ' ' | sed 's/ $//')"

# a section that does not exist yet is appended
write_ini
ini "ini_set '$INI' brandnew somekey somevalue"
check "ini_set appends a missing section" "somevalue" \
  "$(ini "ini_get '$INI' brandnew somekey")"
check "ini_set still parses as INI afterwards" ok \
  "$(python3 -c "
import configparser,sys
c=configparser.ConfigParser(); c.read(sys.argv[1]); print('ok')" "$INI")"

# a missing file is created with the section, KDE-remedy style
rm -f "$T/new.ini"
ini "ini_set '$T/new.ini' General LocalTabTitleFormat '%d : %w'"
check "ini_set creates a missing file with its section" "%d : %w" \
  "$(ini "ini_get '$T/new.ini' General LocalTabTitleFormat")"

# KDE bare `key=value` spacing round-trips (tmux-konsole-title's shape)
printf '[General]\nLocalTabTitleFormat=%%w\nName=Shell\n' > "$T/kde.ini"
ini "ini_set '$T/kde.ini' General LocalTabTitleFormat '%d : %w'"
check "KDE-style file: key updated" "%d : %w" \
  "$(ini "ini_get '$T/kde.ini' General LocalTabTitleFormat")"
check "KDE-style file: sibling key survives" "Shell" \
  "$(ini "ini_get '$T/kde.ini' General Name")"

# idempotent: setting the same value twice changes nothing
cp "$T/kde.ini" "$T/kde.ini.before"
ini "ini_set '$T/kde.ini' General LocalTabTitleFormat '%d : %w'"
check "ini_set is idempotent (byte-identical)" same \
  "$(cmp -s "$T/kde.ini" "$T/kde.ini.before" && echo same || echo differs)"

# =======================================================================
# cfg_taste: HOMES, not hosts (2026-08-06)
# =======================================================================
# The taste registry used to key on `hosts: [...]`, while every doc around
#   [rest: vault:senechal/header-archaeology-20260818.md]
TASTE_CFG="$T/taste.json"
taste_cfg() { printf '%s\n' "$1" > "$TASTE_CFG"; }
taste_field() { # <field-index, 1-based> [id] -> that column of cfg_taste
  local idx="$1" id="${2:-}"
  SENECHAL_CONFIG="$TASTE_CFG" bash -c \
    ". '$REPO/lib/common.sh'; cfg_taste" 2>/dev/null \
    | { [ -n "$id" ] && grep -F "$id" || cat; } \
    | cut -d$'\x1f' -f"$idx"
}

taste_cfg '{"estate": {"taste": [
  {"id": "old", "file": ".bashrc", "hosts": ["mandark", "dexter"], "status": "enabled"}
]}}'
check "hosts shorthand expands to zach@<host>" "zach@mandark,zach@dexter" \
  "$(taste_field 3)"

taste_cfg '{"estate": {"taste": [
  {"id": "new", "file": ".claude/commands/", "status": "enabled",
   "homes": [{"host": "monkey", "account": "ecosim"},
             {"host": "monkey", "account": "zach"}]}
]}}'
check "homes carries the account through" "ecosim@monkey,zach@monkey" \
  "$(taste_field 3)"

taste_cfg '{"estate": {"taste": [
  {"id": "n", "file": "f", "status": "enabled",
   "homes": [{"host": "monkey"}, "dexter"]}
]}}'
check "homes: account defaults to zach, bare string allowed" \
  "zach@monkey,zach@dexter" "$(taste_field 3)"

# Both spellings present: `homes` wins outright and `hosts` is IGNORED,
# not unioned in. Silently merging two spellings of the same field is how
# a home nobody meant to register gets written to.
taste_cfg '{"estate": {"taste": [
  {"id": "both", "file": "f", "status": "enabled",
   "hosts": ["potato"], "homes": [{"host": "monkey", "account": "zach"}]}
]}}'
check "homes wins over hosts, no union" "zach@monkey" "$(taste_field 3)"

# Neither key: an empty home list, and the row still has all six fields
# so a consumer's read -r does not shift columns.
taste_cfg '{"estate": {"taste": [
  {"id": "none", "file": "f", "status": "disabled", "owner": "o", "notes": "n"}
]}}'
check "no homes and no hosts is an empty column" "" "$(taste_field 3)"
check "a homeless row still has 6 fields" "none|f||disabled|o|n" \
  "$(SENECHAL_CONFIG="$TASTE_CFG" bash -c ". '$REPO/lib/common.sh'; cfg_taste" \
     2>/dev/null | tr $'\x1f' '|')"

# Mixed registry: the unmigrated old row and a new one side by side, which
# is exactly the state the real config is in.
taste_cfg '{"estate": {"taste": [
  {"id": "colorhash-prompt", "file": ".bashrc", "hosts": ["mandark"], "status": "enabled"},
  {"id": "claude-slash-commands", "file": ".claude/commands/", "status": "enabled",
   "homes": [{"host": "monkey", "account": "zach"}]}
]}}'
check "old and new rows coexist (old)" "zach@mandark" \
  "$(taste_field 3 colorhash-prompt)"
check "old and new rows coexist (new)" "zach@monkey" \
  "$(taste_field 3 claude-slash-commands)"

# =======================================================================
# resolve_home: account@host -> how to reach it, from estate.devices only
# =======================================================================
DEV_CFG="$T/devices.json"
cat > "$DEV_CFG" <<'JSON'
{"estate": {"devices": [
  {"name": "here",  "reach": "local"},
  {"name": "far",   "reach": "ssh", "ssh_host": "far.example.ts.net"},
  {"name": "noalias", "reach": "ssh"},
  {"name": "pingonly", "reach": "ping"}
]}}
JSON
resolve() { # <home-token> -> "mode|arg"
  SENECHAL_CONFIG="$DEV_CFG" bash -c \
    ". '$REPO/lib/common.sh'; resolve_home '$1'" 2>/dev/null | tr $'\x1f' '|'
}
ME="$(id -un)"
check "local device + this account -> local" "local|" "$(resolve "$ME@here")"
check "ssh device -> user@ssh_host" "ssh|zach@far.example.ts.net" \
  "$(resolve "zach@far")"
check "ssh device with no alias falls back to the device name" \
  "ssh|zach@noalias" "$(resolve "zach@noalias")"

# A local device can still name an account this process is not -- monkey
# has ten. Writing another user's $HOME needs privilege senechal does not
# take, so that is could-not-check, never a pass and never a failure of
# the taste itself.
case "$(resolve "somebodyelse@here")" in
  skip\|*not\ the\ account*) check "local device, other account -> skip" yes yes ;;
  *) check "local device, other account -> skip" yes "no ($(resolve "somebodyelse@here"))" ;;
esac
case "$(resolve "zach@pingonly")" in
  skip\|*) check "a ping-only device -> skip, no probe invented" yes yes ;;
  *) check "a ping-only device -> skip, no probe invented" yes no ;;
esac

# A registry naming a device estate.devices does not is a real fault in
# the registry, kept distinct from skip so a typo cannot hide forever.
case "$(resolve "zach@ghost")" in
  undeclared\|*not\ in\ estate.devices*) check "unknown host -> undeclared" yes yes ;;
  *) check "unknown host -> undeclared" yes "no ($(resolve "zach@ghost"))" ;;
esac
case "$(resolve "nostrudel")" in
  undeclared\|*malformed*) check "a token with no @ -> undeclared" yes yes ;;
  *) check "a token with no @ -> undeclared" yes "no ($(resolve "nostrudel"))" ;;
esac

# =======================================================================
# the two copies of estate.taste must not drift
# =======================================================================
# Same reasoning as health/test-no-self-dev.sh's self_dev guard: the live
#   [rest: vault:senechal/header-archaeology-20260818.md]
LIVE_CFG="${SENECHAL_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/senechal/senechal.json}"
if [ -f "$LIVE_CFG" ] && [ -f "$REPO/senechal.json.example" ]; then
  check "senechal.json and .example estate.taste blocks are identical" same \
    "$(python3 - "$LIVE_CFG" "$REPO/senechal.json.example" <<'PY'
import json, sys
a = json.load(open(sys.argv[1])).get('estate', {}).get('taste')
b = json.load(open(sys.argv[2])).get('estate', {}).get('taste')
print('same' if a is not None and a == b else 'DRIFTED')
PY
)"
else
  check "estate.taste drift check ran" skipped skipped
fi

# =======================================================================
# sync_senechal_issue's body satisfies realisateur's body-grammar.sh
# (hf7y/senechal#366): line 1 must declare DECISION:/NO-DECISION:, and a
# <!-- DEFERRED --> block must be present, or gh-sign refuses the write.
# The findings-sync issue is agent-written and rewritten every run, so
# it can never hand-satisfy the grammar -- the generator must.
# =======================================================================
sync_body() { # <findings> -> the body gh issue create/edit would receive
  # sync_senechal_issue redirects gh's own stdout/stderr to /dev/null (it's
  # best-effort, like notify_alert), so the stub can't hand the body back
  # over a pipe -- it has to write it somewhere the caller still owns.
  local capture="$T/gh-body-capture.txt"
  rm -f "$capture"
  SENECHAL_CONFIG="$T/senechal.json" findings="$1" capture="$capture" bash -c '
    . "'"$REPO"'/lib/common.sh"
    gh() {
      case "$1 $2" in
        "issue list") printf "" ;;                     # no existing issue
        "issue create"|"issue edit")
          shift; while [ $# -gt 0 ]; do
            [ "$1" = "--body" ] && { printf "%s" "$2" > "$capture"; return; }; shift
          done ;;
      esac
    }
    sync_senechal_issue "$findings"
  '
  cat "$capture" 2>/dev/null
}

BODY="$(sync_body '  FAIL  system unit failed: bibliothecaire-intake.service')"
check "the synced body's line 1 declares NO-DECISION:" yes \
  "$(case "$(printf '%s\n' "$BODY" | head -1)" in NO-DECISION:*) echo yes ;; *) echo "no ($BODY)" ;; esac)"
check "the synced body names a decider" yes \
  "$(case "$(printf '%s\n' "$BODY" | head -1)" in *@*) echo yes ;; *) echo "no ($BODY)" ;; esac)"
check "the synced body carries a DEFERRED block" yes \
  "$(case "$BODY" in *'<!-- DEFERRED -->'*'<!-- /DEFERRED -->'*) echo yes ;; *) echo "no ($BODY)" ;; esac)"
check "the synced body's DEFERRED block is non-empty (- none)" yes \
  "$(case "$BODY" in *'<!-- DEFERRED -->'*'- none'*'<!-- /DEFERRED -->'*) echo yes ;; *) echo "no ($BODY)" ;; esac)"
check "the synced body still carries the finding" yes \
  "$(case "$BODY" in *bibliothecaire-intake.service*) echo yes ;; *) echo "no ($BODY)" ;; esac)"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$failed"
[ "$failed" -eq 0 ]
