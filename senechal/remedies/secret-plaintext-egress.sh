#!/usr/bin/env bash
# Concern: registered credentials riding gardien's `.config` backup set
# off the machine in PLAINTEXT. See ../CONCERNS.md and ESTATE.md's
# "The credential registry".
#
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

GARDE_JSON="${GARDE_CONFIG:-$HOME/.config/gardien/garde.json}"
TARGET_SET="${SECRET_EGRESS_SET:-.config}"

# The excludes, relative to the ".config" set path (~/.config). Derived
# from estate.secrets rather than retyped: any credential registered
# offhost=forbid whose path falls inside the set belongs here, so adding
# a credential to the registry is the only edit needed.
wanted_excludes() {
  # Every field is named because the read is POSITIONAL -- \x1f columns
  # must all be consumed to reach offhost/status/path. Same idiom, and
  # same unused-looking locals, as health/dead-config.sh.
  local id host owner path purpose mode recovery mint offhost status verify reprovision notes
  local set_root="$HOME/.config" expanded
  # shellcheck disable=SC2034
  while IFS=$'\x1f' read -r id host owner path purpose mode recovery mint offhost status verify reprovision notes; do
    [ -n "$id" ] || continue
    [ "$offhost" = forbid ] || continue
    [ "$status" = retired ] && continue
    expanded="${path/#\~/$HOME}"
    case "$expanded" in
      "$set_root"/*) printf '%s\n' "${expanded#"$set_root"/}" ;;
    esac
  done < <(cfg_secrets) | sort -u
}

# =======================================================================
# enable
# =======================================================================
cmd_enable() {
  say "senechal remedy: stop copying registered credentials off-host in plaintext"
  say ""

  [ -r "$GARDE_JSON" ] || { say "no gardien config at $GARDE_JSON -- nothing to edit"; return "$RC_INCOMPLETE"; }
  command -v python3 >/dev/null 2>&1 || { say "python3 is required to edit $GARDE_JSON safely"; return "$RC_INCOMPLETE"; }

  local want
  want="$(wanted_excludes)"
  if [ -z "$want" ]; then
    say "No registered credential with offhost=forbid lives under ~/.config."
    say "Nothing to exclude. (That is a pass, not a no-op: the registry is the source.)"
    return 0
  fi

  say "Credentials registered offhost=forbid under ~/.config:"
  printf '%s\n' "$want" | sed 's/^/   /'
  say ""

  local backup
  backup="$GARDE_JSON.senechal-backup.$(date '+%Y%m%d-%H%M%S')"
  cp -p "$GARDE_JSON" "$backup"
  say "Backed up $GARDE_JSON -> $backup"

  # Excludes go in as ARGV, not stdin: `python3 - <<PY` already uses stdin
  # for the script itself, so a sys.stdin.read() here returns nothing and
  # would silently exclude NOTHING while printing success.
  if ! printf '%s\n' "$want" | xargs -d '\n' -- \
       python3 -c '
import json, sys
path, target, want = sys.argv[1], sys.argv[2], sys.argv[3:]
with open(path) as fh:
    d = json.load(fh)
for s in d.get("sets", []):
    if s.get("name") != target:
        continue
    have = list(s.get("exclude", []))
    for w in want:
        if w not in have:
            have.append(w)
    s["exclude"] = have
    s["_comment_senechal"] = (
        "Credential excludes are maintained by senechal from estate.secrets "
        "(offhost=forbid) -- remedies/secret-plaintext-egress.sh. They are "
        "re-mintable; health/secret-registry.sh --reprovision <id> prints how.")
    break
else:
    raise SystemExit("no set named %r in %s" % (target, path))
with open(path, "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
print("updated set %r with %d exclude(s)" % (target, len(want)))
' "$GARDE_JSON" "$TARGET_SET"; then
    cp -p "$backup" "$GARDE_JSON"
    say "edit failed -- restored $GARDE_JSON from $backup"; return "$RC_FAIL"
  fi
  say ""
  say "Done. Verify with: ./secret-plaintext-egress.sh verify"
  say ""
  say "NOT DONE, and yours: the copies already on dexter are untouched."
  say "rsync without --delete leaves them. Remove them with:"
  print_stale_removal
}

print_stale_removal() {
  local want
  want="$(wanted_excludes)"
  say ""
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    say "  ssh -p 2223 -i ~/.ssh/id_dexter_gardien zach@dexter.tail893f2c.ts.net \\"
    say "      rm -f '/mnt/d/gardien-media/mandark/.config/$rel'"
  done <<< "$want"
  say ""
  say "  (check each one first -- this deletes on a real host.)"
}

# =======================================================================
# verify
# =======================================================================
cmd_verify() {
  head_ "secret-plaintext-egress: registered credentials are excluded from gardien"

  if [ ! -r "$GARDE_JSON" ]; then
    skip "no gardien config at $GARDE_JSON -- cannot tell whether credentials are excluded"
    finish_verify "unreachable"
    return $?
  fi

  local want have missing=0
  want="$(wanted_excludes)"
  if [ -z "$want" ]; then
    ok "no registered credential with offhost=forbid lives under ~/.config"
    finish_verify "OK -- nothing to exclude."
    return $?
  fi

  have="$(python3 - "$GARDE_JSON" "$TARGET_SET" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
for s in d.get("sets", []):
    if s.get("name") == sys.argv[2]:
        for e in s.get("exclude", []):
            print(e)
PY
)" || { skip "could not read excludes from $GARDE_JSON"; finish_verify unreachable; return $?; }

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if grep -qxF -- "$rel" <<< "$have"; then
      ok "$rel is excluded from gardien set '$TARGET_SET'"
    else
      fail "$rel is NOT excluded -- gardien still copies this credential off-host in plaintext"
      note "run: ./secret-plaintext-egress.sh enable"
      missing=1
    fi
  done <<< "$want"

  # The half this remedy cannot do. Reported every run so it does not
  # read as finished while plaintext is still sitting on dexter.
  if [ "$missing" -eq 0 ]; then
    note ""
    note "Excludes are in place, which stops FUTURE copies. Copies already on"
    note "dexter are untouched by rsync and must be removed by hand:"
    note "  health/secret-registry.sh  # then see this script's enable output"
  fi

  finish_verify "OK -- every registered offhost=forbid credential is excluded from gardien."
}

case "${1:-}" in
  enable) shift; cmd_enable "$@" ;;
  verify) shift; parse_common_args "$@"; cmd_verify ;;
  *) say "usage: $0 {enable|verify} [-q]"; exit 2 ;;
esac
