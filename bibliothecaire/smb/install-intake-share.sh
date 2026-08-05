#!/usr/bin/env bash
# Install the bibliothecaire scanner-intake SMB share on mandark.
#
# Machine-wide config: a samba share, a service account, and an include
# line in /etc/samba/smb.conf. senechal is told about it at the end
# (CLAUDE.md ecosystem protocols) -- this project owns the config,
# senechal owns knowing it exists.
#
#   sudo smb/install-intake-share.sh            install / re-install
#   sudo smb/install-intake-share.sh --verify   check, change nothing
#   sudo smb/install-intake-share.sh --uninstall
#
# Idempotent. Re-running it is the supported way to apply an edit to
# smb/bibliothecaire-intake.conf.in.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$REPO/smb/bibliothecaire-intake.conf.in"
PUB_TEMPLATE="$REPO/smb/bibliothecaire-published.conf.in"
CONF_D="/etc/samba/conf.d"
INSTALLED="$CONF_D/bibliothecaire-intake.conf"
SMB_CONF="/etc/samba/smb.conf"
INCLUDE_LINE="include = $INSTALLED"

MODE="install"
[[ "${1:-}" == "--verify" ]] && MODE="verify"
[[ "${1:-}" == "--uninstall" ]] && MODE="uninstall"

die() { echo "[FAIL] $*" >&2; exit 1; }
ok()  { echo "[ok] $*"; }

