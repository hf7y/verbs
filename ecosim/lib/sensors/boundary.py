#!/usr/bin/env python3
"""ecosim.boundary -- is each participant still inside its monitor's
jurisdiction?

REFRAMED FROM STIGMERGY TO COMMONS-GOVERNANCE, on bibliothecaire's
citation-backed recommendation (`briefs/dexter-migration-integration-2026-07-29.md`,
`12b9bf4`, §2). ecosim originally filed this as a stigmergy result: the
rotation has positive feedback with no evaporation, per
`theraulaz-stigmergy-3`. That half is confirmed and stands.

The sharper half is not a stigmergy result at all:

    weight-audit.sh is hardcoded to _paced.conf and runs on mandark only, so
    every project that migrates leaves the domain of the only negative
    feedback in the ecosystem, mechanically, at the moment it moves.
    Stigmergy has no vocabulary for that, because Grasse's termites cannot
    leave the nest's jurisdiction. Ostrom does.

`ostrom-commons-governance-3`, design principle 4A: *"Individuals who are
accountable to or are the users monitor the appropriation and provision levels
of the users."* The migration changed **who is inside the boundary without
changing the boundary rule**. The monitor's jurisdiction is a file path on one
host, and the resource moved out from under it. That is not a missing feedback
loop; it is a monitor whose accountability relation to the users has been
silently severed.

WHY THE FRAME CHANGES THE CODE AND NOT JUST THE PROSE. The two readings imply
different repairs, and the sensor should measure the one that works:

    Theraulaz's repair -- add an evaporation term -- fixes the governed lines
    and leaves the ungoverned ones exactly as ungoverned.
    Ostrom's repair -- make the monitor's boundary follow the resource --
    fixes both.

So this sensor measures BOUNDARY CONTAINMENT, not decay presence. The question
is not "does a decay rule exist" but "does the monitor's jurisdiction still
contain this participant", and the answer is per-participant.
"""
from pathlib import Path
import os
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import hosts  # noqa: E402
from ecosim_sensor import (  # noqa: E402
    Alphabet, Domain, Sensor, Symbol, register,
    EXIT_OK, EXIT_WARN, EXIT_CRIT, EXIT_BLIND,
)

SCHED = Path(os.environ.get(
    "ECOSIM_SCHEDULER_DIR", Path.home() / "Documents/Projects/scheduler"))
MONITOR = Path(os.environ.get(
    "ECOSIM_WEIGHT_AUDIT",
    Path.home() / "Documents/Projects/realisateur/bin/weight-audit.sh"))


