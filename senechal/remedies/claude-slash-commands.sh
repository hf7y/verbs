#!/usr/bin/env bash
# Concern: Zach's interactive Claude slash commands (/bashify, /cloture,
# /ideate), his ~/.claude/hooks/*.sh scripts, and the settings.json hooks
# block that wires them, must exist and be CURRENT in every home he might
# type in -- every zach@ account, and anywhere the hf7y verb build lands.
# See CONCERNS.md and senechal.json's estate.taste (id: claude-slash-commands).
# realisateur's --apply skips the zach@ account by construction; this
# remedy covers the account that one deliberately does not (#460 point 2).
#   [rest: vault:senechal/header-archaeology-20260818.md]
PRIVILEGED=no
HOSTS=(mandark dexter monkey)
REACHES=(ssh)
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

TASTE_ID="claude-slash-commands"
SSH_TIMEOUT=8
HOOKS_REL=".claude/hooks"
SETTINGS_REL=".claude/settings.json"

# realisateur's checkout, same default install-shims.sh uses, so the two
# agree without retyping; overridable for the test harness. NOT derived
# from this script's location -- see the same warning in install-shims.sh.
REALISATEUR="${SENECHAL_REALISATEUR:-${INSTALLE_PROJECTS:-$HOME/Documents/Projects}/realisateur}"
GENERATOR="$REALISATEUR/bin/install-shims.sh"
HOOKS_PROVISION="$REALISATEUR/bin/selfdev-hooks-provision.sh"

CANON=""          # scratch dir holding the rendered canonical commands
HOOKS_SCRATCH=""  # scratch dir holding the rendered canonical hooks + hooks.json
HOOKS_CANON=""    # $HOOKS_SCRATCH/hooks
HOOKS_JSON=""     # $HOOKS_SCRATCH/hooks.json
cleanup_canon() {
  [ -n "$CANON" ] && rm -rf "$CANON"
  [ -n "$HOOKS_SCRATCH" ] && rm -rf "$HOOKS_SCRATCH"
}
trap cleanup_canon EXIT

# ---- canonical content, produced by realisateur, never by us ----------
# Runs the generator with EVERY destination redirected into scratch, so
# this can never touch ~/.local/bin, ~/.claude/commands or ~/.claude/hooks
# on this machine. Prints the rendered command dir; returns 1
# (could-not-check, never a pass) if the generator is absent or empty.
render_canonical() {
  local d
  if [ ! -f "$GENERATOR" ]; then
    printf 'no generator at %s\n' "$GENERATOR" >&2
    return 1
  fi
  d="$(mktemp -d)"
  mkdir -p "$d/bin" "$d/commands" "$d/hooks"
  # The generator's own exit code covers far more than we asked about, so
  # the verdict we take is "did files appear", checked below -- not $?.
  BIN_DEST="$d/bin" CMD_DEST="$d/commands" HOOK_DEST="$d/hooks" \
    bash "$GENERATOR" > "$d/generator.log" 2>&1
  if ! compgen -G "$d/commands/*.md" > /dev/null; then
    printf 'generator %s rendered no *.md into its command dir\n' "$GENERATOR" >&2
    printf '%s\n' "--- generator output ---" >&2
    cat "$d/generator.log" >&2
    rm -rf "$d"
    return 1
  fi
  printf '%s\n' "$d/commands"
}

