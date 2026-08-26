#!/usr/bin/env bash
# senechal: give mandark a print queue that never asks the HP 8710 for black.
#
# The 8710's K nozzle row is dead. Measured off the printer's OWN diagnostics
# page (CUPS not in the loop) on 2026-08-25: the black block came out at peak
# row density 12.4 against cyan's 176, i.e. blank paper. A level-1 clean made
# it worse, not better (peak was 97.0 before it). The head is PAULINA, fitted
# 2016-06-30; replacement M0H91A is on order.
#
# Until that lands, anything routed to K prints nothing -- `rgb 0,0,0` and
# `DeviceGray 0` both scanned as (255,255,255) -- and anything asking for a
# black TINT gets composited out of CMY, which with magenta at 20% comes out
# orange. So this queue rasterises each job and maps its ink onto colours the
# printer can still lay down, rotating through a palette so no single supply
# carries the load.
#
#   ./print-black-via-colour.sh enable    # install backend + queue (sudo)
#   ./print-black-via-colour.sh verify    # non-AI, cron-safe
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

# --- target values, defined once, read by both verbs --------------------
QUEUE="HP8710_K2CMY"                # K remapped to C/M/Y -- the one to print to
TARGET_QUEUE="HP8710_BROKEN_K"      # reaches the printer, eats black; owned by cups-purged-by-autoremove.sh
OLD_QUEUES="HP8710_colour"          # pre-2026-08-25 name, removed on enable
DEVICE_URI="k2c:/$TARGET_QUEUE"
BACKEND="/usr/lib/cups/backend/k2c"
TOOL="/usr/local/bin/k2c"
TOOL_SRC="../tools/k2c"
STATE_DIR="/var/lib/k2c"

SUDO_CMD="${SENECHAL_SUDO_CMD-sudo}"

# lpadmin is deliberately NOT run under sudo -- same reason as
# cups-purged-by-autoremove.sh: it authenticates to cupsd over IPP as the
# effective user, and root has no CUPS password. `SystemGroup lpadmin`
# already accepts the invoking user. Only the installs below need root.

# This is a RAW queue, which the sibling remedy forbids for HP8710_raw. It is
# not the same thing and the distinction is the whole design: HP8710_raw was
# raw straight to socket://...:9100, so a PDF reached the print engine as
# literal bytes and spewed paper. This queue is raw only so the PDF arrives at
# our backend UNRASTERISED; the backend converts it and hands it to
# HP8710_direct, which still does every bit of real driver work. Nothing here
# ever reaches the engine unconverted.