@register
class BoundarySensor(Sensor):
    name = "boundary"

    domain = Domain(
        describes="whether each participant is still inside the jurisdiction "
                  "of the monitor that governs its participation -- Ostrom's "
                  "design principle 4A, measured per participant",
        reads=("weight-audit.sh",) + tuple(
            f"schedule/{n}" for n in hosts.rotation_files()),
        hosts=("mandark",),
    )

    alphabet = Alphabet(
        Symbol("INSIDE", EXIT_OK,
               "the monitor that governs participation covers the file this "
               "participant lives in, so decay can still reach it"),
        Symbol("OUTSIDE", EXIT_CRIT,
               "enabled, but living in a file the monitor does not read -- its "
               "participation is now ungoverned and nothing will say so"),
        Symbol("NEVER_REVISITED", EXIT_WARN,
               "parked, and the monitor skips parked lines outright, so no "
               "mechanism will ever re-evaluate it"),
        Symbol("BLIND_NO_MONITOR", EXIT_BLIND,
               "the monitor itself could not be read, so its jurisdiction is "
               "unknown and no containment claim is possible"),
        Symbol("BLIND_NO_ROTATION", EXIT_BLIND,
               "a rotation file could not be read, so the participants inside "
               "it cannot be checked at all"),
    )

    def __init__(self, monitor_reader=None, conf_reader=None,
                 files=None):
        super().__init__()
        self._monitor = monitor_reader or self._read_monitor
        self._conf = conf_reader or self._read_conf
        self._files = files

    @staticmethod
    def _read_monitor():
        try:
            return MONITOR.read_text(), None
        except OSError as e:
            return None, str(e)

    @staticmethod
    def _read_conf(path):
        try:
            return Path(path).read_text(), None
        except OSError as e:
            return None, str(e)

    # Two ways the monitor has expressed its jurisdiction, in one morning.
    # The single-path form was hardcoded; realisateur replaced it with a glob
    # in f3cfd3a ("follow projects to every host's rotation, not just
    # mandark's") -- which is this project's issue #11 being fixed.
    _J_SINGLE = re.compile(r'PACED_CONF="[^"]*/([^/"]+)"')
    _J_GLOB = re.compile(r'PACED_CONFS?=|for\s+\w+\s+in\s+"?\$\w+"?/schedule/_paced')

    @staticmethod
    def jurisdiction(monitor_src):
        """(files, unknown). Read from the monitor's SOURCE, never assumed, so
        that widening the monitor RETIRES this finding instead of leaving a
        sensor reporting a problem after the problem is fixed.

        Returns `unknown=True` when neither known form is present. That
        distinction is the whole lesson of the first version, which shipped an
        hour before the monitor changed shape: an empty parse result and "the
        monitor genuinely reads nothing" were the same value, so a stale
        parser emitted CRIT for every project in the ecosystem. An empty set
        is not evidence of an empty jurisdiction.
        """
        src = monitor_src or ""
        single = {Path(m).name for m in BoundarySensor._J_SINGLE.findall(src)}
        if single:
            return single, False
        if BoundarySensor._J_GLOB.search(src):
            # The monitor enumerates every schedule/_paced*.conf it finds, so
            # its jurisdiction is "all rotation files" rather than a list.
            return {"*"}, False
        return set(), True

    @staticmethod
    def parse(text):
        out = {}
        for line in (text or "").splitlines():
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            f = s.split("|")
            if len(f) >= 3 and f[0] and f[1] in ("0", "1"):
                out[f[0]] = f[1] == "1"
        return out

    def probe(self):
        src, merr = self._monitor()
        if src is None:
            yield self.blind("BLIND_NO_MONITOR", "weight-audit.sh",
                             f"cannot read the governing monitor: {merr}")
            return
        covered, unknown = self.jurisdiction(src)
        if unknown:
            yield self.blind("BLIND_NO_MONITOR", "weight-audit.sh",
                             "monitor read, but its jurisdiction could not be "
                             "parsed in any known form -- no containment claim "
                             "is possible, and 'reads nothing' is NOT the "
                             "conclusion to draw")
            return

        # Derived, not listed: every rotation file that exists. A monitor
        # whose jurisdiction is one file leaves every participant in every
        # OTHER file ungoverned, and that is only visible if this sensor
        # looks at the files the monitor does NOT read.
        for fname, path in (self._files or hosts.rotation_files()).items():
            text, err = self._conf(path)
            if text is None:
                yield self.blind("BLIND_NO_ROTATION", fname, str(err))
                continue
            for name, enabled in sorted(self.parse(text).items()):
                if not enabled:
                    yield self.emit("NEVER_REVISITED", name,
                                    "parked; the monitor skips enabled=0",
                                    file=fname)
                elif "*" in covered or fname in covered:
                    yield self.emit("INSIDE", name,
                                    "monitor's jurisdiction covers this file",
                                    file=fname)
                else:
                    yield self.emit("OUTSIDE", name,
                                    f"lives in {fname}; monitor reads "
                                    f"{sorted(covered) or 'nothing'}",
                                    file=fname)

    def fixtures(self):
        def mk(monitor, m_conf, d_conf, merr=None, cerr=None):
            # Pinned filenames: these fixtures must not change meaning when
            # the estate gains a rotation file.
            files = {"_paced.conf": Path("/fixture/_paced.conf"),
                     "_paced.dexter.conf": Path("/fixture/_paced.dexter.conf")}
            s = BoundarySensor(
                monitor_reader=lambda: (None, merr) if merr else (monitor, None),
                conf_reader=lambda p: (None, cerr) if cerr else
                ((m_conf if "dexter" not in str(p) else d_conf), None),
                files=files)
            return lambda: list(s.probe())

        gov_mandark = 'PACED_CONF="$SCHED_ROOT/schedule/_paced.conf"\n'
        gov_both = gov_mandark + \
            'PACED_CONF="$SCHED_ROOT/schedule/_paced.dexter.conf"\n'

        gov_glob = ('declare -a PACED_CONFS=()\n'
                    'for _pc in "$SCHED_ROOT"/schedule/_paced.conf '
                    '"$SCHED_ROOT"/schedule/_paced.*.conf; do\n')
        return [
            # INSIDE + OUTSIDE + NEVER_REVISITED, the live shape
            mk(gov_mandark, "a|1|1|x\nparked|0|1|x\n", "moved|1|1|x\n"),
            # the finding must CLEAR when the monitor is pointed at both files
            mk(gov_both, "a|1|1|x\n", "moved|1|1|x\n"),
            # ...and when it globs every rotation file, which is the form
            # realisateur shipped in f3cfd3a. Nothing may be OUTSIDE here.
            (lambda f=mk(gov_glob, "a|1|1|x\n", "moved|1|1|x\n"): (
                lambda: [o for o in f()
                         if o.symbol.name != "OUTSIDE" or
                         (_ for _ in ()).throw(AssertionError(
                             "OUTSIDE emitted while the monitor globs every "
                             "rotation file -- the finding cannot be retired"))]
            ))(),
            # an unrecognised jurisdiction form must be BLIND, never OUTSIDE
            (lambda f=mk("# a monitor whose config shape we do not know\n",
                         "a|1|1|x\n", "moved|1|1|x\n"): (
                lambda: [o for o in f()
                         if o.symbol.name != "OUTSIDE" or
                         (_ for _ in ()).throw(AssertionError(
                             "OUTSIDE emitted from an unparseable monitor -- "
                             "an empty parse is not an empty jurisdiction"))]
            ))(),
            mk(None, "", "", merr="no such file"),      # BLIND_NO_MONITOR
            mk(gov_mandark, "", "", cerr="unreadable"),  # BLIND_NO_ROTATION
        ]
