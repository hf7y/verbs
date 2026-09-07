#!/usr/bin/env bash
# Tests for bin/selfdev-runner-provision.sh.
#
#   ./test-selfdev-runner-provision.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO="$(cd .. && pwd)"
TOOL="$REPO/bin/selfdev-runner-provision.sh"

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
contains() { # <desc> <needle> <haystack>
  case "$3" in *"$2"*) pass=$((pass + 1)) ;;
    *) failed=$((failed + 1)); printf 'FAIL: %s\n  missing: %s\n  in:\n%s\n' "$1" "$2" "$3" >&2 ;;
  esac
}

# A stub transport: five classes -- firstcirepo is marked-private with NO
# default-branch workflows, blindrepo's marker cannot be read. Exit code is the
# status; requests land in $CALLS so a test can assert what was NOT asked.
cat > "$T/api" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "$CALLS"
case "$2" in
  /installation/repositories*)
    echo '{"repositories":[{"name":"privrepo","private":true},{"name":"pubrepo","private":false},{"name":"archiverepo","private":true},{"name":"firstcirepo","private":true},{"name":"blindrepo","private":true}]}' ;;
  /repos/*/archiverepo/contents/.agent-project) exit 1 ;;
  /repos/*/blindrepo/contents/.agent-project) exit 22 ;;
  /repos/*/contents/.agent-project) echo '{"name":".agent-project"}' ;;
  /repos/*/firstcirepo/contents/.github/workflows) exit 1 ;;
  /repos/*/contents/.github/workflows) echo '[{"name":"tests.yml"}]' ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "$T/api"

CALLS="$T/calls"
run() { # <args...>
  : > "$CALLS"
  OUT="$(CALLS="$CALLS" SELFDEV_RUNNER_API="$T/api" SELFDEV_APP_DIR="$T/etc" \
         RUNNER_ROOT="$T/runners" SYSTEMD_DIR="$T/systemd" \
         bash "$TOOL" "$@" 2>&1)"
  RC=$?
}

mkdir -p "$T/runners" "$T/systemd" "$T/etc"

# --- the predicate decides membership --------------------------------
# --check is a GATE: a private repo with no runner is the wedge this exists to
# prevent, so it exits nonzero rather than reporting it politely and passing.
run --check
check 'a private repo with no runner fails the check' 1 "$RC"
contains 'private repo is claimed' 'would   privrepo: private' "$OUT"
contains 'a public repo needs none' 'ok      pubrepo: needs no runner' "$OUT"
contains 'an unmarked private repo needs none either' 'ok      archiverepo: needs no runner (private, not an agent project' "$OUT"

# --- THE DEADLOCK a repo's FIRST workflow used to cause; is_agent_project --
contains 'a repo whose CI is still only on a PR branch is claimed' 'would   firstcirepo: private, NO DIRECTORY' "$OUT"
check 'and it fails the check, so the cadence provisions it' 1 "$RC"
asked_wf="$(grep -c '.github/workflows' "$CALLS" || true)"
check 'and membership never reads .github/workflows at all' 0 "$asked_wf"

# a public repo that HAS a runner is a removal, with nothing edited
mkdir -p "$T/runners/pubrepo"; printf 'actions.runner.hf7y-pubrepo.mandark-pubrepo.service\n' > "$T/runners/pubrepo/.service"
run --check
contains 'public + runner is a removal' 'would   pubrepo: needs no runner -- REMOVE' "$OUT"
contains 'and the reason is the half that said no' '(public)' "$OUT"
rm -rf "$T/runners/pubrepo"

mkdir -p "$T/runners/archiverepo"; printf 'actions.runner.hf7y-archiverepo.mandark-archiverepo.service\n' > "$T/runners/archiverepo/.service"
run --check
contains 'a private non-project removal is predicted' 'would   archiverepo: needs no runner -- REMOVE' "$OUT"
contains 'and it names the half that said no' '(private, not an agent project (no .agent-project))' "$OUT"
saidpublic="$(printf '%s\n' "$OUT" | grep -c 'archiverepo.*public' || true)"
check 'and never calls a private repo public' 0 "$saidpublic"
rm -rf "$T/runners/archiverepo"

# --- a half-install is its own row, not "not started" -----------------
run --check
contains 'no directory' 'NO DIRECTORY' "$OUT"

mkdir -p "$T/runners/privrepo"
run --check
contains 'extracted but not registered' 'NOT REGISTERED (no .runner)' "$OUT"

: > "$T/runners/privrepo/.runner"
run --check
contains 'registered but no unit' 'registered but NO UNIT' "$OUT"

# THE UNIT NAME IS THE VENDOR'S, and svc.sh records it in <dir>/.service. A
# guessed name is how a second listener gets installed beside a working runner.
printf 'actions.runner.hf7y-privrepo.mandark-privrepo.service\n' > "$T/runners/privrepo/.service"
: > "$T/systemd/actions.runner.hf7y-privrepo.mandark-privrepo.service"
run --check
contains 'the unit it looks for is the one svc.sh named' 'actions.runner.hf7y-privrepo' "$OUT"
contains 'unit present but not active' 'NOT ACTIVE' "$OUT"
check 'and a half-install fails the check' 1 "$RC"
rm -rf "$T/runners/privrepo" "$T/systemd/actions.runner.hf7y-privrepo.mandark-privrepo.service"

# --- the repair matches the fault, and does not touch the healthy -----
# A stopped service must be STARTED, not re-registered: re-registering every
# repo because one unit stopped is churn on healthy runners and needs a
# credential the App may not hold.
mkdir -p "$T/runners/privrepo"
: > "$T/runners/privrepo/.runner"
printf 'actions.runner.hf7y-privrepo.mandark-privrepo.service\n' > "$T/runners/privrepo/.service"
: > "$T/systemd/actions.runner.hf7y-privrepo.mandark-privrepo.service"
run --check
contains 'an inactive unit is the fault reported' 'NOT ACTIVE' "$OUT"
hasnt_registration="$(grep -c 'registration token' <<<"$OUT" || true)"
check 'and --check mints no token to say so' 0 "$hasnt_registration"
rm -rf "$T/runners/privrepo" "$T/systemd/actions.runner.hf7y-privrepo.mandark-privrepo.service"

# --- EVERY repo the list names produces exactly one row ----------------
# Twelve private repos once produced no row at all, because fault_of returned a
# state the --check case had no arm for: a repo with no row is a repo nobody
# checked, and the run still said "0 failed".
run --check
rows="$(printf '%s\n' "$OUT" | grep -cE '^  (ok|would|HALF|BAD|BLIND) ')"
check 'one row per repo in the list' 5 "$rows"

# --- which credential minted the token is said, not guessed -----------
run --check
contains 'App is the default credential' 'credential: App' "$OUT"
OUT="$(GH_TOKEN=ghp_stub SELFDEV_RUNNER_API="$T/api" SELFDEV_APP_DIR="$T/etc" \
       RUNNER_ROOT="$T/runners" SYSTEMD_DIR="$T/systemd" bash "$TOOL" --check 2>&1)"
contains 'a supplied token is named' 'credential: supplied GH_TOKEN' "$OUT"

# a supplied token needs no App credential at all
OUT="$(GH_TOKEN=ghp_stub SELFDEV_APP_DIR="$T/etc" GITHUB_API="http://127.0.0.1:1" \
       RUNNER_ROOT="$T/runners" SYSTEMD_DIR="$T/systemd" bash "$TOOL" --check 2>&1)"; RC=$?
check 'GH_TOKEN skips the App key check, and an unreachable API is BLIND' 6 "$RC"
contains 'unreachable API says BLIND' 'BLIND' "$OUT"

# --- --check writes nothing ------------------------------------------
before="$(find "$T/runners" "$T/systemd" | sort)"
run --check
after="$(find "$T/runners" "$T/systemd" | sort)"
check '--check writes nothing' "$before" "$after"

# --- a missing App key is BLIND, not "no runners needed" --------------
OUT="$(SELFDEV_APP_DIR="$T/etc" RUNNER_ROOT="$T/runners" SYSTEMD_DIR="$T/systemd" \
       bash "$TOOL" --check 2>&1)"; RC=$?
check 'no credential exits 6' 6 "$RC"
contains 'no credential says BLIND' 'BLIND' "$OUT"

# an unreadable key is BLIND too -- the witness is a read, not a stat
printf 'SELFDEV_APP_ID=1\nSELFDEV_APP_KEY=%s/nope.pem\n' "$T" > "$T/etc/gh-app.conf"
OUT="$(SELFDEV_APP_DIR="$T/etc" RUNNER_ROOT="$T/runners" SYSTEMD_DIR="$T/systemd" \
       bash "$TOOL" --check 2>&1)"; RC=$?
check 'unreadable key exits 6' 6 "$RC"
rm -f "$T/etc/gh-app.conf"

# --- COULD NOT LOOK is not "not a member": --apply cannot remove it --------
mkdir -p "$T/runners/blindrepo"
before="$(find "$T/runners" "$T/systemd" | sort)"
run --check
contains 'an unreadable marker is BLIND' 'BLIND   blindrepo: could not read .agent-project' "$OUT"
contains 'and says nothing was removed on it' 'membership unknown, nothing removed' "$OUT"
check 'and the run fails rather than passing quietly' 1 "$RC"
check 'and it removed nothing' "$before" "$(find "$T/runners" "$T/systemd" | sort)"
rm -rf "$T/runners/blindrepo"

# --- a listener needs SECONDS to connect, so the probe must not call that
# --- dead -- and must still fail a runner that never comes up. Reached only
# --- from --apply (uid 0), so lift the function out and drive its witness --
eval "$(sed -n '/^wait_serving()/,/^}/p' "$TOOL")"
SERVING_TIMEOUT=3
runner_state() { cat "$T/state"; }

printf '%s' none > "$T/state"
t0=$(date +%s); wait_serving deadrepo >/dev/null; rc=$?; el=$(( $(date +%s) - t0 ))
check 'a listener that never appears is still BAD' 1 "$rc"
check 'and it gives up AT the ceiling, not sooner and not forever' yes \
  "$([ "$el" -ge 3 ] && [ "$el" -le 8 ] && echo yes || echo no)"

printf '%s' online-local > "$T/state"
wait_serving liverepo >/dev/null
check 'a listener already serving passes at once' 0 "$?"

echo 0 > "$T/n"          # none, none, then a listener -- the race itself
runner_state() { local n; n=$(( $(cat "$T/n") + 1 )); echo "$n" > "$T/n"
                 [ "$n" -ge 3 ] && printf '%s' online-local || printf '%s' none; }
wait_serving slowrepo >/dev/null
check 'a listener that comes up late is waited for, not failed' 0 "$?"

# --- --apply needs root, so provision_one's own ORDER is the witness -------
body="$(sed -n '/^provision_one()/,/^}/p' "$TOOL")"
mint="$(printf '%s\n' "$body" | grep -n 'registration_token' | head -1 | cut -d: -f1)"
write="$(printf '%s\n' "$body" | grep -n '^  install -d' | head -1 | cut -d: -f1)"
check 'provision_one mints the token before it creates the directory' yes \
  "$([ -n "$mint" ] && [ -n "$write" ] && [ "$mint" -lt "$write" ] && echo yes || echo no)"

run --install-cadence
contains '--install-cadence: --check still goes to /dev/null, unchanged' \
  '--check --quiet >/dev/null 2>&1' "$OUT"
contains '--install-cadence: --apply output is captured, not discarded' \
  '--apply >>' "$OUT"
contains '--install-cadence: the capture is a real log path, not /dev/null' \
  'selfdev-runner-provision.apply.log 2>&1' "$OUT"

# --- --apply as non-root refuses --------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  run --apply
  check '--apply as non-root exits 1' 1 "$RC"
  contains '--apply as non-root says why' 'needs root' "$OUT"
fi

run --check
noquiet_rc="$RC"
run --check --quiet
check '--quiet prints nothing' '' "$OUT"
check '--quiet still exits on the same verdict as without it' "$noquiet_rc" "$RC"

# --- usage --------------------------------------------------------------
run --wat
check 'unknown flag exits 2' 2 "$RC"

printf '%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
