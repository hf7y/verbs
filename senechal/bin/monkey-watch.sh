#!/usr/bin/env bash
set -uo pipefail  # monkey-watch.sh: publish monkey's status FROM DEXTER, alert on change. 2026-08-14 #274: the prior publisher refused to publish on ssh failure, so the page stayed stale for hours. Caller: crontab `monkey-watch-cron-dexter` in senechal-registry.json (test/monkey-watch.test.sh section D)

CLI_NAME='monkey-watch'
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM="${VM:-monkey}"
MONKEY_IP="${MONKEY_IP:-100.121.83.23}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_dexter_monkey}"
COLLECTOR="${COLLECTOR:-$HERE/bin/monkey-status-collect.py}"
PAGE_SRC="${PAGE_SRC:-$HERE/share/monkey-status.html}"
STATE_FILE="${STATE_FILE:-$HOME/.local/state/monkey-watch.last}"
ALERT_EVERY_H="${ALERT_EVERY_H:-12}"
CADENCE_MIN="${CADENCE_MIN:-10}"  # dexter's cron cadence; tells "monkey down" from "watcher stopped"
GRACE_MIN="${GRACE_MIN:-20}"
PUBLISH_REPO="${PUBLISH_REPO:-hf7y/hf7y.github.io}"
PUBLISH_DIR="${PUBLISH_DIR:-monkey}"
. "$HERE/bin/lib/zaxon.sh"
. "$HERE/bin/lib/monkey-watch-alert.sh"
. "$HERE/bin/lib/vmhost.sh"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

die() { printf '%s: FAIL: %s\n' "$CLI_NAME" "$*" >&2; exit 2; }
vmhost_require || die "VBoxManage not at $VMHOST_VBOX -- this must run on the VM host (dexter)."
[ -f "$COLLECTOR" ] || die "collector not found at $COLLECTOR.
  Clone it rather than copying the collector next to me."

. "$HERE/bin/lib/cron-lock.sh"
cron_lock monkey-watch  # ONE AT A TIME (#629): 2026-08-25, seven --apply runs stacked while unreachable

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

VMSTATE="$(vmhost_state "$VM")"  # host-side facts, always available
DISK="$(vmhost_disk_raw "$VM")"
DISK_HOME="$(vmhost_classify_disk "$DISK")"  # published fact: the outage was a disk on external USB, 1580 errors/week
CLOCK_DRIFT_H=""  # realisateur#630: nanoseconds with SPACE separators; pinned by test I6
LOGDIR="$(vmhost_logdir "$VM")"
if [ -n "$LOGDIR" ]; then
  VBOXLOG="$LOGDIR/VBox.log"
  if [ -r "$VBOXLOG" ]; then
    CLOCK_DRIFT_H="$(grep -o 'offVirtualSyncGivenUp=[0-9 ]*' "$VBOXLOG" 2>/dev/null \
      | tail -1 | cut -d= -f2 | tr -d ' ' \
      | awk 'length($0)>0 {printf "%.1f", $0/3600000000000}')"
  fi
fi

BANNER="$(timeout 8 bash -c "exec 3<>/dev/tcp/$MONKEY_IP/22 && head -c 12 <&3" 2>/dev/null || true)"  # guest-side, best effort: banner is the probe, not TCP-connect -- read-only root resets at key exchange
case "$BANNER" in
  SSH-2.0*) SSHD="answering" ;;
  '')       SSHD="silent" ;;
  *)        SSHD="reset" ;;
esac

SSH_DEADLINE="${SSH_DEADLINE:-60}"  # every ssh is deadlined: ConnectTimeout bounds only the connect, and 2026-08-25's stacked runs came from an auth-stage hang the banner probe didn't see (test H)
mssh()   { timeout "$SSH_DEADLINE" ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 \
               -o StrictHostKeyChecking=accept-new "$MONKEY_IP" "$@" 2>/dev/null; }  # no -n: feeds the collector; mssh_n is for calls that send nothing
mssh_n() { timeout "$SSH_DEADLINE" ssh -n -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 \
               -o StrictHostKeyChecking=accept-new "$MONKEY_IP" "$@" 2>/dev/null; }

