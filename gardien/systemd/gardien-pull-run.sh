#!/usr/bin/env bash
# Pull, then back up -- in that order, and with the pull unable to stop the
# backup.
#
# WHY THIS EXISTS. gardien was deployed to dexter on 2026-07-28 as a
# hand-`scp`'d gardien.py with no .git at all. Every fix committed after
# that -- the snapshot completion markers, min_free_gb, the rsync hang
# guard -- sat in the repo while dexter ran code that predated them, and
# nothing could tell. A copied file cannot report its own staleness.
#
# THE ORDERING RULE, which is the whole design: a git problem must never
# become a backup problem. A failed pull leaves the last known-good
# checkout in place and the backup runs anyway, loudly noting that it
# could not refresh. The opposite policy -- abort if the pull fails --
# trades a real guarantee (a backup happened) for a theoretical one (it
# was the newest code), and turns every network blip into a missed night.
#
# gardien.py itself then reports whether what ran was actually current,
# via deployed_code_status()/format_code_status(). That is the "verify
# after" half: the pull is best-effort, the verification is not optional.

set -uo pipefail   # NOT -e: a failed pull is handled here, not fatal.

REPO="${GARDIEN_REPO:-$HOME/gardien-repo}"
CONFIG="${GARDIEN_CONFIG:-$HOME/gardien/gardien.json}"
PULL_TIMEOUT="${GARDIEN_PULL_TIMEOUT:-120}"

if [ ! -d "$REPO/.git" ]; then
  echo "[FAIL] $REPO is not a git checkout -- this wrapper exists to keep a" >&2
  echo "       clone current, and there is nothing here to pull. Clone the" >&2
  echo "       repo there, or point GARDIEN_REPO at one." >&2
  exit 1
fi

if [ ! -f "$CONFIG" ]; then
  echo "[FAIL] config not found at $CONFIG" >&2
  exit 1
fi

# The pull gets its own timeout for the same reason rsync does: an ssh that
# hangs rather than fails would block here forever, and this runs from a
# timer with TimeoutStartUSec=infinity. See DEFAULT_RSYNC_TIMEOUT_SECONDS.
if timeout "$PULL_TIMEOUT" git -C "$REPO" pull --ff-only --quiet 2>/tmp/gardien-pull.err; then
  echo "[OK] pulled $REPO -> $(git -C "$REPO" rev-parse --short HEAD)"
else
  rc=$?
  # Deliberately a warning, not a failure. Name the reason so a recurring
  # pull failure is diagnosable rather than just "it was old again".
  echo "[WARN] git pull failed (rc=$rc) -- running the existing checkout at" \
       "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '?')." \
       "Backup proceeds; code may be stale:" >&2
  sed 's/^/         /' /tmp/gardien-pull.err >&2 || true
  if [ "$rc" -eq 124 ]; then
    echo "         (rc=124 is the ${PULL_TIMEOUT}s timeout -- the remote hung" \
         "rather than refusing, the same failure mode the rsync guard covers.)" >&2
  fi
fi

exec /usr/bin/python3 "$REPO/gardien.py" --config "$CONFIG" "$@"
