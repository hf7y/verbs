#!/usr/bin/env python3
"""ecosim.rotation -- reference sensor, ported onto the contract.

Chosen as the reference because it is the sensor that committed the most
defects in its ad-hoc form: presence-vs-enabled keying, PARKED conflated with
ORPHANED, freeze state read from the wrong host, the rotation file itself read
from the wrong host, and a deliberate park reported as a seam orphan. Five of
the eight. Every one is now either impossible or has a symbol.
"""
from pathlib import Path
import json
import os
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from ecosim_sensor import (  # noqa: E402
    Alphabet, Domain, Sensor, Symbol, register, sh,
    EXIT_OK, EXIT_WARN, EXIT_CRIT, EXIT_BLIND,
)
import hosts  # noqa: E402

SCHED = Path(os.environ.get(
    "ECOSIM_SCHEDULER_DIR", Path.home() / "Documents/Projects/scheduler"))

# Projects dispatched from a second unix account whose crontab this ecosystem
# has never read. BLIND by construction is a constant in code, not a caveat in
# prose, so no run can forget it.
BLIND_BY_CONSTRUCTION = ("aedile", "vkv-inventory")

# The host set is DERIVED, not listed -- see lib/hosts.py for why, and for
# the measurement showing why it is not derived from the tailnet either.
#
# monkey joined on 2026-08-03 (realisateur/MONKEY.md) and this sensor did not
# learn about it for a day, because it carried two host names in a tuple. A
# project enabled ONLY on the new host read as "enabled nowhere", so the
# sensor reported the one project actually dispatching as PARKED -- an OK
# symbol, on the single question this sensor exists to answer. Nothing here
# needs editing for the next host; it needs a rotation file, and that is all.