# ---- canonical hooks + the settings.json block that wires them --------
# Reads selfdev-hooks-provision.sh --print, realisateur's own source of
# truth for the hooks block, so a new hook or matcher needs no edit here.
# Prints a scratch dir on stdout: "$dir/hooks" holds the referenced *.sh
# files, "$dir/hooks.json" holds the block. Returns 1 (could-not-check) if
# the provisioner is absent, unparseable, or names a hook file not there.
render_canonical_hooks() {
  local d hooks_json name
  if [ ! -f "$HOOKS_PROVISION" ]; then
    printf 'no hooks provisioner at %s\n' "$HOOKS_PROVISION" >&2
    return 1
  fi
  hooks_json="$(bash "$HOOKS_PROVISION" --print 2>/dev/null)"
  if [ -z "$hooks_json" ] || ! python3 -c 'import json,sys; json.load(sys.stdin)' \
        >/dev/null 2>&1 <<<"$hooks_json"; then
    printf '%s --print produced no parseable hooks block\n' "$HOOKS_PROVISION" >&2
    return 1
  fi
  d="$(mktemp -d)"
  mkdir -p "$d/hooks"
  printf '%s\n' "$hooks_json" > "$d/hooks.json"
  while read -r name; do
    [ -n "$name" ] || continue
    if [ -f "$REALISATEUR/hooks/$name" ]; then
      cp "$REALISATEUR/hooks/$name" "$d/hooks/$name" && chmod 755 "$d/hooks/$name"
    else
      printf 'the hooks block names %s but %s/hooks/%s does not exist\n' \
        "$name" "$REALISATEUR" "$name" >&2
      rm -rf "$d"
      return 1
    fi
  done < <(python3 -c '
import json, sys
def walk(o):
    if isinstance(o, dict):
        if isinstance(o.get("command"), str):
            yield o["command"]
        for v in o.values():
            yield from walk(v)
    elif isinstance(o, list):
        for v in o:
            yield from walk(v)
data = json.load(sys.stdin)
names = sorted({c.split()[0].rsplit("/", 1)[-1] for c in walk(data)})
print("\n".join(names))
' <<<"$hooks_json")
  printf '%s\n' "$d"
}

# DERIVED from what the generator/provisioner emitted, never typed here --
# a list typed here would go stale silently (install-shims.sh's own
# comments record that failure from 2026-07-27).
canon_names() { # <canon-dir> [glob, default *.md]
  local f glob="${2:-*.md}"
  for f in "$1"/$glob; do [ -f "$f" ] && basename "$f"; done
}

# ---- the taste's registry row -----------------------------------------
taste_row() {
  local id file homes status owner notes
  while IFS=$'\x1f' read -r id file homes status owner notes; do
    [ "$id" = "$TASTE_ID" ] || continue
    printf '%s\x1f%s\x1f%s\x1f%s\n' "$id" "$file" "$homes" "$status"
    return 0
  done <<< "$(cfg_taste)"
  return 1
}

# ---- per-home probes: commands and hook FILES --------------------------
# Both return one line per file: "<name> <state>" where state is
# ok / drifted / missing. One ssh round trip per home, not per file.
probe_local() { # <canon-dir> <dir-relative-to-HOME> [glob]
  local canon="$1" dir="$2" glob="${3:-*.md}" n
  while read -r n; do
    if [ ! -f "$HOME/$dir/$n" ]; then
      printf '%s missing\n' "$n"
    elif cmp -s "$canon/$n" "$HOME/$dir/$n"; then
      printf '%s ok\n' "$n"
    else
      printf '%s drifted\n' "$n"
    fi
  done < <(canon_names "$canon" "$glob")
}

probe_ssh() { # <canon-dir> <dir> <user@sshhost> [glob]; rc 1 = unreachable
  local canon="$1" dir="$2" target="$3" glob="${4:-*.md}" n want got remote
  # One round trip: ask for sha256 of each expected file (absent yields
  # nothing, distinguishable from a hash). Remote side ALWAYS exits 0 and
  # prints a sentinel first.   [rest: vault:senechal/header-archaeology-20260818.md]
  remote="$(ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$target" \
      "echo SENECHAL-PROBE-OK; cd ~/$dir 2>/dev/null && sha256sum $(canon_names "$canon" "$glob" | tr '\n' ' ') 2>/dev/null; exit 0" \
      2>/dev/null)" || return 1
  grep -qx 'SENECHAL-PROBE-OK' <<< "$remote" || return 1
  while read -r n; do
    want="$(sha256sum < "$canon/$n" | cut -d' ' -f1)"
    got="$(awk -v f="$n" '$2==f || $2=="./"f {print $1}' <<< "$remote" | head -n1)"
    if [ -z "$got" ]; then
      printf '%s missing\n' "$n"
    elif [ "$got" = "$want" ]; then
      printf '%s ok\n' "$n"
    else
      printf '%s drifted\n' "$n"
    fi
  done < <(canon_names "$canon" "$glob")
}

