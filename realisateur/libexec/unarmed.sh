#!/usr/bin/env bash
# unarmed.sh -- has the set of built-but-unarmed mechanisms GROWN? (#754)
# RUNNER: no -- DEBT, not liveness, so it wants a weekly clock, not ausculte's.
# GUARD-TEST: bin/tests/unarmed.test.sh -- offline behind UNARMED_SSH
# GATE: none -- it reads a remote host's crontabs, never this tree
set -uo pipefail

CLI_NAME='unarmed.sh'
CLI_SUMMARY='is anything built and not turned on, that was not built and not turned on yesterday?'
CLI_USAGE='  unarmed.sh            --check (default): report, write nothing'
CLI_FLAGS='--check'
CLI_POSITIONAL=none
CLI_EXITS='  0  the floor holds -- nothing new, nothing past its own window
  1  findings: the set GREW, a row REGRESSED, or a row is past its DEFAULT-AFTER
  6  BLIND: a predicate could not run, or the floor names no rows. NEVER clean.'
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/cli-guard.sh"
cli_guard "$@"

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$HERE/lib/host-check.sh"
. "$HERE/lib/propagation-set.sh"   # PROP_HOST_PIN -- the build layout has one home

LEDGER="${UNARMED_LEDGER:-$HERE/lib/unarmed.tsv}"
HOST="${UNARMED_HOST:-monkey}"
SCHED="${UNARMED_SCHED_ROOT:-/home/scheduler/Documents/Projects/scheduler}"
NOW="$(date -u -d "${UNARMED_TODAY:-now}" +%s 2>/dev/null)" || NOW="$(date -u +%s)"

while [ $# -gt 0 ]; do
  case "$1" in --check) ;; *) cli_die "unexpected argument: $1" ;; esac; shift
done

# ONE READING: six round trips to a host that wedges can disagree about one crontab.
FACTS=''
collect() {
  local script rc
  script='
SUDO=""; sudo -n true 2>/dev/null && SUDO="sudo -n"
[ -n "$SUDO" ] || { echo "SUDO no"; exit 0; }
echo "SUDO ok"
rc="$($SUDO crontab -l 2>/dev/null)"
count() { printf "%s\n" "$rc" | grep -c -- "$1"; }
printf "ROOT_PACED %s\n"    "$(count PACED_HOST_MODE=1)"
printf "ROOT_PROVISION %s\n" "$(count selfdev-runner-provision.sh)"
printf "ROOT_UNARMED %s\n"   "$(count unarmed.sh)"
a=0; d=0
for u in $(getent passwd | awk -F: "\$3>=3000 && \$3<=3099 {print \$1}"); do
  ct="$($SUDO crontab -l -u "$u" 2>/dev/null)"
  a=$((a + $(printf "%s\n" "$ct" | grep -c -- PACED_HOST_MODE=1)))
  d=$((d + $(printf "%s\n" "$ct" | grep -c -- scheduler-paced-runner:RUNNER)))
done
printf "ACCT_PACED %s\nACCT_RUNNER %s\n" "$a" "$d"
n=0; f=0; s=0
for c in $($SUDO sh -c "ls '"$SCHED"'/schedule/*.conf 2>/dev/null"); do
  b="${c##*/}"; case "$b" in _*) continue ;; esac
  $SUDO test -r "$c" || continue
  n=$((n + 1))
  $SUDO grep -q "@@FRAGMENT:" "$c" && f=$((f + 1))
  $SUDO grep -q "^USES_STANDING_RULES=1" "$c" && s=$((s + 1))
