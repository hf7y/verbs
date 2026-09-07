#!/usr/bin/env bash
set -uo pipefail  # SUBJECT: bin/monkey-status-collect.py -- hermetic: fixture home root/sudoers dir, `find` stubbed
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/harness.sh"
harness_tmp
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
COLLECTOR="$REPO/bin/monkey-status-collect.py"

echo "monkey-status-collect.test.sh"

mkdir -p "$T/homes/acct/.local/state" "$T/sudoers.d" "$T/stub"
STATUS="$T/homes/acct/.local/state/selfdev-release-tick.status"
printf '2026-08-13T05:49:02Z pin=2026-08-12T183347Z adopted\n' > "$STATUS"

cat > "$T/stub/find" <<'STUB'   # a case says what the sweep saw and its rc
#!/usr/bin/env bash
[ -n "${FIND_OUT:-}" ] && printf '%s\n' "$FIND_OUT"
exit "${FIND_RC:-0}"
STUB
chmod +x "$T/stub/find"

cat > "$T/stub/journalctl" <<'STUB'   # a case says what the journal saw and its rc
#!/usr/bin/env bash
[ -n "${JOURNALCTL_OUT:-}" ] && printf '%s\n' "$JOURNALCTL_OUT"
exit "${JOURNALCTL_RC:-0}"
STUB
chmod +x "$T/stub/journalctl"

cat > "$T/probe.py" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("collect", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)                    # __name__ != "__main__": no sweep
if sys.argv[2] == "containment":
    print(json.dumps(m.containment("acct", 4242)))
elif sys.argv[2] == "armed":
    print(json.dumps(m.armed(json.loads(sys.argv[3]))))
elif sys.argv[2] == "clocksource":
    print(json.dumps(m.clocksource()))
else:
    print(json.dumps(m.release_tick("acct", json.loads(sys.argv[3]))))
PY

probe() {
  PATH="$T/stub:$PATH" SELFDEV_HOME_ROOT="$T/homes" SELFDEV_SUDOERS_D="$T/sudoers.d" \
    PYTHONDONTWRITEBYTECODE=1 \
    python3 "$T/probe.py" "$COLLECTOR" "$@"
}

section "A. containment: an unreadable tree is not an empty one"
out="$(FIND_RC=1 FIND_OUT="/srv/thing" probe containment)"
eq "a failing find is null (BLIND), not a containment record" "$out" "null"

out="$(FIND_RC=1 FIND_OUT="" probe containment)"
eq "...and that holds when it also printed nothing -- the silent zero" "$out" "null"

section "B. containment: every path, not the first one find happened to reach"
out="$(FIND_RC=0 FIND_OUT="/srv/a
/var/backups/b
/etc/c" probe containment)"
eq "three files outside the home report three paths, not one" \
  "$(printf '%s' "$out" | jq '.outside_home | length')" "3"
has "and the hit behind the first is no longer masked" "$out" "/etc/c"
eq "every element is a plain string -- the page maps over them" \
  "$(printf '%s' "$out" | jq -r '[.outside_home[] | type] | unique | join(",")')" "string"

many="$(seq -f '/srv/f%g' 1 25)"
out="$(FIND_RC=0 FIND_OUT="$many" probe containment)"
eq "25 hits are capped at 20 plus one line naming the rest" \
  "$(printf '%s' "$out" | jq '.outside_home | length')" "21"
eq "and the remainder is counted honestly" \
  "$(printf '%s' "$out" | jq -r '.outside_home[-1]')" "... and 5 more"

section "C. release_tick: a retired clock is an absence, not a reading"
[ -s "$STATUS" ] && ok "the fixture account HAS a status file to be tempted by" \
  || bad "fixture status file" "missing, so the case below proves nothing"

out="$(probe release_tick '["17 * * * * /usr/local/bin/selfdev-runner batch"]')"
eq "a crontab with no TICK line reads null, however fresh the file looks" "$out" "null"

out="$(probe release_tick '[]')"
eq "an empty crontab reads null too" "$out" "null"

out="$(probe release_tick '["47 5 * * * tick.sh --apply # realisateur:selfdev-release:TICK"]')"
has "an account that still HAS a tick still publishes its last line" "$out" "pin=2026-08-12T183347Z"

section "D. armed: the cron tag, not a word anywhere in the crontab"
out="$(probe armed '["*/5 * * * * PACED_MAX_PER_TICK=16 /home/zach/.local/bin/usage-paced-runner.sh # scheduler:scheduler-paced-runner:RUNNER (usage-paced dispatch)"]')"
eq "a line carrying the RUNNER tag reads armed" "$out" "true"

out="$(probe armed '["*/15 * * * * /home/zach/.local/bin/sync-crontab.sh # scheduler:sync-crontab:SYNC"]')"
eq "a sync-only line that merely mentions scheduler does NOT read armed" "$out" "false"

out="$(probe armed '["17 * * * * /usr/local/bin/some-runner-script.sh"]')"
eq "a line that happens to contain the word runner does NOT read armed" "$out" "false"

out="$(probe armed '[]')"
eq "an empty crontab does not read armed" "$out" "false"

section "E. clocksource: the NEM wedge's leading indicators (#530/#562), absent vs. zero"
out="$(JOURNALCTL_RC=1 probe clocksource)"
eq "a journal that could not be read is null (BLIND), not a zero-readout reading" "$out" "null"

out="$(JOURNALCTL_RC=0 JOURNALCTL_OUT="" probe clocksource)"
eq "a readable journal with nothing matching is a real, present zero" \
  "$(printf '%s' "$out" | jq '.long_readout_count')" "0"
eq "...and soft_lockup_count is zero right alongside it, not null" \
  "$(printf '%s' "$out" | jq '.soft_lockup_count')" "0"
eq "...and max_ns is zero too" \
  "$(printf '%s' "$out" | jq '.max_ns')" "0"
has "sampled_at is stamped, so a rising series can be told from a stale one" "$out" "sampled_at"

out="$(JOURNALCTL_RC=0 JOURNALCTL_OUT="clocksource: timekeeping watchdog on CPU0: Long readout interval, skipping watchdog check: cs_nsec=8700000000 wd_nsec=8700000000
clocksource: timekeeping watchdog on CPU0: Long readout interval, skipping watchdog check: cs_nsec=167000000000 wd_nsec=167000000000" probe clocksource)"
eq "two long-readout lines count as two, not the last one only" \
  "$(printf '%s' "$out" | jq '.long_readout_count')" "2"
eq "max_ns is the worst of the series, not the first or last" \
  "$(printf '%s' "$out" | jq '.max_ns')" "167000000000"
eq "no lockup line in this boot means soft_lockup_count is 0, not missing" \
  "$(printf '%s' "$out" | jq '.soft_lockup_count')" "0"

out="$(JOURNALCTL_RC=0 JOURNALCTL_OUT="watchdog: BUG: soft lockup - CPU#0 stuck for 26s! [swapper/0:0]
watchdog: BUG: soft lockup - CPU#0 stuck for 24s! [swapper/0:0]" probe clocksource)"
eq "a lockup with no paired readout line still counts -- #530's own finding that they don't always co-occur" \
  "$(printf '%s' "$out" | jq '.soft_lockup_count')" "2"
eq "...and the readout counter stays truthfully at 0, not borrowed from the lockup count" \
  "$(printf '%s' "$out" | jq '.long_readout_count')" "0"
eq "...and max_ns is 0 -- no cs_nsec was ever emitted this boot" \
  "$(printf '%s' "$out" | jq '.max_ns')" "0"

summary
