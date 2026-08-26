#!/usr/bin/env bash
# Concern: Zach's interactive Claude slash commands (/bashify, /cloture,
# /ideate) must exist, and be CURRENT, in every home he might type them
# in -- every zach@ account, and anywhere the hf7y verb build lands. See
# CONCERNS.md and senechal.json's estate.taste (id: claude-slash-commands).
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

TASTE_ID="claude-slash-commands"
SSH_TIMEOUT=8

# realisateur's checkout. Same default install-shims.sh itself uses, so
# the two agree without either retyping the other's path; overridable so
# the test harness can point at a fixture generator and so a second host
# can set it once. NOT derived from this script's location -- see the
# same warning in install-shims.sh.
REALISATEUR="${SENECHAL_REALISATEUR:-${INSTALLE_PROJECTS:-$HOME/Documents/Projects}/realisateur}"
GENERATOR="$REALISATEUR/bin/install-shims.sh"

CANON=""   # scratch dir holding the rendered canonical commands
cleanup_canon() { [ -n "$CANON" ] && rm -rf "$CANON"; }
trap cleanup_canon EXIT

# ---- canonical content, produced by realisateur, never by us ----------
# Runs the generator with EVERY destination redirected into scratch, so
# invoking it here can never touch ~/.local/bin, ~/.claude/commands or
# ~/.claude/hooks on this machine. Prints the directory of rendered
# command files on stdout; returns 1 (could-not-check, never a pass) if
# the generator is absent or produced nothing.
render_canonical() {
  local d
  if [ ! -f "$GENERATOR" ]; then
    printf 'no generator at %s\n' "$GENERATOR" >&2
    return 1
  fi
  d="$(mktemp -d)"
  mkdir -p "$d/bin" "$d/commands" "$d/hooks"
  # The generator's own exit code covers far more than we asked about
  # (PATH shims, hooks, settings.json wiring, reach-lint) and is 1
  # whenever any of that flags on THIS host. That is realisateur's
  # business, not evidence about the rendered text, so the verdict we
  # take is "did files appear", checked below -- not $?.
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

# The set of commands is DERIVED from what the generator emitted, never
# typed here. realisateur adding a fourth `scope: user` command must not
# need an edit in senechal -- and a list typed here would go stale
# silently, which is the exact failure install-shims.sh's own comments
# record from 2026-07-27.
canon_names() { # <canon-dir>
  local f
  for f in "$1"/*.md; do [ -f "$f" ] && basename "$f"; done
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

# ---- per-home probes ---------------------------------------------------
# Both return one line per command file: "<name> <state>" where state is
# ok / drifted / missing. One ssh round trip per home, not per file.
probe_local() { # <canon-dir> <dir-relative-to-HOME>
  local canon="$1" dir="$2" n
  while read -r n; do
    if [ ! -f "$HOME/$dir/$n" ]; then
      printf '%s missing\n' "$n"
    elif cmp -s "$canon/$n" "$HOME/$dir/$n"; then
      printf '%s ok\n' "$n"
    else
      printf '%s drifted\n' "$n"
    fi
  done < <(canon_names "$canon")
}

probe_ssh() { # <canon-dir> <dir> <user@sshhost>; rc 1 = unreachable
  local canon="$1" dir="$2" target="$3" n want got remote
  # One round trip: ask for sha256 of each expected file. A file that is
  # absent yields nothing, which is distinguishable from a hash.
  #
  # The remote side ALWAYS exits 0 and always prints a sentinel first.
  #   [rest: vault:senechal/header-archaeology-20260818.md]
  remote="$(ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$target" \
      "echo SENECHAL-PROBE-OK; cd ~/$dir 2>/dev/null && sha256sum $(canon_names "$canon" | tr '\n' ' ') 2>/dev/null; exit 0" \
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
  done < <(canon_names "$canon")
}

# =======================================================================
# enable
# =======================================================================
cmd_enable() {
  say "senechal remedy: Claude slash commands in every home (id: $TASTE_ID)"
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

  if ! CANON="$(render_canonical)"; then
    die "cannot render the canonical commands -- realisateur is their source of truth and it is not readable here. Nothing written."
  fi
  say "canonical content rendered by $GENERATOR"
  say "commands: $(canon_names "$CANON" | tr '\n' ' ')"
  say ""

  local h mode arg rc=0
  IFS=',' read -ra HOME_LIST <<< "$homes"
  for h in "${HOME_LIST[@]}"; do
    [ -n "$h" ] || continue
    IFS=$'\x1f' read -r mode arg <<< "$(resolve_home "$h")"
    case "$mode" in
      local) enable_local "$h" "$dir" || rc=1 ;;
      ssh)   enable_ssh "$h" "$dir" "$arg" || rc=1 ;;
      *)     warn "$h: $arg -- skipped"; rc=1 ;;
    esac
  done

  say ""
  say "Claude Code reads ~/.claude/commands at session start: an already-open"
  say "session keeps the commands it started with. Start a new one to see them."
  say ""
  say "Then check every home at once:   ./claude-slash-commands.sh verify"
  return "$rc"
}

enable_local() { # <home-token> <dir>
  local h="$1" dir="$2" n state changed=0 stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$HOME/$dir" || { warn "$h: cannot create $HOME/$dir"; return 1; }
  while read -r n state; do
    case "$state" in
      ok) say "  $h: unchanged $n" ;;
      *)
        [ -f "$HOME/$dir/$n" ] && cp -p "$HOME/$dir/$n" "$HOME/$dir/$n.senechal-backup.$stamp"
        cp "$CANON/$n" "$HOME/$dir/$n" || { warn "$h: could not write $n"; return 1; }
        chmod 644 "$HOME/$dir/$n"
        say "  $h: ${state/drifted/repaired} -> wrote $n"
        changed=1
        ;;
    esac
  done < <(probe_local "$CANON" "$dir")
  [ "$changed" -eq 0 ] && say "  $h: already correct, nothing written"
  return 0
}

enable_ssh() { # <home-token> <dir> <user@sshhost>
  local h="$1" dir="$2" target="$3" n state need=0 probe
  if ! probe="$(probe_ssh "$CANON" "$dir" "$target")"; then
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
  # One write round trip. Backs up whatever is there first, under a
  # timestamp, exactly like the local half -- these are files a human may
  # have hand-edited, and this remedy overwrites them by design.
  if ! tar -C "$CANON" -cf - $(canon_names "$CANON" | tr '\n' ' ') | \
      ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$target" \
        "set -e; d=\$HOME/$dir; mkdir -p \"\$d\"; s=\$(date +%Y%m%d-%H%M%S);
         for f in \$(ls \"\$d\" 2>/dev/null); do case \"\$f\" in *.md) cp -p \"\$d/\$f\" \"\$d/\$f.senechal-backup.\$s\";; esac; done;
         tar -C \"\$d\" -xf -"; then
    warn "$h: write over ssh failed -- $target may be partially updated"
    return 1
  fi
  say "  $h: written"
  return 0
}

# =======================================================================
# verify -- no AI, no network beyond a BatchMode ssh, safe to cron
# =======================================================================
cmd_verify() {
  head_ "Claude slash commands in every home (id: $TASTE_ID, see CONCERNS.md)"

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

  # No canonical content means we cannot say anything about any home.
  # SKIP, not PASS and not FAIL: "realisateur is not checked out here" is
  # could-not-look, and the whole point of exit 2 is that it never reads
  # as healthy.
  if ! CANON="$(render_canonical 2>/dev/null)"; then
    skip "cannot render canonical content: $GENERATOR is missing or produced nothing -- realisateur owns these files and is the only source of truth for them"
    finish_verify
    return
  fi

  local h mode arg n state probe bad
  IFS=',' read -ra HOME_LIST <<< "$homes"
  for h in "${HOME_LIST[@]}"; do
    [ -n "$h" ] || continue
    IFS=$'\x1f' read -r mode arg <<< "$(resolve_home "$h")"
    probe=""
    case "$mode" in
      local) probe="$(probe_local "$CANON" "$dir")" ;;
      ssh)
        if ! probe="$(probe_ssh "$CANON" "$dir" "$arg")"; then
          skip "$h: could not reach $arg over BatchMode ssh -- not known to be broken"
          continue
        fi
        ;;
      undeclared) fail "$h: $arg"; continue ;;
      *)          skip "$h: $arg"; continue ;;
    esac
    bad=0
    while read -r n state; do
      case "$state" in
        ok) ;;
        missing) fail "$h: ~/$dir/$n is MISSING -- /${n%.md} does not exist in this home"; bad=1 ;;
        *)       fail "$h: ~/$dir/$n has DRIFTED from realisateur's source -- /${n%.md} is stale here"; bad=1 ;;
      esac
    done <<< "$probe"
    [ "$bad" -eq 0 ] && ok "$h: all $(canon_names "$CANON" | wc -l) command(s) present and byte-identical to source"
    [ "$bad" -eq 1 ] && note "repair every home at once: remedies/claude-slash-commands.sh enable"
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
      say "  enable   render the commands with realisateur's own generator and"
      say "           install/repair them in every home in"
      say "           estate.taste[$TASTE_ID].homes (idempotent)"
      say "  verify   check they are present and byte-identical everywhere;"
      say "           exit 0 pass / 1 fail / 2 could-not-check"
      exit 64
      ;;
  esac
}
main "$@"
