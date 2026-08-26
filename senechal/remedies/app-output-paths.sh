#!/usr/bin/env bash
# Concern: an app's own config defaulting its save/export dialog to bare
# $HOME, which is why files of a given extension scatter loose there
# instead of landing in a canonical Documents/ subfolder. See
# ../CONCERNS.md.
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

# =======================================================================
# enable
# =======================================================================
cmd_enable() {
  say "senechal remedy: app output paths -> canonical Documents/ subfolders"
  say "Backups go to $BACKUP_ROOT/<timestamp>/"
  say ""
  local any=0 changed_any=0

  while IFS=$'\x1f' read -r name ext config_file section key canonical_dir; do
    [ -n "$name" ] || continue
    any=1
    local file dir b current
    file="$(expand_path "$config_file")"
    dir="$(expand_path "$canonical_dir")"

    say "== $name ($ext -> $canonical_dir) =="

    mkdir -p "$dir"
    say "   canonical dir $dir exists (created if missing)"

    if [ ! -f "$file" ]; then
      # Deliberately NOT synthesised. the remedy contract asks for
      # fresh-machine readiness, and the fresh-machine half that is
      # actually safe is the canonical dir above: writing a stub config
      # for an app that has never launched hands it a profile it did not
      # author, which some apps treat as complete and never fill in.
      warn "$file does not exist yet -- $name has probably never been run on this machine. Skipping; re-run enable after its first run."
      say ""
      continue
    fi

    local elsewhere
    elsewhere="$(ini_sections_with_key "$file" "$key" | grep -v "^${section}$" || true)"
    if [ -n "$elsewhere" ] && [ -z "$(ini_get "$file" "$section" "$key")" ]; then
      die "$config_file defines $key under [$(printf '%s' "$elsewhere" | paste -sd, -)], not the registered [$section].
    Refusing to write $key into [$section]: $name would keep reading the other one, and
    verify would report PASS for a setting that changed nothing. Fix the section in
    senechal.json's app_output_paths.apps[] entry for $name, then re-run enable."
    fi

    current="$(ini_get "$file" "$section" "$key")"
    if [ "$current" = "$dir" ]; then
      say "   $config_file already has $key=$dir -- left alone."
      say ""
      continue
    fi

    b="$(backup_file "$file")"
    [ -n "$b" ] && say "   backed up $config_file -> $b"
    ini_set "$file" "$section" "$key" "$dir"

    # Re-probe rather than assume the write landed -- and probe through
    # the SAME section-aware reader verify uses, so "enable said it did
    # it" and "verify agrees" can never come apart.
    if [ "$(ini_get "$file" "$section" "$key")" != "$dir" ]; then
      die "wrote $key=$dir into [$section] of $file but reading it back did not return it. Your backup is $b -- restore it and look before re-running."
    fi
    say "   set [$section] $key=$dir in $config_file (was: ${current:-<unset>})"
    changed_any=1

    say ""
    say "   Config edits alone change nothing for an ALREADY-RUNNING"
    say "   instance of $name -- quit and relaunch it (or reboot) for"
    say "   this to take effect. Nothing else will make it reload."
    say ""
  done < <(cfg_app_output_paths)

  if [ "$any" -eq 0 ]; then
    say "app_output_paths.apps is empty in senechal.json -- nothing configured. See senechal.json.example."
    return
  fi
  if [ "$changed_any" -eq 0 ]; then
    say "Nothing to change -- already applied everywhere it could be checked."
  fi
  say "Then check it worked:   ./app-output-paths.sh verify"
}

expand_path() {
  python3 -c "import os,sys; print(os.path.expanduser(sys.argv[1]))" "$1"
}

# =======================================================================
# verify -- no AI, no network, safe to cron
# =======================================================================
cmd_verify() {
  head_ "app output paths -> canonical Documents/ subfolders (see CONCERNS.md)"

  local any=0
  while IFS=$'\x1f' read -r name ext config_file section key canonical_dir; do
    [ -n "$name" ] || continue
    any=1
    local file dir current loose_count
    file="$(expand_path "$config_file")"
    dir="$(expand_path "$canonical_dir")"

    if [ ! -f "$file" ]; then
      skip "$name: $config_file does not exist -- never run on this machine, or not yet enabled"
      continue
    fi

    current="$(ini_get "$file" "$section" "$key")"
    if [ "$current" = "$dir" ]; then
      ok "$name: $config_file [$section] $key=$dir"
      # Only meaningful once the config points there: a dir that has
      # since been deleted means the app is aimed at nothing. Before
      # enable it is simply not created yet, and saying so twice would
      # just be noise on top of the FAIL below.
      [ -d "$dir" ] || fail "$name: $dir does not exist -- $name is pointed at a path that is not there. Run: ./app-output-paths.sh enable"
    else
      fail "$name: $config_file [$section] $key=${current:-<unset>} (want $dir). Run: ./app-output-paths.sh enable"
    fi

    local elsewhere
    elsewhere="$(ini_sections_with_key "$file" "$key" | grep -v "^${section}$" || true)"
    if [ -n "$elsewhere" ]; then
      fail "$name: $key is also defined under [$(printf '%s' "$elsewhere" | paste -sd, -)] in $config_file, not only the registered [$section] -- one of them is the one $name reads, and a PASS on the other proves nothing. Re-probe the app's config and fix the section in senechal.json."
    fi

    # Witness, not proof: files of this extension still loose directly
    # in $HOME are consistent with the OLD path still being live (config
    # on disk is not the same as an app that re-read it -- same
    # liveness caveat as every other concern in CONCERNS.md). A warn,
    # not a fail: it can't tell "still misconfigured" apart from "the
    # app just hasn't been asked to save anything since enable".
    loose_count="$(find "$HOME" -maxdepth 1 -type f -iname "*${ext}" | wc -l)"
    if [ "$loose_count" -gt 0 ]; then
      warn_ "$name: $loose_count file(s) matching *$ext still loose directly in \$HOME -- consistent with $name not yet having been relaunched since enable, or the config not actually taking effect. Not proof either way; check by hand."
    fi
  done < <(cfg_app_output_paths)

  if [ "$any" -eq 0 ]; then
    skip "app_output_paths.apps is empty in senechal.json -- nothing configured"
  fi

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
      say "  enable   point each registered app's output path at its canonical dir (idempotent)"
      say "  verify   check it is actually in effect; exit 0 pass / 1 fail / 2 could-not-check / 3 warn"
      exit 64  # EX_USAGE, same as every other remedy here
      ;;
  esac
}
main "$@"
