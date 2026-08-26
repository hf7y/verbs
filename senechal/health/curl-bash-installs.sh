#!/usr/bin/env bash
# senechal: curl|bash install audit. Non-AI, cron-safe, READ-ONLY.
#
#   ./curl-bash-installs.sh          # full report
#   ./curl-bash-installs.sh -q       # silent unless something needs attention
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

WARN_PCT="$(cfg health.curl_bash_warn_pct 15)"

# --- evidence: curl|bash / wget|sh lines in shell history ---------------
# Matches "curl ... | bash", "curl ... | sudo sh", "sh -c "$(curl ...)"
# and the wget equivalents. Deliberately does not try to be exhaustive
# against every obfuscation (base64 pipes, `eval`) -- those are a
# different, adversarial threat model; this is an audit of Zach's own
# ordinary install habits.
HIST_PATTERN='(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(env[[:space:]]+[A-Za-z_]+=[^[:space:]]+[[:space:]]+)?(ba)?sh|sh[[:space:]]+-c[[:space:]]+["'"'"']?\$\(curl'

_history_files() {
  local f
  for f in "$HOME/.bash_history" "$HOME/.zsh_history" "${HISTFILE:-}"; do
    [ -n "$f" ] && [ -r "$f" ] && printf '%s\n' "$f"
  done | sort -u
}

# Best-effort tool name from an install-script URL, e.g.
# https://tailscale.com/install.sh -> tailscale
_guess_name() {
  local url="$1" host
  host="$(printf '%s' "$url" | sed -E 's#^https?://##; s#/.*##')"
  printf '%s' "${host%%.*}"
}

# The installer domain doesn't always match the binary it leaves behind
# (gh.io/copilot-install drops `copilot`, not `gh`; nousresearch's
# hermes-agent installer drops `hermes`). Known cases first, guessed
# name last, so the first one found on PATH is what gets judged.
_candidate_names() {
  local host="$1" guessed="$2"
  case "$host" in
    *nousresearch*)  echo "hermes hermes-agent" ;;
    cursor.com)      echo "cursor-agent cursor" ;;
    gh.io)           echo "copilot gh" ;;
    *)               echo "" ;;
  esac
  echo "$guessed"
}

# Is this on-disk binary owned by a package manager, judged by its
# resolved PATH -- not by guessing whether a same-named package exists
# (gh.io/copilot-install's guessed name "gh" collides with the
# apt-installed gh CLI, which is a different binary entirely; only the
#   [rest: vault:senechal/header-archaeology-20260818.md]
_package_managed() {
  local bin="$1" real
  # Check the RAW path before resolving symlinks: /snap/bin/* is snap's
  # own dispatch shim and fully resolves to /usr/bin/snap, which would
  # otherwise misreport every snap-installed command as "dpkg".
  case "$bin" in
    /snap/*) echo snap; return 0 ;;
  esac
  real="$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")"
  case "$real" in
    */flatpak/*) echo flatpak; return 0 ;;
  esac
  command -v dpkg >/dev/null 2>&1 && dpkg -S "$real" >/dev/null 2>&1 && { echo dpkg; return 0; }
  return 1
}

check_curl_bash() {
  head_ "curl|bash install lines found in shell history"
  local files file line url host name managed bin found=0
  files="$(_history_files)"
  if [ -z "$files" ]; then
    skip "no readable shell history (.bash_history / .zsh_history) -- cannot audit"
    return
  fi

  while IFS= read -r file; do
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      found=1
      url="$(printf '%s' "$line" | grep -oE 'https?://[^[:space:]"'"'"']+' | head -1)"
      host="$(printf '%s' "${url:-}" | sed -E 's#^https?://##; s#/.*##')"
      name="$(_guess_name "${url:-unknown}")"
      bin=""
      for cand in $(_candidate_names "$host" "$name"); do
        bin="$(command -v "$cand" 2>/dev/null || true)"
        [ -n "$bin" ] && { name="$cand"; break; }
      done
      if [ -z "$bin" ]; then
        note "$name ($url) -- ran once (history), nothing found on PATH now: removed, renamed, or under a different binary name"
      elif managed="$(_package_managed "$bin")"; then
        ok "$name ($url) -- $bin, handed off to $managed, tracked like any other package"
      else
        warn_ "$name ($url) -- unmanaged binary at $bin, only curl|bash can update or remove it"
        UNMANAGED_LIST+=("$name")
      fi
    done < <(grep -inE "$HIST_PATTERN" "$file" 2>/dev/null | sed 's/^[0-9]*://')
  done <<<"$files"

  [ "$found" -eq 1 ] || note "no curl|bash lines found in $(printf '%s' "$files" | tr '\n' ' ')"
}

# --- denominator: the general ecosystem ----------------------------------
# "General ecosystem" = everything Zach explicitly asked a package
# manager to install, plus global language-tool installs. This
# deliberately excludes dpkg's full ~4k-package count (mostly transitive
# library dependencies, not apps Zach chose) in favour of
# apt-mark showmanual, the same distinction apt itself draws between
# "you asked for this" and "something else pulled it in".
ecosystem_count() {
  local total=0 n
  if command -v apt-mark >/dev/null 2>&1; then
    n="$(apt-mark showmanual 2>/dev/null | wc -l)"; total=$((total + n))
  fi
  if command -v snap >/dev/null 2>&1; then
    n="$(snap list 2>/dev/null | tail -n +2 | wc -l)"; total=$((total + n))
  fi
  if command -v flatpak >/dev/null 2>&1; then
    n="$(flatpak list --app 2>/dev/null | wc -l)"; total=$((total + n))
  fi
  if command -v npm >/dev/null 2>&1; then
    n="$(npm ls -g --depth=0 2>/dev/null | tail -n +2 | grep -c .)"; total=$((total + n))
  fi
  if command -v pip3 >/dev/null 2>&1; then
    n="$(pip3 list --user 2>/dev/null | tail -n +3 | grep -c .)"; total=$((total + n))
  fi
  echo "$total"
}

main() {
  parse_common_args "$@"
  _emit "senechal curl|bash install audit -- $(date '+%Y-%m-%d %H:%M')"

  UNMANAGED_LIST=()
  check_curl_bash

  local eco unmanaged pct
  eco="$(ecosystem_count)"
  unmanaged=${#UNMANAGED_LIST[@]}

  head_ "Share of the ecosystem installed via unmanaged curl|bash"
  if [ "$eco" -eq 0 ] && [ "$unmanaged" -eq 0 ]; then
    skip "could not count package-managed apps (no apt-mark/snap/flatpak/npm/pip found)"
  else
    pct=$(( unmanaged * 100 / (eco + unmanaged) ))
    note "unmanaged curl|bash: $unmanaged   package-managed (apt-mark showmanual + snap + flatpak + npm -g + pip --user): $eco   total: $((eco + unmanaged))"
    if [ "$unmanaged" -gt 0 ]; then
      note "unmanaged: ${UNMANAGED_LIST[*]}"
    fi
    if [ "$pct" -ge "$WARN_PCT" ]; then
      warn_ "${pct}% of the tracked ecosystem is unmanaged curl|bash installs (>= ${WARN_PCT}% threshold)"
    else
      ok "${pct}% of the tracked ecosystem is unmanaged curl|bash installs"
    fi
  fi

  finish_verify "OK -- curl|bash install audit complete."
}
main "$@"
