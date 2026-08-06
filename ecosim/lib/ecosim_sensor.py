#!/usr/bin/env python3
"""ecosim_sensor -- a sensor library with contracts, a namespace, and a
pipeable line protocol.

WHY THIS EXISTS
---------------
Nine ad-hoc sensors were written in one night (`bin/migration-watch.py`) and
they committed EIGHT distinct two-states-one-symbol collapses between them --
inside the instrument built to detect that class of fault. Every one was found
by writing a fixture that made a symbol fire; none by designing or reviewing.
The lesson is not "be more careful". It is that the properties a sensor must
have are checkable mechanically, and prose asking for them decays.

So the contract below is enforced by the library rather than requested by a
comment:

  1. ALPHABET CLOSURE. A sensor declares its symbols. Emitting an undeclared
     symbol raises. (Caught nothing before, because nothing was declared.)
  2. COVERAGE. `selftest` records which symbols actually fired. A declared
     symbol that never fires in any fixture is a CONTRACT VIOLATION, not a
     note. This mechanizes "every sensor needs a negative test", which
     realisateur's spec #1 states as a rule -- and which the author of the
     nine sensors believed he had followed, twice, wrongly.
  3. DOMAIN. A sensor declares what it reads. If it could not read the domain
     it must emit a BLIND symbol; it may never assert over an unread domain.
     Three of the eight defects were exactly this (freeze read from the wrong
     host, rotation read from the wrong host, a state read where a rate was
     needed).
  4. BLIND IS NEVER CLEAN. A BLIND observation forces a nonzero exit, always.

PRIOR ART, deliberately inherited rather than reinvented
--------------------------------------------------------
THE THEORY IS ASHBY'S, AND NOT AT SECOND HAND. bibliothecaire sourced this
against the primary text on 2026-07-29 (`briefs/sensor-variety.md`): the
sensor-side reading is not an extension of the Law of Requisite Variety, it is
Part Two of it. A transducer that maps two distinct messages onto one output
has destroyed a distinction and "the decoder that might distinguish between
them does not exist" (S.8/6); the bound is stated on the output alphabet
directly -- "if the original transducer is not to lose distinctions it must
have at least as many output values as the input has distinct values" (S.8/9).

The name is Ashby's: LOSS OF DISTINCTIONS IN A TRANSDUCER, or equivalently A
CODER THAT CANNOT BE INVERTED. His test is the one this library enforces:
**can the original message be recovered from the output alone?** That is why
`Symbol.meaning` is mandatory -- two symbols whose meanings can be swapped
without either becoming false are one symbol, and an alphabet that fails the
inversion test cannot be repaired downstream. The right sentence when it fails
is "this coder is not invertible", not "the sensor is wrong".

The one part that is NOT prior art, per the same brief, is the corollary that
correlated blind spots make added sensors worthless -- Ashby treats one
transducer at a time. That half is ecosim's own and is to be ARGUED, not cited.

The Monitoring Plugins / Nagios plugin contract (monitoring-plugins.org/doc/
guidelines.html) has had a fourth exit code since the 1990s: 0 OK, 1 WARNING,
2 CRITICAL, **3 UNKNOWN** -- for "low-level failures internal to the plugin
that prevent it from performing the specified operation". That is BLIND, under
another name, thirty years earlier. This library adopts those codes exactly,
so its output is consumable by any tool that already speaks that contract, and
so the claim "adding an output symbol for I-could-not-look is novel" is
correctly retired. Also inherited from that spec: status first on the line,
machine-readable payload separated from human text by `|`, never hang, and
help/usage exits UNKNOWN rather than OK.

The key=value payload is logfmt (Heroku), chosen over JSON for the wire format
because it greps and cuts without a parser while staying machine-readable. The
JSONL event log remains the archival record; logfmt is the pipe.

LINE PROTOCOL
-------------
    STATUS  namespace.sensor.SYMBOL  k=v k=v ... | human text

    OK ecosim.rotation.IN_ONE subject=senechal host=mandark | enabled on one host
    WARN ecosim.rotation.IN_BOTH subject=crt hosts=2 | would dispatch twice
    BLIND ecosim.rotation.BLIND_HOST_UNREADABLE subject=crt host=dexter | unreadable

Single-space delimited on purpose. Aligned columns read better and break
`cut -d' ' -f2`, and a protocol whose own docstring promises cuttability it
does not deliver is the disease this library treats. Verified, not asserted:

    ecosim-sensor run | grep '^BLIND'                     # what could not be read
    ecosim-sensor run | cut -d' ' -f2 | sort | uniq -c    # symbol histogram
    ecosim-sensor run | awk '$1!="OK"'                    # everything not fine
    ecosim-sensor run | head -3                           # SIGPIPE-clean

The symbol is fully namespaced, so two sensors can never collide in one
stream and `grep ecosim.rotation.` selects one sensor out of a merged feed.
"""
from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Callable, Iterable, Iterator, Sequence

