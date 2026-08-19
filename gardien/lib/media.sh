#!/usr/bin/env bash
# media.sh -- copy a set to a destination and PROVE it landed.
#
# The copy is the easy half. The proof is the point: rsync exit 0 means
# "rsync believes it wrote what it read", which is not the same claim as
# "the bytes are there". Hashes are computed LOCALLY on each side and only
# the digests cross the wire -- `rsync --checksum` would re-read every byte
# across a 15.5 MB/s link and double a multi-hour copy for the same
# guarantee.
#
# Measured mandark -> dexter 2026-07-30: 15.5 MB/s incompressible (~56 GB/h).

GARDE_STATE="${GARDE_STATE:-$HOME/.local/share/garde}"

media_log() { [ "$VERB_QUIET" = 1 ] || printf '%s\n' "$*"; }

# Report a set as BROKEN and RETURN, so the caller can record the failure
# and carry on to the remaining sets.
#
# verb_broke exits 5 immediately. Inside a per-set function that is wrong:
# `media_copy_set ... || { failed=...; continue; }` reads as "record it and
# move on", but the || can never fire because the process is already gone.
# One bad set killed a whole 8-set migration that way -- Project Archive
# failed and Videos/Teaching/Audacity/vkv/Pd were never attempted. A batch
# must degrade to "this set is broken", never to "the batch stopped".
media_fail() {
  printf '%s: BROKEN: %s\n' "$VERB_NAME" "$*" >&2
  return 1
}


# Flatten a relative path into one filename that cannot collide and cannot
# be reinterpreted by a shell.
#
# The obvious separator is '~', and it is WRONG: rsync and the remote shell
# both expand a tilde, so 'Brass Charts/Eris/Book of Five/Book of 5.mp3'
# became '.../Brass Charts/home/zachEris/home/zachBook of Five/home' and the
# transfer died with rsync code 3. That bug shipped in the original
# media-to-dexter.sh and stayed invisible for exactly one reason: the only
# collision ever exercised was Siddhartha/Homily.pdf, which is top-level, so
# no separator was ever inserted. A nested collision was always going to
# break it -- and the first test written for this covered only the top-level
# case too, which is why the suite agreed with the bug.
#
# '%' is special to no shell, and encoding '%' first keeps the mapping
# reversible, so the original path stays recoverable from the flat name.
media_flatten() {
  local s="$1"
  s="${s//%/%25}"
  printf '%s\n' "${s//\//%2F}"
}

# The name a rescued file actually gets.
#
# Flattening alone is NOT enough, and the second real migration proved it:
# the two colliding paths differ only in case, so their flattened names
# differ only in case too, and on a case-insensitive destination they
# collide AGAIN -- the rescue directory reproducing the exact bug it exists
# to prevent. 8 files went in and 4 came out.
#
# So the name is prefixed with a short hash OF THE ORIGINAL PATH. Two paths
# that differ only in case hash differently, so the prefixes differ in
# characters that survive lowercasing, and the names can no longer collide
# no matter what the filesystem does with case.
media_safe_name() {
  local rel="$1" h
  h="$(printf '%s' "$rel" | md5sum | cut -c1-8)"
  printf '%s-%s\n' "$h" "$(media_flatten "$rel")"
}

# --- case collisions --------------------------------------------------
# On a case-insensitive destination, homily.pdf and Homily.pdf are ONE
# file: rsync copies both without complaint and the second silently
# overwrites the first. Not theoretical -- it destroyed
# Siddhartha/Homily.pdf on 2026-07-30 and only the hash pass caught it.
# Detect BEFORE copying; carry the shadowed halves under names that
# cannot collide rather than losing them.
#
# Emits EVERY member of a colliding group, not just the shadowed ones.
# That matters: on NTFS the surviving directory entry keeps whichever case
# was written first while holding the LAST writer's content, so which name
# survives and which content it holds are independent. Verifying the main
# tree against either name is therefore unsound. Instead every member is
# carried into .case-collisions/ under a name that cannot collide, proven
# there by hash, and excluded from the main comparison on both sides --
# so correctness never depends on drvfs's overwrite semantics.
# Takes the SET NAME, not just a path, because the scan must honour the
# set's excludes. It did not, and so it rescued Siddhartha/Homily.pdf into
# Project Archive's collision directory -- a file rsync was explicitly told
# to skip and which belongs to an entirely different set.
media_find_collisions() {
  local name="$1" src prune=() ex
  src="$(manifest_set_path "$name")"
  while IFS= read -r ex; do
    [ -n "$ex" ] && prune+=(-path "./$ex" -prune -o)
  done < <(manifest_set_excludes "$name")
  ( cd "$src" 2>/dev/null && find . "${prune[@]+"${prune[@]}"}" -type f -printf '%P\n' ) \
    | awk '{print tolower($0)"\t"$0}' | sort \
    | awk -F'\t' '{ c[$1]=c[$1]"\n"$2; n[$1]++ }
                  END { for (k in n) if (n[k]>1) { s=substr(c[k],2); print s } }'
}