done
printf "SCHED_CONFS %s\nSCHED_FRAGMENT %s\nSCHED_STANDING %s\n" "$n" "$f" "$s"
printf "VAULT_MODE %s\n" "$(stat -c %04a /srv/ecosystem1-vault 2>/dev/null)"
printf "DRAIN_CRON %s\n" "$($SUDO cat /etc/cron.d/vault-spool-drain 2>/dev/null | grep -c vault-spool-drain.sh)"
printf "DRAIN_BIN %s\n" "$($SUDO test -x /usr/local/libexec/selfdev/vault-spool-drain.sh && echo 1 || echo 0)"
FD=https://raw.githubusercontent.com/hf7y/front-door/main
printf "FD_ANCHOR %s\n" "$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 "$FD/.agent-project" 2>/dev/null)"
printf "FD_PROSE %s\n" "$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 "$FD/.github/workflows/prose.yml" 2>/dev/null)"
TOK="$($SUDO /usr/local/libexec/selfdev/selfdev-gh-app.sh --token 2>/dev/null | tail -1)"
case "$TOK" in gh[a-z]_*) printf "APMS_PROSE %s\n" "$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 -H "Authorization: Bearer $TOK" https://api.github.com/repos/hf7y/apms-2173/contents/.github/workflows/prose.yml 2>/dev/null)" ;; esac
[ -d '"$PROP_HOST_PIN"' ] && printf "BUILD_LIBEXEC %s\n" "$(ls '"$PROP_HOST_PIN"'/*/libexec/ 2>/dev/null | grep -cE "^(unarmed|vault-spool-drain)\.sh$")"
exit 0'   # ALWAYS LAST, and unconditional: a fact line that reads nothing costs its own row, never the other nine (#815).
  if on_target_host "$HOST"; then
    FACTS="$(bash -c "$script" 2>/dev/null)"; rc=$?
  else
    FACTS="$(${UNARMED_SSH:-ssh} -n -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "$script" 2>/dev/null)"; rc=$?
  fi
  [ "$rc" -eq 0 ] || FACTS=''   # the script always exits 0, so a bad rc is the TRANSPORT, not a fact line.
}
collect

# fact <key> -- the value, or nothing. Nothing is BLIND; it is never zero.
fact() { printf '%s\n' "$FACTS" | awk -v k="$1" '$1 == k { print $2; found = 1 } END { exit !found }'; }
host_readable() { [ -n "$FACTS" ] && [ "$(fact SUDO)" = ok ]; }

probe_host_mode() {
  host_readable || { echo "BLIND cannot read $HOST's crontabs"; return; }
  local r a d; r="$(fact ROOT_PACED)"; a="$(fact ACCT_PACED)"; d="$(fact ACCT_RUNNER)"
  [ -n "$r" ] && [ -n "$a" ] && [ -n "$d" ] ||
    { echo "BLIND $HOST returned no row count, which is not a count of zero"; return; }
  if [ "$r" = 1 ] && [ "$a" = 0 ] && [ "$d" = 0 ]; then
    echo "ARMED one root row on $HOST carries PACED_HOST_MODE=1 and no account carries a dispatcher"
  elif [ "$r" = 1 ]; then
    echo "UNARMED $HOST is armed TWICE: one root PACED_HOST_MODE=1 row and $((a + d)) account dispatcher row(s); a row leaves its crontab in the same act that migrates it, never a fleet at once"
  else
    echo "UNARMED PACED_HOST_MODE=1 in $r root row(s) on $HOST and $d account row(s) still carry the per-account dispatcher; the host dispatcher wants exactly 1 and 0"
  fi
}

probe_runner_cadence() {
  host_readable || { echo "BLIND cannot read $HOST's crontabs"; return; }
  local n; n="$(fact ROOT_PROVISION)"
  if [ "${n:-0}" -ge 1 ]; then
    echo "ARMED selfdev-runner-provision.sh runs on root's clock on $HOST, so a dead runner is repaired not discovered"
  else
    echo "UNARMED nothing on root's clock on $HOST invokes selfdev-runner-provision.sh"
  fi
}

probe_standing_rules() {
  local n s; n="$(fact SCHED_CONFS)"; s="$(fact SCHED_STANDING)"
  { host_readable && [ "${n:-0}" -gt 0 ]; } || { echo "BLIND could not enumerate $SCHED/schedule/*.conf on $HOST"; return; }
  if [ "$s" = "$n" ]; then
    echo "ARMED all $n project conf(s) set USES_STANDING_RULES=1"
  else
    echo "UNARMED $s of $n project conf(s) set USES_STANDING_RULES=1"
  fi
}

