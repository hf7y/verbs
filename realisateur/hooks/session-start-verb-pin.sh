#!/usr/bin/env bash
set -uo pipefail  # session-start-verb-pin.sh: SessionStart context hook -- states the verb-build pin so a finding is never filed against a stale command (#708; realisateur#653 was filed against /cloture 2 days behind main because it ran from verb-builds/current, not the checkout). Always exits 0: context, never a gate. No network call -- reads only what is already cached locally.

BUILD_ROOT="${VERB_BUILD_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/verb-builds}"
REPO="$BUILD_ROOT/repo"

payload="$(cat 2>/dev/null)" || true
cwd="${CLAUDE_PROJECT_DIR:-}"
[ -n "$cwd" ] || cwd="$(printf '%s' "$payload" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[ -n "$cwd" ] || cwd="$PWD"

[ -d "$BUILD_ROOT" ] || exit 0
pin="$(readlink "$BUILD_ROOT/current" 2>/dev/null)"
[ -n "$pin" ] || exit 0

stamp="$(printf '%s' "$pin" | sed -n 's/^\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)T.*/\1-\2-\3/p')"  # build ids are UTC stamps; age from the id itself, same derivation verbs-refresh.sh uses, not the dir's mtime
age_days=''
if [ -n "$stamp" ]; then
  then_s="$(date -u -d "$stamp" +%s 2>/dev/null)"
  now_s="$(date -u +%s)"
  [ -n "$then_s" ] && age_days=$(( (now_s - then_s) / 86400 ))
fi

findings=()

if [ -d "$REPO/.git" ]; then   # never fetches -- reads only whatever the bare clone already has cached
  latest_tag="$(git -C "$REPO" tag --list 'build/*' --sort=-refname 2>/dev/null | head -1)"
  latest_id="${latest_tag#build/}"
  if [ -n "$latest_id" ] && [ "$latest_id" != "$pin" ]; then
    findings+=("NEWER  build $latest_id is cached and unadopted -- verbs-refresh.sh --apply")
  fi
fi

if [ -f "$cwd/bin/lib/carries.tsv" ]; then   # carries.tsv is unique to realisateur; the pinned build is a whole-tree copy of bashified, so each row is a direct path comparison
  pinned_proj="$BUILD_ROOT/$pin/realisateur"
  if [ -d "$pinned_proj" ]; then
    diverged=0
    while IFS=$'\t' read -r carried source; do
      case "$carried" in ''|'#'*) continue ;; esac
      [ -n "$source" ] || continue
      src="$cwd/$source"
      [ -f "$src" ] || continue
      cmp -s "$src" "$pinned_proj/$carried" 2>/dev/null || diverged=$((diverged + 1))
    done < "$cwd/bin/lib/carries.tsv"
    if [ "$diverged" -gt 0 ]; then
      findings+=("DIVERGES  $diverged carried file(s) in this checkout differ from the pinned build -- diff a command against THIS CHECKOUT before trusting a finding about it")
    fi
  fi
fi

[ "${#findings[@]}" -eq 0 ] && exit 0   # current pin, checkout matches (or nothing to compare) -- boring, say nothing

printf 'verbs: on build %s%s\n' "$pin" "${age_days:+ ($age_days day(s) old)}"
printf '  %s\n' "${findings[@]}"
exit 0