# media_remote_dir <set> -- the directory name a copy actually lands under
# $root at, independent of the set's manifest NAME. rsync is handed the
# source path with no trailing slash, so it lands at basename(<source
# path>) -- copy and verify must agree on that, not each derive it their
# own way (#27: they used to, and diverged the moment a set's manifest
# name stopped matching its path's basename).
media_remote_dir() {
  basename "$(manifest_set_path "$1")"
}

# media_copy_set <set> <dest>   -- returns 0 kept, non-zero broken
media_copy_set() {
  local name="$1" dest="$2"
  local src root remote_dir target ssh_target ci collisions rc
  src="$(manifest_set_path "$name")"
  root="$(manifest_dest_field "$dest" root)"
  remote_dir="$(media_remote_dir "$name")"
  ci="$(manifest_dest_field "$dest" case_insensitive false)"

  [ -d "$src" ] || { media_fail "set '$name': no such source directory: $src"; return 1; }

  local rsync_args=(-rt --timeout=600 --partial-dir=.rsync-partial --info=stats2)
  local ex
  while IFS= read -r ex; do
    [ -n "$ex" ] && rsync_args+=(--exclude="$ex")
  done < <(manifest_set_excludes "$name")

  collisions=""
  if [ "$ci" = true ]; then
    media_log "[*] pre-flight: case-collision scan ($dest is case-insensitive)"
    collisions="$(media_find_collisions "$name")"
    if [ -n "$collisions" ]; then
      media_log "[!] $(printf '%s\n' "$collisions" | wc -l) file(s) would be silently"
      media_log "    overwritten; copying them to $name.case-collisions/ instead:"
      printf '%s\n' "$collisions" | sed 's/^/      /'
    fi
  fi

  case "$(manifest_dest_field "$dest" kind)" in
    ssh)
      dest_ssh_opts "$dest"; ssh_target="$(dest_target "$dest")"
      target="$ssh_target:$root/"
      media_log "[*] copying: $src  ->  $root/$remote_dir"
      rsync "${rsync_args[@]}" -e "ssh ${DEST_SSH_OPTS[*]}" "$src" "$target"
      rc=$? ;;
    local)
      media_log "[*] copying: $src  ->  $root/$remote_dir"
      rsync "${rsync_args[@]}" "$src" "$root/"
      rc=$? ;;
    *) media_fail "set '$name': destination '$dest' has an unknown kind"; return 1 ;;
  esac
  [ "$rc" -eq 0 ] || { media_fail "set '$name': rsync exited $rc"; return 1; }

  if [ -n "$collisions" ]; then
    local cdir="$root/$name.case-collisions" rel safe
    if [ "$(manifest_dest_field "$dest" kind)" = ssh ]; then
      ssh "${DEST_SSH_OPTS[@]}" "$ssh_target" "mkdir -p '$cdir'" || \
        { media_fail "set '$name': could not create $cdir"; return 1; }
    else
      mkdir -p "$cdir" || { media_fail "set '$name': could not create $cdir"; return 1; }
    fi
    # Read the group into an ARRAY before iterating.
    #
    # `while read ... done <<< "$collisions"` looks equivalent and is not:
    # ssh (and rsync) read from stdin, and inside such a loop stdin IS the
    # remaining collision list. ssh swallowed it, so only the first few of
    # 8 files were processed and the rest silently stayed in the comparison
    # -- 3 uppercase variants stranded in the local md5 list, reported as a
    # hash mismatch on an transfer that had actually succeeded. An array
    # cannot be consumed by anything the body calls.
    local _cols=(); mapfile -t _cols <<< "$collisions"
    for rel in "${_cols[@]}"; do
      [ -n "$rel" ] || continue
      safe="$(media_safe_name "$rel")"
      if [ "$(manifest_dest_field "$dest" kind)" = ssh ]; then
        rsync -t --timeout=600 -e "ssh ${DEST_SSH_OPTS[*]}" \
              "$src/$rel" "$ssh_target:$cdir/$safe" \
          || { media_fail "set '$name': shadowed file '$rel' failed to copy"; return 1; }
      else
        cp -p "$src/$rel" "$cdir/$safe" \
          || { media_fail "set '$name': shadowed file '$rel' failed to copy"; return 1; }
      fi
    done
  fi

  MEDIA_COLLISIONS="$collisions"
  return 0
}