probe_fragment_adoption() {
  local n f; n="$(fact SCHED_CONFS)"; f="$(fact SCHED_FRAGMENT)"
  { host_readable && [ "${n:-0}" -gt 0 ]; } || { echo "BLIND could not enumerate $SCHED/schedule/*.conf on $HOST"; return; }
  if [ "$f" = "$n" ]; then
    echo "ARMED all $n project conf(s) splice with @@FRAGMENT:"
  else
    echo "UNARMED $f of $n project conf(s) use @@FRAGMENT:, which bin/scheduler-run has expanded since 2026-08-13"
  fi
}

probe_unarmed_cadence() {
  host_readable || { echo "BLIND cannot read $HOST's crontabs"; return; }
  local n; n="$(fact ROOT_UNARMED)"
  if [ "${n:-0}" -ge 1 ]; then echo "ARMED this probe runs on root's clock on $HOST"
  else echo "UNARMED this probe is on no clock, so nothing reads the floor it keeps"; fi
}

probe_vault_read_door() {
  local m; m="$(fact VAULT_MODE)"
  { host_readable && [ -n "$m" ]; } || { echo "BLIND could not stat /srv/ecosystem1-vault on $HOST"; return; }
  if [ "$m" = 0700 ]; then
    echo "ARMED /srv/ecosystem1-vault is 0700 on $HOST -- no self-dev account reads the vault (#742)"
  else
    echo "UNARMED /srv/ecosystem1-vault is $m on $HOST, not 0700, so every account in the vault group still reads it"
  fi
}

probe_vault_drain() {
  host_readable || { echo "BLIND cannot read $HOST"; return; }
  local c b; c="$(fact DRAIN_CRON)"; b="$(fact DRAIN_BIN)"
  if [ "${c:-0}" -ge 1 ] && [ "${b:-0}" = 1 ]; then
    echo "ARMED $HOST drains /srv/vault-spool every 5 minutes and the drain that row names is installed"
  elif [ "${c:-0}" -ge 1 ]; then
    echo "UNARMED /etc/cron.d/vault-spool-drain fires every 5 minutes on $HOST and vault-spool-drain.sh is not installed under /usr/local/libexec/selfdev, so the row is a silent no-op"
  else
    echo "UNARMED nothing on $HOST drains /srv/vault-spool, so a deposit would queue and never land"
  fi
}

probe_libexec_payload() {
  local n; n="$(fact BUILD_LIBEXEC)"
  { host_readable && [ -n "$n" ]; } || { echo "BLIND could not read the adopted verb build on $HOST"; return; }
  if [ "$n" = 2 ]; then
    echo "ARMED the build $HOST adopted carries both libexec/ host tools that bashified declares"
  else
    echo "UNARMED the build $HOST adopted carries $n of the 2 libexec/ host tools bashified declares, and no cut has shipped the rest"
  fi
}

probe_front_door_guard() {
  local a p; a="$(fact FD_ANCHOR)"; p="$(fact FD_PROSE)"
  { host_readable && [ "$a" = 200 ]; } || { echo "BLIND could not read hf7y/front-door's default branch, so whether it is still a declared project is unknown"; return; }
  case "$p" in
    200) echo "ARMED hf7y/front-door carries .github/workflows/prose.yml, so its pull requests reach the shared guard" ;;
    404) echo "UNARMED hf7y/front-door ships ratify.yml and ritual.yml and no prose.yml, so no pull request there reaches the shared prose guard" ;;
    *)   echo "BLIND reading hf7y/front-door's prose.yml gave HTTP '$p'" ;;
  esac
}

