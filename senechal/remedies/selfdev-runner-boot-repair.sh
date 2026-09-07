#!/usr/bin/env bash
PRIVILEGED=yes
HOSTS=(monkey)
REACHES=()
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
. ../lib/common.sh

SYSTEMD_DIR="${SENECHAL_RUNNER_REPAIR_SYSTEMD_DIR:-/etc/systemd/system}"
LIBEXEC="${SENECHAL_LIBEXEC:-/usr/local/libexec/senechal}"
PROVISION="${SENECHAL_RUNNER_REPAIR_PROVISION:-$LIBEXEC/selfdev-runner-provision.sh}"
CLASSIFY="$LIBEXEC/selfdev-runner-refusal-classify.sh"
REPAIR_UNIT_NAME="selfdev-runner-repair.service"
DROP_IN_NAME="50-selfdev-runner-boot-repair.conf"
SUDO_CMD="${SENECHAL_SUDO_CMD-sudo}"
SYSTEMCTL="${SENECHAL_SYSTEMCTL:-systemctl}"
INSTALLS=("$CLASSIFY" "$SYSTEMD_DIR/$REPAIR_UNIT_NAME" "$DROP_IN_NAME")
LIVE=1
[ -z "${SENECHAL_RUNNER_REPAIR_SYSTEMD_DIR:-}" ] || LIVE=0

runner_units() {
  local f
  for f in "$SYSTEMD_DIR"/actions.runner.*.service; do
    [ -f "$f" ] || continue
    basename "$f"
  done
}

classify_content() {
  cat <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
unit="${1:?usage: selfdev-runner-refusal-classify.sh <unit>}"
since="$(systemctl show -p ExecMainStartTimestamp --value "$unit" 2>/dev/null)"
[ -n "$since" ] || exit 0
journalctl -u "$unit" --since "$since" --no-pager 2>/dev/null \
  | grep -q 'registration has been deleted from the server' && exit 1
exit 0
EOF
}

drop_in_content() {
  cat <<EOF
[Unit]
OnFailure=$REPAIR_UNIT_NAME

[Service]
ExecStopPost=$CLASSIFY %n
EOF
}

repair_unit_content() {
  cat <<EOF
[Unit]
Description=senechal: repair a refused GitHub Actions runner (#437)

[Service]
Type=oneshot
ExecStart=$PROVISION --apply
EOF
}

install_file() { # $1 dest, $2 mode, content on stdin
  local dest="$1" mode="$2" content b
  content="$(cat)"
  if [ -f "$dest" ] && [ "$(cat "$dest" 2>/dev/null)" = "$content" ]; then
    say "  $dest -- already correct, untouched"
    chmod "$mode" "$dest"
    return 0
  fi
  b="$(backup_file "$dest")" && [ -n "$b" ] && say "  backed up old $dest -> $b"
  mkdir -p "$(dirname "$dest")" || die "could not create $(dirname "$dest")"
  printf '%s\n' "$content" > "$dest" || die "could not write $dest"
  chmod "$mode" "$dest"
  say "  wrote $dest"
}

do_enable() {
  say "selfdev-runner-boot-repair enable: a refused runner's clean exit becomes FAILED, so OnFailure repairs it without waiting for the daily 06:17 sweep"
  local units u
  units="$(runner_units)"
  [ -n "$units" ] || die "no actions.runner.*.service unit found under $SYSTEMD_DIR -- nothing to cover"

  classify_content     | install_file "$CLASSIFY" 0755
  repair_unit_content  | install_file "$SYSTEMD_DIR/$REPAIR_UNIT_NAME" 0644

  while IFS= read -r u; do
    [ -n "$u" ] || continue
    drop_in_content | install_file "$SYSTEMD_DIR/$u.d/$DROP_IN_NAME" 0644
  done <<< "$units"

  if [ "$LIVE" -eq 1 ]; then
    $SUDO_CMD "$SYSTEMCTL" daemon-reload || die "daemon-reload failed"
  else
    say "  (test mode: skipped daemon-reload)"
  fi
  say ""
  say "Done. run: ./selfdev-runner-boot-repair.sh verify"
}

do_disable() {
  say "selfdev-runner-boot-repair disable: remove the drop-ins and the repair unit"
  local units u
  units="$(runner_units)"
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    rm -f "$SYSTEMD_DIR/$u.d/$DROP_IN_NAME" && say "  removed $SYSTEMD_DIR/$u.d/$DROP_IN_NAME"
    rmdir "$SYSTEMD_DIR/$u.d" 2>/dev/null || true
  done <<< "$units"
  rm -f "$SYSTEMD_DIR/$REPAIR_UNIT_NAME" && say "  removed $SYSTEMD_DIR/$REPAIR_UNIT_NAME"
  rm -f "$CLASSIFY" && say "  removed $CLASSIFY"
  if [ "$LIVE" -eq 1 ]; then
    $SUDO_CMD "$SYSTEMCTL" daemon-reload || true
  fi
  say "Done. Nothing enable wrote is left behind."
}

do_verify() {
  head_ "selfdev-runner-boot-repair: every runner unit converts a refusal into FAILED"
  local units u bad=""
  units="$(runner_units)"
  if [ -z "$units" ]; then
    skip "no actions.runner.*.service unit found under $SYSTEMD_DIR -- nothing to check"
    finish_verify
  fi

  if [ ! -f "$CLASSIFY" ]; then
    fail "$CLASSIFY missing -- run: ./selfdev-runner-boot-repair.sh enable"
    finish_verify
  fi
  [ "$(without_comments < "$CLASSIFY")" = "$(classify_content | without_comments)" ] \
    && ok "$CLASSIFY matches this script" \
    || fail "$CLASSIFY drifted from this script -- re-run enable"

  if [ ! -f "$SYSTEMD_DIR/$REPAIR_UNIT_NAME" ]; then
    fail "$SYSTEMD_DIR/$REPAIR_UNIT_NAME missing -- run: ./selfdev-runner-boot-repair.sh enable"
    finish_verify
  fi
  [ "$(without_comments < "$SYSTEMD_DIR/$REPAIR_UNIT_NAME")" = "$(repair_unit_content | without_comments)" ] \
    && ok "$REPAIR_UNIT_NAME matches this script" \
    || fail "$REPAIR_UNIT_NAME drifted from this script -- re-run enable"

  while IFS= read -r u; do
    [ -n "$u" ] || continue
    if [ ! -f "$SYSTEMD_DIR/$u.d/$DROP_IN_NAME" ]; then
      bad="$bad $u"
    elif [ "$(without_comments < "$SYSTEMD_DIR/$u.d/$DROP_IN_NAME")" != "$(drop_in_content | without_comments)" ]; then
      bad="$bad $u"
    fi
  done <<< "$units"

  if [ -n "$bad" ]; then
    fail "drop-in missing or drifted for:$bad -- run: ./selfdev-runner-boot-repair.sh enable"
  else
    ok "every runner unit under $SYSTEMD_DIR has the drop-in"
  fi

  finish_verify "OK -- every runner unit converts a refusal into FAILED and repairs on it."
}

case "${1:-}" in
  enable)  shift; parse_common_args "$@"; do_enable ;;
  disable) shift; parse_common_args "$@"; do_disable ;;
  verify)  shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $(basename "$0") enable|disable|verify [-q]" ;;
esac