# media_verify_set <set> <dest> -- 0 proven, non-zero broken
media_verify_set() {
  local name="$1" dest="$2"
  local src root remote_dir mode lf rf rel safe lh rh
  src="$(manifest_set_path "$name")"
  root="$(manifest_dest_field "$dest" root)"
  remote_dir="$(media_remote_dir "$name")"
  mode="$(manifest_set_field "$name" verify md5)"

  if [ "$mode" != md5 ]; then
    media_log "[*] $name: verify mode '$mode' -- rsync itemization only, not a byte proof"
    return 0
  fi

  mkdir -p "$GARDE_STATE"
  lf="$GARDE_STATE/$name.local.md5"; rf="$GARDE_STATE/$name.remote.md5"

  media_log "[*] hashing local side"
  local prune=() ex
  while IFS= read -r ex; do
    [ -n "$ex" ] && prune+=(-path "./$ex" -prune -o)
  done < <(manifest_set_excludes "$name")
  ( cd "$src" && find . "${prune[@]+"${prune[@]}"}" -type f -print0 \
      | sort -z | xargs -0 md5sum ) | sed 's|\./||' | sort -k2 > "$lf" \
    || { media_fail "set '$name': local hashing failed"; return 1; }

  media_log "[*] hashing remote side"
  case "$(manifest_dest_field "$dest" kind)" in
    ssh)
      dest_ssh_opts "$dest"
      ssh "${DEST_SSH_OPTS[@]}" "$(dest_target "$dest")" \
        "cd '$root/$remote_dir' && find . -type f -print0 | sort -z | xargs -0 md5sum" \
        | sed 's|\./||' | sort -k2 > "$rf" ;;
    local)
      ( cd "$root/$remote_dir" && find . -type f -print0 | sort -z | xargs -0 md5sum ) \
        | sed 's|\./||' | sort -k2 > "$rf" ;;
  esac
  [ -s "$rf" ] || { media_fail "set '$name': remote hashing produced nothing"; return 1; }

  # Shadowed files cannot appear in the main remote tree by definition.
  # Verify them where they actually live, then drop them from the main
  # comparison so it stays strict about everything else.
  if [ -n "${MEDIA_COLLISIONS:-}" ]; then
    media_log "[*] verifying $name.case-collisions/"
    # Read the group into an ARRAY before iterating.
    #
    # `while read ... done <<< "$collisions"` looks equivalent and is not:
    # ssh (and rsync) read from stdin, and inside such a loop stdin IS the
    # remaining collision list. ssh swallowed it, so only the first few of
    # 8 files were processed and the rest silently stayed in the comparison
    # -- 3 uppercase variants stranded in the local md5 list, reported as a
    # hash mismatch on an transfer that had actually succeeded. An array
    # cannot be consumed by anything the body calls.
    local _vcols=(); mapfile -t _vcols <<< "$MEDIA_COLLISIONS"
    for rel in "${_vcols[@]}"; do
      [ -n "$rel" ] || continue
      safe="$(media_safe_name "$rel")"
      lh="$(md5sum "$src/$rel" | cut -d' ' -f1)"
      if [ "$(manifest_dest_field "$dest" kind)" = ssh ]; then
        rh="$(ssh -n "${DEST_SSH_OPTS[@]}" "$(dest_target "$dest")" \
              "md5sum '$root/$name.case-collisions/$safe'" | cut -d' ' -f1)"
      else
        rh="$(md5sum "$root/$name.case-collisions/$safe" 2>/dev/null | cut -d' ' -f1)"
      fi
      [ "$lh" = "$rh" ] || { media_fail "set '$name': shadowed '$rel' did not land intact"; return 1; }
      media_log "    [ok] $rel -> $safe"
      # Drop this path from BOTH lists, case-insensitively: the remote may
      # hold it under a different case than the source does.
      local low; low="$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')"
      awk -v p="$low" 'BEGIN{IGNORECASE=0}
        { path=$0; sub(/^[0-9a-f]+  /,"",path);
          lp=tolower(path); if (lp!=p) print }' "$lf" > "$lf.t" && mv "$lf.t" "$lf"
      awk -v p="$low" '{ path=$0; sub(/^[0-9a-f]+  /,"",path);
          lp=tolower(path); if (lp!=p) print }' "$rf" > "$rf.t" && mv "$rf.t" "$rf"
    done
  fi

  diff -u "$lf" "$rf" > "$GARDE_STATE/$name.md5diff" || true

  # CLASSIFY THE DIFFERENCE. Do not treat any difference as breakage.
  #
  # Found 2026-08-02, on this verifier's FIRST EVER nightly run, which failed
  # on `Projects` -- the most important set on the box. The entire difference
  # was ONE line: `realisateur/.git/logs/refs/stash`, present on the
  # destination and absent locally. A concurrent session stashed and unstashed
  # during the copy window; git deletes that reflog when the stash stack
  # empties. rsync copied it at 03:39:48, and by the local hashing at 03:40:00
  # it was gone.
  #
  # THAT WOULD NOT HAVE BEEN A ONE-NIGHT RACE. `rsync_args` carries no
  # `--delete` (deliberately -- a backup that deletes will happily propagate
  # an accidental `rm` to the only copy you have). So a file that is ever
  # copied and then deleted locally stays on the destination FOREVER, and a
  # symmetric `diff -u` of the two hash lists reports it every single night.
  # `Projects` was set to fail permanently, from the first run, on a file
  # belonging to git's own bookkeeping.
  #
  # The asymmetry is the fix, because the PROMISE is asymmetric. garde's claim
  # is "everything I have is copied and proven" -- not "the destination is
  # byte-identical to me". Three outcomes, not two:
  #
  #   MISSING    a local file the destination does not have  -> BROKEN
  #   DIFFERENT  same path, different bytes                  -> BROKEN
  #   EXTRA      a path only the destination has             -> STALE, not broken
  #
  # EXTRA is reported loudly and counted -- never swallowed -- because stale
  # material on the destination is worth knowing about. It is simply not a
  # failure of the promise, and calling it one is how a guard that cries wolf
  # gets switched off.
  #
  # Keyed by PATH in awk rather than joined on a sorted field: an md5sum line
  # is 32 hex, two spaces, then the path VERBATIM, and paths here contain
  # spaces (`Project Archive/...`). Any field-splitting comparison silently
  # mis-pairs those.
  local cls; cls="$GARDE_STATE/$name.classified"
  awk 'FNR==NR { L[substr($0,35)]=substr($0,1,32); next }
       { R[substr($0,35)]=substr($0,1,32) }
       END {
         for (p in L) {
           if (!(p in R))          print "MISSING\t"   p
           else if (L[p] != R[p])  print "DIFFERENT\t" p
         }
         for (p in R) if (!(p in L)) print "EXTRA\t" p
       }' "$lf" "$rf" > "$cls"

  local n_missing n_different n_extra n_total
  n_missing=$(grep -c '^MISSING'   "$cls" || true)
  n_different=$(grep -c '^DIFFERENT' "$cls" || true)
  n_extra=$(grep -c '^EXTRA'     "$cls" || true)
  n_total=$(wc -l < "$lf")

  if [ "$n_extra" -gt 0 ]; then
    printf 'garde: STALE: %s: %d path(s) on the destination that are not local\n' \
      "$name" "$n_extra" >&2
    printf 'garde: STALE:   not a copy failure -- garde never passes --delete, so a\n' >&2
    printf 'garde: STALE:   file deleted locally after a copy remains at the destination.\n' >&2
    grep '^EXTRA' "$cls" | head -5 | cut -f2 | sed 's/^/garde: STALE:   /' >&2
    [ "$n_extra" -gt 5 ] && printf 'garde: STALE:   ... and %d more; full list: %s\n' \
      "$((n_extra - 5))" "$cls" >&2
  fi

  if [ "$n_missing" -eq 0 ] && [ "$n_different" -eq 0 ]; then
    # `${n_extra:+...}` would be wrong here: "0" is non-empty, so it would
    # append "(0 stale...)" to every clean run.
    local stale_note=''
    [ "$n_extra" -gt 0 ] && stale_note=" ($n_extra stale at destination)"
    media_log "[ok] $name: $n_total files, every md5 matches$stale_note"
    media_mark_verified "$name"
    return 0
  fi

  printf 'garde: BROKEN: %s: %d missing, %d differing (of %d local files)\n' \
    "$name" "$n_missing" "$n_different" "$n_total" >&2
  grep -E '^(MISSING|DIFFERENT)' "$cls" | head -10 | sed 's/^/garde: BROKEN:   /' >&2
  printf 'garde: BROKEN: full classification: %s\n' "$cls" >&2
  printf 'garde: diagnosis is not mechanizable yet. It needs a summon:\n' >&2
  printf 'garde:   garde media triage %q --summon\n' "$name" >&2
  return 5
}