@register
class RotationSensor(Sensor):
    name = "rotation"

    domain = Domain(
        describes="which host will dispatch each registered project, and "
                  "whether a dispatch freeze is in force where it matters",
        reads=tuple(f"schedule/{hosts.conf_for(h).name}"
                    for h in hosts.dispatch_hosts()) + ("schedule/FREEZE",),
        # Declared because the answer differs per host and reading one host's
        # copy while reporting on another is what went wrong three times.
        hosts=hosts.dispatch_hosts(),
    )

    alphabet = Alphabet(
        Symbol("IN_ONE", EXIT_OK,
               "enabled on exactly one host, which is the healthy steady state"),
        Symbol("PARKED_BEFORE", EXIT_OK,
               "enabled nowhere, and already so before this run's baseline -- "
               "deliberate, not lost"),
        Symbol("FROZEN", EXIT_OK,
               "enabled, but the dispatch freeze is present ON THE HOST that "
               "would dispatch it, so it will not run"),
        Symbol("FROZEN_EXEMPT", EXIT_WARN,
               "freeze is in force on that host but this project is exempt "
               "there, so it alone may still dispatch"),
        Symbol("IN_BOTH", EXIT_WARN,
               "enabled on both hosts at once -- would dispatch twice, subject "
               "to whatever freeze is actually in force"),
        Symbol("ORPHANED", EXIT_CRIT,
               "was enabled at baseline and is now enabled nowhere, with no "
               "commit explaining it -- runs nowhere and emits nothing"),
        Symbol("PARKED_DURING", EXIT_OK,
               "enabled nowhere, and the commit that disabled it says so "
               "deliberately -- a park, not a seam failure"),
        Symbol("FREEZE_NOT_PROPAGATED", EXIT_CRIT,
               "a freeze is engaged here but ABSENT on the host that "
               "dispatches this project, so the abort handle does not reach it"),
        Symbol("BLIND_CONF_UNREADABLE", EXIT_BLIND,
               "a rotation file could not be read, so no claim about the "
               "projects in it is possible"),
        Symbol("BLIND_HOST_UNREADABLE", EXIT_BLIND,
               "the dispatching host's own copy could not be read, so this "
               "sensor cannot say what that host will actually do"),
        Symbol("BLIND_NO_BASELINE", EXIT_BLIND,
               "no run baseline is recorded, so a project enabled nowhere "
               "cannot be told from one that was parked before the run"),
        Symbol("BLIND_BY_CONSTRUCTION", EXIT_BLIND,
               "dispatched from an account whose crontab has never been read; "
               "the enabled bit here is not its dispatch state"),
        Symbol("BLIND_NO_FREEZE_AUTHORITY", EXIT_BLIND,
               "the recorded freeze-authority host is not among the hosts "
               "this run actually dispatches to, so no freeze comparison "
               "against it is possible"),
    )

    # -- probes are injectable so every symbol has a fixture ---------------
    # Read from ECOSIM_STATE_DIR if a baseline has been captured there, else
    # from the copy carried beside this tree. capture_baseline() WRITES, so it
    # always targets the state dir: this file now ships inside the immutable
    # verb build, where writing back into the tree is writing into something
    # the next build replaces.
    _CARRIED = Path(__file__).resolve().parent.parent.parent / \
        "sensors" / "rotation-baseline-v2.json"
    _STATE = Path(os.environ.get("ECOSIM_STATE_DIR", str(_CARRIED.parent)))
    BASELINE = _STATE / "rotation-baseline-v2.json"
    if not BASELINE.exists():
        BASELINE = _CARRIED

    # Explicit "there is no baseline" for fixtures. `baseline=None` means
    # "load the persisted one", so a fixture passing None would silently start
    # reading production the moment a baseline is captured -- the third time
    # this pattern has bitten, and the reason it now has a sentinel instead of
    # a convention.
    NONE = object()

    def __init__(self, conf_reader=None, host_reader=None, freeze_reader=None,
                 baseline=None, why_reader=None, host_list=None,
                 conf_path=None, freeze_authority_reader=None):
        super().__init__()
        # Both injectable so fixtures are hermetic. Without `conf_path` a
        # fixture would resolve paths against the LIVE scheduler checkout, so
        # deleting `_paced.monkey.conf` in production would silently collapse
        # two fixture hosts onto one file and change what the fixture proves.
        self._hosts = tuple(host_list) if host_list else hosts.dispatch_hosts()
        self._conf_for = conf_path or hosts.conf_for
        # ONE source for "who holds freeze authority" -- lib/hosts.py -- and
        # this is the only place rotation asks it. Injectable so a fixture
        # can pin the unresolvable case without needing a real topology that
        # has dropped its authority host (hf7y/ecosim#32).
        self._freeze_authority = freeze_authority_reader or hosts.freeze_authority
        # Load the persisted baseline when none is injected. Without this the
        # live path passed baseline=None, so `was_enabled` was None and EVERY
        # unenabled project reported PARKED_BEFORE -- meaning ORPHANED and
        # PARKED_DURING were reachable in fixtures and UNREACHABLE IN
        # PRODUCTION. H-M6's headline symbol among them. A project dropped
        # from both rotation files mid-run would have read green.
        if baseline is self.NONE:
            baseline = None
        elif baseline is None:
            try:
                baseline = json.loads(self.BASELINE.read_text())["enabled"]
            except (OSError, ValueError, KeyError):
                baseline = None
        self._conf = conf_reader or self._read_conf
        self._host = host_reader or self._read_host_conf
        self._freeze = freeze_reader or self._read_freeze
        self._baseline = baseline
        self._why = why_reader or self._read_why

    # -- default readers ---------------------------------------------------
    @staticmethod
    def _read_conf(path):
        try:
            return Path(path).read_text(), None
        except OSError as e:
            return None, str(e)

    @classmethod
    def capture_baseline(cls):
        """Record which projects are enabled anywhere, as the run's reference.

        Must be taken BEFORE a run: afterwards the pre-state is unrecoverable
        except from git, and only if every change was committed.
        """
        s = cls()
        seen = {}
        for host in s._hosts:
            txt = None
            if not hosts.is_local(host):
                txt, _ = s._host(host)
            if txt is None:
                txt = cls._read_conf(s._conf_for(host))[0]
            parsed, _ = cls.parse(txt)
            for name, on in parsed.items():
                seen[name] = seen.get(name, False) or on
        enabled = sorted(n for n, on in seen.items() if on)
        cls._STATE.mkdir(parents=True, exist_ok=True)
        (cls._STATE / "rotation-baseline-v2.json").write_text(json.dumps(
            {"captured": __import__("time").strftime("%Y-%m-%dT%H:%M:%S%z"),
             "enabled": enabled}, indent=1) + "\n")
        return enabled

    # Where a host keeps its scheduler checkout. NOT one path: dexter has it
    # at ~/scheduler, and on monkey the HANDS account has no clones at all --
    # every checkout belongs to a PROJECT user (/home/ecosim/Documents/...),
    # which is that host's whole design. A single hardcoded path made monkey
    # permanently unreadable and produced a CRIT about it; see _read_freeze.
    #
    # Declared limit: this picks the FIRST match, so on a host with several
    # project users it reads one project's checkout of a file they all share
    # from git. That is sound for the rotation and freeze files and would not
    # be for anything a single account can modify locally.
    # Emits "<path> <reader>" where reader is `cat` or `sudo -n cat`.
    #
    # The sudo arm is not belt-and-braces. On monkey the project users' homes
    # are 0700 BY DESIGN, and the account we log in as owns no checkout, so a
    # plain read finds nothing at all. Reading some other clone instead --
    # zach's, or mandark's -- would answer a different question than "what
    # will this host dispatch", which is the one defect this sensor has
    # committed most often. So it reads the dispatching account's copy, and
    # says BLIND when it cannot.
    # THE GLOB MUST EXPAND UNDER SUDO, not before it. `/home/*/Documents/...`
    # is expanded by the CALLING shell, which on monkey cannot traverse the
    # 0700 project homes -- so the pattern stays literal and every test on it
    # fails. `sudo -n sh -c '<glob>'` is the difference between finding the
    # checkout and concluding there is none. (The same mistake, made by hand
    # at a prompt, is what first suggested monkey had no checkouts at all.)
    # The probe lives in lib/hosts.py so rotation, sync, relocation and quota
    # all get the SAME answer about where a host keeps its scheduler. Four
    # sensors independently guessing that path is how three of them stayed
    # blind to monkey after the fourth had been fixed.

    @classmethod
    def _read_host_conf(cls, host):
        # The FILE NAME is per-host. This read dexter's name on every host
        # until monkey arrived, at which point asking monkey for its rotation
        # would have handed back dexter's -- the "read one host's copy while
        # reporting on another" defect, committed by the reader this time.
        conf = hosts.conf_for(host).name
        found, why = hosts.remote_scheduler(host)
        if found is None:
            return None, why
        root, reader = found
        return hosts.ssh_read(host, f"{reader} {root}/schedule/{conf}")

    @classmethod
    def _read_freeze(cls, host):
        if hosts.is_local(host):
            p = SCHED / "schedule/FREEZE"
            return (p.read_text() if p.is_file() else ""), None
        found, why = hosts.remote_scheduler(host)
        if found is None:
            return None, why
        root, reader = found
        # THE BUG THIS SHAPE EXISTS TO KILL. The previous form was
        #     cat ~/scheduler/schedule/FREEZE 2>/dev/null || true
        # which exits 0 and prints nothing when the path does not exist. On
        # monkey the path never existed, so "could not read the freeze" became
        # "there is no freeze", and the sensor emitted
        #     CRIT FREEZE_NOT_PROPAGATED ... freeze engaged on mandark,
        #     absent on monkey
        # about a freeze that was neither absent nor unpropagated. A CRIT
        # invented out of a swallowed error is worse than the silence it
        # replaced, and it is the exact defect this namespace is named for.
        #
        # So: an ABSENT file says so in-band, and anything else is an error
        # that becomes BLIND upstream. Empty output is no longer overloaded.
        test = "sudo -n test" if reader.startswith("sudo") else "test"
        out, err = hosts.ssh_read(
            host, f'if {test} -f {root}/schedule/FREEZE; then '
                  f'  {reader} {root}/schedule/FREEZE; '
                  f'else echo __NO_FREEZE_FILE__; fi')
        if out is None:
            return None, err
        return ("" if out.strip() == "__NO_FREEZE_FILE__" else out), None

    @staticmethod
    def _read_why(name):
        rc, out = sh("git", "-C", str(SCHED), "log", "-1", "--format=%s",
                     "--", "schedule/_paced.dexter.conf")
        return out if rc == 0 else ""

    # -- parsing -----------------------------------------------------------
    @staticmethod
    def parse(text):
        """name -> enabled. Handles both live arities (4-field and the
        3-field chezz-sweep form). An unparseable line is returned as a
        problem, never silently skipped: skipping is how a rotation file
        loses a project with nothing saying so."""
        entries, problems = {}, []
        for n, line in enumerate((text or "").splitlines(), 1):
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            f = s.split("|")
            if len(f) < 3 or not f[0] or f[1] not in ("0", "1"):
                problems.append(f"line {n}: {line.strip()[:48]}")
                continue
            entries[f[0]] = f[1] == "1"
        return entries, problems

    @staticmethod
    def exempt_set(freeze_text):
        """`EXEMPT: <project>[@<host>]`. The bare form means every host.

        Written against the format as it stands; the @host form landed 21
        minutes after the previous parser shipped, which is why the fixture
        below pins both forms.
        """
        out = set()
        for line in (freeze_text or "").splitlines():
            if line.strip().startswith("EXEMPT:"):
                for tok in line.split(":", 1)[1].split():
                    nm, _, hst = tok.partition("@")
                    out.add((nm, hst or None))
        return out

    # -- the probe ---------------------------------------------------------
    def probe(self):
        texts, first_err = {}, None
        for host in self._hosts:
            txt, err = self._conf(self._conf_for(host))
            texts[host] = txt
            if txt is None and first_err is None:
                first_err = err
        if any(t is None for t in texts.values()):
            yield self.blind("BLIND_CONF_UNREADABLE", "rotation-files",
                             first_err or "unreadable")
            return
        enabled = {}
        for host in self._hosts:
            enabled[host], probs = self.parse(texts[host])
            for p in probs:
                yield self.blind("BLIND_CONF_UNREADABLE", "conf-line", p)

        # The dispatching host's OWN copy is authoritative for that host.
        # A host we cannot reach falls back to mandark's checkout of its file,
        # which is what SHOULD be there rather than what is -- so the run is
        # marked non-authoritative and says which host it could not ask.
        authoritative = True
        for host in (h for h in self._hosts if not hosts.is_local(h)):
            host_text, host_err = self._host(host)
            if host_text is None:
                yield self.blind("BLIND_HOST_UNREADABLE", host,
                                 f"cannot read {host}'s copy: {host_err}",
                                 host=host)
                authoritative = False
            else:
                enabled[host], _ = self.parse(host_text)

        freeze_cache = {}
        for host in self._hosts:
            txt, err = self._freeze(host)
            freeze_cache[host] = (txt, err)

        # ONE call, ONE source (lib/hosts.py), checked against the host set
        # this run actually resolved -- not trusted blind. See
        # BLIND_NO_FREEZE_AUTHORITY below for what happens when it drifts.
        authority_host, authority_err = self._freeze_authority(self._hosts)

        was_enabled = set(self._baseline) if self._baseline is not None else None
        # (freeze_cache is populated above; IN_BOTH needs it too)

        every_name = set()
        for host in self._hosts:
            every_name |= set(enabled[host])
        for name in sorted(every_name):
            if name in BLIND_BY_CONSTRUCTION:
                yield self.blind("BLIND_BY_CONSTRUCTION", name,
                                 "svc-vaporwave crontab never read")
                continue
            on = [h for h in self._hosts if enabled[h].get(name, False)]
            if len(on) > 1:
                # "Dispatches twice" and "would dispatch twice once the freeze
                # lifts" are different PRESENT-TENSE facts. The config hazard
                # is real either way and keeps its symbol, but a detail that
                # asserts the first while a freeze holds one side is wrong in
                # the direction that causes an unnecessary scramble. Fixed in
                # the legacy sensor last night and not carried across -- the
                # cost of two harnesses, recorded rather than excused.
                # Only the hosts it is actually enabled ON can hold it back,
                # so `held` is scoped to those. With three hosts, a freeze on
                # an unrelated third host is not a reprieve.
                held = [h for h in on if (freeze_cache[h][0] or "").strip()]
                where = ",".join(on)
                yield self.emit(
                    "IN_BOTH", name,
                    (f"enabled on {len(on)} hosts ({where}) -- would dispatch "
                     f"{len(on)}x once the freeze lifts (held on: "
                     f"{','.join(held)})") if held
                    else (f"enabled on {len(on)} hosts ({where}) -- "
                          f"dispatches {len(on)}x"),
                    hosts=len(on), on=where, authoritative=authoritative,
                    frozen_on=",".join(held) or "none")
                continue
            if not on:
                if was_enabled is None:
                    # Two world-states -- "parked before the run" and "lost
                    # during it" -- and no baseline to separate them. Guessing
                    # the benign one is what made ORPHANED unreachable.
                    yield self.blind("BLIND_NO_BASELINE", name,
                                     "enabled nowhere, and no baseline says "
                                     "whether that is new")
                elif name not in was_enabled:
                    yield self.emit("PARKED_BEFORE", name,
                                    "enabled nowhere, and already so at baseline")
                else:
                    why = self._why(name)
                    if why and re.search(r"\bpark|disable|stop dispatch", why, re.I):
                        yield self.emit("PARKED_DURING", name,
                                        f"deliberate: {why[:48]}")
                    else:
                        yield self.emit("ORPHANED", name,
                                        "was enabled at baseline, now nowhere")
                continue

            host = on[0]
            if authority_host is None:
                # Cannot be determined -- not guessed, not skipped silently.
                # This is the shape hf7y/ecosim#32 crashed instead of taking:
                # `freeze_cache["mandark"]` assumed the authority host was
                # always in `self._hosts` and blew up the moment it wasn't.
                yield self.blind("BLIND_NO_FREEZE_AUTHORITY", name,
                                 authority_err, host=host)
                continue
            # "Engaged" and "in force where it matters" are two different
            # facts. The freeze is authored on `authority_host` and only
            # binds a host once that host holds it. Comparing a host's
            # freeze against ITSELF -- the first version of this block --
            # made FREEZE_NOT_PROPAGATED unreachable, and the coverage gate
            # caught it on the first run. That is the gate paying for
            # itself: the identical bug shipped undetected in the ad-hoc
            # sensor and was only found hours later by a live incident.
            here_txt, here_err = freeze_cache[authority_host]
            there_txt, there_err = freeze_cache[host]
            if there_err is not None:
                yield self.blind("BLIND_HOST_UNREADABLE", name,
                                 f"cannot read {host}'s freeze state: {there_err}",
                                 host=host)
                continue
            engaged_here = bool((here_txt or "").strip())
            in_force_there = bool((there_txt or "").strip())
            if not engaged_here and not in_force_there:
                yield self.emit("IN_ONE", name, "enabled on one host", host=host)
            elif engaged_here and not in_force_there:
                yield self.emit("FREEZE_NOT_PROPAGATED", name,
                                f"freeze engaged on {authority_host}, absent "
                                f"on {host}", host=host)
            else:
                ex = self.exempt_set(there_txt)
                if (name, host) in ex or (name, None) in ex:
                    yield self.emit("FROZEN_EXEMPT", name,
                                    "exempt on its dispatching host", host=host)
                else:
                    yield self.emit("FROZEN", name, "refused at dispatch",
                                    host=host)

    # -- fixtures: every symbol must fire ---------------------------------
    def fixtures(self):
        # Readers are keyed BY HOST, not by "is 'dexter' in the path". The
        # substring form silently handed monkey's read back mandark's text
        # the moment a third host existed, which is the same class of defect
        # as the one being fixed -- so the fixtures pin the host explicitly.
        # A pinned host set and synthetic paths: these fixtures must not
        # change meaning when the estate gains or loses a host.
        FH = ("mandark", "dexter", "monkey")
        def fpath(h):
            return Path(f"/fixture/_paced.{h}.conf")

        def by_host(texts, default=""):
            def read(p):
                host = str(p).rsplit("_paced.", 1)[-1][:-5]
                return texts.get(host, default), None
            return read

        def mk(m, d, k="", dhost=None, freeze="", baseline=None, why="",
               host_err=None, freeze_err=None, conf_err=None):
            texts = {"mandark": m, "dexter": d, "monkey": k}
            live = dict(texts, dexter=dhost if dhost is not None else d)
            reader = by_host(texts)
            s = RotationSensor(
                conf_reader=lambda p: (None, conf_err) if conf_err
                else reader(p),
                host_reader=lambda h: (None, host_err) if host_err
                else (live.get(h, ""), None),
                freeze_reader=lambda h: (None, freeze_err) if freeze_err
                else (freeze, None),
                baseline=baseline,
                why_reader=lambda n: why,
                host_list=FH, conf_path=fpath)
            return lambda: list(s.probe())

        return [
            # IN_ONE, IN_BOTH, PARKED_BEFORE, BLIND_BY_CONSTRUCTION
            mk("a|1|1|x\nb|1|1|x\nc|0|1|x\naedile|0|x\n",
               "b|1|1|x\n", baseline={"a", "b"}),
            # no baseline at all -> BLIND, never the benign guess
            mk("a|0|1|x\n", "a|0|1|x\n", baseline=RotationSensor.NONE, why=""),
            # ORPHANED: enabled at baseline, now nowhere, no explaining commit
            mk("a|0|1|x\n", "a|0|1|x\n", baseline={"a"}, why="refactor loader"),
            # PARKED_DURING: same state, explained
            mk("a|0|1|x\n", "a|0|1|x\n", baseline={"a"},
               why="_paced.dexter.conf: park a and b (by hand)"),
            # FROZEN + FROZEN_EXEMPT, host-scoped
            mk("a|1|1|x\nb|1|1|x\n", "", freeze="frozen\nEXEMPT: b@mandark\n",
               baseline={"a", "b"}),
            # FREEZE_NOT_PROPAGATED: engaged on the freeze authority (monkey,
            # the real hosts.FREEZE_AUTHORITY -- these fixtures inject no
            # freeze_authority_reader, so they exercise the real accessor),
            # absent on mandark, which is where "a" actually dispatches.
            # freeze_reader is per-host here, which is the whole point.
            (lambda s=RotationSensor(
                conf_reader=by_host({"mandark": "a|1|1|x\n",
                                     "dexter": "z|1|1|x\n", "monkey": ""}),
                host_reader=lambda h: (("z|1|1|x\n" if h == "dexter" else ""),
                                       None),
                freeze_reader=lambda h: (("frozen\n" if h == "monkey" else ""), None),
                baseline={"a", "z"}, why_reader=lambda n: "",
                host_list=FH, conf_path=fpath):
             lambda: list(s.probe()))(),
            # BLIND_HOST_UNREADABLE
            mk("a|1|1|x\n", "a|0|1|x\n", host_err="ssh failed", baseline={"a"}),
            # BLIND_CONF_UNREADABLE
            mk("", "", conf_err="no such file"),
            # THE MONKEY REGRESSION, pinned. A project enabled ONLY on the
            # third host. While HOST_CONF held two names this read as
            # "enabled nowhere" and emitted PARKED_DURING -- an OK symbol,
            # on the one project that was in fact dispatching every night.
            # It must read IN_ONE host=monkey.
            mk("", "", k="ecosim|1|1|x\n", baseline={"ecosim"}),
            # BLIND_NO_FREEZE_AUTHORITY, pinned to hf7y/ecosim#32's own
            # shape: a host set that does not include the freeze authority
            # host at all (mirroring `_paced.mandark.conf` vanishing from a
            # real `dispatch_hosts()`), and a name enabled on exactly one of
            # the hosts that remain -- the common case, and the one that
            # crashed with `KeyError: 'mandark'` before this fix. No
            # freeze_authority_reader is injected, so this exercises the
            # real hosts.freeze_authority() against a host set it genuinely
            # is not part of, not a mocked-out failure.
            (lambda s=RotationSensor(
                conf_reader=by_host({"mandark": "a|1|1|x\n", "dexter": ""}),
                host_reader=lambda h: (
                    {"mandark": "a|1|1|x\n", "dexter": ""}.get(h, ""), None),
                freeze_reader=lambda h: ("", None),
                baseline={"a"}, why_reader=lambda n: "",
                host_list=("mandark", "dexter"), conf_path=fpath):
             lambda: list(s.probe()))(),
        ]
