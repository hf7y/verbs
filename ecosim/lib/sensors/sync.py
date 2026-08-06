#!/usr/bin/env python3
"""ecosim.sync -- is a host's checkout current, and if not, is it catching up?

WHY THIS SENSOR EXISTS, and it is an error of mine rather than a prediction.

At 11:05 this project filed a hazard (issue #22) that read, in part, "mandark's
checkout is 3 commits behind origin" -- framed as a standing condition needing
intervention. It was ordinary lag: mandark's runner pulls on a five-minute tick,
dexter was pushing faster than that, and the checkout is behind at almost any
instant you sample it. The condition cleared on its own within one pull cycle.

The evidence to know better was one grep away -- `PULL fast-forwarded to
31b6623` sat in the runner log -- and I read `git status -sb` without checking
whether pulls were succeeding.

    "BEHIND, AND CATCHING UP" AND "BEHIND, AND STUCK" ARE TWO WORLD-STATES
    THAT SHARE A COMMIT COUNT.

Last night the same pair produced the opposite error, and that one was not
harmless: dexter sat 6 commits behind with two dirty tracked files, could not
pull, and never received the migration's freeze -- and the ecosystem's only
symbol for it was `PULL skip`, which it also emits when there is nothing to
pull. One absent distinction, two errors, in both directions.

So this sensor never reports a distance without reporting whether the distance
is closing.
"""
from pathlib import Path
import os
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import hosts  # noqa: E402
from ecosim_sensor import (  # noqa: E402
    Alphabet, Domain, Sensor, Symbol, register, sh,
    EXIT_OK, EXIT_WARN, EXIT_CRIT, EXIT_BLIND,
)

SCHED = Path(os.environ.get(
    "ECOSIM_SCHEDULER_DIR", Path.home() / "Documents/Projects/scheduler"))
RUNLOG = "~/.local/share/scheduler-paced-runner/run.log"

# A pull that succeeded recently enough to count as "catching up". Two runner
# ticks (5 min each) plus slack: a host that has not pulled in 15 minutes is
# not merely lagging.
FRESH_PULL_SECONDS = 900