# ---------------------------------------------------------------- exit codes
# Inherited verbatim from the Monitoring Plugins contract.
EXIT_OK, EXIT_WARN, EXIT_CRIT, EXIT_BLIND = 0, 1, 2, 3

STATUS_BY_EXIT = {EXIT_OK: "OK", EXIT_WARN: "WARN",
                  EXIT_CRIT: "CRIT", EXIT_BLIND: "BLIND"}

NAMESPACE = "ecosim"
_NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")
_SYMBOL_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")


class ContractViolation(Exception):
    """Raised when a sensor breaks its own declared contract.

    Deliberately an exception and not a log line: a sensor that violates its
    contract is not producing degraded data, it is producing data of unknown
    meaning, and that must stop the run rather than colour it.
    """


# -------------------------------------------------------------------- symbol
@dataclass(frozen=True)
class Symbol:
    """One distinguishable world-state a sensor can report.

    `meaning` is required and is not decoration: the entire failure mode this
    library exists to prevent is two world-states sharing one symbol, and the
    cheapest moment to notice that is while writing down what the symbol
    means. If two symbols' meanings can be swapped without either becoming
    false, they are one symbol.
    """
    name: str
    severity: int                 # EXIT_OK / EXIT_WARN / EXIT_CRIT / EXIT_BLIND
    meaning: str

    def __post_init__(self):
        if not _SYMBOL_RE.match(self.name):
            raise ContractViolation(
                f"symbol {self.name!r} must be UPPER_SNAKE_CASE")
        if self.severity not in STATUS_BY_EXIT:
            raise ContractViolation(
                f"symbol {self.name}: severity {self.severity} is not one of "
                f"{sorted(STATUS_BY_EXIT)}")
        if not self.meaning or len(self.meaning) < 12:
            raise ContractViolation(
                f"symbol {self.name}: needs a real `meaning`, got {self.meaning!r}. "
                "A symbol nobody can state the meaning of is how two "
                "world-states end up sharing one.")

    @property
    def is_blind(self) -> bool:
        return self.severity == EXIT_BLIND

    @property
    def status(self) -> str:
        return STATUS_BY_EXIT[self.severity]


class Alphabet:
    """A sensor's complete, closed set of output symbols.

    Closure is the point. `migration-watch.py` shipped
    BLIND_CONF_DIR_UNREADABLE declared and UNREACHABLE -- an audit over a
    vanished directory would have exited clean -- and shipped RUN_PUSHED
    declared and never emitted, collapsing the one pair its own spec said must
    never collapse. Both are impossible here: an undeclared symbol raises at
    emit time, and an unfired declared symbol fails the coverage gate.
    """

    def __init__(self, *symbols: Symbol):
        self._by_name: dict[str, Symbol] = {}
        for s in symbols:
            if s.name in self._by_name:
                raise ContractViolation(f"duplicate symbol {s.name}")
            self._by_name[s.name] = s
        if not any(s.is_blind for s in symbols):
            raise ContractViolation(
                "an alphabet with no BLIND symbol cannot report that it failed "
                "to read its domain, so it will report clean instead -- which "
                "is the 19/19 failure exactly")

    def __contains__(self, name: str) -> bool:
        return name in self._by_name

    def __iter__(self) -> Iterator[Symbol]:
        return iter(self._by_name.values())

    def __len__(self) -> int:
        return len(self._by_name)

    def get(self, name: str) -> Symbol:
        try:
            return self._by_name[name]
        except KeyError:
            raise ContractViolation(
                f"symbol {name!r} is not in this sensor's declared alphabet "
                f"({', '.join(sorted(self._by_name))}). Declare it or do not "
                f"emit it -- an undeclared symbol is a world-state nobody "
                f"agreed the sensor could distinguish.") from None

    @property
    def names(self) -> list[str]:
        return sorted(self._by_name)