# ---- the settings.json hooks block: one JSON key, whole-object compare
# Neither host is assumed to have jq; both have python3, which senechal
# itself already requires. The "want" block travels over stdin, never
# argv, and nothing else in settings.json is ever read or printed -- only
# whether ".hooks" matches.
read -r -d '' SETTINGS_PROBE_PY <<'PY' || true
import json, sys, os
want = json.load(sys.stdin)
path = os.path.expanduser("~/.claude/settings.json")
try:
    with open(path) as f:
        cur = json.load(f)
except FileNotFoundError:
    print("missing")
except Exception:
    print("unreadable")
else:
    print("ok" if cur.get("hooks") == want else "drifted")
PY

read -r -d '' SETTINGS_WRITE_PY <<'PY' || true
import json, os, sys, shutil, time
want = json.load(sys.stdin)
path = os.path.expanduser("~/.claude/settings.json")
if os.path.exists(path):
    try:
        with open(path) as f:
            cur = json.load(f)
    except Exception:
        print("BLIND: existing settings.json is not valid JSON -- refusing to overwrite")
        sys.exit(1)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    shutil.copy2(path, path + ".senechal-backup." + stamp)
else:
    cur = {}
cur["hooks"] = want
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
tmp = path + ".senechal-tmp"
with open(tmp, "w") as f:
    json.dump(cur, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print("written")
PY

probe_settings_local() { # <hooks-json-file>
  python3 -c "$SETTINGS_PROBE_PY" < "$1" 2>/dev/null
}

# Sent as base64, not a locally %q-escaped `-c` string -- that assumes a
# bash login shell remotely, and every other remote command here is
# deliberately plain-POSIX.
remote_py_cmd() { # <python-heredoc-var-name> -> a `sh -c`-safe command string
  local b64
  b64="$(printf '%s' "${!1}" | base64 | tr -d '\n')"
  printf 'python3 -c "$(printf %%s '\''%s'\'' | base64 -d)"' "$b64"
}