@register
class SyncSensor(Sensor):
    name = "sync"

    domain = Domain(
        describes="whether each host's scheduler checkout is current with "
                  "origin and, when it is not, whether its pulls are still "
                  "succeeding -- distance and direction of travel, never "
                  "distance alone",
        reads=("git status", RUNLOG),
        hosts=hosts.dispatch_hosts(),
    )

    alphabet = Alphabet(
        Symbol("LEVEL", EXIT_OK,
               "the checkout matches origin; nothing outstanding to pull"),
        Symbol("BEHIND_PULLING", EXIT_OK,
               "behind origin, and a pull succeeded recently -- ordinary lag "
               "on a host whose peer is pushing faster than its tick"),
        Symbol("BEHIND_STALLED", EXIT_CRIT,
               "behind origin with no recent successful pull -- the distance "
               "is not closing and the host is working from stale code"),
        Symbol("DIVERGED", EXIT_CRIT,
               "ahead AND behind origin: local commits exist that origin does "
               "not have, which no pull will resolve on its own"),
        Symbol("BLIND_NO_PULL_LOG", EXIT_BLIND,
               "the runner log could not be read, so whether pulls are "
               "succeeding is unknown and lag cannot be classified"),
        Symbol("BLIND_HOST_UNREADABLE", EXIT_BLIND,
               "the host's checkout could not be read at all, so neither "
               "distance nor direction is available"),
    )

    def __init__(self, reader=None, now=None, host_list=None):
        super().__init__()
        self._read = reader or self._read_host
        self._now = now
        # Pinned in fixtures; derived in production. See lib/hosts.py.
        self._hosts = tuple(host_list) if host_list else hosts.dispatch_hosts()

    @staticmethod
    def _read_host(host):
        """(ahead, behind, pull_lines) or (None, None, reason)."""
        if hosts.is_local(host):
            rc, _ = sh("git", "-C", str(SCHED), "fetch", "-q", timeout=40)
            rc1, ahead = sh("git", "-C", str(SCHED), "rev-list", "--count",
                            "origin/main..HEAD")
            rc2, behind = sh("git", "-C", str(SCHED), "rev-list", "--count",
                             "HEAD..origin/main")
            if rc1 != 0 or rc2 != 0:
                return None, None, f"rev-list failed: {ahead or behind}"
            try:
                lines = [l for l in
                         Path(RUNLOG.replace("~", str(Path.home()))).read_text()
                         .splitlines() if "PULL" in l][-20:]
            except OSError as e:
                return int(ahead), int(behind), None  # distance known, log not
            return int(ahead), int(behind), lines
        # WHERE the checkout is: asked once, in lib/hosts.py. `~/scheduler` is
        # dexter's layout; on monkey it is /srv/scheduler and the login account
        # owns no clone at all, which is why this sensor stayed blind to monkey
        # after rotation could already see it.
        found, why = hosts.remote_scheduler(host)
        if found is None:
            return None, None, why
        sroot, _ = found

        # READ-ONLY, and deliberately so. The previous form ran `git fetch` on
        # the observed host: a monitor mutating its own subject, and on a
        # root-owned /srv it simply fails. Instead take that host's HEAD and
        # measure the distance HERE, against mandark's own fetched origin/main.
        # safe.directory because a root-owned checkout read by another account
        # trips git's dubious-ownership guard, which is correct and not worth
        # disabling globally just to read a sha.
        cmd = (f"git -c safe.directory={sroot} -C {sroot} rev-parse HEAD; "
               f"grep PULL {RUNLOG} 2>/dev/null | tail -20")
        out, err = hosts.ssh_read(host, cmd, timeout=45)
        if out is None:
            return None, None, err
        lines = out.splitlines()
        sha = lines[0].strip() if lines else ""
        if not re.fullmatch(r"[0-9a-f]{7,40}", sha):
            return None, None, f"no HEAD sha from {sroot}: {sha[:40]!r}"
        sh("git", "-C", str(SCHED), "fetch", "-q", timeout=40)
        rc1, ahead = sh("git", "-C", str(SCHED), "rev-list", "--count",
                        f"origin/main..{sha}")
        rc2, behind = sh("git", "-C", str(SCHED), "rev-list", "--count",
                         f"{sha}..origin/main")
        if rc1 != 0 or rc2 != 0:
            # Its HEAD is not an object we hold. Unknown distance -- never 0.
            return None, None, (f"{host} is at {sha[:12]}, which mandark does "
                                f"not have; unpushed branch or unfetched remote")
        return int(ahead), int(behind), lines[1:]

    @staticmethod
    def last_good_pull(lines):
        """Timestamp of the most recent SUCCESSFUL pull, or None.

        `PULL skip` and `PULL WARNING` are explicitly NOT successes -- that
        conflation is what let dexter sit unable to pull for hours while its
        log looked busy.
        """
        for line in reversed(lines or []):
            if "PULL" in line and not re.search(r"skip|WARNING|ERROR", line):
                m = re.match(r"(\S+)", line)
                return m.group(1) if m else None
        return None

    def probe(self):
        for host in self._hosts:
            ahead, behind, lines = self._read(host)
            if ahead is None:
                yield self.blind("BLIND_HOST_UNREADABLE", host,
                                 f"{lines}", host=host)
                continue
            if ahead and behind:
                yield self.emit("DIVERGED", host,
                                f"ahead {ahead}, behind {behind} -- no pull "
                                f"resolves this", host=host,
                                ahead=ahead, behind=behind)
                continue
            if not behind:
                yield self.emit("LEVEL", host, "current with origin",
                                host=host, behind=0)
                continue
            if lines is None:
                yield self.blind("BLIND_NO_PULL_LOG", host,
                                 f"behind {behind}, but whether pulls are "
                                 f"succeeding is unknown", host=host,
                                 behind=behind)
                continue
            last = self.last_good_pull(lines)
            if last:
                yield self.emit("BEHIND_PULLING", host,
                                f"behind {behind}, last good pull {last}",
                                host=host, behind=behind, last_pull=last)
            else:
                yield self.emit("BEHIND_STALLED", host,
                                f"behind {behind}, no successful pull in the "
                                f"last {len(lines)} PULL lines",
                                host=host, behind=behind)

    def fixtures(self):
        def mk(ahead, behind, lines):
            s = SyncSensor(reader=lambda h: (ahead, behind, lines),
                           host_list=("mandark",))
            return lambda: list(s.probe())

        good = ["2026-07-29T11:05:03-05:00 PULL fast-forwarded to 31b6623"]
        skips = ["2026-07-29T10:05:03-05:00 PULL skip -- has uncommitted changes",
                 "2026-07-29T10:10:02-05:00 PULL WARNING -- diverged from origin"]
        return [
            mk(0, 0, good),                 # LEVEL
            mk(0, 3, good),                 # BEHIND_PULLING -- the #22 case
            mk(0, 6, skips),                # BEHIND_STALLED -- last night's dexter
            mk(1, 6, good),                 # DIVERGED
            mk(0, 3, None),                 # BLIND_NO_PULL_LOG
            mk(None, None, "ssh failed"),   # BLIND_HOST_UNREADABLE
        ]
