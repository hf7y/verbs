#!/usr/bin/env bash
# Test harness for no-self-dev.sh. Runs the real script against a
# throwaway self-dev inventory and a fake $HOME fixture tree, so every
# verdict x probe-state cell is exercised deterministically and no real
# unit, crontab or dotfile is ever read.
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
H="$T/home"
mkdir -p "$H/.local/bin" "$H/.local/share" "$H/.config/systemd/user" "$H/.claude"

fails=0
# assert <label> <expected-substring> -- against the CURRENT $out
assert_has() {
  if grep -qF -- "$2" <<<"$out"; then
    printf 'ok:   %s\n' "$1"
  else
    printf 'MISS: %s (no "%s" in output)\n' "$1" "$2"; fails=$((fails + 1))
  fi
}
assert_rc() {
  if [ "$rc" -eq "$2" ]; then
    printf 'ok:   %s (rc=%s)\n' "$1" "$rc"
  else
    printf 'MISS: %s -- expected rc=%s, got %s\n' "$1" "$2" "$rc"; fails=$((fails + 1))
  fi
}

# Run the real script against the fixture. Every root the script reads is
# redirected, so nothing here can touch the live machine.
run() {
  out="$(SENECHAL_CONFIG="$T/conf.json" \
         SENECHAL_HOSTNAME=fixturehost \
         SENECHAL_SELFDEV_HOME="$H" \
         SENECHAL_CLAUDE_SETTINGS="$H/.claude/settings.json" \
         SENECHAL_CRONTAB_FILE="$T/crontab" \
         HOME="$H" \
         bash ./no-self-dev.sh "$@" 2>&1)"
  rc=$?
}

# Write an inventory whose host matches the fixture hostname.
conf() { printf '{ "self_dev": { "host": "fixturehost", "items": [ %s ] } }\n' "$1" > "$T/conf.json"; }
item() { # item <id> <kind> <target> <verdict> [phase]
  printf '{"id":"%s","kind":"%s","target":"%s","verdict":"%s","phase":%s,"owner":"o","why":"w","retire":"R-%s"}' \
    "$1" "$2" "$3" "$4" "${5:-1}" "$1"
}

printf '== fixture: %s\n\n' "$T"

# ---------------------------------------------------------------- 1. gone
: > "$T/crontab"
conf "$(item absent-file path '~/.local/bin/nope' must-be-absent)"
run
assert_rc "all-clear is a real pass" 0
assert_has "absent must-be-absent item reads gone" "absent-file -- gone"
assert_has "clean pass names the host" "SELF-DEV IS OFF fixturehost"

# ------------------------------------------------- 2. straggler is a FAIL
touch "$H/.local/bin/straggler"
conf "$(item straggler path '~/.local/bin/straggler' must-be-absent)"
run
assert_rc "a straggler fails" 1
assert_has "straggler is named STILL HERE" "straggler -- STILL HERE"
assert_has "the retire command is printed for a human to run" "retire: R-straggler"

# ------------------------------------- 3. must-remain: absent is ALSO a FAIL
# The half of the definition that stops the teardown from overshooting.
conf "$(item keeper path '~/.local/bin/keeper' must-remain 0)"
run
assert_rc "a wrongly-removed keeper fails" 1
assert_has "keeper loss is reported as overshoot" "keeper -- GONE, and it was supposed to stay"
assert_has "keeper loss routes to its owner, not to senechal" "senechal does not"
touch "$H/.local/bin/keeper"
run
assert_rc "keeper present is a pass" 0
assert_has "surviving keeper reads as intended" "keeper -- still here, as it must be"

# ------------------------------------------------ 4. deferred is never a pass
conf "$(item undecided deferred-note '~/git-remotes' deferred 5)"
run
assert_rc "a deferred item is INCOMPLETE, not a pass" 2
# The label is generic on purpose since 2026-08-06: the per-item reason
# lives in the item's `retire` field and is printed as `next:`. Asserting
# the old hardcoded "until the destination host is named" wording froze a
# claim that stopped being true the day Zach named monkey.
assert_has "deferred says it has no verdict" "deferred -- no verdict yet"
assert_has "deferred points at the item's own reason" "next:"