# A file-count match is not a freshness proof (gardien#21): `.config`
# reported `ok x1` on 2026-08-13 with a file created two days earlier still
# entirely absent from the destination, because a file deleted locally after
# an earlier copy was still masking it in the same count. The count can only
# be trusted at the moment `media_verify_set` actually walks every byte;
# after that moment it is stale evidence, and staleness is the thing `list`
# has no way to say. These three functions give it one, keyed by SET only
# (not set+destination) -- `list` already reports one aggregate STATUS word
# per set across every destination it names, so the freshness word matches
# that grain rather than inventing a finer one.

# Stamp the moment a full byte-proof passed. Never called for a set whose
# `verify` mode is not `md5` -- there is no byte-level claim to stamp.
media_mark_verified() {
  mkdir -p "$GARDE_STATE"
  date +%s > "$GARDE_STATE/$1.verified-at"
}

# Epoch seconds of the last full verify, or 0 if this set has never been
# proven since GARDE_STATE was last empty.
media_last_verified() {
  local f="$GARDE_STATE/$1.verified-at"
  [ -f "$f" ] && cat "$f" || echo 0
}

# Epoch seconds of the newest local file's mtime in this set, or 0 if the
# set has no source directory or no files. Excludes honored the same way
# media_local_files honors them, so the two agree on what "in the set" means.
media_newest_local_mtime() {
  local src prune=() ex t
  src="$(manifest_set_path "$1")"
  [ -d "$src" ] || { echo 0; return; }
  while IFS= read -r ex; do
    [ -n "$ex" ] && prune+=(-path "./$ex" -prune -o)
  done < <(manifest_set_excludes "$1")
  t="$( ( cd "$src" && find . "${prune[@]+"${prune[@]}"}" -type f -printf '%T@\n' 2>/dev/null ) \
        | sort -n | tail -1 | cut -d. -f1)"
  printf '%s\n' "${t:-0}"
}

