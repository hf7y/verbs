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

# ----------------------------------------------------------- writing (gardien#32)
#
# garde.json was hand-edited untracked JSON with no safety net -- no
# history, no validation, no undo. These are the only functions in the
# tree that write it, so an edit either goes through here or it is still
# a hand edit.
#
# manifest_write <jq-arg>... <jq-filter> -- the filter runs against the
# CURRENT manifest and its stdout becomes the candidate. That candidate is
# written to a temp file IN THE SAME DIRECTORY (so the final `mv` is one
# rename, not a copy racing a reader) and is validated as parseable JSON
# BEFORE it ever touches the real path -- the one invariant gardien#32
# named as non-negotiable, as opposed to the backup, which is an
# implementation choice made here for the same reason the hand-edit
# workflow already took one: cheap, and it was the near-miss that
# actually happened once.
manifest_write() {
  local tmp
  tmp="$(mktemp "${GARDE_MANIFEST}.XXXXXX" 2>/dev/null)" \
    || verb_broke "could not create a temp file beside the manifest (is its directory writable?)"
  if ! jq "$@" "$GARDE_MANIFEST" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    verb_broke "the manifest edit failed; nothing was written"
  fi
  jq -e . "$tmp" >/dev/null 2>&1 || {
    rm -f "$tmp"
    verb_broke "refusing to write: the generated manifest did not parse as JSON"
  }
  cp "$GARDE_MANIFEST" "$GARDE_MANIFEST.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$GARDE_MANIFEST"
}

# manifest_set_add_include/_exclude <set-name> <pattern> -- appended and
# deduplicated, never replaced, so a repeated `garde add`/`garde exclude`
# is idempotent rather than growing the array forever.
manifest_set_add_include() {
  manifest_write --arg n "$1" --arg p "$2" \
    '(.sets[] | select(.name==$n) | .include) |= ((. // []) + [$p] | unique)'
}
manifest_set_add_exclude() {
  manifest_write --arg n "$1" --arg p "$2" \
    '(.sets[] | select(.name==$n) | .exclude) |= ((. // []) + [$p] | unique)'
}
manifest_add_global_exclude() {
  manifest_write --arg p "$1" \
    '.global_exclude |= ((. // []) + [$p] | unique)'
}

manifest_set_includes() { jq -r --arg n "$1" \
    '.sets[] | select(.name==$n) | (.include // [])[]' "$GARDE_MANIFEST"; }
manifest_global_excludes() { jq -r '(.global_exclude // [])[]' "$GARDE_MANIFEST"; }

# manifest_print_rules [set-name] -- the effective rule set, in the
# precedence stated in gardien#32: within a set, exclude beats include
# because the copy engine (lib/media.sh) only ever consumes `exclude`
# today, and a global exclude beats every set-level include because it is
# printed last and labelled as the final word. `include` and
# `global_exclude` are new fields as of this build and are NOT YET wired
# into `media run` -- said here in the output itself, not just in
# GAPS.md, so `garde rules` cannot be read as a promise the copy engine
# does not keep.
manifest_print_rules() {
  local only="$1" n path any p
  if [ -n "$only" ]; then
    manifest_set_exists "$only" || verb_die "rules: no such set: $only"
  fi

  printf 'global exclude (every set, cannot be overridden by a set-level include):\n'
  any=0
  while IFS= read -r p; do [ -n "$p" ] || continue; printf '  - %s\n' "$p"; any=1; done \
    < <(manifest_global_excludes)
  [ "$any" = 1 ] || printf '  (none)\n'
  printf '\n'

  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ -z "$only" ] || [ "$n" = "$only" ] || continue
    path="$(manifest_set_path "$n")"
    printf '%s  (path: %s)\n' "$n" "$path"
    any=0
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      printf '  exclude  %s\n' "$p"; any=1
    done < <(manifest_set_excludes "$n")
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      printf '  include  %-30s [not yet enforced by media run -- gardien#32]\n' "$p"; any=1
    done < <(manifest_set_includes "$n")
    [ "$any" = 1 ] || printf '  (no set-level rules)\n'
  done < <(manifest_set_names)
}

# Build the ssh option array for a destination. ONE definition of the
# transport flags. ServerAliveInterval is unconditional and deliberate:
# mandark is wifi-only, and a link that HANGS (TCP open, no RST) blocks
# rsync forever, holding the lock so every later run fails too. A drop
# is survivable -- rsync resumes at file granularity. A hang is not.
DEST_SSH_OPTS=()
dest_ssh_opts() {
  local d="$1" id port kh
  id="$(manifest_expand "$(manifest_dest_field "$d" identity)")"
  port="$(manifest_dest_field "$d" port 22)"
  DEST_SSH_OPTS=(-o BatchMode=yes -o ServerAliveInterval=30
                 -o ServerAliveCountMax=6 -p "$port")
  [ -n "$id" ] && DEST_SSH_OPTS+=(-i "$id")
  # Optional, and absent from every real destination today: ssh resolves
  # `~/.ssh/known_hosts` from the account's passwd entry, NOT from $HOME,
  # so a caller cannot redirect it by exporting HOME (found building
  # test/ssh-media-test.sh, gardien#35 -- a loopback sshd fixture has no
  # business writing into this account's real known_hosts). A destination
  # naming its own `known_hosts` gets `-o UserKnownHostsFile=`; one that
  # does not is untouched, so no existing destination's behaviour changes.
  kh="$(manifest_expand "$(manifest_dest_field "$d" known_hosts)")"
  [ -n "$kh" ] && DEST_SSH_OPTS+=(-o "UserKnownHostsFile=$kh")
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