# ------------------------------------- 5. an unknown kind must not pass
# A typo in senechal.json would otherwise silently drop an item from the
# definition of done -- the same class as an empty inventory.
conf "$(item typo systemd-uzer-unit 'x.service' must-be-absent)"
run
assert_rc "an unrecognised kind is INCOMPLETE" 2
assert_has "unrecognised kind is named" "unrecognised kind: systemd-uzer-unit"

# ---------------------------------------- 6. empty inventory is not a pass
printf '{ "self_dev": { "host": "fixturehost", "items": [] } }\n' > "$T/conf.json"
run
assert_rc "an empty inventory fails rather than passing" 1
assert_has "empty inventory says why that is not a pass" "self_dev.items is empty"

# ------------------------------- 7. wrong host probes nothing, and says so
conf "$(item straggler path '~/.local/bin/straggler' must-be-absent)"
out="$(SENECHAL_CONFIG="$T/conf.json" SENECHAL_HOSTNAME=otherhost \
       SENECHAL_SELFDEV_HOME="$H" HOME="$H" bash ./no-self-dev.sh 2>&1)"; rc=$?
assert_rc "an inventory for another host is INCOMPLETE" 2
assert_has "wrong host is stated, not silently skipped" "running on otherhost"
assert_has "wrong host probes nothing" "Nothing was probed"

# ------------------------------------------------------- 8. crontab probe
# Commented-out lines must read absent: realisateur left mandark's crontab
# as a block of comments EXPLAINING the removal, and that documentation
# must not be mistaken for a live dispatcher.
cat > "$T/crontab" <<'CT'
# EMPTIED -- the scheduler block and the weight-audit line were removed.
#*/5 * * * * usage-paced-runner.sh
PATH=/usr/bin
CT
conf "$(item cron crontab-active '(usage-paced-runner|weight-audit)' must-be-absent)"
run
assert_rc "a commented-out dispatcher line is absent" 0
assert_has "commented dispatcher reads gone" "cron -- gone"
printf '*/5 * * * * usage-paced-runner.sh\n' >> "$T/crontab"
run
assert_rc "an active dispatcher line fails" 1
assert_has "active dispatcher counts matching lines" "active line(s) match"

# ------------------------------------------------------- 9. claude hook
printf '{"hooks":{"SessionStart":[{"hooks":[{"command":"/x/realisateur/bin/session-marker.sh acquire"}]}]}}\n' \
  > "$H/.claude/settings.json"
conf "$(item hook claude-hook 'realisateur/bin/session-marker.sh' must-be-absent 4)"
run
assert_rc "a wired hook fails" 1
assert_has "hook is found by command substring" "session-marker.sh is wired"
printf '{"hooks":{}}\n' > "$H/.claude/settings.json"
run
assert_rc "an unwired hook passes" 0

# ------------------------------------------ 10. symlinks are still present
# -e follows symlinks, so a link into an ARCHIVED repo would read absent
# under a naive check -- while still working when typed. That is the
# scheduler-path-entries hazard exactly.
ln -sfn "$T/does-not-exist/scheduler" "$H/.local/bin/dangling"
conf "$(item dangling path '~/.local/bin/dangling' must-be-absent)"
run
assert_rc "a dangling symlink is still present" 1
assert_has "dangling symlink reports its target" "symlink -> "

# ================= the two expansion regressions, pinned ================

# --- 11. brace alternation must expand. Bash performs brace expansion
# BEFORE parameter expansion, so a `{a,b}` arriving inside a variable is
# never expanded by bash at all: a naive `for p in $pattern` globs for a
# literal directory named "{a,b}", finds nothing, and reports the item as
# already torn down. Live symptom: 6 bibliothecaire units read as gone.
touch "$H/.local/bin/tool.service" "$H/.local/bin/tool.timer"
conf "$(item braces glob '~/.local/bin/tool.{service,timer}' must-be-absent)"
run
assert_rc "brace alternation finds its files" 1
assert_has "both brace alternatives matched" "2 match(es)"

