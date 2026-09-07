#!/usr/bin/env python3
"""Merge dexter's host-side view onto monkey-status-collect.py's document.

Reads everything from the environment (GUEST_JSON plus the host facts) and
prints the published status.json on stdout. A separate file rather than a
heredoc inside monkey-watch.sh: the merge is where the page's contract lives,
and a nested heredoc is how the first attempt at this silently produced the
wrong shape.

THE CONTRACT, which share/monkey-status.html depends on:
    d.accounts   -- list; .length is read off it, so it must ALWAYS exist
    d.generated, d.host, d.valid_until, d.verb_build, d.filter
    each account: .account .armed .last_run .release_tick .uid

Those come from the COLLECTOR, which probes live crontabs and run ledgers as
root on monkey. They are never synthesised here. On 2026-08-14 a hand-rolled
payload omitted `accounts` entirely and the page died on
`can't access property "length", d.accounts is undefined` -- which was itself
the correct finding (the real publisher had not run), and is the failure this
file exists to make impossible.

The host-side facts go under `watcher`: what only the VM host can see -- that
the VM is running but not answering, or that its disk is back on the external
drive.

THE `watcher` BLOCK IS NOT OPTIONAL FOR THE RENDERER (2026-08-23). This
docstring used to call it "ADDITIVE, so an older renderer keeps working", and
that is exactly how the page rotted: the renderer kept deriving its headline
from accounts[], so an unreachable monkey -- empty accounts[], verdict DOWN --
rendered as a GREEN "0 ARMED". The publisher was honest and the page hid it
anyway. A consumer that ignores `watcher.verdict` is not "older", it is wrong.

`watcher.valid_until` is the WATCHER'S OWN freshness claim, and it is separate
from the collector's `valid_until` (24 h, absent whenever the guest was
unreachable -- so it can never bound this document). Without it a dexter that
stops ticking leaves the last verdict on the page reading as current forever:
the observer dies and the page still says OK.
"""
import json
import os
import sys
from datetime import datetime, timedelta


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

    # An empty list is the honest report when the collector could not run, and
    # it keeps the page alive to say so. Never a guess, never absent.
    if not isinstance(doc.get("accounts"), list):
        doc["accounts"] = []
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
        # realisateur#630: hours VirtualBox has GIVEN UP making up. None means
        # the log was unreadable, which is not the same as zero drift.
        "clock_drift_hours": (
            float(os.environ["CLOCK_DRIFT_H"])
            if os.environ.get("CLOCK_DRIFT_H", "").strip() else None
        ),
        "clocksource": {  # realisateur#805: guest-side successor to clock_drift_hours -- WSL2 has no VBox.log, journalctl's stall counter works under either backend
            "long_readout_count": (
                int(os.environ["LONG_READOUT"])
                if os.environ.get("LONG_READOUT", "").strip().isdigit() else None
            ),  # None (not 0) whenever the guest could not be asked, never a healthy-looking zero
            "sampled_at": (
                now if os.environ.get("LONG_READOUT", "").strip().isdigit() else None
            ),
        },
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