probe_settings_ssh() { # <hooks-json-file> <target>; rc 1 = unreachable
  local hooks_file="$1" target="$2" out
  out="$(ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$target" \
      "$(remote_py_cmd SETTINGS_PROBE_PY)" \
      < "$hooks_file" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# ---- enable -------------------------------------------------------------
cmd_enable() {
  say "senechal remedy: Claude slash commands and hooks in every home (id: $TASTE_ID)"
  say ""

  local row id dir homes status
  if ! row="$(taste_row)"; then
    die "senechal.json has no estate.taste entry with id \"$TASTE_ID\" -- nothing to apply."
  fi
  IFS=$'\x1f' read -r id dir homes status <<< "$row"
  dir="${dir%/}"

  if [ "$status" != "enabled" ]; then
    say "estate.taste[$id].status is \"$status\", not \"enabled\" -- nothing to do."
    return 0
  fi

  local have_commands=1 have_hooks=1
  if ! CANON="$(render_canonical)"; then
    warn "cannot render canonical commands -- $GENERATOR is not readable here; commands left untouched"
    have_commands=0
  else
    say "canonical commands rendered by $GENERATOR"
    say "commands: $(canon_names "$CANON" | tr '\n' ' ')"
  fi

  if HOOKS_SCRATCH="$(render_canonical_hooks)"; then
    HOOKS_CANON="$HOOKS_SCRATCH/hooks"
    HOOKS_JSON="$HOOKS_SCRATCH/hooks.json"
    say "canonical hooks rendered by $HOOKS_PROVISION"
    say "hooks: $(canon_names "$HOOKS_CANON" '*' | tr '\n' ' ')"
  else
    warn "cannot render canonical hooks -- $HOOKS_PROVISION is not readable here; hooks and the settings.json hooks block left untouched"
    have_hooks=0
  fi
  say ""

  if [ "$have_commands" -eq 0 ] && [ "$have_hooks" -eq 0 ]; then
    die "neither canonical commands nor canonical hooks could be rendered -- realisateur is the source of truth for both and neither is readable here. Nothing written."
  fi

  local h mode arg rc=0
  IFS=',' read -ra HOME_LIST <<< "$homes"
  for h in "${HOME_LIST[@]}"; do
    [ -n "$h" ] || continue
    IFS=$'\x1f' read -r mode arg <<< "$(resolve_home "$h")"
    case "$mode" in
      local)
        [ "$have_commands" -eq 1 ] && { enable_local "$h" "$CANON" "$dir" || rc=1; }
        [ "$have_hooks" -eq 1 ] && { enable_local "$h" "$HOOKS_CANON" "$HOOKS_REL" '*' 755 || rc=1; }
        [ "$have_hooks" -eq 1 ] && { enable_settings_local "$h" || rc=1; }
        ;;
      ssh)
        [ "$have_commands" -eq 1 ] && { enable_ssh "$h" "$CANON" "$dir" "$arg" || rc=1; }
        [ "$have_hooks" -eq 1 ] && { enable_ssh "$h" "$HOOKS_CANON" "$HOOKS_REL" "$arg" '*' 755 || rc=1; }
        [ "$have_hooks" -eq 1 ] && { enable_settings_ssh "$h" "$arg" || rc=1; }
        ;;
      *) warn "$h: $arg -- skipped"; rc=1 ;;
    esac
  done

  say ""
  say "Claude Code reads ~/.claude/commands, ~/.claude/hooks and ~/.claude/settings.json"
  say "at session start: an already-open session keeps what it started with. Start a"
  say "new one to see any change."
  say ""
  say "Then check every home at once:   ./claude-slash-commands.sh verify"
  return "$rc"
}

enable_local() { # <home-token> <canon-dir> <dir> [glob=*.md] [mode=644]
  local h="$1" canon="$2" dir="$3" glob="${4:-*.md}" mode="${5:-644}" n state changed=0 stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$HOME/$dir" || { warn "$h: cannot create $HOME/$dir"; return 1; }
  while read -r n state; do
    case "$state" in
      ok) say "  $h: unchanged $n" ;;
      *)
        [ -f "$HOME/$dir/$n" ] && cp -p "$HOME/$dir/$n" "$HOME/$dir/$n.senechal-backup.$stamp"
        cp "$canon/$n" "$HOME/$dir/$n" || { warn "$h: could not write $n"; return 1; }
        chmod "$mode" "$HOME/$dir/$n"
        say "  $h: ${state/drifted/repaired} -> wrote $n"
        changed=1
        ;;
    esac
  done < <(probe_local "$canon" "$dir" "$glob")
  [ "$changed" -eq 0 ] && say "  $h: already correct, nothing written"
  return 0
}