# --- 12. multi-pattern specs must not be eaten by nullglob. Splitting a
# spec with an unquoted `for pat in $spec` also performs PATHNAME
# expansion on it; with nullglob set, every pattern that does not match
# relative to the CWD is deleted before the loop body runs, and an item
#   [rest: vault:senechal/header-archaeology-20260818.md]
mkdir -p "$H/.local/share/alpha-nightly-batch" "$H/.local/share/beta-nightly-batch"
touch "$H/.local/bin/gamma-batch-loop.sh"
conf "$(item multi glob '~/.local/share/*-nightly-batch ~/.local/bin/*-batch-loop.sh' must-be-absent)"
run
assert_rc "a multi-glob spec finds its matches" 1
assert_has "every pattern in the spec was expanded, not dropped" "3 match(es)"
# And the false-all-clear direction, stated as its own assertion: a spec
# of only wildcard patterns that match nothing must still be a real
# absent, not an accident.
conf "$(item multi glob '~/.local/share/*-no-such-thing ~/.local/bin/*-no-such-thing' must-be-absent)"
run
assert_rc "genuinely-absent globs are a real pass" 0

# --- 13. a spec that could reach the shell as code is refused, and
# refusal is INCOMPLETE rather than a pass.
conf "$(item danger glob '~/.local/bin/$(touch pwned)' must-be-absent)"
run
assert_rc "a metacharacter spec is refused as INCOMPLETE" 2
assert_has "refusal says why" "refusing to expand"
if [ -e "$H/.local/bin/pwned" ] || [ -e ./pwned ]; then
  printf 'MISS: command substitution in a config target EXECUTED\n'; fails=$((fails + 1))
else
  printf 'ok:   command substitution in a config target did not execute\n'
fi

# --------------------------- 14. read-only: the fixture is not mutated
before="$(find "$H" | sort | md5sum)"
conf "$(item straggler path '~/.local/bin/straggler' must-be-absent)"
run
after="$(find "$H" | sort | md5sum)"
if [ "$before" = "$after" ]; then
  printf 'ok:   the check removed and created nothing\n'
else
  printf 'MISS: the check mutated the fixture tree\n'; fails=$((fails + 1))
fi

# --- 15. the two copies of the inventory must not drift -----------------
# senechal.json is gitignored, so the tracked senechal.json.example is the
# only copy another host or project can read, and the reaped migration brief
# (hf7y/ecosystem1-vault, senechal/MIGRATION-OFF-MANDARK.md)
#   [rest: vault:senechal/header-archaeology-20260818.md]
_live_config="${SENECHAL_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/senechal/senechal.json}"
if [ ! -f "$_live_config" ] && [ -f ../senechal.json ]; then
  # Pre-#67 layout, still honoured so an old checkout is compared, not skipped.
  _live_config=../senechal.json
fi
if [ -f "$_live_config" ] && [ -f ../senechal.json.example ]; then
  if python3 - "$_live_config" ../senechal.json.example <<'PY'
import json, sys
a = json.load(open(sys.argv[1])).get('self_dev')
b = json.load(open(sys.argv[2])).get('self_dev')
raise SystemExit(0 if a is not None and a == b else 1)
PY
  then
    printf 'ok:   %s and .example self_dev blocks are identical\n' "$_live_config"
  else
    printf 'MISS: self_dev has DRIFTED between %s and .example\n' "$_live_config"
    printf '      the tracked example is the only copy off-host readers get\n'
    fails=$((fails + 1))
  fi
else
  # Not a pass. On a host with no live config there is nothing to compare,
  # but "nothing to compare" and "the two copies agree" are different
  # answers and this guard existed for five days only saying the second.
  printf 'SKIP: no live config at %s -- drift NOT checked (this is not a pass)\n' "$_live_config"
fi

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'all assertions passed\n'; exit 0
fi
printf '%d assertion(s) failed\n' "$fails"
exit 1
