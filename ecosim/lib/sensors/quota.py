#!/usr/bin/env python3
"""ecosim.quota -- T1's measurement, re-axed onto the resource that is
actually shared.

WHY THIS SENSOR EXISTS
----------------------
bibliothecaire's integration brief (2026-07-29) read ecosim's results and
found the theory had been testing the wrong axis:

    T1 is not refuted, it is confirmed at a boundary nobody drew. The
    credential axis decomposes by HOST, not by project. If T1 is to be
    re-run, QUOTA is the axis, not credentials.

That is right, and the evidence was already in the night's logs unremarked:
the API credential turned out to be per-host (331/479 failures on dexter
against 0/512 on mandark, same probe, 21 seconds apart), so it could never
show the correlated failure T1 predicts. **The weekly quota is different: two
hosts draw on one account with no shared lock**, which is the one place a
failure genuinely must hit both at once.

So this sensor asks the question T1 actually needs answered:

    Do the two hosts enter and leave quota pressure TOGETHER, or independently?

Simultaneous HOLD on both hosts is Simon's short run ending — the aggregate
dependence becoming visible. Independent HOLDs are the short run continuing.
The transition between them is the measurement, and nothing has been recording
it.
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

RUNLOG = "~/.local/share/scheduler-paced-runner/run.log"


@register
class QuotaSensor(Sensor):
    name = "quota"

    domain = Domain(
        describes="whether the hosts drawing on one weekly quota enter "
                  "pressure together (aggregate dependence) or independently "
                  "(short-run independence) -- T1's actual measurement",
        reads=(RUNLOG,),
        hosts=hosts.dispatch_hosts(),
    )

    alphabet = Alphabet(
        Symbol("HEADROOM", EXIT_OK,
               "this host's gate last returned RUN -- quota is not binding here"),
        Symbol("HOLD_LOCAL", EXIT_WARN,
               "this host is holding on quota while the other is not, which is "
               "the short-run independence T1 predicts early"),
        Symbol("HOLD_CORRELATED", EXIT_CRIT,
               "BOTH hosts are holding on quota at once -- the shared-fate "
               "signal, and the transition T1 is actually about"),
        Symbol("PRESSURE_RISING", EXIT_WARN,
               "utilisation is above the burn-line but the gate still says "
               "RUN -- pressure without a hold yet"),
        Symbol("BLIND_NO_GATE_LINE", EXIT_BLIND,
               "no gate verdict in this host's runner log, so its quota state "
               "cannot be read at all"),
        Symbol("BLIND_HOST_UNREADABLE", EXIT_BLIND,
               "the host's runner log could not be read, so no claim about "
               "its quota state is possible"),
    )

    def __init__(self, reader=None, host_list=None):
        super().__init__()
        self._read = reader or self._read_host
        # Pinned in fixtures so a new host in the estate cannot change what
        # a fixture proves. See lib/hosts.py.
        self._hosts = tuple(host_list) if host_list else hosts.dispatch_hosts()

    @staticmethod
    def _read_host(host):
        if hosts.is_local(host):
            try:
                p = Path(RUNLOG.replace("~", str(Path.home())))
                return [l for l in p.read_text().splitlines()
                        if "verdict=" in l][-40:], None
            except OSError as e:
                return None, str(e)
        # The runner log is PER-USER RUNTIME STATE, so unlike the rotation and
        # registry files it cannot live in /srv: there is one per dispatching
        # account. On monkey the login account does not dispatch and has no
        # log at all, while ecosim/bibliothecaire/vim-arcade each keep their
        # own -- so reading only "$HOME"'s answered for the one account that
        # never runs, and reported the host as having no verdicts.
        #
        # The host's quota state is the most RECENT verdict across all of its
        # dispatching accounts: they draw on one quota, which is the entire
        # premise of this sensor. Lines are ISO-timestamped, so a lexical sort
        # is a chronological one.
        out, err = hosts.ssh_read(
            host, f"{{ grep -hE '^2026' {RUNLOG} 2>/dev/null; "
                  f"  sudo -n sh -c \"grep -hE '^2026' "
                  f"/home/*/.local/share/scheduler-paced-runner/run.log\" "
                  f"    2>/dev/null; }} "
                  f"| grep -E 'verdict=' | sort -u | tail -40")
        # Transport/ssh failure is an ERROR and is returned as one. It must not
        # fall through to the emptiness test below: "could not ask the host"
        # and "the host has no verdict lines" are different findings, and
        # collapsing them is how an unreachable host reads as merely quiet.
        if out is None:
            return None, err
        # NOTE: this remote command contains a pipe, so a failing grep would be
        # masked by the pipeline's own status. That is acceptable ONLY because
        # a failure is caught by the emptiness check rather than by the rc --
        # called out because the 19/19 probe died on exactly this.
        return (out.splitlines() if out.strip() else None), None

    @staticmethod
    def classify(lines):
        """(state, detail) for one host from its recent gate verdicts."""
        if not lines:
            return "BLIND_NO_GATE_LINE", "no verdict lines"
        last = lines[-1]
        verdict = re.search(r"verdict=(\w+)", last)
        verdict = verdict.group(1) if verdict else ""
        used = re.search(r"(\d+)% used vs burn-line (\d+)%", last)
        when = last.split()[0]
        if verdict == "HOLD":
            return "HOLD", f"{when} {used.group(0) if used else 'holding'}"
        if verdict == "RUN" and used and int(used.group(1)) > int(used.group(2)):
            return "PRESSURE", f"{when} {used.group(0)}"
        if verdict == "RUN":
            return "RUN", f"{when} gate says RUN"
        # ERROR (e.g. a 401) is NOT a quota reading. Reporting it as headroom
        # or as a hold would both be wrong; it means quota is unknown here.
        return "BLIND_NO_GATE_LINE", f"{when} verdict={verdict or 'absent'}"

    def probe(self):
        states = {}
        for host in self._hosts:
            lines, err = self._read(host)
            if err is not None:
                yield self.blind("BLIND_HOST_UNREADABLE", host,
                                 f"cannot read runner log: {err}", host=host)
                states[host] = None
                continue
            state, detail = self.classify(lines)
            states[host] = (state, detail)

        holding = [h for h, v in states.items() if v and v[0] == "HOLD"]
        for host, v in states.items():
            if v is None:
                continue
            state, detail = v
            if state == "BLIND_NO_GATE_LINE":
                yield self.blind("BLIND_NO_GATE_LINE", host, detail, host=host)
            elif state == "HOLD":
                # The discrimination this sensor exists for: one host holding
                # is independence, both holding is aggregate dependence.
                if len(holding) > 1:
                    yield self.emit("HOLD_CORRELATED", host,
                                    f"both hosts holding: {detail}",
                                    host=host, holding=len(holding))
                else:
                    yield self.emit("HOLD_LOCAL", host, detail,
                                    host=host, holding=1)
            elif state == "PRESSURE":
                yield self.emit("PRESSURE_RISING", host, detail, host=host)
            else:
                yield self.emit("HEADROOM", host, detail, host=host)

    def fixtures(self):
        def mk(mandark_lines, dexter_lines, err=None):
            data = {"mandark": mandark_lines, "dexter": dexter_lines}
            s = QuotaSensor(reader=lambda h: (None, err) if err
                            else (data.get(h), None),
                            host_list=("mandark", "dexter"))
            return lambda: list(s.probe())

        run_line = "2026-07-29T01:00:03-05:00 RUN verdict=RUN http_code=200 " \
                   "# RUN -- 5h window 23% used vs burn-line 40%"
        pressure = "2026-07-29T03:00:03-05:00 RUN verdict=RUN http_code=200 " \
                   "# RUN -- 5h window 61% used vs burn-line 40%"
        hold = "2026-07-29T03:30:03-05:00 HOLD verdict=HOLD http_code=200 " \
               "# HOLD -- 5h window 89% used vs burn-line 57%"
        err_line = "2026-07-29T06:00:03-05:00 HOLD verdict=ERROR http_code=401"

        return [
            mk([run_line], [run_line]),                  # HEADROOM x2
            mk([hold], [run_line]),                      # HOLD_LOCAL
            mk([hold], [hold]),                          # HOLD_CORRELATED
            mk([pressure], [run_line]),                  # PRESSURE_RISING
            mk([err_line], [run_line]),                  # BLIND_NO_GATE_LINE
            mk(None, None, err="ssh failed"),            # BLIND_HOST_UNREADABLE
        ]