GUEST_JSON=""; GUEST_ERR=""; ROOTMOUNT=""; UPTIME=""
if [ "$SSHD" = "answering" ]; then
  GUEST_JSON="$(mssh 'sudo -n python3 -' < "$COLLECTOR")"; guest_rc=$?  # fed over stdin: no second collector copy to drift
  if ! printf '%s' "$GUEST_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d.get("accounts"),list) else 1)' 2>/dev/null; then
    if [ "$guest_rc" -eq 124 ]; then  # 124 is `timeout`'s: a stalled ssh differs from a bad-answer collector
      GUEST_ERR="sshd sent its banner but the session stalled -- no answer in ${SSH_DEADLINE}s"
    else
      GUEST_ERR="collector ran but returned no usable accounts array"
    fi
    GUEST_JSON=""
  fi
  ROOTMOUNT="$(mssh_n 'mount | grep " / " | grep -o "(r[wo]" | tr -d "("' || true)"
  UPTIME="$(mssh_n 'uptime -p' || true)"
else
  GUEST_ERR="sshd is $SSHD -- the collector could not be run"
fi

if   [ "$VMSTATE" != "running" ];       then VERDICT="DOWN";     WHY="VM is $VMSTATE"  # verdict: read-only root is called out separately from "down"
elif [ "$SSHD" != "answering" ];        then VERDICT="DOWN";     WHY="VM running but sshd is $SSHD"
elif [ "$ROOTMOUNT" = "ro" ];           then VERDICT="DEGRADED"; WHY="root is mounted READ-ONLY"
elif [ "$DISK_HOME" = "EXTERNAL-USB" ]; then VERDICT="DEGRADED"; WHY="disk is back on the external USB drive"
elif [ -z "$GUEST_JSON" ];              then VERDICT="DEGRADED"; WHY="${GUEST_ERR:-guest detail unavailable}"
else                                         VERDICT="OK";       WHY="running, sshd answering, root rw, disk internal"
fi

SCREENSHOT=""
if [ "$VERDICT" = DOWN ]; then
  vmhost_screenshot "$VM" "$WORK/console.png"
  [ -s "$WORK/console.png" ] && SCREENSHOT=1
fi

payload="$(GUEST_JSON="$GUEST_JSON" NOW="$NOW" VMSTATE="$VMSTATE" DISK="$DISK" \
  CLOCK_DRIFT_H="$CLOCK_DRIFT_H" \
  CADENCE_MIN="$CADENCE_MIN" GRACE_MIN="$GRACE_MIN" \
  DISK_HOME="$DISK_HOME" SSHD="$SSHD" UPTIME="$UPTIME" ROOTMOUNT="$ROOTMOUNT" \
  VERDICT="$VERDICT" WHY="$WHY" GUEST_ERR="$GUEST_ERR" SCREENSHOT="$SCREENSHOT" \
  python3 "$HERE/bin/lib/monkey-watch-merge.py")"
[ -n "$payload" ] || die "payload builder produced nothing -- publishing nothing."

printf '%s\n' "$payload"
printf '%s: %s -- %s\n' "$CLI_NAME" "$VERDICT" "$WHY"

[ "$APPLY" = 1 ] || { printf '%s: NOT published (need --apply)\n' "$CLI_NAME"; exit 0; }

mkdir -p "$(dirname "$STATE_FILE")"
LAST="$(cat "$STATE_FILE" 2>/dev/null || echo "")"
DECISION="$(mw_alert_decide "$VERDICT" "$LAST" "$STATE_FILE" "$ALERT_EVERY_H" "$NOW")"
set -- $DECISION
if [ "$1" != NONE ]; then
  case "$1" in
    TRANSITION) LABEL="$2 -> $3" ;;
    PERSIST)    LABEL="still $2 (down ${3}h, unread past ${ALERT_EVERY_H}h)" ;;
  esac
  msg="monkey: $LABEL

$WHY

vm=$VMSTATE sshd=$SSHD root=${ROOTMOUNT:-?} disk=$DISK_HOME
https://hf7y.com/$PUBLISH_DIR/"
  tid="$(zaxon_ask "$msg" monkey-watch)"
  if [ -n "$tid" ]; then
    mw_alert_mark_sent "$STATE_FILE" "$NOW"
    printf '%s: alerted (%s) ticket %s\n' "$CLI_NAME" "$LABEL" "$tid"
  fi
fi

gh repo clone "$PUBLISH_REPO" "$WORK/site" -- -q --depth 1 2>/dev/null \
  || { echo "$CLI_NAME: could not clone $PUBLISH_REPO -- nothing published" >&2; exit 1; }  # ALWAYS publishes: no "refuse an empty page" guard (#274)
mkdir -p "$WORK/site/$PUBLISH_DIR"
printf '%s\n' "$payload" > "$WORK/site/$PUBLISH_DIR/status.json"
[ -f "$PAGE_SRC" ] && cp "$PAGE_SRC" "$WORK/site/$PUBLISH_DIR/index.html"
rm -f "$WORK/site/$PUBLISH_DIR/console.png"
[ -n "$SCREENSHOT" ] && cp "$WORK/console.png" "$WORK/site/$PUBLISH_DIR/console.png"
cd "$WORK/site" || die "could not enter the site clone"
if [ -n "$(git status --porcelain "$PUBLISH_DIR")" ]; then
  git add "$PUBLISH_DIR"
  git -c user.name='monkey-watch' -c user.email='noreply@hf7y.com' \
      commit -q -m "monkey-watch: $VERDICT ($WHY)"
  git push -q || { echo "$CLI_NAME: push failed" >&2; exit 1; }
  printf '%s: published %s\n' "$CLI_NAME" "$VERDICT"
else
  printf '%s: no change to publish\n' "$CLI_NAME"
fi