probe_apms_guard() {
  local p; p="$(fact APMS_PROSE)"
  { host_readable && [ -n "$p" ]; } || { echo "BLIND no App token on $HOST, so whether hf7y/apms-2173 reaches the shared guard is unread"; return; }
  case "$p" in
    200) echo "ARMED hf7y/apms-2173 carries .github/workflows/prose.yml, so its pull requests reach the shared guard" ;;
    404) echo "UNARMED hf7y/apms-2173 is a declared project carrying no .github/workflows at all, so no pull request there reaches the shared prose guard" ;;
    *)   echo "BLIND reading hf7y/apms-2173's prose.yml gave HTTP '$p'" ;;
  esac
}

findings=0; blind=0
row() { printf '  %-9s %-18s %s\n' "$1" "$2" "$3"; }
act() { printf '            DO  %s\n' "$1"; }

echo "== unarmed --check -- $HOST, floor $LEDGER =="

[ -r "$LEDGER" ] || {
  printf '%s: BLIND -- the floor at %s is unreadable, so nothing was compared.\n' "$CLI_NAME" "$LEDGER" >&2
  exit 6
}

ids=''
while IFS=$'\t' read -r id since window floor remedy || [ -n "$id" ]; do
  case "$id" in ''|'#'*) continue ;; esac
  ids="$ids $id"
  fn="probe_${id//-/_}"
  if ! declare -F "$fn" >/dev/null; then
    row BLIND "$id" "the floor names this row and no $fn predicate exists to measure it"
    blind=1; continue
  fi
  verdict="$($fn)"; state="${verdict%% *}"; detail="${verdict#* }"

  if [ "$state" = BLIND ]; then row BLIND "$id" "$detail"; blind=1; continue; fi

  if [ "$floor" = ARMED ] && [ "$state" = UNARMED ]; then
    # No window: the floor recorded this ARMED, so it was turned OFF.
    row REGRESSED "$id" "$detail"; act "$remedy"; findings=1; continue
  fi
  if [ "$state" = ARMED ]; then
    if [ "$floor" = ARMED ]; then row OK "$id" "$detail"
    else row LOWER "$id" "$detail"; act "set this row's floor to ARMED in $LEDGER -- until then a later disarming cannot read as a regression"; fi
    continue
  fi

  if [ -z "$window" ] || [ "$window" = - ]; then
    row NO-WINDOW "$id" "$detail"
    act "declare this row's window in $LEDGER (DEFAULT-AFTER shape, e.g. 30d) -- a row that blocks by omission is the closeable issue again"
    findings=1; continue
  fi
  due="$(date -u -d "$since +${window%d} days" +%s 2>/dev/null)" || due=''
  if [ -z "$due" ]; then
    row BLIND "$id" "since='$since' window='$window' is not a date this could age"
    blind=1
  elif [ "$NOW" -gt "$due" ]; then
    row EXPIRED "$id" "$detail -- built $since, past its own ${window} window"
    act "$remedy"; findings=1
  else
    row HELD "$id" "$detail -- ${window} from $since, $(( (due - NOW) / 86400 ))d left"
  fi
done < "$LEDGER"

[ -n "$ids" ] || {
  printf '%s: BLIND -- the floor at %s names no rows. Nothing was measured, which is NOT a clean result.\n' "$CLI_NAME" "$LEDGER" >&2
  exit 6
}

# THE RATCHET: a predicate with no floor row is an arming someone deferred.
for fn in $(declare -F | awk '{ print $3 }' | grep '^probe_'); do
  id="${fn#probe_}"; id="${id//_/-}"
  case " $ids " in *" $id "*) continue ;; esac
  row GREW "$id" "$fn measures a mechanism no row in $LEDGER declares"
  act "add an '$id' row to $LEDGER: its build date, its DEFAULT-AFTER window, ARMED or UNARMED, and the act that arms it"
  findings=1
done

echo
if [ "$findings" = 1 ]; then
  echo 'FINDINGS -- the set grew, regressed, or a row outlived its own window. Named above.'
elif [ "$blind" = 1 ]; then
  echo 'BLIND -- a predicate could not run. This is NOT "nothing new".'
else
  echo 'The floor holds -- nothing new is built and unarmed, and no row is past its window.'
fi

[ "$findings" = 1 ] && exit 1
[ "$blind" = 1 ] && exit 6
exit 0