# --------------------------------------------------------------- observation
@dataclass
class Observation:
    sensor: str
    symbol: Symbol
    subject: str
    fields: dict = field(default_factory=dict)
    text: str = ""
    ts: str = ""

    def __post_init__(self):
        if not self.ts:
            self.ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")

    @property
    def qualified(self) -> str:
        return f"{NAMESPACE}.{self.sensor}.{self.symbol.name}"

    def to_line(self) -> str:
        """The wire format. Status first so `grep '^BLIND'` works."""
        kv = " ".join(f"{k}={_logfmt(v)}" for k, v in
                      [("subject", self.subject)] + sorted(self.fields.items()))
        # SINGLE space, not an aligned column. Padding made the line pretty
        # and made `cut -d' ' -f2` return empty -- the docstring promised
        # cuttability the bytes did not deliver, which is the same disease
        # this library treats: a contract stated in prose and contradicted by
        # the implementation. Humans lose a little alignment; pipes work.
        line = f"{self.symbol.status} {self.qualified} {kv}"
        return f"{line} | {self.text}" if self.text else line

    def to_json(self) -> str:
        return json.dumps({"ts": self.ts, "sensor": self.sensor,
                           "symbol": self.symbol.name,
                           "status": self.symbol.status,
                           "subject": self.subject, "text": self.text,
                           **self.fields})


def _logfmt(v) -> str:
    s = str(v)
    return f'"{s}"' if (not s or re.search(r"[\s\"=|]", s)) else s


# -------------------------------------------------------------------- sensor
@dataclass(frozen=True)
class Domain:
    """What a sensor reads, declared so it can be checked rather than assumed.

    `hosts` is the field that would have caught three of the eight defects:
    a sensor that declares it reads dexter and then reads mandark's copy of a
    file is making a claim about a domain it did not read.
    """
    describes: str
    reads: tuple = ()
    hosts: tuple = ("localhost",)


class Sensor:
    """Base class. Subclasses declare `name`, `alphabet`, `domain`, and
    implement `probe()` and `fixtures()`.

    `probe()` yields Observations. `fixtures()` yields callables that each
    drive the sensor with known-bad or known-good input; between them they
    MUST make every declared symbol fire, and the coverage gate enforces it.
    """

    name: str = ""
    alphabet: Alphabet
    domain: Domain

    def __init__(self):
        if not _NAME_RE.match(self.name or ""):
            raise ContractViolation(
                f"sensor name {self.name!r} must be lower_snake_case")
        if not isinstance(getattr(self, "alphabet", None), Alphabet):
            raise ContractViolation(f"{self.name}: no declared Alphabet")
        if not isinstance(getattr(self, "domain", None), Domain):
            raise ContractViolation(f"{self.name}: no declared Domain")

    # -- emission ---------------------------------------------------------
    def emit(self, symbol: str, subject: str, text: str = "", **fields
             ) -> Observation:
        return Observation(self.name, self.alphabet.get(symbol), subject,
                           fields, text)

    def blind(self, symbol: str, subject: str, text: str = "", **fields
              ) -> Observation:
        obs = self.emit(symbol, subject, text, **fields)
        if not obs.symbol.is_blind:
            raise ContractViolation(
                f"{self.name}.{symbol} was emitted via blind() but is declared "
                f"severity {obs.symbol.severity}. A BLIND reading that does not "
                f"carry BLIND severity will be aggregated as clean.")
        return obs

    # -- to implement -----------------------------------------------------
    def probe(self) -> Iterable[Observation]:
        raise NotImplementedError

    def fixtures(self) -> Iterable[Callable[[], Iterable[Observation]]]:
        raise NotImplementedError

    # -- the coverage gate ------------------------------------------------
    def selftest(self) -> tuple[set, list]:
        """Run every fixture; return (symbols_seen, problems).

        This is the mechanized form of "a sensor that has never been observed
        to say NO has not been shown to be able to."
        """
        seen, problems = set(), []
        for i, fx in enumerate(self.fixtures()):
            try:
                for obs in fx() or ():
                    seen.add(obs.symbol.name)
            except ContractViolation:
                raise
            except Exception as e:                     # noqa: BLE001
                problems.append(f"{self.name}: fixture {i} raised {e!r}")
        missing = set(self.alphabet.names) - seen
        if missing:
            problems.append(
                f"{self.name}: {len(missing)} declared symbol(s) never fired in "
                f"any fixture: {', '.join(sorted(missing))}. Either the symbol "
                f"is unreachable in code, or it has never been tested; both "
                f"are how a check that cannot fail passes.")
        return seen, problems