# ------------------------------------------------------------------------
do_enable() {
  command -v gs >/dev/null 2>&1 || die "ghostscript not installed: apt install ghostscript"
  python3 -c 'import numpy, PIL' 2>/dev/null \
    || die "needs python3 numpy + pillow: apt install python3-numpy python3-pil"
  [ -f "$TOOL_SRC" ] || die "missing $TOOL_SRC (run from the senechal checkout)"

  say "installing the transform to $TOOL"
  # Copied, never symlinked: a symlink into a working clone is exactly what
  # health/path-from-checkout.sh exists to catch, and the clone can vanish.
  backup_file "$TOOL" >/dev/null
  $SUDO_CMD install -m 0755 "$TOOL_SRC" "$TOOL" || die "could not install $TOOL"

  say "installing the CUPS backend to $BACKEND"
  backup_file "$BACKEND" >/dev/null
  # Mode 0700 so cupsd runs it as root; it needs to write $STATE_DIR and
  # re-submit with lp. Backends with no filename argument read the job on
  # stdin, and a backend invoked with NO arguments must print its discovery
  # line and exit -- cupsd calls it that way at startup to enumerate devices.
  $SUDO_CMD tee "$BACKEND" >/dev/null <<BACKEND_EOF
#!/usr/bin/env bash
# senechal: CUPS backend for $QUEUE. Remaps black onto printable colour inks
# and re-submits to $TARGET_QUEUE. Installed by remedies/print-black-via-colour.sh.
set -uo pipefail
if [ \$# -eq 0 ]; then
  echo 'direct k2c "Unknown" "Black remapped to colour (senechal k2c)"'
  exit 0
fi
target="\${DEVICE_URI#k2c:/}"; target="\${target:-$TARGET_QUEUE}"
job=\$1 user=\$2 title=\$3
src=\${6:-}
tmp=\$(mktemp -d) || exit 1
trap 'rm -rf "\$tmp"' EXIT
if [ -z "\$src" ]; then src="\$tmp/job"; cat > "\$src" || exit 1; fi
[ -s "\$src" ] || { echo "ERROR: k2c got an empty job" >&2; exit 1; }
export K2C_STATE="$STATE_DIR"
DEST="\$target" "$TOOL" "\$src" >&2 || { echo "ERROR: k2c transform failed" >&2; exit 1; }
echo "INFO: k2c sent job \$job (\$title, \$user) to \$target" >&2
exit 0
BACKEND_EOF
  $SUDO_CMD chown root:root "$BACKEND" && $SUDO_CMD chmod 0700 "$BACKEND" \
    || die "could not set ownership/mode on $BACKEND"

  say "creating $STATE_DIR for the palette rotation counter"
  $SUDO_CMD install -d -m 0755 "$STATE_DIR"

  say "restarting cups so it picks up the new backend"
  $SUDO_CMD systemctl restart cups || warn "could not restart cups -- do it yourself"
  for _ in 1 2 3 4 5; do lpstat -r >/dev/null 2>&1 && break; sleep 1; done

  for old in $OLD_QUEUES; do
    if lpstat -v "$old" >/dev/null 2>&1; then
      say "removing $old -- renamed to $QUEUE, which says what it does"
      lpadmin -x "$old" 2>/dev/null || warn "could not remove $old"
    fi
  done

  if ! lpstat -v "$TARGET_QUEUE" >/dev/null 2>&1; then
    die "$TARGET_QUEUE does not exist -- run cups-purged-by-autoremove.sh enable first; it owns the queue that reaches the printer"
  fi

  say "creating queue $QUEUE -> $DEVICE_URI (raw, unsudoed lpadmin)"
  lpadmin -p "$QUEUE" -v "$DEVICE_URI" -E \
    -D "HP 8710, black remapped to colour (dead K row)" \
    || die "lpadmin failed to create $QUEUE"
  cupsenable "$QUEUE" 2>/dev/null
  cupsaccept "$QUEUE" 2>/dev/null

  # This remedy owns the default destination. "Which queue is safe to default
  # to" is only answerable by whoever knows the K row is dead, so
  # cups-purged-by-autoremove.sh deliberately no longer sets one.
  say "pointing the system default at $QUEUE"
  lpoptions -d "$QUEUE" >/dev/null 2>&1 || warn "could not set the default destination"

  say ""
  say "Done. Print to it with:  lp -d $QUEUE file.pdf"
  say ""
  say "What this script could NOT do for you:"
  say "  - It cannot fix the K row. The head is dead; M0H91A is the part."
  say "  - It does not touch $TARGET_QUEUE, which still asks for black and"
  say "    still prints nothing when it does. Pick the queue deliberately."
  say "  - Every job carries a small black exercise strip in the bottom"
  say "    margin. If that strip ever prints solid, the K row came back and"
  say "    this whole queue can be removed with: lpadmin -x $QUEUE"
}

# ------------------------------------------------------------------------
do_verify() {
  head_ "queue"
  local uri
  uri=$(lpstat -v "$QUEUE" 2>/dev/null | sed -n 's/^device for .*: //p')
  if [ -z "$uri" ]; then
    fail "queue $QUEUE does not exist -- run: $0 enable"
  elif [ "$uri" != "$DEVICE_URI" ]; then
    fail "$QUEUE points at '$uri', expected '$DEVICE_URI'"
  else
    ok "$QUEUE -> $DEVICE_URI"
  fi
  if lpstat -v "$TARGET_QUEUE" >/dev/null 2>&1; then
    ok "downstream queue $TARGET_QUEUE exists"
  else
    fail "downstream queue $TARGET_QUEUE is missing -- $QUEUE has nowhere to send"
  fi

  head_ "default destination"
  local dflt
  dflt=$(lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p')
  if [ "$dflt" = "$QUEUE" ]; then
    ok "default is $QUEUE"
  elif [ -z "$dflt" ]; then
    fail "no default destination -- plain 'lp file.pdf' has nowhere to go. Fix: lpoptions -d $QUEUE"
  else
    fail "default is $dflt, which prints black as nothing. Fix: lpoptions -d $QUEUE"
  fi

  head_ "installed pieces"
  if [ -x "$TOOL" ]; then ok "$TOOL installed"; else fail "$TOOL missing -- run: $0 enable"; fi
  if [ -e "$BACKEND" ]; then
    local mode owner
    mode=$(stat -c %a "$BACKEND"); owner=$(stat -c %U "$BACKEND")
    [ "$owner" = root ] && ok "$BACKEND owned by root" || fail "$BACKEND owned by $owner, must be root"
    [ "$mode" = 700 ] && ok "$BACKEND mode 700" || fail "$BACKEND mode $mode, must be 700 (cupsd runs it as root)"
  else
    fail "$BACKEND missing -- run: $0 enable"
  fi
  if [ -d "$STATE_DIR" ]; then ok "$STATE_DIR exists"; else fail "$STATE_DIR missing"; fi

  # The point of the whole queue, mechanised: a transform that quietly stopped
  # remapping would leave every check above green while printing blank pages.
  head_ "the transform actually removes black"
  if ! command -v gs >/dev/null 2>&1 || ! python3 -c 'import numpy, PIL' 2>/dev/null; then
    skip "ghostscript or python3 numpy/pillow unavailable"
  elif [ ! -x "$TOOL" ]; then
    skip "$TOOL not installed, nothing to exercise"
  else
    local t; t=$(mktemp -d)
    printf '%%!PS\n/Helvetica findfont 24 scalefont setfont 0 setgray\n72 700 moveto (verify) show\n0 0 0 setrgbcolor 72 600 200 60 rectfill\nshowpage\n' > "$t/v.ps"
    if ! gs -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -o "$t/v.pdf" "$t/v.ps" 2>/dev/null; then
      skip "could not build the probe PDF"
    else
      ( cd "$t" && K2C_STATE="$t/state" DRY=1 DPI=150 "$TOOL" v.pdf >/dev/null 2>&1 )
      if [ ! -s "$t/out.pdf" ]; then
        fail "transform produced no output"
      else
        local r
        r=$(cd "$t" && python3 - <<'PY' 2>/dev/null
import numpy as np, subprocess, sys
from PIL import Image
subprocess.run(["gs","-q","-dNOPAUSE","-dBATCH","-sDEVICE=png16m","-r100",
                "-sOutputFile=v.png","out.pdf"], check=True)
a = np.asarray(Image.open("v.png").convert("RGB")).astype(int)
h = a.shape[0]
body, strip = a[:int(h*0.82)], a[int(h*0.82):]
bi = body[(255 - body.min(2)) > 40]
si = strip[(255 - strip.min(2)) > 40]
print(len(bi), int((bi < 40).all(1).sum()) if len(bi) else -1,
      int((si < 40).all(1).sum()) if len(si) else 0)
PY
        )
        set -- $r
        if [ $# -ne 3 ]; then
          skip "could not measure the probe output"
        elif [ "${1:-0}" -lt 100 ]; then
          fail "probe page came out essentially blank ($1 inked pixels) -- the transform is eating the job"
        elif [ "${2:-1}" -ne 0 ]; then
          fail "$2 black pixels left in the page body -- black is still being sent to a dead nozzle row"
        elif [ "${3:-0}" -lt 100 ]; then
          fail "K exercise strip missing ($3 black pixels) -- nothing is keeping the K row wet"
        else
          ok "body has $1 inked pixels and 0 black; K strip present ($3 px)"
        fi
      fi
    fi
    rm -rf "$t"
  fi

  finish_verify "OK -- $QUEUE remaps black onto printable inks."
}

case "${1:-}" in
  enable) do_enable ;;
  verify) shift; parse_common_args "$@"; do_verify ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
