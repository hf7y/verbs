#!/usr/bin/env bash
# Shared helpers for senechal's shell-side tools -- `remedies/*.sh`
# (per-concern enable/verify) and `health/*.sh` (estate health checks).
# Sourced, never run directly.
#
#   [rest: vault:senechal/header-archaeology-20260818.md]

# Exit-code contract, shared by every verify/check:
#   0  everything passed
#   1  real failure -- broken now, or the concern is NOT in effect
#   2  could not fully check (no tmux server, no DISPLAY, needs root)
#   [rest: vault:senechal/header-archaeology-20260818.md]
RC_PASS=0
RC_FAIL=1
RC_INCOMPLETE=2
RC_WARN=3

# Rank an exit code by real severity, for aggregating several checks.
rc_severity() {
  case "$1" in
    1) echo 3 ;;
    2) echo 2 ;;
    3) echo 1 ;;
    *) echo 0 ;;
  esac
}

# Repo root, so tools can find their sibling files wherever they're
# invoked from.
#
# NOTE THIS IS THE INVOCATION PATH, not a deployment path. It is whatever
# directory this file physically sits in -- a permanent clone, a worktree,
# or a `mktemp -d` that will be gone in ten minutes. That is correct for
# finding a sibling script during THIS run, and wrong for anything written
# down and read later. Use senechal_entrypoint/refuse_undeployable_path
# below before baking it into a symlink, a unit, or a config file.
SENECHAL_ROOT="${SENECHAL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# --- paths that outlive the process that wrote them ---------------------
#
# A path baked into a systemd unit's ExecStart or a symlink on PATH is read
# long after this run, by something that will not notice it went bad. Two
# ways it goes bad, both observed on mandark:
#
#   /tmp   -- window-spawn-desktop.sh baked /tmp/tmp.XXXX/tools/<shim> into
#             ~/.local/bin from a vault.sh temp clone; verify passed at
#             enable time because the directory was still there (#2026-08-16).
#             On 2026-08-22 21:23 the same thing happened to BOTH --user
#             timers: /tmp/tmp.UUh80RFo5e baked into ExecStart, 203/EXEC
#             every run from 22:25 on, estate unguarded and nothing saying so.
#   a clone -- deletable, rebasable, switchable under a consumer that never
#             notices. The deployed form is the verb build (Zach, 2026-08-23:
#             "no we don't do shims anymore"), which is dated, immutable, and
#             repointed by an upgrade rather than edited underneath you.
#
# Refuse at the source. A guard that only fires after the directory is gone
# is not a guard.

