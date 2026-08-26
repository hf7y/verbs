#!/usr/bin/env bash
# containment-audit.sh -- no self-dev account reaches outside its own home.
#
#   ./containment-audit.sh              audit this host
#   ./containment-audit.sh --host <h>   audit another host over ssh
#   ./containment-audit.sh --json       one object per check
#
# exit: 0 contained  5 DOWN (owns something outside, or holds sudo)
#       6 BLIND (a probe could not run -- never "contained")
#
# TRAP: BLIND is a third verdict, never folded into OK.
#
set -uo pipefail

CLI_NAME='containment-audit.sh'
usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done

HOST=""; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:?--host needs a hostname}"; shift ;;
    --json) JSON=1 ;;
    -*) echo "$CLI_NAME: unknown flag $1" >&2; exit 2 ;;
    *)  echo "$CLI_NAME: unexpected argument $1" >&2; exit 2 ;;
  esac; shift
done

UID_MIN="${SELFDEV_UID_MIN:-3000}"
UID_MAX="${SELFDEV_UID_MAX:-3099}"

# `ssh -n` so a probe cannot eat this script's stdin.
probe() {
  if [ -n "$HOST" ]; then ssh -n -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "$1" 2>/dev/null
  else bash -c "$1" 2>/dev/null; fi
}

down=0; blind=0; rows=""
record() { rows="$rows$1|$2|$3"$'\n'; case "$2" in DOWN) down=1 ;; BLIND) blind=1 ;; esac; }

accounts="$(probe "getent passwd | awk -F: -v lo=$UID_MIN -v hi=$UID_MAX '\$3>=lo && \$3<=hi {print \$1\":\"\$6}'")"
if [ -z "$accounts" ]; then
  record accounts BLIND "no account in uid band $UID_MIN-$UID_MAX answered -- this is not the self-dev host, or the probe could not run"
else
  record accounts OK "$(printf '%s\n' "$accounts" | grep -c .) account(s) in the band"

  # An unreadable tree is BLIND for that account, not "owns nothing". The one
  # exemption -- the account's OWN crontab, where its clock lives -- is derived
  # from the account name at probe time, so it covers exactly one path.
  while IFS=: read -r acct home; do
    [ -n "$acct" ] || continue
    out="$(probe "sudo -n find /home /etc /usr/local /srv /var -xdev -uid \$(id -u $acct) -not -path '$home' -not -path '$home/*' -not -path '/var/spool/cron/crontabs/$acct' -print -quit 2>/dev/null; echo RC=\$?")"
    case "$out" in
      "") record "reach:$acct" BLIND 'the sweep produced nothing at all, not even a return code' ;;
      RC=0) record "reach:$acct" OK "owns nothing outside $home" ;;
      RC=*) record "reach:$acct" BLIND "the sweep could not read the tree ($out)" ;;
      *)    record "reach:$acct" DOWN "owns $(printf '%s' "$out" | head -1) outside $home" ;;
    esac
  done <<< "$accounts"

  # A mention in sudoers is a grant until proven otherwise; parsing sudoers and
  # calling the result safe is not this guard's job.
  names="$(printf '%s\n' "$accounts" | cut -d: -f1 | paste -sd'|')"
  out="$(probe "sudo -n grep -rlE '^[[:space:]]*($names)[[:space:]]' /etc/sudoers /etc/sudoers.d 2>/dev/null; echo RC=\$?")"
  case "$out" in
    "")   record sudo BLIND 'could not read /etc/sudoers.d' ;;
    RC=*) record sudo OK 'no self-dev account appears in sudoers' ;;
    *)    record sudo DOWN "a self-dev account appears in $(printf '%s' "$out" | head -1)" ;;
  esac
fi

if [ "$JSON" = 1 ]; then
  printf '%s' "$rows" | while IFS='|' read -r n v d; do
    [ -n "$n" ] || continue
    printf '{"check":"%s","verdict":"%s","detail":"%s"}\n' "$n" "$v" "${d//\"/\\\"}"
  done
else
  printf '== containment-audit %s (uid band %s-%s) ==\n' "${HOST:-$(hostname -s 2>/dev/null || echo local)}" "$UID_MIN" "$UID_MAX"
  printf '%s' "$rows" | while IFS='|' read -r n v d; do
    [ -n "$n" ] || continue
    printf '  %-6s %-24s %s\n' "$v" "$n" "$d"
  done
fi

[ "$down" -eq 0 ] || exit 5
[ "$blind" -eq 0 ] || exit 6
exit 0
