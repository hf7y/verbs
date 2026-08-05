#!/usr/bin/env bash
# manifest.sh -- the ONE place garde.json is read.
#
# Every other file asks this one. No subcommand re-parses the manifest,
# and no path, host, port or key is retyped anywhere else in the tree --
# that retyping is the failure this ecosystem records most often.
#
# Requires jq. A missing jq is BLIND (exit 6), not a crash: garde cannot
# read its own domain, which is a different statement from "there is
# nothing to report".

# WHERE THE LIVE MANIFEST LIVES, and why it is not next to this file.
#
# This defaulted to "$SELF/garde.json" -- beside the code. That was true
# while garde ran out of a `bashified` worktree of the dev clone, and it
# stopped being true the moment garde started running out of a verb build:
#
#   1. garde.json is untracked and gitignored (it holds real device
#      serials, hostnames and an ssh key path), so it is never carried by
#      a branch, a build, or a clone.
#   2. A verb build is a DISPOSABLE, REPLACEABLE directory. Adopting the
#      next nightly build repoints `current` at a fresh tree, so a manifest
#      stored inside one is silently left behind by an ordinary upgrade.
#
# Both together already cost this estate the file once: the live manifest
# existed only inside ~/Documents/Projects/gardien-garde, the migration off
# dev clones deleted that worktree, and garde was BLIND on mandark until it
# was reconstructed on 2026-08-05. Nothing was corrupted and nothing lied --
# garde exits 6 and says it cannot see -- but for that window this host
# could not prove a single byte was backed up, including the 1.4 GB
# bibliothecaire scan corpus whose only other copy is on dexter.
#
# So the manifest belongs to the MACHINE, not to any checkout of gardien:
# XDG config, which outlives every build, worktree and clone. The
# GARDE_MANIFEST override is unchanged and is still how a test or a second
# estate points garde somewhere else.
GARDE_MANIFEST="${GARDE_MANIFEST:-${XDG_CONFIG_HOME:-$HOME/.config}/gardien/garde.json}"

manifest_require() {
  command -v jq >/dev/null 2>&1 \
    || verb_blind "jq is not installed; garde cannot read its manifest"
  [ -f "$GARDE_MANIFEST" ] \
    || verb_blind "no manifest at $GARDE_MANIFEST -- create it with: mkdir -p $(dirname "$GARDE_MANIFEST") && cp <gardien>/garde.json.example $GARDE_MANIFEST && chmod 600 $GARDE_MANIFEST, then edit it"
  jq -e . "$GARDE_MANIFEST" >/dev/null 2>&1 \
    || verb_blind "$GARDE_MANIFEST is not valid JSON"
}

# Expand a leading ~ ONLY. Deliberately not eval: a manifest is data, and
# running it as shell would make an edited config an execution vector.
manifest_expand() {
  case "$1" in
    "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *)     printf '%s\n' "$1" ;;
  esac
}

manifest_set_names()  { jq -r '.sets[].name' "$GARDE_MANIFEST"; }

# manifest_set_field <set-name> <field> [default]
manifest_set_field() {
  local v
  v="$(jq -r --arg n "$1" --arg f "$2" \
       '.sets[] | select(.name==$n) | .[$f] // empty' "$GARDE_MANIFEST")"
  [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
  [ $# -ge 3 ] && printf '%s\n' "$3"
  return 0
}

manifest_set_exists() {
  [ "$(jq -r --arg n "$1" '[.sets[] | select(.name==$n)] | length' "$GARDE_MANIFEST")" != 0 ]
}

manifest_set_path()      { manifest_expand "$(manifest_set_field "$1" path)"; }
manifest_set_excludes()  { jq -r --arg n "$1" \
    '.sets[] | select(.name==$n) | (.exclude // [])[]' "$GARDE_MANIFEST"; }
manifest_set_dests()     { jq -r --arg n "$1" \
    '.sets[] | select(.name==$n) | (.copies // [])[]' "$GARDE_MANIFEST"; }

# manifest_dest_field <dest> <field> [default]
manifest_dest_field() {
  local v
  v="$(jq -r --arg d "$1" --arg f "$2" \
       '.destinations[$d] | .[$f] // empty' "$GARDE_MANIFEST" 2>/dev/null)"
  [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
  [ $# -ge 3 ] && printf '%s\n' "$3"
  return 0
}

manifest_dest_exists() {
  [ "$(jq -r --arg d "$1" 'has("destinations") and (.destinations|has($d))' \
       "$GARDE_MANIFEST")" = true ]
}

# Build the ssh option array for a destination. ONE definition of the
# transport flags. ServerAliveInterval is unconditional and deliberate:
# mandark is wifi-only, and a link that HANGS (TCP open, no RST) blocks
# rsync forever, holding the lock so every later run fails too. A drop
# is survivable -- rsync resumes at file granularity. A hang is not.
DEST_SSH_OPTS=()
dest_ssh_opts() {
  local d="$1" id port
  id="$(manifest_expand "$(manifest_dest_field "$d" identity)")"
  port="$(manifest_dest_field "$d" port 22)"
  DEST_SSH_OPTS=(-o BatchMode=yes -o ServerAliveInterval=30
                 -o ServerAliveCountMax=6 -p "$port")
  [ -n "$id" ] && DEST_SSH_OPTS+=(-i "$id")
}

dest_target() {
  printf '%s@%s\n' "$(manifest_dest_field "$1" user)" "$(manifest_dest_field "$1" host)"
}

# Is the destination actually reachable RIGHT NOW? Probed, never quoted
# from the manifest's own `online` field -- that field states intent, this
# states fact, and the whole point of the distinction is that they drift.
dest_reachable() {
  local d="$1" kind root
  kind="$(manifest_dest_field "$d" kind)"
  root="$(manifest_dest_field "$d" root)"
  case "$kind" in
    local)
      local marker; marker="$(manifest_dest_field "$d" marker)"
      [ -d "$root" ] || return 1
      [ -z "$marker" ] || [ -e "$root/$marker" ] || return 1
      return 0 ;;
    ssh)
      dest_ssh_opts "$d"
      ssh "${DEST_SSH_OPTS[@]}" -o ConnectTimeout=10 "$(dest_target "$d")" \
          "test -d '$root'" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