enable_ssh() { # <home-token> <canon-dir> <dir> <target> [glob=*.md] [mode=644]
  local h="$1" canon="$2" dir="$3" target="$4" glob="${5:-*.md}" mode="${6:-644}" n state need=0 probe
  if ! probe="$(probe_ssh "$canon" "$dir" "$target" "$glob")"; then
    warn "$h: could not reach $target over BatchMode ssh -- left unchanged"
    return 1
  fi
  while read -r n state; do
    [ "$state" = "ok" ] || need=1
    say "  $h: $n $state"
  done <<< "$probe"
  if [ "$need" -eq 0 ]; then
    say "  $h: already correct, nothing written"
    return 0
  fi
  # One write round trip, backing up whatever is there first, like the
  # local half. Mode travels via the source file's own bits, not a remote
  # chmod -- tar preserves them across the pipe.
  if ! tar -C "$canon" -cf - $(canon_names "$canon" "$glob" | tr '\n' ' ') | \
      ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$target" \
        "set -e; d=\$HOME/$dir; mkdir -p \"\$d\"; s=\$(date +%Y%m%d-%H%M%S);
         for f in \$(ls \"\$d\" 2>/dev/null); do case \"\$f\" in $glob) cp -p \"\$d/\$f\" \"\$d/\$f.senechal-backup.\$s\";; esac; done;
         tar -C \"\$d\" -xf -"; then
    warn "$h: write over ssh failed -- $target may be partially updated"
    return 1
  fi
  say "  $h: written"
  return 0
}

enable_settings_local() { # <home-token>
  local h="$1" state out
  state="$(probe_settings_local "$HOOKS_JSON")"
  if [ "$state" = "ok" ]; then
    say "  $h: settings.json hooks block unchanged"
    return 0
  fi
  out="$(python3 -c "$SETTINGS_WRITE_PY" < "$HOOKS_JSON" 2>&1)"
  if [ "$out" = "written" ]; then
    say "  $h: settings.json hooks block ${state/drifted/repaired}"
    return 0
  fi
  warn "$h: settings.json hooks block -- $out"
  return 1
}

enable_settings_ssh() { # <home-token> <target>
  local h="$1" target="$2" state out
  if ! state="$(probe_settings_ssh "$HOOKS_JSON" "$target")"; then
    warn "$h: could not reach $target over BatchMode ssh -- settings.json left unchanged"
    return 1
  fi
  if [ "$state" = "ok" ]; then
    say "  $h: settings.json hooks block unchanged"
    return 0
  fi
  out="$(ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$target" \
      "$(remote_py_cmd SETTINGS_WRITE_PY)" \
      < "$HOOKS_JSON" 2>&1)" || { warn "$h: write over ssh failed -- $target may be partially updated"; return 1; }
  if [ "$out" = "written" ]; then
    say "  $h: settings.json hooks block ${state/drifted/repaired}"
    return 0
  fi
  warn "$h: settings.json hooks block -- $out"
  return 1
}

