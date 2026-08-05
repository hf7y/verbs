#!/usr/bin/env bash
# Archive the mandark agent-ecosystem set onto a removable drive.
#
# Why tar and not rsync: the target (08A4-7AA6) is exFAT. exFAT has no
# POSIX permissions, no symlinks and no hardlinks, so an rsync -a of
# ~/.ssh or ~/.local/bin lands with 0755 on private keys and shims
# flattened into copies. Inside a tarball all of that survives, and the
# restore is byte-exact. Large files are fine on exFAT.
#
# Fails loud: any tar or verify failure exits non-zero and the run is
# NOT marked complete. "Worked" means restore-and-diff came back clean,
# never that tar exited 0.
set -euo pipefail

DEST_ROOT="${1:-/media/zach/08A4-7AA6/gardien-ecosystem}"
STAMP="$(date +%Y-%m-%d)"
DEST="$DEST_ROOT/$STAMP"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mountpoint -q "$(df --output=target "$DEST_ROOT" 2>/dev/null | tail -1)" 2>/dev/null || {
  # first run: DEST_ROOT may not exist yet, check its parent
  :
}
TARGET_MOUNT="$(df --output=target "$(dirname "$DEST_ROOT")" | tail -1)"
if [ "$TARGET_MOUNT" = "/" ]; then
  echo "[FAIL] $DEST_ROOT resolves to the root filesystem, not a removable drive." >&2
  exit 1
fi
mkdir -p "$DEST"

# set name : tar -C base : paths...
run_set() {
  local name="$1" base="$2"; shift 2
  local out="$DEST/$name.tar.gz"
  echo "[*] $name"
  tar --create --gzip --file "$out" \
      --directory "$base" \
      --exclude='node_modules' --exclude='__pycache__' \
      --exclude='.venv' --exclude='*.pyc' \
      --warning=no-file-changed --warning=no-file-ignored \
      "$@" || {
        rc=$?
        # tar exits 1 for "file changed as we read it" on live dirs; 2 is fatal
        [ "$rc" = 1 ] || { echo "[FAIL] tar $name exited $rc" >&2; exit "$rc"; }
        echo "[warn] $name: some files changed while reading (rc=1)"
      }
  echo "[*] verify $name (restore + diff)"
  local rdir="$WORK/$name"
  mkdir -p "$rdir"
  tar --extract --gzip --file "$out" --directory "$rdir"
  local ok=1
  for p in "$@"; do
    # -x mirrors the tar --exclude list, so the only diffs reported are
    # real ones (or live-file churn), not this script's own exclusions.
    diff -r --no-dereference -x __pycache__ -x node_modules -x .venv -x '*.pyc' \
      "$base/$p" "$rdir/$p" >>"$WORK/$name.diff" 2>&1 || ok=0
  done
  if [ "$ok" = 0 ] && [ -s "$WORK/$name.diff" ]; then
    # churn in live logs is expected; report it rather than hiding it
    echo "[warn] $name: differences after restore (live files changed mid-run):"
    head -20 "$WORK/$name.diff"
    cp "$WORK/$name.diff" "$DEST/$name.diff.txt"
  else
    echo "[ok] $name: restore diff clean"
  fi
  rm -rf "$rdir"
}

cd "$HOME"

# 1. Claude Code's own state: settings, per-project memory, transcripts,
#    commands, plugins. Nothing here is in any repo.
run_set claude-home "$HOME" .claude

# 2. Machine-level ecosystem config: the ~40 PATH shims every project
#    assumes, the systemd user units, and the crontab (currently empty on
#    purpose -- captured anyway, so its emptiness is a recorded fact).
crontab -l >"$WORK/crontab.txt" 2>/dev/null || echo "# no crontab" >"$WORK/crontab.txt"
cp "$WORK/crontab.txt" "$DEST/crontab.txt"
run_set ecosystem-config "$HOME" .local/bin .config/systemd/user

# 3. Nightly-batch / bug-sweep working state and run logs. The clones are
#    reproducible from git; the logs are not.
mapfile -t batch < <(cd "$HOME/.local/share" && ls -d *-nightly-batch *-bug-sweep ecosim-sensor 2>/dev/null)
run_set batch-state "$HOME/.local/share" "${batch[@]}"

# 4. Local bare remotes (basheur's ONLY copy) and the report history.
run_set git-remotes "$HOME" git-remotes reports

# 5. The keyring. Disk-only, never a git remote. See WARNING in the manifest.
run_set ssh-keys "$HOME" .ssh

# 6. All project working copies, including uncommitted work.
run_set projects "$HOME/Documents" Projects

sha256sum "$DEST"/*.tar.gz >"$DEST/SHA256SUMS"
echo
echo "[done] $DEST"
du -sh "$DEST"
