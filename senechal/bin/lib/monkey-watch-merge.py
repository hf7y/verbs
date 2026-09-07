#!/usr/bin/env python3
import json
import os
import sys
from datetime import datetime, timedelta  # merges dexter's host-side view onto monkey-status-collect.py's doc (not a heredoc in monkey-watch.sh: 2026-08-14 #274 shipped one with `d.accounts` undefined, page died reading `.length`); CONTRACT: share/monkey-status.html reads d.accounts (list, .length must ALWAYS exist), d.generated/.host/.valid_until/.verb_build/.filter, each account's .account/.armed/.last_run/.release_tick/.uid -- all from the COLLECTOR, never synthesised here; host-side facts go under `watcher`, NOT OPTIONAL (2026-08-23: ignoring watcher.verdict showed DOWN as green "0 ARMED"); its own valid_until is separate from the collector's, or a dead dexter reads OK


def main() -> int:
    raw = os.environ.get("GUEST_JSON", "").strip()
    try:
        doc = json.loads(raw) if raw else {}
    except json.JSONDecodeError as e:
        print(f"monkey-watch-merge: guest JSON did not parse: {e}", file=sys.stderr)
        doc = {}
    if not isinstance(doc, dict):
        print("monkey-watch-merge: guest JSON was not an object", file=sys.stderr)
        doc = {}

    now = os.environ["NOW"]
    cadence_min = int(os.environ.get("CADENCE_MIN") or 10)
    grace_min = int(os.environ.get("GRACE_MIN") or 20)

    if not isinstance(doc.get("accounts"), list):
        doc["accounts"] = []  # the honest report when the collector could not run
    doc.setdefault("generated", now)
    doc.setdefault("host", "monkey")

    guest_err = os.environ.get("GUEST_ERR", "") or None
    stamp = datetime.strptime(now, "%Y-%m-%dT%H:%M:%SZ")
    doc["watcher"] = {
        "generated": now,
        "cadence_minutes": cadence_min,
        "grace_minutes": grace_min,
        "valid_until": (stamp + timedelta(minutes=cadence_min + grace_min))
                       .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "verdict": os.environ["VERDICT"],
        "why": os.environ["WHY"],
        "vm_state": os.environ["VMSTATE"],
        "disk": os.environ["DISK"],
        "disk_home": os.environ["DISK_HOME"],
        "sshd": os.environ["SSHD"],
        "screenshot": bool(os.environ.get("SCREENSHOT")),
        "uptime": os.environ.get("UPTIME") or None,
        "clock_drift_hours": (  # realisateur#630: None means unreadable, not zero drift
            float(os.environ["CLOCK_DRIFT_H"])
            if os.environ.get("CLOCK_DRIFT_H", "").strip() else None
        ),
        "root_mount": os.environ.get("ROOTMOUNT") or None,
        "guest_error": guest_err,
        "accounts_from": (
            "bin/monkey-status-collect.py, run as root on monkey -- live probes "
            "of each account's crontab and scheduler ledger"
            if doc["accounts"] else
            "NOT COLLECTED -- the guest was unreachable, so accounts[] is empty "
            "rather than stale"
        ),
        "note": (
            f"Generated on dexter, the VM host, every {cadence_min} minutes. It can report "
            "monkey being down because it does not run on monkey. If "
            "watcher.generated is old, the WATCHER is broken -- not necessarily "
            "monkey."
        ),
    }
    print(json.dumps(doc, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