# sudo resets PATH to secure_path, which excludes ~/.local/bin -- where
# realisateur installs the ecosystem guards. Looking for notify-senechal
# on root's PATH finds nothing and silently skips the notification, which
# is a guard that fails quietly: the worst kind. Resolve it through the
# owner's own login shell instead, and treat "still not found" as a
# finding rather than a shrug.
find_notify() {
  local p
  p="$(sudo -u "$OWNER" bash -lc 'command -v notify-senechal' 2>/dev/null || true)"
  [[ -n "$p" && -x "$p" ]] && { echo "$p"; return 0; }
  for p in "/home/$OWNER/.local/bin/notify-senechal" /usr/local/bin/notify-senechal; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

pay_senechal() {
  local note="$1" bin
  if bin="$(find_notify)"; then
    # `sudo -u` does not load a login shell, so the callee inherits root's
    # secure_path and cannot find ITS own guards -- notify-senechal went
    # looking for focus-commit, missed it, and fell back to a bare git
    # sequence it exists to replace. Hand the owner's bin dir down
    # explicitly rather than hoping.
    if sudo -u "$OWNER" env "PATH=/home/$OWNER/.local/bin:/usr/local/bin:/usr/bin:/bin" \
         "$bin" "$note"; then
      ok "senechal told (via $bin)"
    else
      echo "[WARN] notify-senechal FAILED -- senechal does NOT know this machine config exists." >&2
      echo "[WARN] Re-run by hand: notify-senechal '<what changed, where, who owns it>'" >&2
    fi
  else
    echo "[FAIL] notify-senechal not found for user $OWNER -- a missing guard is a finding," >&2
    echo "[FAIL] not an inconvenience. senechal has NOT been told about this config." >&2
  fi
}


[[ $EUID -eq 0 ]] || die "must run as root (samba config, useradd, chown)"
[[ -f "$REPO/intake.json" ]] || die "missing $REPO/intake.json -- config has one source"

# Read every value from intake.json. Nothing here is retyped.
# TAB-separated, and read with IFS set to tab only. hosts_allow legitimately
# contains a space ("192.168.0.0/24 127.0.0.1"), and a whitespace-split read
# silently ate it as two fields -- shifting every later variable by one and
# installing a share literally named "127.0.0.1". Field data containing the
# delimiter is not an edge case here, it is the normal value.
IFS=$'\t' read -r SHARE INTAKE_ROOT SMB_USER HOSTS PUB_SHARE PUB_DIR PUB_PAGE < <(
  python3 - "$REPO/intake.json" <<'PYCFG'
import json, sys
c = json.load(open(sys.argv[1]))
p = c.get("publish", {})
fields = [c["smb_share"], c["intake_root"], c["smb_user"], c["hosts_allow"],
          p.get("share", "bibquotes"), p.get("dir", "published"),
          str(p.get("page", 92))]
assert not any("\t" in f for f in fields), "config value contains a tab"
print("\t".join(fields))
PYCFG
)
for v in SHARE INTAKE_ROOT SMB_USER HOSTS PUB_SHARE PUB_DIR PUB_PAGE; do
  [[ -n "${!v:-}" ]] || die "config field $v came out empty -- refusing to install a half-read config"
done
[[ "$PUB_SHARE" != *[/.]* ]] || die "publish.share is '$PUB_SHARE', which looks like a path or an address, not a share name -- config was misparsed"
INCOMING="$INTAKE_ROOT/incoming"
PUBLISHED="$INTAKE_ROOT/$PUB_DIR"
OWNER="$(stat -c %U "$(dirname "$INTAKE_ROOT")" 2>/dev/null || echo zach)"

if [[ "$MODE" == "uninstall" ]]; then
  # Named retirement: this is what the installer takes back.
  rm -f "$INSTALLED"
  if grep -qF "$INCLUDE_LINE" "$SMB_CONF"; then
    grep -vF "$INCLUDE_LINE" "$SMB_CONF" > "$SMB_CONF.tmp" && mv "$SMB_CONF.tmp" "$SMB_CONF"
    ok "removed include line from $SMB_CONF"
  fi
  systemctl reload smbd || systemctl restart smbd
  ok "share '$SHARE' removed. Service account '$SMB_USER' and $INCOMING left in place"
  ok "  (delete deliberately: 'smbpasswd -x $SMB_USER; userdel $SMB_USER' -- "
  ok "   NOT done automatically, because $INCOMING may still hold unreaped scans)"
  exit 0
fi

if [[ "$MODE" == "verify" ]]; then
  rc=0
  [[ -f "$INSTALLED" ]] || { echo "[FAIL] $INSTALLED absent" >&2; rc=1; }
  grep -qF "$INCLUDE_LINE" "$SMB_CONF" || { echo "[FAIL] include line absent from $SMB_CONF" >&2; rc=1; }
  id "$SMB_USER" >/dev/null 2>&1 || { echo "[FAIL] service account $SMB_USER absent" >&2; rc=1; }
  pdbedit -L 2>/dev/null | grep -q "^$SMB_USER:" || { echo "[FAIL] $SMB_USER has no samba password set (smbpasswd -a $SMB_USER)" >&2; rc=1; }
  if [[ -d "$INCOMING" ]]; then
    perms="$(stat -c '%a %U:%G' "$INCOMING")"
    [[ "$perms" == "730 $OWNER:$SMB_USER" ]] || { echo "[FAIL] $INCOMING is '$perms', expected '730 $OWNER:$SMB_USER' -- a readable drop box is not a write-only one" >&2; rc=1; }
  else
    echo "[FAIL] $INCOMING absent" >&2; rc=1
  fi
  if [[ -d "$PUBLISHED" ]]; then
    pperms="$(stat -c '%a' "$PUBLISHED")"
    [[ "$pperms" == "755" ]] || { echo "[FAIL] $PUBLISHED is '$pperms', expected 755 -- consumers cannot read it" >&2; rc=1; }
  else
    echo "[FAIL] $PUBLISHED absent" >&2; rc=1
  fi
  testparm -s --section-name="$PUB_SHARE" 2>/dev/null | grep -qi 'read only *= *yes' \
    || { echo "[FAIL] share '$PUB_SHARE' is not read-only -- a writable publishing surface is not one" >&2; rc=1; }
  systemctl is-active --quiet smbd || { echo "[FAIL] smbd not active" >&2; rc=1; }
  testparm -s >/dev/null 2>&1 || { echo "[FAIL] testparm rejects the current samba config" >&2; rc=1; }
  [[ $rc -eq 0 ]] && ok "share '$SHARE' installed and correct"
  exit $rc
fi

# ---- install ----------------------------------------------------------

if ! id "$SMB_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SMB_USER"
  ok "created service account $SMB_USER (no shell, no home)"
else
  ok "service account $SMB_USER already exists"
fi
# Lock the unix password: this account exists to own SMB writes, not to log in.
passwd -l "$SMB_USER" >/dev/null
usermod -aG "$SMB_USER" "$OWNER"
ok "$OWNER added to group $SMB_USER (so bin/intake.py can drain incoming/)"

mkdir -p "$INTAKE_ROOT"/{incoming,accepted,work,rejected}
chown -R "$OWNER:$OWNER" "$INTAKE_ROOT"
chmod 0711 "$INTAKE_ROOT"                 # traversable, not listable
chown "$OWNER:$SMB_USER" "$INCOMING"
chmod 0730 "$INCOMING"                    # owner rwx; group write+traverse, NO read
chmod 0700 "$INTAKE_ROOT"/{accepted,work,rejected}
# published/ is the one directory here the world may read. 0755, owned by
# the intake owner so only `bin/intake.py --publish` ever writes it.
mkdir -p "$PUBLISHED"
chown "$OWNER:$OWNER" "$PUBLISHED"
chmod 0755 "$PUBLISHED"
ok "intake tree at $INTAKE_ROOT ($(stat -c %a "$INCOMING") on incoming/, $(stat -c %a "$PUBLISHED") on $PUB_DIR/)"

mkdir -p "$CONF_D"
{
  sed -e "s|@SHARE@|$SHARE|g" -e "s|@PATH@|$INCOMING|g" \
      -e "s|@USER@|$SMB_USER|g" -e "s|@HOSTS@|$HOSTS|g" "$TEMPLATE"
  sed -e "s|@SHARE@|$PUB_SHARE|g" -e "s|@PATH@|$PUBLISHED|g" \
      -e "s|@INSHARE@|$SHARE|g" -e "s|@PAGE@|$PUB_PAGE|g" \
      -e "s|@HOSTS@|$HOSTS|g" "$PUB_TEMPLATE"
} > "$INSTALLED"
chmod 0644 "$INSTALLED"
ok "wrote $INSTALLED: write-only '$SHARE' + read-only '$PUB_SHARE'"

# Guest access needs a global setting. Samba defaults `map to guest` to
# Never, which refuses guest sessions -- so a guest-ok share exists and
# still rejects every client, which looks exactly like a broken share.
if ! grep -qE '^[[:space:]]*map to guest[[:space:]]*=' "$SMB_CONF"; then
  warn_guest=1
fi

if ! grep -qF "$INCLUDE_LINE" "$SMB_CONF"; then
  cp -a "$SMB_CONF" "$SMB_CONF.bak.$(date +%Y%m%d-%H%M%S)"
  printf '\n# bibliothecaire scanner intake -- owned by ~/Documents/Projects/bibliothecaire\n%s\n' \
    "$INCLUDE_LINE" >> "$SMB_CONF"
  ok "added include line to $SMB_CONF (backup taken)"
else
  ok "include line already present in $SMB_CONF"
fi

testparm -s >/dev/null || die "testparm rejects the resulting config -- NOT reloading smbd"
systemctl reload smbd || systemctl restart smbd
ok "smbd reloaded"

if ! pdbedit -L 2>/dev/null | grep -q "^$SMB_USER:"; then
  echo
  echo "NEXT, and the share does not work until you do it:"
  echo "    sudo smbpasswd -a $SMB_USER"
  echo "  then on the Mac, connect to:  smb://$(hostname -s)/$SHARE"
  echo "  (or smb://$(hostname -I | awk '{print $1}')/$SHARE)"
fi

if [[ "${warn_guest:-0}" == "1" ]]; then
  echo
  echo "[WARN] $SMB_CONF has no 'map to guest' setting. Samba defaults to" >&2
  echo "[WARN] 'Never', which refuses guest sessions -- so '$PUB_SHARE' will" >&2
  echo "[WARN] exist and still reject potato, looking exactly like a bug." >&2
  echo "[WARN] Add to [global]:   map to guest = Bad User" >&2
fi

echo
echo "Read-only publishing surface: smb://$(hostname -s)/$PUB_SHARE"
echo "  Populate it with: bin/intake.py --publish"

pay_senechal "mandark: TWO samba shares from one config at $INSTALLED (include line in $SMB_CONF). '$SHARE' -> $INCOMING is the WRITE-ONLY scanner drop box (0730, service account '$SMB_USER'). '$PUB_SHARE' -> $PUBLISHED is READ-ONLY and GUEST-READABLE, LAN-restricted, serving quotes.txt and page-$PUB_PAGE extracts for potato (crt's Pi) to pull -- guest deliberately, because senechal's own ESTATE.md records potato as NOT a trusted secret-holder. Owned by the bibliothecaire project (~/Documents/Projects/bibliothecaire, smb/install-intake-share.sh --uninstall)."