# ------------------------------------------------------------------ registry
class Registry:
    """The `ecosim.*` namespace. One place that knows every sensor."""

    def __init__(self):
        self._sensors: dict[str, Sensor] = {}

    def register(self, sensor: Sensor) -> Sensor:
        if sensor.name in self._sensors:
            raise ContractViolation(f"sensor {sensor.name} already registered")
        self._sensors[sensor.name] = sensor
        return sensor

    def __iter__(self) -> Iterator[Sensor]:
        return iter(self._sensors.values())

    def get(self, name: str) -> Sensor:
        if name not in self._sensors:
            raise ContractViolation(
                f"no sensor {name!r} in the {NAMESPACE} namespace "
                f"({', '.join(sorted(self._sensors))})")
        return self._sensors[name]

    @property
    def names(self) -> list[str]:
        return sorted(self._sensors)


REGISTRY = Registry()


def register(sensor_cls):
    """Class decorator: `@register` puts a sensor in the ecosim namespace."""
    REGISTRY.register(sensor_cls())
    return sensor_cls


# -------------------------------------------------------------------- runner
def run(sensors: Sequence[Sensor], out=sys.stdout, jsonl_path=None) -> int:
    """Run sensors, write the line protocol, return the worst exit code.

    Worst-wins aggregation with BLIND (3) beating CRIT (2) is deliberate and
    is the Monitoring Plugins convention: a run that could not read part of
    its domain has not established that the rest is fine.
    """
    worst = EXIT_OK
    records = []
    for s in sensors:
        try:
            observations = list(s.probe())
        except ContractViolation:
            raise
        except Exception as e:                          # noqa: BLE001
            # A sensor that crashes has not observed a clean world.
            print(f"BLIND {NAMESPACE}.{s.name}.PROBE_RAISED "
                  f"subject={s.name} | {type(e).__name__}: {e}", file=out)
            worst = _worse(worst, EXIT_BLIND)
            continue
        for obs in observations:
            print(obs.to_line(), file=out)
            records.append(obs)
            worst = _worse(worst, obs.symbol.severity)
    if jsonl_path:
        with open(jsonl_path, "a") as fh:
            for obs in records:
                fh.write(obs.to_json() + "\n")
    return worst


def _worse(a: int, b: int) -> int:
    order = {EXIT_OK: 0, EXIT_WARN: 1, EXIT_CRIT: 2, EXIT_BLIND: 3}
    return a if order[a] >= order[b] else b


def selftest_all(sensors: Sequence[Sensor], out=sys.stderr) -> int:
    problems, total = [], 0
    for s in sensors:
        seen, probs = s.selftest()
        total += len(s.alphabet)
        problems.extend(probs)
        print(f"{s.name}: {len(seen)}/{len(s.alphabet)} symbols exercised",
              file=out)
    for p in problems:
        print(f"FAIL {p}", file=out)
    print(f"\n{'FAILED' if problems else 'ok'} -- {len(problems)} contract "
          f"violation(s) across {total} declared symbol(s)", file=out)
    return EXIT_CRIT if problems else EXIT_OK


# ------------------------------------------------------------ shell helpers
def sh(*args, timeout=30, cwd=None) -> tuple[int, str]:
    """Run a command and return (rc, output). THE RC IS THE COMMAND'S.

    The 19/19 probe reported READY for every project because it ran
    `git ls-remote | head -1`, making $? head's status. Piping inside a probe
    is therefore banned here rather than discouraged: this helper takes an
    argv, never a shell string, so there is no pipeline whose exit status can
    be silently substituted.
    """
    if len(args) == 1 and isinstance(args[0], (list, tuple)):
        args = tuple(args[0])
    try:
        p = subprocess.run(args, timeout=timeout, cwd=cwd,
                           capture_output=True, text=True)
        return p.returncode, (p.stdout or p.stderr).strip()
    except (subprocess.TimeoutExpired, OSError) as e:
        return 124, f"{type(e).__name__}: {e}"


def install_sigpipe_default():
    """Die quietly on SIGPIPE so `... | head -5` does not traceback.

    Proper bash citizenship: a tool that explodes when its reader goes away is
    not pipeable, and a traceback on stdout would corrupt the stream a
    downstream grep is reading.
    """
    try:
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    except (AttributeError, ValueError):
        pass