# Is this set already proven at this destination? Cheap check for `list`:
# does the remote tree exist and hold roughly the right file count.
# Counts the main tree PLUS the .case-collisions sibling. Files rescued
# from a collision group cannot live in the main tree by definition, so a
# count that ignores them reports a fully-proven set as short -- which is
# exactly what Siddhartha did on the first real run (2760 local vs 2759
# remote, the one file being the rescued Homily.pdf).
media_remote_files() {
  local name="$1" dest="$2" root remote_dir
  root="$(manifest_dest_field "$dest" root)"
  remote_dir="$(media_remote_dir "$name")"
  case "$(manifest_dest_field "$dest" kind)" in
    ssh)
      dest_ssh_opts "$dest"
      ssh "${DEST_SSH_OPTS[@]}" -o ConnectTimeout=10 "$(dest_target "$dest")" \
          "{ find '$root/$remote_dir' -type f 2>/dev/null; find '$root/$name.case-collisions' -type f 2>/dev/null; } | wc -l" 2>/dev/null ;;
    local)
      { find "$root/$remote_dir" -type f 2>/dev/null
        find "$root/$name.case-collisions" -type f 2>/dev/null; } | wc -l ;;
  esac
}

media_local_files() {
  local src prune=() ex
  src="$(manifest_set_path "$1")"
  [ -d "$src" ] || { echo 0; return; }
  while IFS= read -r ex; do
    [ -n "$ex" ] && prune+=(-path "./$ex" -prune -o)
  done < <(manifest_set_excludes "$1")
  ( cd "$src" && find . "${prune[@]+"${prune[@]}"}" -type f -print 2>/dev/null | wc -l )
}