# 0 if $1 resolves under a temp directory.
ephemeral_path() {
  case "$(readlink -f "$1")" in
    /tmp/*|/var/tmp/*|"${TMPDIR:-/nonexistent}"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if $1 sits inside a git working tree (a clone, not a build).
in_working_clone() {
  local d
  d="$(readlink -f "$1")"
  [ -d "$d" ] || d="$(dirname "$d")"
  git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# The verb build's copy of this project, if one is installed. Echoes
# nothing when there is none, so a caller can test for empty.
senechal_deployed_root() {
  local d="${SENECHAL_DEPLOYED_ROOT:-$HOME/.local/share/verb-builds/current/senechal}"
  [ -d "$d" ] && printf '%s\n' "$d"
}

# Resolve a repo-relative entrypoint (e.g. health/estate-health.sh) to the
# deployed copy when there is one, else to this checkout. The fallback is
# deliberate: `verify` and by-hand runs must keep working from a clone.
# What must NOT fall back is writing the path down -- that is what
# refuse_undeployable_path is for.
senechal_entrypoint() {
  local rel="$1" root
  root="$(senechal_deployed_root)"
  if [ -n "$root" ] && [ -x "$root/$rel" ]; then
    printf '%s\n' "$root/$rel"
  else
    printf '%s\n' "$SENECHAL_ROOT/$rel"
  fi
}

# Refuse to persist $1 anywhere durable. $2 names what would have been
# written, for the message. Returns RC_INCOMPLETE -- "I did not do it",
# never a silent pass.
refuse_undeployable_path() {
  local p="$1" what="${2:-this}" root rp rr
  # Inside the DECLARED build root is always allowed -- that root is the
  # deploy target by definition. This is not an escape hatch: it is the one
  # place the machine says builds live. A hermetic test points
  # SENECHAL_DEPLOYED_ROOT at its own mktemp -d tree and is thereby
  # declaring its build location, which is why the /tmp rule below does not
  # then fire on it. With the variable unset -- every real run -- the root
  # is under $HOME and /tmp is refused as normal.
  root="$(senechal_deployed_root)"
  if [ -n "$root" ]; then
    rp="$(readlink -f "$p")"; rr="$(readlink -f "$root")"
    # The root ITSELF counts, not just paths under it: WorkingDirectory=
    # legitimately names the tree root.
    case "$rp" in "$rr"|"$rr"/*) return 0 ;; esac
  fi
  if ephemeral_path "$p"; then
    printf 'REFUSING: %s would name %s\n' "$what" "$p" >&2
    printf '  That is a temporary directory. It will be deleted, and %s will\n' "$what" >&2
    printf '  keep pointing at it with nothing watching -- exactly how both --user\n' >&2
    printf '  timers went 203/EXEC on 2026-08-22. Run this from the verb build.\n' >&2
    return "$RC_INCOMPLETE"
  fi
  if in_working_clone "$p"; then
    printf 'REFUSING: %s would name %s\n' "$what" "$p" >&2
    printf '  That is a git working clone -- deletable, rebasable, switchable\n' >&2
    printf '  under a consumer that never notices. The deployed form is\n' >&2
    printf '  ~/.local/share/verb-builds/current/senechal/. If it is not there,\n' >&2
    printf '  the tree is not on the branch that ships (origin/bashified); cut a\n' >&2
    printf '  build rather than pointing at this checkout.\n' >&2
    return "$RC_INCOMPLETE"
  fi
  return 0
}

# The config belongs to the MACHINE, not to any checkout: XDG config,
# which outlives every build, worktree and clone. senechal.json is
# untracked, and a verb build is a disposable directory an ordinary
# upgrade repoints away from -- the pair that cost gardien its garde.json
# (hf7y/gardien#7, hf7y/senechal#67). SENECHAL_CONFIG still points a test
# or a second estate somewhere else.
SENECHAL_CONFIG="${SENECHAL_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/senechal/senechal.json}"

# "I cannot see" -- exit RC_INCOMPLETE (2), which rc_severity() ranks
# ABOVE a warning precisely so it can never read as a pass.
#
# A config file that is MISSING or UNPARSEABLE is loud, because
# otherwise every caller quietly receives its hardcoded default and
# prints a confident, much emptier report. A key that is simply ABSENT
# stays silent: there the supplied default IS the correct answer.
senechal_blind() {
  printf 'senechal: CANNOT SEE -- %s\n' "$1" >&2
  printf 'senechal: this is "could not look" (exit %s), NOT "nothing to report".\n' \
    "$RC_INCOMPLETE" >&2
  # cfg() and friends run inside "$(...)", where a plain `exit` would end
  # only the substitution subshell and hand the caller an empty string --
  # exactly the silent degradation this exists to prevent. $$ stays the
  # top-level shell even inside a subshell (unlike $BASHPID), so signal
  # that shell and let the TERM trap below turn it into the contract's
  # exit code. Never from an interactive shell: that would kill the
  # human's terminal for sourcing this file by hand.
  case "$-" in
    *i*) ;;
    *) [ "${BASHPID:-$$}" != "$$" ] && kill -s TERM "$$" 2>/dev/null ;;
  esac
  exit "$RC_INCOMPLETE"
}
trap 'exit '"$RC_INCOMPLETE" TERM

# Why the config could not be read, re-probed at the moment of failure
# rather than guessed, so the message names the actual cause.
_config_why() {
  if [ ! -e "$SENECHAL_CONFIG" ]; then
    printf 'the file does not exist'
  elif [ ! -r "$SENECHAL_CONFIG" ]; then
    printf 'the file exists but is not readable'
  elif ! command -v python3 >/dev/null 2>&1; then
    printf 'python3 is not installed, so nothing here can parse JSON'
  else
    python3 - "$SENECHAL_CONFIG" 2>/dev/null <<'PY' || printf 'it does not parse'
import json, sys
try:
    json.load(open(sys.argv[1]))
    print('it re-read cleanly -- the file changed underneath this run')
except Exception as e:
    print('%s: %s' % (type(e).__name__, e))
PY
  fi
}

# Refuse to run at all without a readable config. Called at SOURCE time,
# below, so the failure lands in the top-level shell (where `exit` really
# exits) before a single reassuring line has been printed.
senechal_config_require() {
  local example="$SENECHAL_ROOT/senechal.json.example"
  if [ -f "$SENECHAL_CONFIG" ] && python3 - "$SENECHAL_CONFIG" 2>/dev/null <<'PY'
import json, sys
json.load(open(sys.argv[1]))
PY
  then
    return 0
  fi
  senechal_blind "no usable config at $SENECHAL_CONFIG -- $(_config_why).
    Every device, host and threshold would fall back to a hardcoded default,
    and this run would print a confident, empty report. Create it with:
      mkdir -p $(dirname "$SENECHAL_CONFIG") && cp $example $SENECHAL_CONFIG && chmod 600 $SENECHAL_CONFIG
    then edit it."
}

# Read one value out of senechal.json -- the single config source, so
# thresholds and the device registry are never retyped per script.
# Usage: cfg <dotted.key> <default>.  Lists/objects come back as JSON.
#
# An absent KEY prints the default and exits 0 -- silent, because the
# default is the right answer. An unreadable FILE exits nonzero and is
# escalated to senechal_blind, because there the default is a lie.
cfg() {
  local out rc
  out="$(python3 - "$SENECHAL_CONFIG" "$1" "$2" 2>/dev/null <<'PY'
import json, sys
path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    cur = json.load(open(path))
except Exception:
    raise SystemExit(9)   # UNREADABLE -- not the same thing as "key absent"
for k in key.split('.'):
    if isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        print(default); raise SystemExit(0)   # absent key: the default is correct
print(json.dumps(cur) if isinstance(cur, (list, dict)) else cur)
PY
  )"
  rc=$?
  [ "$rc" -eq 0 ] \
    || senechal_blind "cannot read '$1' from $SENECHAL_CONFIG -- $(_config_why)"
  printf '%s\n' "$out"
}

# Read a config list as one item per line, so callers can `while read`
# it instead of hand-parsing the JSON `cfg` hands back for a list.
# Usage: cfg_list <dotted.key> [newline-separated defaults]
# Same contract as cfg: an absent key yields the caller's default (the
# right answer), an unreadable file is escalated by cfg to senechal_blind.
cfg_list() {
  local raw
  raw="$(cfg "$1" "__ABSENT__")"
  [ "$raw" = "__ABSENT__" ] && { printf '%s' "${2:-}"; return 0; }
  printf '%s' "$raw" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    v = json.loads(raw)
except Exception:
    v = raw
for item in (v if isinstance(v, list) else [v]):
    print(item)
' 2>/dev/null || printf '%s' "${2:-}"
}

# Emit the estate device registry, one line per device, fields in order:
#   name kind addr reach owner expect ssh_host os
# separated by ASCII unit separator (\x1f) -- NOT tab: bash `read`
# treats tab as IFS whitespace and collapses consecutive tabs, so a
#   [rest: vault:senechal/header-archaeology-20260818.md]
cfg_devices() {
  local out rc
  out="$(python3 - "$SENECHAL_CONFIG" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(9)
for dev in d.get('estate', {}).get('devices', []):
    print('\x1f'.join(str(dev.get(k, '')) for k in
          ('name', 'kind', 'addr', 'reach', 'owner', 'expect',
           'ssh_host', 'os')))
PY
  )"
  rc=$?
  [ "$rc" -eq 0 ] \
    || senechal_blind "cannot read estate.devices from $SENECHAL_CONFIG -- $(_config_why). An estate with no devices and an estate we cannot see are not the same report."
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# Emit the registered machine-config footprint, one line per entry,
# fields in order:
#   id host owner kind target status retire notes
# separated by ASCII unit separator (\x1f), for the same reason
#   [rest: vault:senechal/header-archaeology-20260818.md]
cfg_footprint() {
  local out rc
  out="$(python3 - "$SENECHAL_CONFIG" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(9)
for e in d.get('estate', {}).get('footprint', []):
    print('\x1f'.join(str(e.get(k, '')).replace('\x1f', ' ') for k in
          ('id', 'host', 'owner', 'kind', 'target', 'status',
           'retire', 'notes')))
PY
  )"
  rc=$?
  [ "$rc" -eq 0 ] \
    || senechal_blind "cannot read estate.footprint from $SENECHAL_CONFIG -- $(_config_why)"
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# Emit the credential inventory, one line per secret, fields in order:
#   id host owner path purpose mode recovery reprovision_cost offhost
#   status verify reprovision notes
# separated by \x1f, same reason as cfg_footprint.
#
# `verify` and `reprovision` are what make NOT backing a credential up a
# real strategy rather than a shrug (Zach, 2026-08-13). Presence is the
# weak question -- a revoked token is still a file. `verify` is a command
# that proves the credential WORKS; `reprovision` is the command or
# runbook that issues a new one. Between them the answer to "it's gone"
# is a procedure, not a restore.
#
# There is ONE reissue field: `reprovision`. `reprovision_cost`
# (low|medium|high|none|unknown) is the honest half -- a recorded runbook
# is not the same as a CHEAP one, so high and unknown are surfaced.
#
# `status` is the live/retired idiom estate.footprint uses, and for the
# same reason: a credential deliberately destroyed needs an entry that
# PASSES while it stays gone and FAILS if it comes back.
#
# THE VALUE IS NEVER A FIELD: this reader takes only declared metadata
# from senechal.json. A registry that stored the secret would be a
# keychain, and Zach's call on 2026-08-13 was explicitly the opposite.
cfg_secrets() {
  local out rc
  out="$(python3 - "$SENECHAL_CONFIG" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(9)
for e in d.get('estate', {}).get('secrets', []):
    print('\x1f'.join(str(e.get(k, '')).replace('\x1f', ' ') for k in
          ('id', 'host', 'owner', 'path', 'purpose', 'mode',
           'recovery', 'reprovision_cost', 'offhost', 'status', 'verify',
           'reprovision', 'notes')))
PY
  )"
  rc=$?
  [ "$rc" -eq 0 ] \
    || senechal_blind "cannot read estate.secrets from $SENECHAL_CONFIG -- $(_config_why)"
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# Emit one line per gardien backup set:
#   <expanded-path>\x1f<set-name>\x1f<exclude>\x1e<exclude>...
#
# Cross-project READ, deliberately: gardien owns backups and senechal
#   [rest: vault:senechal/header-archaeology-20260818.md]
cfg_garde_sets() {
  local conf="${GARDE_CONFIG:-$HOME/.config/gardien/garde.json}"
  [ -r "$conf" ] || return 1
  python3 - "$conf" "$HOME" 2>/dev/null <<'PY' || return 1
import json, sys
conf, home = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(conf))
except Exception:
    raise SystemExit(9)
for s in d.get('sets', []):
    p = str(s.get('path', ''))
    if not p:
        continue
    if p.startswith('~'):
        p = home + p[1:]
    # Excludes ride along, \x1e-separated. A set that excludes a path is
    # NOT copying it, and a caller that cannot see that reports a leak
    # that has already been fixed -- which is exactly what happened on
    # 2026-08-13 the moment the remedy landed.
    ex = '\x1e'.join(str(e) for e in (s.get('exclude') or []))
    print('\x1f'.join((p.rstrip('/'), str(s.get('name', '')), ex)))
PY
}

# Emit the self-dev teardown inventory, one line per item, fields in
# order:
#   id kind target owner phase verdict why retire
# separated by ASCII unit separator (\x1f) -- same reason as
#   [rest: vault:senechal/header-archaeology-20260818.md]
cfg_self_dev() {
  local out rc
  out="$(python3 - "$SENECHAL_CONFIG" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(9)
for e in d.get('self_dev', {}).get('items', []):
    print('\x1f'.join(str(e.get(k, '')).replace('\x1f', ' ') for k in
          ('id', 'kind', 'target', 'owner', 'phase', 'verdict',
           'why', 'retire')))
PY
  )"
  rc=$?
  [ "$rc" -eq 0 ] \
    || senechal_blind "cannot read self_dev.items from $SENECHAL_CONFIG -- $(_config_why)"
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# Emit the taste registry, one line per entry, fields in order:
#   id file homes status owner notes
# where `homes` is comma-joined `account@host` tokens (host = a device
# name from estate.devices; account = the UNIX account on that device).
#   [rest: vault:senechal/header-archaeology-20260818.md]
cfg_taste() {
  local out rc
  out="$(python3 - "$SENECHAL_CONFIG" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(9)


def homes_of(e):
    """-> ['account@host', ...]. `homes` is authoritative; `hosts` is the
    older shorthand for the same thing with account=zach."""
    if e.get('homes'):
        out = []
        for h in e['homes']:
            if isinstance(h, str):          # bare "host" inside homes[]
                out.append('zach@' + h)
            else:
                out.append('%s@%s' % (h.get('account', 'zach') or 'zach',
                                      h.get('host', '')))
        return out
    return ['zach@' + h for h in e.get('hosts', [])]


for e in d.get('estate', {}).get('taste', []):
    homes = ','.join(homes_of(e))
    row = [e.get('id',''), e.get('file',''), homes, e.get('status',''),
           e.get('owner',''), str(e.get('notes','')).replace('\x1f', ' ')]
    print('\x1f'.join(row))
PY
  )"
  rc=$?
  [ "$rc" -eq 0 ] \
    || senechal_blind "cannot read estate.taste from $SENECHAL_CONFIG -- $(_config_why)"
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# Resolve one `account@host` home token (as emitted by cfg_taste) into
# how to reach it, using estate.devices as the ONLY source of transport
# knowledge -- no remedy hardcodes a host, a user, or an ssh alias.
#
#   [rest: vault:senechal/header-archaeology-20260818.md]
resolve_home() {
  local home="$1" acct host n k addr reach owner expect ssh_host os
  acct="${home%%@*}"
  host="${home#*@}"
  [ -n "$acct" ] && [ -n "$host" ] && [ "$acct" != "$home" ] || {
    printf 'undeclared\x1fmalformed home token "%s" (want account@host)\n' "$home"
    return 0
  }
  while IFS=$'\x1f' read -r n k addr reach owner expect ssh_host os; do
    [ "$n" = "$host" ] || continue
    case "$reach" in
      local)
        if [ "$acct" = "$(id -un)" ]; then
          printf 'local\x1f\n'
        else
          printf 'skip\x1faccount "%s" on local host %s is not the account this check runs as (%s)\n' \
            "$acct" "$host" "$(id -un)"
        fi
        ;;
      ssh) printf 'ssh\x1f%s@%s\n' "$acct" "${ssh_host:-$host}" ;;
      *)   printf 'skip\x1freach="%s" on %s -- no probe for this transport\n' "$reach" "$host" ;;
    esac
    return 0
  done <<< "$(cfg_devices)"
  printf 'undeclared\x1fhost "%s" is not in estate.devices -- the taste registry references an undeclared device\n' "$host"
  return 0
}

# Emit the app-output-path registry, one line per entry, fields in
# order: name extension config_file section key canonical_dir
# separated by \x1f (same reason as cfg_devices/cfg_footprint: a
# missing middle field must not shift columns). Consume with:
#   [rest: vault:senechal/header-archaeology-20260818.md]
cfg_app_output_paths() {
  local out rc
  out="$(python3 - "$SENECHAL_CONFIG" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(9)
for e in d.get('app_output_paths', {}).get('apps', []):
    print('\x1f'.join(str(e.get(k, '')).replace('\x1f', ' ') for k in
          ('name', 'extension', 'config_file', 'section', 'key', 'canonical_dir')))
PY
  )"
  rc=$?
  [ "$rc" -eq 0 ] \
    || senechal_blind "cannot read app_output_paths.apps from $SENECHAL_CONFIG -- $(_config_why). 'no apps registered' and 'cannot see the registry' are not the same report."
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# Emit the unused-software removal registry, one line per item, fields
# in order:
#   name kind evidence desktop_id
# where kind is "apt", "snap", or "localbin", evidence is the free-text
#   [rest: vault:senechal/header-archaeology-20260818.md]
cfg_unused_software() {
  local out rc
  out="$(python3 - "$SENECHAL_CONFIG" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(9)
for e in d.get('unused_software', {}).get('items', []):
    print('\x1f'.join(str(e.get(k, '')).replace('\x1f', ' ') for k in
          ('name', 'kind', 'evidence', 'desktop_id')))
PY
  )"
  rc=$?
  [ "$rc" -eq 0 ] \
    || senechal_blind "cannot read unused_software.items from $SENECHAL_CONFIG -- $(_config_why)"
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

QUIET=0
_fail_count=0
_incomplete_count=0
_warn_count=0
_out=""

_emit() { # buffer output so --quiet can drop it on a clean pass
  _out+="$1"$'\n'
}

ok()   { _emit "  PASS  $*"; }
fail() { _emit "  FAIL  $*"; _fail_count=$((_fail_count + 1)); }
skip() { _emit "  SKIP  $* (could not check -- not a pass)"; _incomplete_count=$((_incomplete_count + 1)); }
warn_() { _emit "  WARN  $*"; _warn_count=$((_warn_count + 1)); }
note() { _emit "        $*"; }
head_() { _emit ""; _emit "$*"; }

# say/warn go straight to the terminal -- for `enable`, which is always
# interactive and should narrate as it goes.
say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Print the buffered verify report and exit on the contract above.
# On a clean pass with --quiet, prints nothing at all (cron-friendly).
# $1: optional closing line for the all-clear case.
finish_verify() {
  local rc=$RC_PASS
  if [ "$_fail_count" -gt 0 ]; then
    rc=$RC_FAIL
  elif [ "$_incomplete_count" -gt 0 ]; then
    rc=$RC_INCOMPLETE
  elif [ "$_warn_count" -gt 0 ]; then
    rc=$RC_WARN
  fi

  if [ "$rc" -ne $RC_PASS ] || [ "$QUIET" -eq 0 ]; then
    printf '%s' "$_out"
    say ""
    case "$rc" in
      0) say "${1:-OK -- verified.}" ;;
      1) say "FAILED -- $_fail_count check(s) failed. See each FAIL line for the fix." ;;
      2) say "INCOMPLETE -- $_incomplete_count check(s) could not run. Nothing is known to be broken, but this is not a pass." ;;
      3) say "WARNINGS -- $_warn_count check(s) degrading but not broken. Raise the threshold in senechal.json if a warning is not worth acting on." ;;
    esac
  fi
  exit "$rc"
}

# Back up a file before touching it, into a dated directory. Echoes the
# backup path. No-op (silent) if the file doesn't exist yet.
BACKUP_ROOT="${SENECHAL_BACKUP_ROOT:-$HOME/.senechal-remedy-backups}"
backup_file() {
  local f="$1" stamp dest
  [ -e "$f" ] || return 0
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_ROOT/$stamp"
  mkdir -p "$dest"
  cp -a "$f" "$dest/$(basename "$f")"
  printf '%s\n' "$dest/$(basename "$f")"
}

# True if an X/Wayland display is actually reachable. Guards the
# window-manager witness: `wmctrl -l | grep ...` returns the *pipeline's*
# status, so without this check a missing display reads as exit 0 /
# "nothing wrong" instead of "could not look".
have_display() {
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || return 1
  command -v wmctrl >/dev/null 2>&1 || return 1
  wmctrl -l >/dev/null 2>&1
}

# True if a tmux server is running and reachable (works without a
# display -- tmux uses its own socket).
have_tmux_server() {
  command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1
}

# Read one INI key from one SECTION. Prints the value (empty if the
# file, section or key is absent) and always returns 0 -- an absent key
# is a normal answer here, not an error, and a nonzero return would
# detonate under the `set -e` every caller runs with. That is not
#   [rest: vault:senechal/header-archaeology-20260818.md]
ini_get() { # <file> <section> <key>
  local file="$1" section="$2" key="$3"
  [ -f "$file" ] || return 0
  awk -v want="$section" -v key="$key" '
    /^[[:space:]]*[;#]/ { next }
    /^[[:space:]]*\[/ {
      s=$0; sub(/^[[:space:]]*\[/,"",s); sub(/\][[:space:]]*$/,"",s)
      insec = (s == want); next
    }
    insec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "")
      print; exit
    }
  ' "$file"
  return 0
}

# Every section of <file> that already defines <key>, one per line.
#
# This exists to catch a registry that names the WRONG section, which is
# otherwise invisible: point a remedy at [general] for a key the app
#   [rest: vault:senechal/header-archaeology-20260818.md]
ini_sections_with_key() { # <file> <key>
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -v key="$key" '
    /^[[:space:]]*[;#]/ { next }
    /^[[:space:]]*\[/ {
      s=$0; sub(/^[[:space:]]*\[/,"",s); sub(/\][[:space:]]*$/,"",s)
      cur=s; next
    }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { if (cur != "") print cur }
  ' "$file" | sort -u
  return 0
}

# Set an INI key under a SECTION, creating either if absent. Idempotent.
#
# SECTION-AWARE, and that is the whole point. A file-wide `^key=` match
# edits a same-named key in a section the caller never asked about, and
#   [rest: vault:senechal/header-archaeology-20260818.md]
ini_set() { # <file> <section> <key> <value>
  local file="$1" section="$2" key="$3" value="$4" tmp
  if [ ! -f "$file" ]; then
    mkdir -p "$(dirname "$file")"
    printf '[%s]\n%s=%s\n' "$section" "$key" "$value" > "$file"
    return 0
  fi
  tmp="$(mktemp "${file}.senechal.XXXXXX")"
  awk -v want="$section" -v key="$key" -v value="$value" '
    function emit() { print key "=" value; done=1 }
    /^[[:space:]]*\[/ {
      if (insec && !done) emit()
      s=$0; sub(/^[[:space:]]*\[/,"",s); sub(/\][[:space:]]*$/,"",s)
      insec = (s == want)
      print; next
    }
    insec && $0 !~ /^[[:space:]]*[;#]/ && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      # First hit becomes the new value; any later duplicate in the same
      # section is dropped rather than left to shadow it.
      if (!done) emit()
      next
    }
    { print }
    END {
      if (insec && !done) emit()
      if (!done) { print "[" want "]"; print key "=" value }
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Should a run with these counts page Zach? Threshold comes from
# senechal.json's health.alert_min_severity, so it can be tightened
# without a code change. Values, loosest to tightest:
#   incomplete -- any non-PASS run alerts (fail, warn, or could-not-check)
#   [rest: vault:senechal/header-archaeology-20260818.md]
should_alert() {
  local f="${1:-0}" i="${2:-0}" w="${3:-0}" level
  level="$(cfg health.alert_min_severity warn)"
  case "$level" in
    fail|warn|incomplete) ;;
    *)
      warn "health.alert_min_severity='$level' unrecognised -- using 'warn'"
      level=warn ;;
  esac
  # Non-numeric counts mean a caller bug. Err toward paging: a silent
  # `[: x: integer expression expected` would turn a broken caller into
  # "nothing to report", the one direction an alert gate must not fail.
  case "$f$i$w" in
    ''|*[!0-9]*) warn "should_alert got non-numeric counts ($f/$i/$w) -- alerting anyway"
                 return 0 ;;
  esac
  [ "$f" -gt 0 ] && return 0
  case "$level" in
    warn)       [ "$w" -gt 0 ] && return 0 ;;
    incomplete) { [ "$w" -gt 0 ] || [ "$i" -gt 0 ]; } && return 0 ;;
  esac
  return 1
}

# Best-effort alert delivery for a non-passing health run. Never fails
# the caller -- both channels are fire-and-forget, since a broken alert
# channel must not turn into a false FAIL on the health check itself.
# Channels, tried independently:
#   [rest: vault:senechal/header-archaeology-20260818.md]
notify_alert() {
  local summary="$1" logfile="${2:-}" urgency="${3:-critical}"
  local title="senechal estate health" msg device
  local statedir idfile last_id expire_min expire_ms new_id
  msg="$summary"
  [ -n "$logfile" ] && msg="$msg -- see $logfile"

  device="$(cfg health.kdeconnect_device "")"
  if [ -n "$device" ] && command -v kdeconnect-cli >/dev/null 2>&1; then
    if kdeconnect-cli --list-available 2>/dev/null | grep -q "$device"; then
      kdeconnect-cli -d "$device" --ping-msg "$title: $msg" >/dev/null 2>&1 || true
    fi
  fi

  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v notify-send >/dev/null 2>&1; then
    statedir="$(senechal_state_dir)"
    mkdir -p "$statedir" 2>/dev/null || true
    idfile="$statedir/notify-id.txt"
    last_id="$(cat "$idfile" 2>/dev/null || echo 0)"
    case "$last_id" in ''|*[!0-9]*) last_id=0 ;; esac

    expire_min="$(cfg health.alert_expire_minutes 60)"
    case "$expire_min" in ''|*[!0-9]*) expire_min=60 ;; esac
    if [ "$expire_min" -gt 0 ]; then
      expire_ms=$((expire_min * 60000))
      new_id="$(notify-send -u "$urgency" -t "$expire_ms" -p -r "$last_id" \
        -a senechal "$title" "$msg" 2>/dev/null)" || true
    else
      new_id="$(notify-send -u "$urgency" -p -r "$last_id" \
        -a senechal "$title" "$msg" 2>/dev/null)" || true
    fi
    case "$new_id" in ''|*[!0-9]*) ;; *) printf '%s\n' "$new_id" > "$idfile" 2>/dev/null || true ;; esac
  fi
}

# --- transient app scopes are not services (2026-08-05) -----------------
# KDE and snapd launch each app window inside a transient .scope named
# with a fresh random id. When the app exits nonzero -- a Konsole whose
# shell returned nonzero, a killed Chromium -- systemd parks that scope
#   [rest: vault:senechal/header-archaeology-20260818.md]
TRANSIENT_UNIT_PATTERNS_DEFAULT='app-*.scope
snap.*.scope
session-*.scope
vte-spawn-*.scope'

is_transient_scope() {
  local u="$1" p
  # The guard, and deliberately NOT one of the globs: patterns are
  # configuration and could be widened by hand, but a .service must
  # never be eligible -- otherwise a real service could be quietly
  # un-failed and its breakage hidden.
  case "$u" in *.scope) ;; *) return 1 ;; esac
  [ -n "${TRANSIENT_UNIT_PATTERNS+x}" ] || TRANSIENT_UNIT_PATTERNS="$(
    cfg_list health.transient_unit_patterns "$TRANSIENT_UNIT_PATTERNS_DEFAULT")"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # shellcheck disable=SC2254  -- $p is a glob on purpose
    case "$u" in $p) return 0 ;; esac
  done <<< "$TRANSIENT_UNIT_PATTERNS"
  return 1
}

# Is the code in a checkout actually the merged code?
#
# The question is deliberately NOT "which branch". This repo lives on
# feature branches and worktrees, and a branch rebased onto the mainline
#   [rest: vault:senechal/header-archaeology-20260818.md]
deploy_state() {
  local root="${1:-$SENECHAL_ROOT}" ref="${2:-origin/main}" sha dirty behind
  command -v git >/dev/null 2>&1 || { printf 'nogit - - 0\n'; return 0; }
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || { printf 'nogit - - 0\n'; return 0; }

  dirty="$(git -C "$root" status --porcelain 2>/dev/null | grep -c . || true)"
  case "$dirty" in ''|*[!0-9]*) dirty=0 ;; esac
  sha="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo '-')"

  git -C "$root" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 \
    || { printf 'noref - %s %s\n' "$sha" "$dirty"; return 0; }

  if git -C "$root" merge-base --is-ancestor "$ref" HEAD 2>/dev/null; then
    printf 'current - %s %s\n' "$sha" "$dirty"
  else
    behind="$(git -C "$root" rev-list --count "HEAD..$ref" 2>/dev/null || echo '?')"
    printf 'behind %s %s %s\n' "$behind" "$sha" "$dirty"
  fi
}

# --- transient app scopes are not services (2026-08-05) -----------------
# KDE and snapd launch each app window inside a transient .scope named
# with a fresh random id. When the app exits nonzero -- a Konsole whose
# shell returned nonzero, a killed Chromium -- systemd parks that scope
#   [rest: vault:senechal/header-archaeology-20260818.md]
TRANSIENT_UNIT_PATTERNS_DEFAULT='app-*.scope
snap.*.scope
session-*.scope
vte-spawn-*.scope'

is_transient_scope() {
  local u="$1" p
  # The guard, and deliberately NOT one of the globs: patterns are
  # configuration and could be widened by hand, but a .service must
  # never be eligible -- otherwise a real service could be quietly
  # un-failed and its breakage hidden.
  case "$u" in *.scope) ;; *) return 1 ;; esac
  [ -n "${TRANSIENT_UNIT_PATTERNS+x}" ] || TRANSIENT_UNIT_PATTERNS="$(
    cfg_list health.transient_unit_patterns "$TRANSIENT_UNIT_PATTERNS_DEFAULT")"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # shellcheck disable=SC2254  -- $p is a glob on purpose
    case "$u" in $p) return 0 ;; esac
  done <<< "$TRANSIENT_UNIT_PATTERNS"
  return 1
}

# --- alerting on EVENTS, not on LEVELS -----------------------------------
# should_alert answers "is this run non-clean?". That alone paged every
# hourly run of a non-clean estate -- 243 consecutive critical
# notifications carrying the same counts. An alert that always fires is
#   [rest: vault:senechal/header-archaeology-20260818.md]

# The identity of a finding is its text shape, not its exact numbers.
# "/ at 92%, 40G free" and "/ at 91%, 41G free" are the same finding and
# must not re-page on hourly jitter; a threshold crossing still reads as
# different because it changes the WARN/FAIL prefix, which is not
# normalized away. Long hex runs collapse too -- systemd mints a fresh
# random id per transient scope, so an un-normalized name can never
# match itself twice.
_alert_normalize() {
  sed -E 's/[0-9a-f]{8,}/<id>/g; s/[0-9]+/<n>/g'
}

# The findings that count for alerting, at the configured severity, one
# per line and sorted. A SKIP is a known gap tracked in ESTATE.md, not
# news, unless the threshold is 'incomplete' -- the same rule
# should_alert applies to the counts, applied here to the lines, so the
# two cannot drift apart and disagree about what a finding is.
_alert_findings() {
  local level="$1" pat='^  FAIL  '
  case "$level" in
    warn)       pat='^  (FAIL|WARN)  ' ;;
    incomplete) pat='^  (FAIL|WARN|SKIP)  ' ;;
  esac
  printf '%s' "$_out" | grep -E "$pat" 2>/dev/null | sed -E 's/^  +//' | sort || true
}

# Lines of $2 that are absent from $1, compared by normalized shape but
# printed in their original human-readable form.
_alert_diff() {
  local basen
  basen="$(printf '%s\n' "$1" | _alert_normalize)"
  paste -d'\t' <(printf '%s\n' "$2" | _alert_normalize) <(printf '%s\n' "$2") \
    | awk -F'\t' -v base="$basen" '
        BEGIN { n = split(base, b, "\n"); for (i = 1; i <= n; i++) if (b[i] != "") seen[b[i]] = 1 }
        $1 != "" && !($1 in seen) { print $2 }'
}

# The complement of _alert_diff: lines of $2 that ARE present in $1, by
# the same normalized-shape comparison. Used to confirm a finding has
# been missing on two runs running, not just this one -- see
# alert_if_changed's flap guard.
_alert_intersect() {
  local basen
  basen="$(printf '%s\n' "$1" | _alert_normalize)"
  paste -d'\t' <(printf '%s\n' "$2" | _alert_normalize) <(printf '%s\n' "$2") \
    | awk -F'\t' -v base="$basen" '
        BEGIN { n = split(base, b, "\n"); for (i = 1; i <= n; i++) if (b[i] != "") seen[b[i]] = 1 }
        $1 != "" && ($1 in seen) { print $2 }'
}

# Where run-to-run state lives. ONE definition, because every change
# detector in this project is only as good as its memory: if two callers
# disagree about the directory, one of them silently starts from scratch
# every run and its "this is new" is a lie that reads exactly like a
# working check.
senechal_state_dir() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/senechal"
}

# --- route, don't page ---------------------------------------------------
# Zach, 2026-08-11: "this information is not suitable for this channel
# ... not actionable, creates multiple tiles, stale and sticky ... it
# needs to be 1% the current volume."
#   [rest: vault:senechal/header-archaeology-20260818.md]

# Pull the project names out of a finding's trailing "Owner: ..." clause,
# one per line, "senechal" excluded. senechal.json's owner field is
# "name (role note), name2 (role note)" or "name (note) / name2 (note)"
# -- role notes can themselves contain commas ("realisateur (accounts,
#   [rest: vault:senechal/header-archaeology-20260818.md]
_alert_owners() {
  local line="$1" tail
  case "$line" in
    *"Owner: "*) tail="${line#*Owner: }" ;;
    *) return 0 ;;
  esac
  printf '%s' "$tail" \
    | sed -E 's/\([^)]*\)//g' \
    | tr ',/' '\n\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -v '^$' \
    | grep -v '^senechal$'
}

# The subset of a findings list (one per line) that has no external
# owner -- senechal's own, per _alert_owners' default.
_alert_senechal_owned() {
  local line
  printf '%s\n' "$1" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ -z "$(_alert_owners "$line")" ] && printf '%s\n' "$line"
  done
}

# File one finding to the project that owns fixing it. Best-effort and
# non-fatal like notify_alert -- a missing `scheduler` binary must not
# turn "route this" into "crash the health check."
route_to_owner() {
  local project="$1" text="$2"
  if ! command -v scheduler >/dev/null 2>&1; then
    warn "scheduler not found -- could not file to $project: $text"
    return 1
  fi
  scheduler -i "$project" "senechal estate health: $text" >/dev/null 2>&1 || true
}

# Keep ONE GitHub issue in sync with senechal's own currently-open
# findings -- created when the first one appears, body rewritten (not
# appended) on every change so it always reads as the CURRENT set, closed
# when the list goes empty. This is the "log an agent checks on a timed
# run" Zach asked for, reusing the same mechanism triage-run.md's own
# "agent-pickup work" issues already use, rather than inventing a new
# format. Best-effort like notify_alert/route_to_owner.
_SENECHAL_HEALTH_ISSUE_TITLE="senechal: open estate-health findings (senechal-owned)"
sync_senechal_issue() {
  local findings="$1" n num body
  if ! command -v gh >/dev/null 2>&1; then
    warn "gh not found -- could not sync the senechal health-findings issue"
    return 1
  fi
  n="$(printf '%s\n' "$findings" | grep -c . || true)"
  num="$(gh issue list --state open \
    --search "in:title \"$_SENECHAL_HEALTH_ISSUE_TITLE\"" \
    --json number --jq '.[0].number' 2>/dev/null)"

  if [ "$n" -eq 0 ]; then
    if [ -n "$num" ] && [ "$num" != "null" ]; then
      gh issue close "$num" \
        --comment "estate is clean of senechal-owned findings" >/dev/null 2>&1 || true
    fi
    return 0
  fi

  body="$(printf 'NO-DECISION: @zach -- senechal-owned estate-health findings; none of them page you.\n\nFindings senechal owns directly, kept in sync by health/estate-health.sh -- rewritten on every change to reflect the CURRENT open set, do not hand-edit. Pick these up on your own schedule; none of them are paging Zach.\n\n%s\n\n<!-- DEFERRED -->\n- none\n<!-- /DEFERRED -->\n' \
    "$(printf '%s\n' "$findings" | grep -v '^$' | sed 's/^/- [ ] /')")"

  if [ -n "$num" ] && [ "$num" != "null" ]; then
    gh issue edit "$num" --body "$body" >/dev/null 2>&1 || true
  else
    gh issue create --title "$_SENECHAL_HEALTH_ISSUE_TITLE" --body "$body" >/dev/null 2>&1 || true
  fi
}

# The gate itself. Call instead of should_alert+notify_alert.
#   $1: path to the durable findings log, named in the "recovered" page.
# State lives beside that log: alert-findings.txt (the current confirmed
# set), and alert-pending-clear.txt (findings on their first missed run
#   [rest: vault:senechal/header-archaeology-20260818.md]
alert_if_changed() {
  local logfile="${1:-}" level statedir f_file p_file
  local findings prev_findings pending_prev added missing_now cleared grace
  local remaining new_confirmed line owners owner senechal_owned prev_senechal_owned

  level="$(cfg health.alert_min_severity warn)"
  case "$level" in fail|warn|incomplete) ;; *) level=warn ;; esac

  statedir="$(senechal_state_dir)"
  mkdir -p "$statedir" 2>/dev/null || true
  f_file="$statedir/alert-findings.txt"
  p_file="$statedir/alert-pending-clear.txt"

  findings="$(_alert_findings "$level")"
  prev_findings="$(cat "$f_file" 2>/dev/null || true)"

  # Clean now. A recovery is worth exactly one notification of its own --
  # it is rare, it is good news, and it is the one thing here still worth
  # interrupting Zach for. Only touch the senechal issue if it could
  # plausibly be open (some senechal-owned finding was tracked last run)
  # -- otherwise every clean run would call gh for nothing to close.
  if ! should_alert "$_fail_count" "$_incomplete_count" "$_warn_count"; then
    if [ -n "$prev_findings" ]; then
      notify_alert "recovered -- $(printf '%s\n' "$prev_findings" | grep -c .) finding(s) cleared, estate is clean" \
        "$logfile" normal
    fi
    prev_senechal_owned="$(_alert_senechal_owned "$prev_findings")"
    [ -n "$prev_senechal_owned" ] && sync_senechal_issue ""
    : > "$f_file" 2>/dev/null || true
    rm -f "$p_file" 2>/dev/null || true
    return 0
  fi

  pending_prev="$(cat "$p_file" 2>/dev/null || true)"

  added="$(_alert_diff "$prev_findings" "$findings")"
  missing_now="$(_alert_diff "$findings" "$prev_findings")"
  # confirmed clear: missing this run AND already missing last run
  cleared="$(_alert_intersect "$pending_prev" "$missing_now")"
  # first-miss grace: missing this run, not yet flagged last run
  grace="$(_alert_diff "$pending_prev" "$missing_now")"

  if [ -z "$added$cleared" ]; then
    # same findings, nothing to route -- but still record any fresh
    # first-miss so a second consecutive miss can confirm it later
    printf '%s\n' "$grace" > "$p_file" 2>/dev/null || true
    return 0
  fi

  if [ -n "$added" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      owners="$(_alert_owners "$line")"
      [ -n "$owners" ] || continue
      while IFS= read -r owner; do
        [ -n "$owner" ] || continue
        route_to_owner "$owner" "$line"
      done <<< "$owners"
    done <<< "$added"
  fi

  remaining="$(_alert_diff "$cleared" "$prev_findings")"
  new_confirmed="$(printf '%s\n%s\n' "$remaining" "$added" | grep -v '^$' | sort -u)"

  # Only touch the senechal issue if senechal's own open set could have
  # changed -- an externally-owned finding adding/clearing must not
  # trigger a `gh` call for a set that never moved.
  senechal_owned="$(_alert_senechal_owned "$new_confirmed")"
  prev_senechal_owned="$(_alert_senechal_owned "$prev_findings")"
  if [ -n "$senechal_owned$prev_senechal_owned" ]; then
    sync_senechal_issue "$senechal_owned"
  fi

  printf '%s\n' "$new_confirmed" > "$f_file" 2>/dev/null || true
  printf '%s\n' "$grace" > "$p_file" 2>/dev/null || true
}

# --- memory pressure, as EVENTS ------------------------------------------
# Three shapes, none of which a RAM gauge can see:
#
#   1. SWAP is the leading indicator, and the default posture of most
#   [rest: vault:senechal/header-archaeology-20260818.md]

# How many configured band thresholds is this percentage at or above?
# 0 means below every band; N (the band count) means the top band.
# Counting rather than scanning in order makes this independent of the
# order the bands are listed in -- an unsorted config list must not
# silently produce a nonsense band.
# Usage: mem_swap_band <pct> <threshold>...   (rc 2 if pct is not a number)
mem_swap_band() {
  local pct="$1" b n=0
  shift
  case "$pct" in ''|*[!0-9]*) return 2 ;; esac
  for b in "$@"; do
    case "$b" in ''|*[!0-9]*) continue ;; esac
    [ "$pct" -ge "$b" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
  return 0
}

# The crossing detector. Compares this reading against the band recorded
# at the previous run and updates the state file.
#
#   mem_swap_transition <state_file> <pct> <sustained_hours> <now_epoch> <band>...
#   [rest: vault:senechal/header-archaeology-20260818.md]
mem_swap_transition() {
  local sf="$1" pct="$2" sus_h="$3" now="$4"
  shift 4
  local band prev entered reported hours verdict
  band="$(mem_swap_band "$pct" "$@")" || return 2
  case "$sus_h" in ''|*[!0-9]*) sus_h=0 ;; esac
  case "$now" in ''|*[!0-9]*) return 2 ;; esac

  prev=""; entered=""; reported=""
  [ -r "$sf" ] && read -r prev entered reported < "$sf" 2>/dev/null
  case "$prev" in ''|*[!0-9]*) prev=-1 ;; esac
  case "$entered" in ''|*[!0-9]*) entered=0 ;; esac
  case "$reported" in ''|*[!0-9]*) reported=0 ;; esac

  if [ "$prev" -lt 0 ]; then
    verdict=first; entered="$now"; reported=0
  elif [ "$band" -gt "$prev" ]; then
    verdict=rise;  entered="$now"; reported=0
  elif [ "$band" -lt "$prev" ]; then
    verdict=fall;  entered="$now"; reported=0
  else
    verdict=steady
  fi

  hours=$(( (now - entered) / 3600 ))
  [ "$hours" -lt 0 ] && hours=0

  if [ "$verdict" = steady ] && [ "$band" -gt 0 ] && [ "$reported" -eq 0 ] \
     && [ "$sus_h" -gt 0 ] && [ "$hours" -ge "$sus_h" ]; then
    verdict=sustained; reported=1
  fi

  printf '%s\t%s\t%s\t%s\n' "$verdict" "$band" "$prev" "$hours"
  printf '%s %s %s\n' "$band" "$entered" "$reported" > "$sf" 2>/dev/null || return 3
  return 0
}

# Pull the OOM kills out of kernel journal text on stdin, one record per
# line: <timestamp> <pid> <comm> <anon_rss_kb>.
#
# Parses the kernel's own wording rather than journalctl's framing, so it
#   [rest: vault:senechal/header-archaeology-20260818.md]
mem_oom_parse() {
  awk '
    /Out of memory: Killed process/ {
      when = $1; pid = ""; comm = ""; rss = 0
      if (match($0, /Killed process [0-9]+ \([^)]*\)/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^Killed process /, "", s)
        pid = s; sub(/[^0-9].*$/, "", pid)
        comm = s; sub(/^[0-9]+ \(/, "", comm); sub(/\)$/, "", comm)
      }
      if (match($0, /anon-rss:[0-9]+kB/)) {
        r = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", r); rss = r
      }
      if (pid != "") printf "%s\t%s\t%s\t%s\n", when, pid, comm, rss
    }'
}

# The duration half. Reads a process table on stdin, one per line:
#   <pid> <swap_kb> <elapsed_seconds> <cpu_seconds> <comm...>
# and prints those that are BOTH big enough in swap AND idle long enough:
#   <pid> <swap_mb> <idle_days> <comm>
#   [rest: vault:senechal/header-archaeology-20260818.md]
mem_swap_squatters() {
  local min_mb="$1" min_days="$2" max_pct="$3"
  awk -v minkb="$((min_mb * 1024))" -v mins="$((min_days * 86400))" -v maxpct="$max_pct" '
    NF >= 5 {
      pid = $1; sw = $2 + 0; el = $3 + 0; cpu = $4 + 0
      comm = $5; for (i = 6; i <= NF; i++) comm = comm " " $i
      if (sw < minkb) next
      if (el < mins || el <= 0) next
      # cpu/el*100 > maxpct, without dividing -- keeps it exact for the
      # integer inputs /proc actually hands over.
      if (cpu * 100 > maxpct * el) next
      printf "%s\t%d\t%d\t%s\n", pid, sw / 1024, el / 86400, comm
    }'
}

parse_common_args() {
  for a in "$@"; do
    case "$a" in
      -q|--quiet) QUIET=1 ;;
    esac
  done
}

# LAST, deliberately: every helper above is defined, so the refusal can
# use senechal_blind and _config_why. Running this at source time is what
# makes "I cannot see my own config" a stop rather than an emptier report
# -- the failure lands in the top-level shell, before any check has run.
# Opt out with SENECHAL_SKIP_CONFIG_CHECK=1 only where the config is
# genuinely irrelevant (a test exercising a helper in isolation).
[ "${SENECHAL_SKIP_CONFIG_CHECK:-0}" = 1 ] || senechal_config_require
