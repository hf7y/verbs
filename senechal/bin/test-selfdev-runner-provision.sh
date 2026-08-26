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

# A stub transport: one private repo, one public repo, and nothing else.
cat > "$T/api" <<'STUB'
#!/usr/bin/env bash
case "$2" in
  /installation/repositories*)
    echo '{"repositories":[{"name":"privrepo","private":true},{"name":"pubrepo","private":false},{"name":"nocirepo","private":true}]}' ;;
  # membership is private AND has workflows: nocirepo is private with no CI.
  /repos/*/nocirepo/contents/.github/workflows) exit 1 ;;
  /repos/*/contents/.github/workflows) echo '[{"name":"tests.yml"}]' ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "$T/api"

run() { # <args...>
  OUT="$(SELFDEV_RUNNER_API="$T/api" SELFDEV_APP_DIR="$T/etc" \
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
contains 'a private repo with no CI needs none either' 'ok      nocirepo: needs no runner' "$OUT"

# a public repo that HAS a runner is a removal, with nothing edited
mkdir -p "$T/runners/pubrepo"; printf 'actions.runner.hf7y-pubrepo.mandark-pubrepo.service\n' > "$T/runners/pubrepo/.service"
run --check
contains 'public + runner is a removal' 'would   pubrepo: needs no runner -- REMOVE' "$OUT"
rm -rf "$T/runners/pubrepo"

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
check 'one row per repo in the list' 3 "$rows"

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

# --- --apply as non-root refuses --------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  run --apply
  check '--apply as non-root exits 1' 1 "$RC"
  contains '--apply as non-root says why' 'needs root' "$OUT"
fi

# --- usage --------------------------------------------------------------
run --wat
check 'unknown flag exits 2' 2 "$RC"

printf '%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
