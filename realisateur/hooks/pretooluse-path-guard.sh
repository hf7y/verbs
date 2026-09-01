#!/usr/bin/env bash
set -uo pipefail  # hooks/pretooluse-path-guard.sh: PreToolUse guard on Write|Edit (#707) -- refuses a write to a known dead end and names the front door instead of just walling it off

log() { printf 'pretooluse-path-guard: %s\n' "$*" >&2; }

payload="$(cat 2>/dev/null)" || { log "could not read hook payload from stdin"; exit 1; }

tool="$(sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q' <<<"$payload")"

deny() { # deny <why, and what to do instead>
  echo "BLOCKED: $1" >&2
  exit 2
}

# ---- THE VAULT IS AN ARCHIVE: READS ARE DENIED (#742, #762) -----------------
# BOTH routes, because closing one leaves the other open: the contents API and
# /srv/ecosystem1-vault. #762's open question: `consigne`'s writes do NOT trip
# it -- a Bash command naming a deposit front door is a write path.
VAULT_DOOR='the vault is an ARCHIVE -- prose goes there when it stops being true, so reading one back is how a retired fact returns as documentation (CLAUDE.md, #762). Establish the fact from live code, config or API instead; if you cannot, say UNVERIFIED and act on nothing. Depositing is unaffected: `consigne <path>`.'
case "$tool" in
  Read|Grep|Glob|NotebookRead)
    case "$payload" in
      *ecosystem1-vault*) deny "$VAULT_DOOR" ;;
    esac
    ;;
  Bash)
    case "$payload" in
      *ecosystem1-vault*)
        # A deposit front door in the same command means this is a write path.
        case "$payload" in
          *consigne*|*fonde*|*fauche*|*vault-group-provision*|*vault-spool-drain*|*"vault.sh"*) ;;
          *) deny "$VAULT_DOOR" ;;
        esac
        ;;
    esac
    ;;
esac

case "$tool" in
  Write|Edit) ;;
  *) exit 0 ;;  # not a file write this guard has an opinion about
esac

path="$(sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q' <<<"$payload")"
[ -n "$path" ] || exit 0

block() { # block <front door message>
  {
    echo "BLOCKED: $path has a known front door -- this is not it."
    echo
    echo "$1"
  } >&2
  exit 2
}

TABLE="${PATH_GUARD_TABLE:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../bin/lib/path-guard.tsv}"
if [ -r "$TABLE" ]; then
  while IFS=$'\t' read -r pattern door; do
    case "$pattern" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2254  # deliberate: pattern is a glob read from path-guard.tsv, not a literal
    case "$path" in
      $pattern) block "$door" ;;
    esac
  done < "$TABLE"
fi

case "$path" in  # A COPY OF THE LABEL GRAMMAR (#707): a path pattern alone cannot tell a copy of bin/lib/labels.tsv from the source, so this also asks the containing repo's own remote (constraint 3: must not fire on the source)
  */lib/labels.tsv)
    d="$(dirname -- "$path")"
    remote="$(git -C "$d" remote get-url origin 2>/dev/null)" || remote=""
    case "$remote" in
      *hf7y/realisateur*) : ;;
      *) block "the label grammar has ONE home, bin/lib/labels.tsv in hf7y/realisateur -- read it at the point of use instead of copying it" ;;
    esac
    ;;
esac

me="$(id -un 2>/dev/null)"  # ANOTHER PROJECT'S TREE (CLAUDE.md subagent rules): this account's own project is $SELFDEV_PROJECTS_ROOT/$me; a write under that root but under a different name reaches past that project's own regulator
proj_root="${SELFDEV_PROJECTS_ROOT:-$HOME/Documents/Projects}"
case "$path" in
  "$proj_root"/*)
    rest="${path#"$proj_root"/}"
    other="${rest%%/*}"
    if [ -n "$other" ] && [ "$other" != "$me" ]; then
      block "that is $other's project tree, not $me's -- use its front door instead (scheduler -i $other, or notify-senechal <door> <field>=<value>), never a direct write"
    fi
    ;;
esac

exit 0
