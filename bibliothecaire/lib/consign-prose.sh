#!/usr/bin/env bash
# lib/consign-prose.sh -- deposit prose into the vault as linked data.
#
# VENDORED, AND FROM WHERE. This is basheur's `impl/consign-prose`, copied
# from hf7y/basheur blob 2d02c1ca412d509d868a5d7dd1aab55951c0c4c6 (fetched
# 2026-08-06). Only this header differs; everything below is byte-for-byte
# what basheur ran, so a deposit made through this file is the same deposit
# that produced the ~150 notes already in the vault.
#
# WHY IT LIVES HERE NOW. `bin/fonde` reached this code by running
# `basheur run consign-prose`. **basheur was retired on 2026-08-05** and its
# clone is gone from mandark, so that call could not be made: `fonde consign`
# exited 4 with "basheur is not on PATH, so no summon can be routed through
# the contract store" -- loud, correct, and useless, because the mechanism it
# was routing to is a plain bash script that needs no contract store to run.
#
# The routing existed to ask ONE question: is this contract MECHANIZED (exec
# the impl, spend nothing, say so) or AGENT (summon one)? For consign-prose
# that question was answered on 2026-08-01 and cannot come out differently
# again -- the impl exists, it is below, and it contacts no model. Asking a
# retired agent a question whose answer is settled is what was broken.
#
# This is the move `range` made in #14 -- carry the implementation on the
# branch instead of exec'ing something that is not on it -- for the same
# reason: a verb that depends on a tree nobody guarantees is a verb that
# stops working the day that tree is cleared, silently, at the next call.
#
# WHAT IS MECHANICAL AND WHAT IS NOT (basheur's own note, kept because it is
# still true of the code below). Everything about provenance, fidelity and
# the two refusals is mechanical and is done here exactly. The one genuinely
# agent-shaped judgment -- which names in a document are ecosystem references
# worth linking -- is NOT faked. Names that are also ordinary words (`range`,
# `verse`, `archive`) are not linked on sight; they are recorded in the
# note's own `ambiguous_candidates` frontmatter, so the judgment is visible
# and can be made later, by a reader, against a note that says it is pending.
#
# That is deliberate. The summon that preceded this impl emitted `[[_paced]]`
# for a mention of `_paced.conf` -- a link to a file, not an entity. Agent
# judgment on this row is not reliable enough to be worth paying for, and a
# wrong link is worse than an absent one because it looks decided.
set -uo pipefail