# ---- verify -- no AI, no network beyond a BatchMode ssh, safe to cron --
cmd_verify() {
  head_ "Claude slash commands and hooks in every home (id: $TASTE_ID, see CONCERNS.md)"

  local row id dir homes status
  if ! row="$(taste_row)"; then
    fail "senechal.json has no estate.taste entry with id \"$TASTE_ID\""
    finish_verify
    return
  fi
  IFS=$'\x1f' read -r id dir homes status <<< "$row"
  dir="${dir%/}"

  if [ "$status" != "enabled" ]; then
    skip "estate.taste[$id].status is \"$status\" -- not expected to be in effect"
    finish_verify
    return
  fi

  # No canonical content means SKIP, not PASS/FAIL -- could-not-look must
  # never read as healthy. Commands and hooks have independent sources and
  # fail independently: one unrenderable does not skip the other.
  local have_commands=1 have_hooks=1
  if ! CANON="$(render_canonical 2>/dev/null)"; then
    skip "cannot render canonical commands: $GENERATOR is missing or produced nothing -- realisateur owns these files and is the only source of truth for them"
    have_commands=0
  fi
  if HOOKS_SCRATCH="$(render_canonical_hooks 2>/dev/null)"; then
    HOOKS_CANON="$HOOKS_SCRATCH/hooks"
    HOOKS_JSON="$HOOKS_SCRATCH/hooks.json"
  else
    skip "cannot render canonical hooks: $HOOKS_PROVISION is missing or produced no parseable block -- realisateur owns these files and is the only source of truth for them"
    have_hooks=0
  fi
  if [ "$have_commands" -eq 0 ] && [ "$have_hooks" -eq 0 ]; then
    finish_verify
    return
  fi

  local h mode arg n state probe
  IFS=',' read -ra HOME_LIST <<< "$homes"
  for h in "${HOME_LIST[@]}"; do
    [ -n "$h" ] || continue
    IFS=$'\x1f' read -r mode arg <<< "$(resolve_home "$h")"
    case "$mode" in
      undeclared) fail "$h: $arg"; continue ;;
      local|ssh)  ;;
      *)          skip "$h: $arg"; continue ;;
    esac

    local bad=0 hbad=0 unreachable=0

    if [ "$have_commands" -eq 1 ]; then
      case "$mode" in
        local) probe="$(probe_local "$CANON" "$dir")" ;;
        ssh)
          if ! probe="$(probe_ssh "$CANON" "$dir" "$arg")"; then
            skip "$h: could not reach $arg over BatchMode ssh -- not known to be broken"
            unreachable=1
          fi
          ;;
      esac
      if [ "$unreachable" -eq 0 ]; then
        while read -r n state; do
          case "$state" in
            ok) ;;
            missing) fail "$h: ~/$dir/$n is MISSING -- /${n%.md} does not exist in this home"; bad=1 ;;
            *)       fail "$h: ~/$dir/$n has DRIFTED from realisateur's source -- /${n%.md} is stale here"; bad=1 ;;
          esac
        done <<< "$probe"
        [ "$bad" -eq 0 ] && ok "$h: all $(canon_names "$CANON" | wc -l) command(s) present and byte-identical to source"
      fi
    fi

    if [ "$have_hooks" -eq 1 ] && [ "$unreachable" -eq 0 ]; then
      case "$mode" in
        local) probe="$(probe_local "$HOOKS_CANON" "$HOOKS_REL" '*')" ;;
        ssh)
          if ! probe="$(probe_ssh "$HOOKS_CANON" "$HOOKS_REL" "$arg" '*')"; then
            skip "$h: could not reach $arg over BatchMode ssh -- not known to be broken"
            unreachable=1
          fi
          ;;
      esac
      if [ "$unreachable" -eq 0 ]; then
        while read -r n state; do
          case "$state" in
            ok) ;;
            missing) fail "$h: ~/$HOOKS_REL/$n is MISSING"; hbad=1 ;;
            *)       fail "$h: ~/$HOOKS_REL/$n has DRIFTED from realisateur's source"; hbad=1 ;;
          esac
        done <<< "$probe"
      fi

      if [ "$unreachable" -eq 0 ]; then
        case "$mode" in
          local) state="$(probe_settings_local "$HOOKS_JSON")" ;;
          ssh)
            if ! state="$(probe_settings_ssh "$HOOKS_JSON" "$arg")"; then
              skip "$h: could not reach $arg over BatchMode ssh -- not known to be broken"
              unreachable=1
            fi
            ;;
        esac
      fi
      if [ "$unreachable" -eq 0 ]; then
        case "$state" in
          ok)          ;;
          missing)     fail "$h: ~/$SETTINGS_REL is MISSING -- the hooks block is not wired"; hbad=1 ;;
          unreadable)  fail "$h: ~/$SETTINGS_REL is not valid JSON -- cannot check the hooks block"; hbad=1 ;;
          *)           fail "$h: ~/$SETTINGS_REL's hooks block has DRIFTED from realisateur's declared set"; hbad=1 ;;
        esac
      fi
      [ "$unreachable" -eq 0 ] && [ "$hbad" -eq 0 ] && \
        ok "$h: all $(canon_names "$HOOKS_CANON" '*' | wc -l) hook file(s) and the settings.json hooks block match realisateur's declared set"
    fi

    if [ "$bad" -eq 1 ] || [ "$hbad" -eq 1 ]; then
      note "repair every home at once: remedies/claude-slash-commands.sh enable"
    fi
  done

  finish_verify
}

# =======================================================================
main() {
  local verb="${1:-}"
  shift || true
  parse_common_args "$@"
  case "$verb" in
    enable) cmd_enable ;;
    verify) cmd_verify ;;
    *)
      say "usage: $(basename "$0") {enable|verify} [-q|--quiet]"
      say ""
      say "  enable   render commands and hooks with realisateur's own generators and"
      say "           install/repair them, plus the settings.json hooks block, in"
      say "           every home in estate.taste[$TASTE_ID].homes (idempotent)"
      say "  verify   check they are present and byte-identical everywhere;"
      say "           exit 0 pass / 5 fail / 2 could-not-check"
      exit "$RC_FAIL"
      ;;
  esac
}
main "$@"