VAULT="${1:-}"
[ -n "$VAULT" ] || { printf 'consign-prose: usage: consign-prose <vault> <path>...\n' >&2; exit 2; }
shift
[ $# -gt 0 ] || { printf 'consign-prose: at least one path is required\n' >&2; exit 2; }

SCHED="${SCHEDULER_HOME:-/home/zach/Documents/Projects/scheduler}"

die()    { printf 'consign-prose: %s\n' "$*" >&2; exit 2; }
blind()  { printf 'consign-prose: BLIND: %s\n' "$*" >&2; exit 6; }
refuse() { printf 'consign-prose: REFUSED: %s\n' "$*" >&2; exit 7; }

# ---- refusals, before anything is read or written -------------------------
[ -d "$VAULT" ] || blind "no vault at $VAULT"
git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1 \
  || refuse "$VAULT is not a git repository; a deposit there would be the only copy with no history behind it"

for p in "$@"; do
  [ -e "$p" ] || die "no such path: $p"
  [ -r "$p" ] || blind "cannot read $p"
done

# ---- candidate entity names, generated and never typed --------------------
# Registered projects, plus whatever installe reports on PATH. A hand-typed
# list goes stale silently, which is the failure this whole ecosystem records
# most often.
declare -a CAND=()
for c in "$SCHED"/schedule/*.conf; do
  [ -e "$c" ] || continue
  n="$(basename "$c" .conf)"
  case "$n" in _*) continue ;; esac
  CAND+=("$n")
done
if command -v installe >/dev/null 2>&1; then
  while IFS=$'\t' read -r n _; do
    [ -n "$n" ] && CAND+=("$n")
  done < <(installe list 2>/dev/null)
fi

# Names that are also ordinary words. Linking these on sight produces
# [[range]] inside "a wide range of sources", which is the example the
# contract names. They become candidates for judgment, not links.
is_ambiguous() {
  case "$1" in
    range|verse|fonde|cueille|garde|trie|lance|veille|classe|archive|installe|recense|basheur) return 0 ;;
    *) return 1 ;;
  esac
}

DEPOSITED=()
SAFE=()

for p in "$@"; do
  abs="$(readlink -f "$p")"
  dir="$(dirname "$abs")"
  repo="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" \
    || blind "$p is not inside a git repository, so its provenance cannot be recorded"
  project="$(basename "$repo")"
  rel="${abs#"$repo"/}"
  commit="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || commit="unknown"
  sha="$(sha256sum "$abs" | cut -d' ' -f1)"

  # A document that does not end in a newline runs its last line into the end
  # marker, so the marker stops delimiting anything and the body reads back one
  # line short. One of bibliothecaire's 37 prose files is like this, and the
  # read-back gate caught it rather than depositing a truncated archive. The
  # newline is added so the format holds, and the fact that it was added is
  # recorded, so the deposit still describes the original exactly.
  noeol=0
  [ -n "$(tail -c 1 "$abs")" ] && noeol=1

  dest="$VAULT/$project/$rel"
  mkdir -p "$(dirname "$dest")" || blind "cannot create $(dirname "$dest")"
  tmp="$(mktemp)" || blind "cannot create a temporary file"

  # Which candidate names does this document actually mention?
  linked=(); ambiguous=()
  for n in $(printf '%s\n' "${CAND[@]}" | sort -u); do
    grep -qw -- "$n" "$abs" 2>/dev/null || continue
    if is_ambiguous "$n"; then ambiguous+=("$n"); else linked+=("$n"); fi
  done

  {
    printf -- '---\n'
    printf 'source_repo: %s\n' "$repo"
    printf 'source_path: %s\n' "$rel"
    printf 'source_commit: %s\n' "$commit"
    printf 'source_sha256: %s\n' "$sha"
    printf 'consigned: %s\n' "$(date +%Y-%m-%d)"
    printf 'project: %s\n' "$project"
    [ "$noeol" = 1 ] && printf 'body_trailing_newline_added: true\n'
    if [ ${#ambiguous[@]} -gt 0 ]; then
      # Named, not linked, and not dropped. The judgment is pending and says so.
      printf 'ambiguous_candidates: %s\n' "$(printf '%s ' "${ambiguous[@]}" | sed 's/ $//')"
    fi
    printf -- '---\n\n'
    printf '# %s\n\n' "$rel"
    printf '<!-- consigned: body below is byte-for-byte the original -->\n'
    cat "$abs"
    [ "$noeol" = 1 ] && printf '\n'
    printf '<!-- fonde:end-body -->\n'
    if [ ${#linked[@]} -gt 0 ]; then
      printf '\n## Referenced\n\n'
      for n in "${linked[@]}"; do printf -- '- [[%s]]\n' "$n"; done
    fi
  } > "$tmp" || blind "cannot write a temporary note for $rel"

  # OVERWRITE REFUSAL, and it compares the WHOLE FILE rather than just the body.
  # An earlier draft compared only the region between the markers, which meant a
  # note a reader had annotated below the body -- added links, notes, anything --
  # was indistinguishable from a fresh one and got silently replaced. Its own
  # verify: script caught that. An identical file is an idempotent re-run and is
  # fine; anything else is somebody's work, and this refuses to destroy it.
  if [ -f "$dest" ]; then
    if cmp -s "$tmp" "$dest"; then
      rm -f "$tmp"
      printf 'DEPOSITED %s\n' "$dest"
      DEPOSITED+=("$dest"); SAFE+=("$rel")
      continue
    fi
    rm -f "$tmp"
    refuse "$dest already exists and differs from what this deposit would write; overwriting it would destroy the earlier note"
  fi
  mv "$tmp" "$dest" || blind "cannot place $dest"

  # THE READ-BACK GATE. Never self-reported: the bytes are pulled back off disk
  # and hashed. An archive that edits what it archives has destroyed the thing
  # it was protecting.
  if [ "$noeol" = 1 ]; then
    got="$(sed -n '/<!-- consigned: body below/,/<!-- fonde:end-body -->/p' "$dest" \
           | sed '1d;$d' | head -c -1 | sha256sum | cut -d' ' -f1)"
  else
    got="$(sed -n '/<!-- consigned: body below/,/<!-- fonde:end-body -->/p' "$dest" \
           | sed '1d;$d' | sha256sum | cut -d' ' -f1)"
  fi
  if [ "$got" != "$sha" ]; then
    printf 'consign-prose: BROKEN: %s was written but read back with a different body (%s != %s)\n' \
      "$dest" "$got" "$sha" >&2
    exit 5
  fi

  printf 'DEPOSITED %s\n' "$dest"
  DEPOSITED+=("$dest")
  SAFE+=("$rel")
done

# Nothing is deleted, ever, including on success. What is safe to remove is
# REPORTED, and a caller who has read that takes the decision.
printf 'safe to remove from the source repository: %s\n' "$(printf '%s ' "${SAFE[@]}" | sed 's/ $//')"
exit 0
