#!/usr/bin/env python3
"""migration-watch.py -- ecosim's instrument for the mandark -> dexter migration.

Sensors 1, 2 and 4 of the manifest in HYPOTHESES-dexter-migration.md.
OBSERVER ONLY: reads two rotation files and every project's FOCUS.md, writes
nothing outside this repo, and cannot halt, gate or block a move. Its exit
code reports what it saw; nothing in the migration consults it.

    bin/migration-watch.py rotation            # sensor 1  -> decides H-M6
    bin/migration-watch.py milestones --snapshot   # sensor 2 -> decides H-M3b
    bin/migration-watch.py milestones --diff
    bin/migration-watch.py histogram           # sensor 4  -> decides H-M0
    bin/migration-watch.py --selftest          # the negative tests (brief §4)

Every sensor here ships with a negative test that feeds it a known-bad input
and asserts the failure symbol appears. A sensor that has never been observed
to say NO has not been shown to be able to. --selftest is that proof and it
fails if any symbol stops firing.

EXIT: 0 clean, 1 hazard symbol emitted, 2 BLIND (a domain could not be read).
BLIND is never folded into clean -- that is this project's entire thesis.
"""
import argparse, json, os, re, shlex, subprocess, sys, tempfile, shutil, time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PROJECTS = Path(os.environ.get("ECOSIM_PROJECTS_DIR", Path.home() / "Documents/Projects"))
SCHED = Path(os.environ.get("ECOSIM_SCHEDULER_DIR",
                            Path.home() / "Documents/Projects/scheduler"))
SENSORS = REPO / "sensors"

# WRITES DO NOT GO WHERE READS COME FROM, once this tree is a BUILD.
#
# This file ships in the immutable verb build (~/.local/share/verb-builds/<id>)
# as well as in a dev clone. In a build, REPO/sensors is carried, read-only by
# intent, and replaced wholesale by the next build -- so an append there is a
# record that quietly dies at the next `install-verb-build.sh --apply`. That is
# the same "the archive died with the thing it archived" fault realisateur's
# ecosim-sensor-tick.sh already names in its own comments.
#
# So: STATE is where this instrument WRITES, defaulting to REPO/sensors so a
# dev clone behaves exactly as before. `sonde` sets ECOSIM_STATE_DIR when it
# runs out of a build. Baselines are READ through _carried(), which prefers a
# snapshot taken into STATE and falls back to the one carried in the tree --
# without that fallback a build would report BLIND_NO_ROTATION_BASELINE on
# every run, which is honest but is a regression, not a port.
STATE = Path(os.environ.get("ECOSIM_STATE_DIR", str(SENSORS)))


def _carried(name):
    """A baseline path: the snapshot in STATE if one was taken, else the
    copy carried in the tree. Writers always use STATE / name directly."""
    p = STATE / name
    return p if p.exists() else SENSORS / name


EVENTS = STATE / "events.jsonl"
BASELINE = _carried("milestones-baseline.json")

# Projects whose dispatch lives under the svc-vaporwave crontab, which this
# project has never read (BRIEF-dexter-migration.md §0). They are BLIND by
# construction: reported as unreadable, never as absent and never as clean.
BLIND_BY_CONSTRUCTION = {"aedile", "vkv-inventory"}

# The declared alphabets. Sensor 4 reads these: a symbol listed here that never
# appears in the log is reported as NEVER_EMITTED, which is what makes a clean
# reading auditable instead of self-certifying.
ALPHABET = {
    "rotation": ["IN_ONE", "FROZEN", "FROZEN_EXEMPT", "FREEZE_NOT_PROPAGATED",
                 "BLIND_FREEZE_UNKNOWN", "ROTATION_DIVERGED",
                 "BLIND_HOST_CONF_UNREADABLE", "PARKED_DURING_MIGRATION",
                 "IN_BOTH_ENABLED",
                 "ORPHANED_IN_MIGRATION",
                 "PARKED_AT_BASELINE", "BLIND_NO_ROTATION_BASELINE",
                 "BLIND_UNPARSEABLE_LINE", "BLIND_FILE_UNREADABLE",
                 "BLIND_BY_CONSTRUCTION"],
    "dispatch_ref": ["EQUAL", "BEHIND", "AHEAD", "DIVERGED",
                     "UNREACHABLE_FROM_HOST", "UNREACHABLE_GITHUB",
                     "INDETERMINATE_ANCESTRY", "BLIND_NO_REPO_URL",
                     "BLIND_CONF_DIR_UNREADABLE"],
    "unit": ["QUEUED", "SELECTED", "RUN_STARTED", "RUN_IN_FLIGHT",
             "RUN_COMMITTED", "RUN_PUSHED",
             "VERIFIED_FROM_DEXTER", "BLOCKED", "BLIND_NO_RUNLOG",
             "BLIND_NO_UNIT_EVIDENCE"],
    "accumulation": ["DECAY_IN_SCOPE", "DECAY_OUT_OF_SCOPE", "NEVER_REVISITED",
                     "BLIND_NO_DECAY_TOOL"],
    "simultaneity": ["NO_CLASS_MATCHED", "ONE_CLASS", "TWO_CLASSES",
                     "THREE_CLASSES", "FOUR_PLUS_CLASSES", "BLIND_NO_HISTORY"],
    "staleness": ["HOLDS", "EXPIRED", "EXPIRED_REF_ADVANCED", "UNCHECKABLE",
                  "BLIND_DOC_UNREADABLE"],
    "credential": ["CREDENTIAL_OK", "CREDENTIAL_GONE",
                   "REPO_SPECIFIC_FAILURE", "INDETERMINATE",
                   "API_CREDENTIAL_OK", "API_CREDENTIAL_GONE",
                   "API_INDETERMINATE", "BLIND_NO_GATE_LINE"],
    "milestones": ["CAPTURED", "BLIND_NO_CURRENT_LINE", "BLIND_NO_FOCUS_FILE",
                   "UNCHANGED", "OVERRIDDEN", "RESTORED", "UNRESTORED",
                   "CHANGED_OTHER"],
}
HAZARD = {"IN_BOTH_ENABLED", "ORPHANED_IN_MIGRATION", "UNRESTORED",
          "BEHIND", "DIVERGED", "UNREACHABLE_FROM_HOST", "CREDENTIAL_GONE", "API_CREDENTIAL_GONE",
          "FREEZE_NOT_PROPAGATED", "ROTATION_DIVERGED",
          "REPO_SPECIFIC_FAILURE", "EXPIRED",
          "FOUR_PLUS_CLASSES",
          "DECAY_OUT_OF_SCOPE", "NEVER_REVISITED", "BLOCKED"}
BLIND = {"BLIND_UNPARSEABLE_LINE", "BLIND_FILE_UNREADABLE", "BLIND_BY_CONSTRUCTION",
         "BLIND_NO_CURRENT_LINE", "BLIND_NO_FOCUS_FILE",
         "BLIND_NO_ROTATION_BASELINE", "BLIND_PROJECT_DIR_NOT_FOUND",
         "BLIND_NO_REPO_URL", "BLIND_CONF_DIR_UNREADABLE",
         "INDETERMINATE_ANCESTRY", "UNREACHABLE_GITHUB", "INDETERMINATE",
         "BLIND_DOC_UNREADABLE", "BLIND_NO_HISTORY", "BLIND_NO_DECAY_TOOL",
         "BLIND_FREEZE_UNKNOWN", "BLIND_HOST_CONF_UNREADABLE",
         "BLIND_NO_RUNLOG", "BLIND_NO_UNIT_EVIDENCE", "API_INDETERMINATE",
         "BLIND_NO_GATE_LINE"}
ROT_BASELINE = _carried("rotation-baseline.json")
FIXTURE_LEDGER = SENSORS / "fixture-symbols.json"
_IN_SELFTEST = []          # symbols observed under --selftest, for the ledger

# "bootstrap yourself on dexter" is the temporary override (commissioning brief
# §1). Matching is deliberately loose -- an override worded differently must
# still be caught, and a false positive here is cheaper than a missed one.
OVERRIDE_RE = re.compile(r"bootstrap.{0,20}dexter|dexter.{0,20}bootstrap", re.I)


# ---------------------------------------------------------------- event log
def emit(sensor, subject, symbol, detail="", log=None):
    """One record per observation. Includes the boring ones on purpose: the
    boring ticks are the baseline, and a baseline is what makes an anomaly
    legible (commissioning brief §3)."""
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "sensor": sensor,
           "subject": subject, "symbol": symbol, "detail": detail}
    if _IN_SELFTEST:
        _IN_SELFTEST[0].add((sensor, symbol))
    if log is not None:
        log.append(rec)
    else:
        STATE.mkdir(parents=True, exist_ok=True)
        with EVENTS.open("a") as fh:
            fh.write(json.dumps(rec) + "\n")
    return rec


# ------------------------------------------------------- sensor 1: rotation
def parse_conf(path):
    """Returns (entries, problems). entries: name -> (enabled, raw_line).

    Handles BOTH arities live in the real files: `name|enabled|weight|cmd` and
    the 3-field `name|enabled|cmd` (chezz-sweep). A line it cannot parse is a
    problem, never a silently skipped line -- skipping is how a rotation file
    loses a project without anything saying so.
    """
    entries, problems = {}, []
    try:
        text = path.read_text()
    except OSError as e:
        return None, [f"{path}: {e}"]
    for n, line in enumerate(text.splitlines(), 1):
        s = line.split("#", 1)[0].strip()
        if not s:
            continue
        f = s.split("|")
        if len(f) < 3 or not f[0] or f[1] not in ("0", "1"):
            problems.append(f"{path.name}:{n}: {line.strip()[:60]}")
            continue
        entries[f[0]] = (f[1] == "1", line.rstrip())
    return entries, problems


def read_freeze(path=None):
    """(frozen, exempt_set, reason). THE PLAY engaged a dispatch freeze at
    2026-07-29 01:17 (scheduler 983ed3d): participants frozen, scheduler
    exempt. Without reading it this sensor reports a frozen project as IN_ONE
    -- 'enabled, and dispatching' and 'enabled, and refused at dispatch' are
    two world-states, and the freeze is precisely what separates them. The
    hole opened the moment the play started; it is the exact class this
    project exists to name, so it gets a symbol rather than a footnote."""
    f = path or (SCHED / "schedule/FREEZE")
    try:
        text = f.read_text()
    except OSError:
        return False, set(), ""
    # `EXEMPT: <project>@<host>` exempts on that host only; the bare form
    # means every host (scheduler 6bed73f, 2026-07-29 01:26 -- the bare form
    # had unfrozen scheduler self-dev on BOTH hosts and re-created the
    # two-writer hazard). This parser was written 20 minutes before that
    # commit and would have read "scheduler@dexter" as a literal project
    # name that matches nothing -- a silent mis-parse, right by accident on
    # mandark and wrong on dexter. The format moved under the sensor within
    # the hour, which is H-M4 aimed at this file.
    exempt = set()
    for line in text.splitlines():
        if line.strip().startswith("EXEMPT:"):
            for tok in line.split(":", 1)[1].split():
                name, _, hst = tok.partition("@")
                exempt.add((name, hst or None))
    reason = next((l.strip() for l in text.splitlines()
                   if l.strip() and not l.strip().startswith(("#", "EXEMPT:"))), "")
    return True, exempt, reason[:60]


def freeze_on_host(host, probe=None):
    """Is the freeze file present in the checkout THAT HOST dispatches from?

    True / False / None(unreadable). A freeze engaged in one checkout is not
    a freeze in force everywhere: it reaches a host only when that host pulls
    it. On 2026-07-29 dexter sat 6 commits behind with two dirty tracked
    files and never received the freeze at all, while this sensor -- reading
    mandark's copy -- reported its dexter-hosted projects FROZEN. Asserting a
    state over a domain it had not read, in the sensor built to catch that.
    """
    # The injected probe wins for EVERY host. The earlier form short-circuited
    # the local host before consulting it, so no fixture could exercise the
    # local path -- a test that cannot reach a branch does not cover it, which
    # is the fixture-side twin of a symbol that cannot fire.
    if probe:
        return probe(host)
    if host in (None, "", "mandark", "local"):
        return (SCHED / "schedule/FREEZE").is_file()
    rc, out = (0, "")
    try:
        pr = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", host,
             "test -f ~/scheduler/schedule/FREEZE && echo YES || echo NO"],
            timeout=30, capture_output=True, text=True)
        rc, out = pr.returncode, (pr.stdout or "").strip()
    except (subprocess.TimeoutExpired, OSError):
        return None
    if rc != 0 or out not in ("YES", "NO"):
        return None
    return out == "YES"


PARK_RE = re.compile(r"\bpark|disable|stop dispatch", re.I)


def why_disabled(name, host="dexter", probe=None):
    """Subject of the last commit touching this project's rotation line.

    'Dropped from one file and never added to the other' and 'deliberately
    parked mid-migration' are both 'enabled nowhere' -- the pre-migration
    baseline separates the FIRST pair, but not a park that happens DURING the
    run. The attributing commit is what separates these, and it is one log
    read away. Without it H-M6's headline symbol fires on a correct operator
    action and the writeup records a seam failure that never happened.
    """
    if probe is not None:
        return probe(name)
    try:
        pr = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", host,
             # FILE-level, not line-level, and deliberately so. The first
             # form used the pickaxe (-S<name>), which counts OCCURRENCES of
             # the string: parking rewrites `crt|1|3` to `crt|0|0`, so the
             # count of "crt" is unchanged and the pickaxe silently returned
             # an unrelated older commit. A probe that returns a PLAUSIBLE
             # wrong answer is worse than one that returns nothing, because
             # nothing is visibly missing. Attribution is therefore to the
             # last commit touching the FILE, and the detail says so.
             "cd ~/scheduler && git log -1 --format=%s -- "
             "schedule/_paced.dexter.conf"],
            timeout=35, capture_output=True, text=True)
        return (pr.stdout or "").strip() if pr.returncode == 0 else ""
    except (subprocess.TimeoutExpired, OSError):
        return ""


def host_rotation(host="dexter", probe=None):
    """dexter's OWN copy of its rotation file, read FROM dexter.

    Mandark's checkout is not authoritative for what dexter dispatches. On
    2026-07-29 a hand-edit committed on dexter (eaf6954, unpushed) parked crt
    and wtul there while mandark's copy still showed both enabled, and this
    sensor -- reading mandark -- described a file that was not the one in use.
    A two-host system has two copies of everything, and a sensor that reads
    one and reports on both is wrong the moment they diverge.

    Returns (entries, None) or (None, reason).
    """
    if probe is not None:
        return probe(host)
    try:
        pr = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", host,
             "cat ~/scheduler/schedule/_paced.dexter.conf"],
            timeout=35, capture_output=True, text=True)
    except (subprocess.TimeoutExpired, OSError) as e:
        return None, f"{type(e).__name__}: {e}"
    if pr.returncode != 0:
        return None, (pr.stderr or "").strip()[:70] or f"rc={pr.returncode}"
    entries = {}
    for line in pr.stdout.splitlines():
        s = line.split("#", 1)[0].strip()
        if not s:
            continue
        f = s.split("|")
        if len(f) >= 3 and f[0] and f[1] in ("0", "1"):
            entries[f[0]] = (f[1] == "1", line.rstrip())
    return entries, None


def rotation(log=None, mandark=None, dexter=None, rot_baseline=None,
             snapshot=False, freeze=None, host_probe=None, conf_probe=None,
             why_probe=None):
    """Sensor 1 -- decides H-M6 (Conway: the failure lands on the seam).

    THE SYMBOL THAT MATTERS IS IN_NEITHER_ENABLED. A project enabled in no
    rotation file runs NOWHERE and emits NOTHING; absence of a run is
    otherwise indistinguishable from 'not its turn yet' in every existing log.

    Keyed on the ENABLED BIT, not on presence. Re-probed 2026-07-29 00:2x:
    crt and wtul are present in BOTH files today and the enabled bit is what
    moved. A presence-keyed reconciler would have called the current, correct
    state a duplicate on every tick -- a sensor that cries hazard at the
    healthy baseline gets muted, and then it is not a sensor.
    """
    mp = mandark or SCHED / "schedule/_paced.conf"
    dp = dexter or SCHED / "schedule/_paced.dexter.conf"
    m, mprob = parse_conf(mp)
    d, dprob = parse_conf(dp)
    for p in mprob + dprob:
        emit("rotation", p.split(":")[0], "BLIND_UNPARSEABLE_LINE", p, log)
    for f, e in ((mp, m), (dp, d)):
        if e is None:
            emit("rotation", str(f), "BLIND_FILE_UNREADABLE", "", log)
    if m is None or d is None:
        return  # cannot assert anything about a domain we could not read

    rb = rot_baseline or ROT_BASELINE
    if snapshot:
        # A snapshot is a WRITE, so it lands in STATE even when the read above
        # fell back to the carried copy -- otherwise a build would try to
        # rewrite its own immutable tree.
        rb = rot_baseline or (STATE / "rotation-baseline.json")
        STATE.mkdir(parents=True, exist_ok=True)
        rb.write_text(json.dumps(
            {"captured": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
             "enabled_at_baseline": sorted(
                 n for n in set(m) | set(d)
                 if m.get(n, (False,))[0] or d.get(n, (False,))[0])},
            indent=1) + "\n")
    try:
        was_enabled = set(json.loads(rb.read_text())["enabled_at_baseline"])
        have_baseline = True
    except (OSError, ValueError):
        was_enabled, have_baseline = set(), False

    # What dexter ACTUALLY dispatches from, read from dexter.
    d_host, d_why = host_rotation("dexter", conf_probe)
    if d_host is None:
        emit("rotation", "dexter:_paced.dexter.conf", "BLIND_HOST_CONF_UNREADABLE",
             f"cannot read dexter's own copy: {d_why} -- dexter-side readings "
             f"below fall back to mandark's copy and may not match", log)
    else:
        for name in sorted(set(d) | set(d_host)):
            ours = d.get(name, (None,))[0]
            theirs = d_host.get(name, (None,))[0]
            if ours != theirs:
                emit("rotation", name, "ROTATION_DIVERGED",
                     f"mandark's copy says enabled={ours}, dexter's own says "
                     f"enabled={theirs} -- dexter's is the one that dispatches",
                     log)
        d = d_host          # authoritative for every judgement below

    frozen, exempt, why = read_freeze(freeze)
    for name in sorted(set(m) | set(d)):
        if name in BLIND_BY_CONSTRUCTION:
            emit("rotation", name, "BLIND_BY_CONSTRUCTION",
                 "svc-vaporwave crontab never read; enabled bit here is not "
                 "its dispatch state", log)
            continue
        me = m.get(name, (False, ""))[0]
        de = d.get(name, (False, ""))[0]
        if me and de:
            # The config hazard is real whatever the freeze says, so this
            # keeps its symbol. But "dispatches twice" and "would dispatch
            # twice once the freeze lifts" are different present-tense facts,
            # and the detail must not assert the first while a freeze holds.
            fr = read_freeze(freeze)[0]
            emit("rotation", name, "IN_BOTH_ENABLED",
                 "enabled on both hosts -- would dispatch twice (freeze "
                 "currently engaged)" if fr else
                 "enabled on both hosts -- dispatches twice", log)
        elif not me and not de:
            # Two world-states, and the pre-migration baseline is the ONLY
            # thing that separates them: a project parked on purpose before
            # any of this started, and a project dropped from one file and
            # never added to the other. Both are "enabled nowhere"; only the
            # second is the seam failure H-M6 predicts. Without the baseline
            # this sensor emitted one symbol for both -- caught by its own
            # first live reading, which is the argument for taking baselines.
            if not have_baseline:
                emit("rotation", name, "BLIND_NO_ROTATION_BASELINE",
                     "enabled nowhere, and no baseline to say whether that is "
                     "deliberate", log)
            elif name in was_enabled:
                subj = why_disabled(name, probe=why_probe)
                if subj and PARK_RE.search(subj):
                    emit("rotation", name, "PARKED_DURING_MIGRATION",
                         f"enabled nowhere, deliberately -- last change to the "
                         f"file: {subj[:52]}", log)
                else:
                    emit("rotation", name, "ORPHANED_IN_MIGRATION",
                         "was enabled at baseline, now enabled nowhere -- runs "
                         f"nowhere, silently{'; last change: ' + subj[:40] if subj else ''}",
                         log)
            else:
                emit("rotation", name, "PARKED_AT_BASELINE",
                     "enabled nowhere, and already so before the migration", log)
        elif frozen:
            where = "mandark" if me else "dexter"
            here = freeze_on_host(where, host_probe)
            if here is None:
                emit("rotation", name, "BLIND_FREEZE_UNKNOWN",
                     f"{where}: cannot read that host's checkout, so cannot "
                     f"say whether the freeze reached it", log)
            elif not here:
                emit("rotation", name, "FREEZE_NOT_PROPAGATED",
                     f"{where}: freeze engaged here but ABSENT on that host -- "
                     f"it will dispatch normally", log)
            elif (name, where) in exempt or (name, None) in exempt:
                emit("rotation", name, "FROZEN_EXEMPT",
                     f"{where} -- freeze in force, this one may still dispatch",
                     log)
            else:
                emit("rotation", name, "FROZEN",
                     f"{where} -- refused at dispatch: {why}", log)
        else:
            emit("rotation", name, "IN_ONE", "mandark" if me else "dexter", log)


# ----------------------------------------------------- sensor 2: milestones
FOCUS_CANDIDATES = (".scheduler/FOCUS.md", ".claude/FOCUS.md", "FOCUS.md")


def read_milestone(proj_dir):
    for rel in FOCUS_CANDIDATES:
        f = proj_dir / rel
        if not f.exists():
            continue
        try:
            for line in f.read_text().splitlines():
                if line.startswith("**Current:**"):
                    return ("CAPTURED", line.strip(), str(f))
        except OSError as e:
            return ("BLIND_NO_FOCUS_FILE", f"{f}: {e}", str(f))
        return ("BLIND_NO_CURRENT_LINE", "", str(f))
    return ("BLIND_NO_FOCUS_FILE", "", "")


def registered(root):
    """The set this instrument is accountable for: every name in either
    rotation file. Falls back to a directory listing ONLY if neither file can
    be read, and that case is already reported BLIND by the rotation sensor."""
    names = set()
    for p in (SCHED / "schedule/_paced.conf", SCHED / "schedule/_paced.dexter.conf"):
        e, _ = parse_conf(p)
        if e:
            names |= set(e)
    names -= {"chezz-sweep"}          # a second job for chezz, not a project
    names -= BLIND_BY_CONSTRUCTION    # reported BLIND by the rotation sensor
    if not names:
        names = {p.name for p in root.iterdir() if p.is_dir()
                 and not p.name.startswith(".")}
    return names


def prior_overrides(path):
    """Subjects this instrument has previously recorded as OVERRIDDEN. This is
    the memory that separates RESTORED from UNCHANGED. A missing log is not an
    empty log: with no history, 'never overridden' is unknowable, so the caller
    is told so rather than being handed a confident UNCHANGED."""
    try:
        recs = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    except OSError:
        return set()
    return {r["subject"] for r in recs if r.get("symbol") == "OVERRIDDEN"}


def project_dir(name, root):
    """Registered projects do not all live under one root. Searching a fixed
    list of roots is what turns BLIND_PROJECT_DIR_NOT_FOUND from an honest
    non-answer into actual coverage -- honest blindness is the floor here, not
    the goal. Anything still unfound stays BLIND and names the paths tried."""
    for base in (root, Path.home() / "Documents/Project Archive",
                 Path.home() / "Documents"):
        d = base / name
        if d.is_dir():
            return d
    return None


def milestones(snapshot=False, diff=False, log=None, root=None, baseline=None,
               events=None, names=None):
    """Sensor 2 -- decides H-M3b (Theraulaz: the override is a trace with no
    evaporation mechanism named).

    TIME-CRITICAL. The pre-override state cannot be captured after the first
    override lands. --snapshot must run before the migration's first unit.
    """
    root = root or PROJECTS
    bpath = baseline or BASELINE
    events = events or EVENTS
    cur = {}
    # Driven by the REGISTERED set (the rotation files), not by a directory
    # listing. A listing silently omitted chezz, wtul, home-assistant and
    # scheduler -- they are registered but do not live under this root -- and
    # silently added `.claude`. That is an instrument reporting complete
    # coverage of an incomplete domain, which is the one thing this project
    # may never do. A registered project whose checkout cannot be found is
    # now BLIND, and says which path it looked at.
    for name in sorted(names if names is not None else registered(root)):
        d = project_dir(name, root)
        if d is None:
            sym, val, src = "BLIND_PROJECT_DIR_NOT_FOUND", "", f"not under {root}"
        else:
            sym, val, src = read_milestone(d)
        cur[name] = {"symbol": sym, "current": val, "source": src}
        if snapshot:
            emit("milestones", name, sym, src, log)
    if snapshot:
        # As above: the snapshot is written into STATE, never back into a
        # carried (possibly immutable) tree.
        bpath = baseline or (STATE / "milestones-baseline.json")
        STATE.mkdir(parents=True, exist_ok=True)
        bpath.write_text(json.dumps(
            {"captured": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "projects": cur},
            indent=1, sort_keys=True) + "\n")
        return
    if not diff:
        return
    try:
        base = json.loads(bpath.read_text())["projects"]
    except (OSError, ValueError) as e:
        emit("milestones", str(bpath), "BLIND_NO_FOCUS_FILE",
             f"no baseline to diff against: {e}", log)
        return
    previously_overridden = prior_overrides(events)
    for name in sorted(set(base) | set(cur)):
        b = base.get(name, {}).get("current", "")
        c = cur.get(name, {}).get("current", "")
        if cur.get(name, {}).get("symbol", "").startswith("BLIND"):
            emit("milestones", name, cur[name]["symbol"], "cannot compare", log)
        elif OVERRIDE_RE.search(c):
            # An override still standing after its unit finished is UNRESTORED,
            # not OVERRIDDEN: same text, opposite meaning. The discriminator is
            # whether this project's unit is done, which the log does not know,
            # so both symbols are emitted against the same state and the
            # writeup resolves them against the rotation. Stated, not hidden.
            emit("milestones", name,
                 "UNRESTORED" if b == c else "OVERRIDDEN", c[:80], log)
        elif b == c:
            # RESTORED and UNCHANGED are the two world-states that would
            # otherwise collide here: 'was overridden and put back' and 'was
            # never touched' produce identical bytes. The log is what tells
            # them apart -- without it this is a one-symbol sensor over two
            # states, which is the failure this project exists to name.
            emit("milestones", name,
                 "RESTORED" if name in previously_overridden else "UNCHANGED",
                 "", log)
        else:
            emit("milestones", name, "CHANGED_OTHER", c[:80], log)



# ------------------------------------------- sensor S5: dispatch-ref staleness
# Spec: hf7y/ecosim#6. Distinguishes "registered, enabled, checkout fine,
# dispatch ref stale/unreachable" from a genuinely healthy project -- a state
# with no symbol anywhere in the ecosystem (steward-survey renders it LIVE).
#
# NOTE, because it retires a property #9 verified: this sensor SHELLS OUT.
# Until now `subprocess` was imported and never called, which made observer-
# only structural rather than intentional. It now runs `git ls-remote` and
# `git merge-base`, both read-only, against remotes and local checkouts.
# Writes remain confined to REPO/sensors/. Stated rather than discovered.

def git(*args, cwd=None, timeout=25):
    """Run git and return (rc, stdout). The rc is GIT'S, captured directly.

    The 19/19 probe reported READY for every project because it ran
    `git ls-remote | head -1`, making $? head's exit status. Piping here is
    therefore banned, not discouraged, and --selftest asserts a known-bad
    remote yields a nonzero rc.
    """
    try:
        p = subprocess.run(("git",) + args, cwd=cwd, timeout=timeout,
                           capture_output=True, text=True)
        return p.returncode, (p.stdout or p.stderr).strip()
    except (subprocess.TimeoutExpired, OSError) as e:
        return 124, f"{type(e).__name__}: {e}"


def ls_remote_head(url, host=None):
    """HEAD sha of a remote, or (None, reason). host=None means from mandark;
    otherwise the probe runs over ssh from that host, which is the question
    that actually matters -- a remote reachable from here says nothing about
    whether the executing host can reach it."""
    if host:
        rc, out = git("ls-remote", url) if False else (None, None)
        try:
            p = subprocess.run(
                ["ssh", "-o", "BatchMode=yes", host,
                 f"git ls-remote {shlex.quote(url)} HEAD"],
                timeout=40, capture_output=True, text=True)
            rc, out = p.returncode, (p.stdout or p.stderr).strip()
        except (subprocess.TimeoutExpired, OSError) as e:
            rc, out = 124, f"{type(e).__name__}: {e}"
    else:
        rc, out = git("ls-remote", url, "HEAD")
    if rc != 0 or not out or "\t" not in out.split("\n")[0]:
        return None, (out.split("\n")[0][:90] or f"rc={rc}")
    return out.split("\n")[0].split("\t")[0], ""


def dispatch_ref(log=None, host="dexter", confs=None, projects_root=None,
                 gh_url=None):
    """Sensor S5 -- the only one here aimed at a CONFIRMED live defect."""
    root = projects_root or PROJECTS
    conf_dir = confs or (SCHED / "schedule")
    if not conf_dir.is_dir():
        # glob() on a missing directory yields nothing and raises nothing, so
        # the original `try/except OSError` around it could never fire and this
        # symbol was declared-but-unreachable: an audit over a vanished conf
        # directory would have returned zero findings and looked clean. Caught
        # by the fixture that finally tried to make the symbol appear.
        emit("dispatch_ref", str(conf_dir), "BLIND_CONF_DIR_UNREADABLE",
             "conf directory does not exist or is not a directory", log)
        return
    try:
        files = sorted(f for f in conf_dir.glob("*.conf")
                       if not f.name.startswith("_"))
    except OSError as e:
        emit("dispatch_ref", str(conf_dir), "BLIND_CONF_DIR_UNREADABLE", str(e), log)
        return
    for f in files:
        name = f.stem
        m = re.search(r'^REPO_URL="([^"]*)"', f.read_text(), re.M)
        if not m or not m.group(1):
            emit("dispatch_ref", name, "BLIND_NO_REPO_URL", str(f), log)
            continue
        url = m.group(1)
        # (1) Can the EXECUTING host reach the dispatch ref at all? This is the
        # question the migration turns from academic into load-bearing.
        sha_host, why = ls_remote_head(url, host=host)
        if sha_host is None:
            emit("dispatch_ref", name, "UNREACHABLE_FROM_HOST",
                 f"{host}: {url} -- {why}", log)
            continue
        # (2) Is that ref current against GitHub?
        gh = gh_url(name) if gh_url else f"git@github.com:hf7y/{name}.git"
        sha_gh, why_gh = ls_remote_head(gh)
        if sha_gh is None:
            emit("dispatch_ref", name, "UNREACHABLE_GITHUB", f"{gh} -- {why_gh}", log)
            continue
        if sha_host == sha_gh:
            emit("dispatch_ref", name, "EQUAL", sha_gh[:8], log)
            continue
        # BEHIND and DIVERGED are different severities and must not share a
        # symbol: behind-but-ancestor is a clean repoint, diverged needs
        # judgement. Ancestry needs a checkout holding both commits; if none
        # does, that is INDETERMINATE, never a guess.
        d = project_dir(name, root)
        if d is None:
            emit("dispatch_ref", name, "INDETERMINATE_ANCESTRY",
                 "no local checkout to resolve ancestry", log)
            continue
        behind = git("merge-base", "--is-ancestor", sha_host, sha_gh, cwd=d)[0]
        ahead = git("merge-base", "--is-ancestor", sha_gh, sha_host, cwd=d)[0]
        if behind == 0 and ahead != 0:
            n = git("rev-list", "--count", f"{sha_host}..{sha_gh}", cwd=d)[1]
            emit("dispatch_ref", name, "BEHIND", f"{n} commits behind GitHub", log)
        elif ahead == 0 and behind != 0:
            emit("dispatch_ref", name, "AHEAD", f"dispatch ref ahead of GitHub", log)
        elif behind != 0 and ahead != 0:
            emit("dispatch_ref", name, "DIVERGED",
                 f"{sha_host[:8]} vs {sha_gh[:8]} -- needs judgement", log)
        else:
            emit("dispatch_ref", name, "INDETERMINATE_ANCESTRY",
                 "checkout holds neither sha", log)



# --------------------------------------- sensor S4: shared-fate credential
# Spec: hf7y/ecosim#5, serving T1. Distinguishes "this clone failed" from
# "the credential is gone" -- today one symbol for both, and the second means
# EVERY project on that host is about to fail while the first means nothing
# beyond itself. The migration deliberately put every project behind one
# OAuth token (insteadOf HTTPS rewrite) in place of per-repo deploy keys,
# converting N independent failure modes into one.
#
# This is not merely an outage check. T1 predicts apparent independence in
# the short run and aggregate dependence later, WITH THE TRANSITION POINT AS
# THE MEASUREMENT. A shared credential is the most likely mechanism by which
# independent-looking failures become correlated, so this sensor is watching
# for the moment Simon's short run ends.

AUTH_MARKERS = ("authentication failed", "invalid username or password",
                "could not read username", "permission denied",
                "terminal prompts disabled", "401", "403")
MISSING_MARKERS = ("repository not found", "does not appear to be a git",
                   "not found", "404")
NET_MARKERS = ("could not resolve host", "connection timed out", "network is",
               "timeoutexpired", "connection refused", "temporary failure")


def classify_credential(canary_rc, canary_out, target_rc, target_out):
    """Pure classifier, so every symbol is testable without a live outage.

    The canary is a repo known to exist and be readable. Probing the target
    ALONE cannot tell these apart -- GitHub answers 'Repository not found'
    both for a repo that is absent and for one the caller may not see, which
    is exactly the two-states-one-symbol problem. The second probe is what
    supplies the missing distinction.
    """
    c, tg = (canary_out or "").lower(), (target_out or "").lower()
    if any(m in c for m in NET_MARKERS):
        # A network fault looks exactly like a revoked token from one probe,
        # and guessing between them is how a sensor acquires a symbol it has
        # not earned. INDETERMINATE is the honest answer, not a hedge.
        return "INDETERMINATE", "canary probe hit a network fault: " + c[:60]
    if canary_rc != 0:
        if any(m in c for m in AUTH_MARKERS):
            return "CREDENTIAL_GONE", "canary repo rejected the credential"
        return "INDETERMINATE", "canary failed for a non-auth reason: " + c[:60]
    if target_rc == 0:
        return "CREDENTIAL_OK", "canary and target both answered"
    if any(m in tg for m in NET_MARKERS):
        return "INDETERMINATE", "target hit a network fault: " + tg[:60]
    if any(m in tg for m in AUTH_MARKERS + MISSING_MARKERS):
        return "REPO_SPECIFIC_FAILURE", "credential works, this repo does not: " + tg[:60]
    return "INDETERMINATE", "target failed unclassifiably: " + tg[:60]


def api_credential(log=None, host="dexter", probe=None):
    """The OTHER shared-fate credential, and the one that actually failed.

    S4 was built from BRIEF-dexter-migration.md §9, which is about the GIT
    credential. At 06:00:03 the credential that broke was the ANTHROPIC API
    key that `usage-gate.sh` probes for rate-limit headers -- `http_code=401
    reason=no_headers`. Equally shared-fate (every project on every host
    depends on it), equally a single point of failure, and instrumented by
    nobody. A sensor pointed at one shared credential says nothing about
    another one, and "the shared credential" was never a single object.

    Read from the runner's own gate line rather than by probing the API: this
    project does not hold that key and must not start using quota to check it.
    """
    rl = "~/.local/share/scheduler-paced-runner/run.log"
    if probe is not None:
        line = probe(host)
    elif host in (None, "", "mandark", "local"):
        # Local read. Previously this path ssh'd to an empty hostname and
        # reported BLIND -- an honest non-answer, but a BLIND that a one-line
        # fix can resolve is not a domain that could not be read, it is a
        # sensor that did not try.
        try:
            lines = [l for l in Path(rl.replace("~", str(Path.home()))).read_text()
                     .splitlines() if "verdict=" in l][-600:]
            line = "\n".join(lines) if lines else None
        except OSError:
            line = None
    else:
        try:
            pr = subprocess.run(
                ["ssh", "-o", "BatchMode=yes", host,
                 f"grep -E '^2026' {rl} 2>/dev/null | grep -E 'verdict=' | tail -600"],
                timeout=35, capture_output=True, text=True)
            line = (pr.stdout or "").strip() if pr.returncode == 0 else None
        except (subprocess.TimeoutExpired, OSError):
            line = None
    if not line:
        emit("credential", f"{host}:usage-gate", "BLIND_NO_GATE_LINE",
             "no gate verdict in the runner log -- API credential state unknown",
             log)
        return
    # A single line says what the state IS and is structurally incapable of
    # saying whether it is NEW. Reading three consecutive 401s as a migration
    # failure nearly happened here; the same log held 164 of them the day
    # before the migration existed. So the window, not just the sample:
    # "failing now" / "failing for days" / "intermittent" are three states and
    # one sample cannot separate them.
    lines = [l for l in line.splitlines() if l.strip()]
    line = lines[-1]
    codes = [(re.search(r"http_code=(\d+)", l) or [None, ""])[1] if
             re.search(r"http_code=(\d+)", l) else "" for l in lines]
    codes = [re.search(r"http_code=(\d+)", l).group(1)
             if re.search(r"http_code=(\d+)", l) else "" for l in lines]
    streak = 0
    for c in reversed(codes):
        if c in ("401", "403"):
            streak += 1
        else:
            break
    bad = sum(1 for c in codes if c in ("401", "403"))
    # Current streak against the LONGEST one this host has already survived.
    # Twice tonight a growing streak looked like a new fault; dexter's gate
    # had already run 322 consecutive 401s days earlier. "Unusual" is a claim
    # about a distribution, and a sensor that reports only the current value
    # invites the reader to supply the distribution from memory -- which is
    # where the false novelty comes from.
    worst = cur = 0
    for c in codes:
        cur = cur + 1 if c in ("401", "403") else 0
        worst = max(worst, cur)
    verdict = ("within prior behaviour" if streak <= worst and worst > streak
               else "AT OR ABOVE the worst previously seen in this window")
    rate = (f"{bad}/{len(codes)} in window, streak {streak}, "
            f"worst-in-window {worst} -- {verdict}")
    code = re.search(r"http_code=(\d+)", line)
    code = code.group(1) if code else ""
    when = line.split()[0]
    if code in ("401", "403"):
        emit("credential", f"{host}:usage-gate", "API_CREDENTIAL_GONE",
             f"{when} http_code={code}; {rate} -- every project on this host "
             f"is gated by this one key", log)
    elif code == "200":
        emit("credential", f"{host}:usage-gate", "API_CREDENTIAL_OK",
             f"{when} gate answered 200; {rate}", log)
    else:
        # A network fault and a dead key look identical from one sample.
        emit("credential", f"{host}:usage-gate", "API_INDETERMINATE",
             f"{when} gate http_code={code or 'absent'}: {line[-46:]}", log)


def credential(log=None, host="dexter", canary="https://github.com/hf7y/ecosim.git",
               targets=None, probe=None):
    """Sensor S4. `probe(url)` -> (rc, output); injectable so the classifier's
    every symbol has a fixture rather than needing a real revoked token."""
    if probe is None:
        def probe(url):
            if host:
                try:
                    p = subprocess.run(
                        ["ssh", "-o", "BatchMode=yes", host,
                         f"GIT_TERMINAL_PROMPT=0 git ls-remote {shlex.quote(url)} HEAD"],
                        timeout=40, capture_output=True, text=True)
                    return p.returncode, (p.stdout or p.stderr).strip()
                except (subprocess.TimeoutExpired, OSError) as e:
                    return 124, f"{type(e).__name__}: {e}"
            return git("ls-remote", url, "HEAD")
    c_rc, c_out = probe(canary)
    for tgt in (targets or [canary]):
        t_rc, t_out = (c_rc, c_out) if tgt == canary else probe(tgt)
        sym, why = classify_credential(c_rc, c_out, t_rc, t_out)
        emit("credential", tgt, sym, f"{host or 'local'}: {why}", log)
        if sym == "CREDENTIAL_GONE":
            # One credential, one verdict: probing the rest would emit N
            # copies of one world-state, which is N co-blind sensors
            # reporting with the variety of one.
            emit("credential", "*", "CREDENTIAL_GONE",
                 "shared-fate: every project on this host is affected", log)
            return



# ----------------------------------------- sensor S3: domain-moved / staleness
# Spec: hf7y/ecosim#4. Distinguishes "this document is current" from "this
# document was true when written" -- a frozen observation renders identically
# in both states, and a carefully-sourced document is MORE dangerous stale
# than a sloppy one because the citations read as verification.
#
# Evidence base is this project's own work: BRIEF-dexter-migration.md was
# filed with every claim carrying the command that produced it, and lost two
# of three findings in 35 minutes. Tonight a third expired -- its §2 rests on
# 3a45bf3, which was reverted by 356ecb0 an hour after it landed.
#
# SAFETY: this sensor RE-RUNS COMMANDS IT FINDS IN PROSE. That is only
# defensible behind a strict allowlist of read-only verbs. Anything not on it
# is UNCHECKABLE -- never executed, never assumed true. Per the spec,
# UNCHECKABLE is the most useful symbol here: it names the claims that were
# never falsifiable, which are the ones most likely to survive on authority
# alone.

SAFE_CMDS = (
    "git ls-remote", "git log", "git status", "git config --get",
    "git config --global --get", "git merge-base", "git rev-parse",
    "git show", "git branch", "crontab -l", "command -v", "which ",
    "ls ", "ls -", "cat /proc", "hostname", "aplay -l", "tmux ls",
    "gh api", "gh auth status",
)
# `ssh <host> '<cmd>'` is allowed only when the INNER command is also safe.
SSH_RE = re.compile(r"^ssh\s+(?:-\S+\s+)*(\S+)\s+['\"](.+)['\"]$")
PROMPT_RE = re.compile(r"^\s*(?:[\w.-]+\$|\$)\s*(.+)$")


def is_safe(cmd):
    m = SSH_RE.match(cmd.strip())
    if m:
        return is_safe(m.group(2))
    c = cmd.strip()
    if any(ch in c for ch in ";|&><`$(") :
        return False          # no pipes, no substitution, no chaining
    return any(c.startswith(s) for s in SAFE_CMDS)


def extract_claims(text):
    """Commands inside fenced blocks, with any recorded expectation.

    A claim is checkable only if the document wrote down BOTH the command and
    what it produced. A command with no recorded result is a claim nobody can
    falsify, which is exactly what UNCHECKABLE is for.
    """
    claims, in_fence = [], False
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.strip().startswith("```"):
            in_fence = not in_fence
            continue
        if not in_fence:
            continue
        m = PROMPT_RE.match(line)
        if not m:
            continue
        cmd = m.group(1).strip()
        expect = ""
        if "→" in cmd:
            cmd, expect = (x.strip() for x in cmd.split("→", 1))
        else:
            for nxt in lines[i + 1:i + 3]:
                if nxt.strip().startswith("```") or PROMPT_RE.match(nxt):
                    break
                if nxt.strip():
                    expect = nxt.strip()
                    break
        claims.append((cmd, expect))
    return claims


def staleness(log=None, docs=None, runner=None):
    """Sensor S3. `runner(cmd)` -> (rc, out); injectable for fixtures."""
    if runner is None:
        def runner(cmd):
            m = SSH_RE.match(cmd.strip())
            args = (["ssh", "-o", "BatchMode=yes", m.group(1), m.group(2)]
                    if m else shlex.split(cmd))
            try:
                pr = subprocess.run(args, timeout=40, capture_output=True, text=True)
                return pr.returncode, (pr.stdout or pr.stderr).strip()
            except (subprocess.TimeoutExpired, OSError) as e:
                return 124, f"{type(e).__name__}: {e}"
    for doc in docs or []:
        d = Path(doc)
        try:
            text = d.read_text()
        except OSError as e:
            emit("staleness", str(d), "BLIND_DOC_UNREADABLE", str(e), log)
            continue
        for cmd, expect in extract_claims(text):
            label = f"{d.name}: {cmd[:48]}"
            if not is_safe(cmd):
                emit("staleness", label, "UNCHECKABLE",
                     "not on the read-only allowlist -- NOT executed", log)
                continue
            if not expect:
                emit("staleness", label, "UNCHECKABLE",
                     "no recorded result -- the claim was never falsifiable", log)
                continue
            rc, out = runner(cmd)
            key = expect.strip().strip("`").split()[0].strip(".,")
            if rc == 0 and key and key.lower() in out.lower():
                emit("staleness", label, "HOLDS", f"still: {key[:32]}", log)
                continue
            # A recorded sha that is merely an ANCESTOR of the current one is
            # a document aging normally: the claim it supported ("this repo
            # answers") still holds. A claim that FLIPPED -- succeeded then
            # failed, or the reverse -- is a different world-state and the
            # only one worth waking anyone for. Collapsing them makes the
            # sensor cry hazard at every commit, and a sensor that cries
            # hazard at normal gets muted.
            now = out.split()[0] if out.split() else ""
            if (re.fullmatch(r"[0-9a-f]{7,40}", key or "") and
                    re.fullmatch(r"[0-9a-f]{7,40}", now)):
                m = re.search(r"/([\w.-]+?)(?:\.git)?$", cmd)
                # NOT `d` -- that is the document being audited, and rebinding
                # it here silently reattributed every later claim in the file
                # to whichever project this lookup happened to resolve. A lab
                # notebook that misattributes its own records is worse than
                # one that records nothing.
                repo_dir = project_dir(m.group(1), PROJECTS) if m else None
                if repo_dir and git("merge-base", "--is-ancestor", key, now,
                                    cwd=repo_dir)[0] == 0:
                    emit("staleness", label, "EXPIRED_REF_ADVANCED",
                         f"{key[:8]} -> {now[:8]}, ancestor: claim substance intact",
                         log)
                    continue
            emit("staleness", label, "EXPIRED",
                 f"recorded {key[:24]!r}, now rc={rc} {out[:44]!r}", log)



# ------------------------------------------- sensor S6: simultaneity (T4)
# Spec: hf7y/ecosim#7. Perrow's two dimensions are INDEPENDENT and separately
# adjustable, which is what makes the theory a design tool rather than
# fatalism. The self-writing rotation unambiguously raises COUPLING --
# scheduler's turn directly determines the next unit's turn with no buffer,
# and previously a human edited the rotation between turns. That human WAS
# the slack.
#
# Whether it also raises INTERACTIVE COMPLEXITY is genuinely open and is the
# variable nobody is watching. This sensor measures the part that is
# measurable: how many independent change classes move within one turn. One
# turn changing one thing is legible; one turn changing four is where a
# non-localisable failure comes from.
#
# The prediction it tests: if a failure occurs that cannot be localised to a
# single component, coupling was not the cause -- coupling was already known
# to be rising -- interactive complexity was, and it entered through
# simultaneity. Recorded BEFORE an incident rather than reconstructed after,
# which is the entire point.

CHANGE_CLASSES = (
    ("rotation",   lambda p, d: "_paced" in p),
    ("conf",       lambda p, d: p.startswith("schedule/") and "_paced" not in p),
    ("transport",  lambda p, d: "REPO_URL" in d or "insteadOf" in d
                                or "ssh" in p.lower()),
    # Deliberately NOT `"dexter" in diff`: that matched every document that
    # merely MENTIONS the host, and a brief discussing dexter is not a change
    # to a host. Over-broad predicates inflate the very count this sensor
    # exists to report, which would manufacture the finding rather than
    # measure it. Path signals and crontab/systemd edits only.
    ("host",       lambda p, d: "dexter" in p or "crontab" in p
                                or "systemd" in p or "autostart" in p
                                or re.search(r"^[-+].*(crontab|systemctl|"
                                             r"\*/\d+ \* \* \*)", d or "", re.M)),
    ("milestone",  lambda p, d: p.endswith("FOCUS.md") and "**Current:**" in d),
    ("doctrine",   lambda p, d: p.endswith(("CLAUDE.md", "BUILD-DISCIPLINE.md"))
                                or p.startswith("docs/") or p.startswith("BRIEF-")),
)
# 0 is NOT 1. A turn that touched nothing this classifier recognises is
# unclassified, not legible -- reporting it as ONE_CLASS was the same
# two-states-one-symbol collapse this sensor exists to measure, committed
# inside it. NO_CLASS_MATCHED is a prompt to widen the classifier, and it
# must never be read as "a simple turn".
COUNT_SYMBOL = {0: "NO_CLASS_MATCHED", 1: "ONE_CLASS", 2: "TWO_CLASSES",
                3: "THREE_CLASSES"}


def classify_turn(files_and_diffs):
    """(path, diff-text) pairs -> the set of change classes touched."""
    hit = set()
    for path, diff in files_and_diffs:
        for name, pred in CHANGE_CLASSES:
            try:
                if pred(path, diff or ""):
                    hit.add(name)
            except Exception:
                pass
    return hit


def simultaneity(log=None, repo=None, window_min=10, since="24 hours ago",
                 commits=None):
    """Sensor S6. A 'turn' is approximated by a window of commits, since a
    dispatch turn leaves no marker of its own -- stated as a limit, not
    hidden: if scheduler ever stamps a turn id, key on that instead."""
    r = repo or SCHED
    if commits is None:
        rc, out = git("-C", str(r), "log", f"--since={since}",
                      "--format=%H|%ct|%s")
        if rc != 0 or not out.strip():
            emit("simultaneity", str(r), "BLIND_NO_HISTORY",
                 f"no commit history readable: rc={rc} {out[:50]}", log)
            return
        commits = []
        for line in out.splitlines():
            sha, ct, subj = line.split("|", 2)
            files = git("-C", str(r), "show", "--name-only", "--format=", sha)[1]
            pairs = []
            for f in files.splitlines():
                if not f.strip():
                    continue
                d = git("-C", str(r), "show", f"{sha}", "--", f)[1]
                pairs.append((f.strip(), d))
            commits.append((sha[:8], int(ct), subj, pairs))

    commits.sort(key=lambda c: c[1])
    turns, cur = [], []
    for c in commits:
        if cur and (c[1] - cur[-1][1]) > window_min * 60:
            turns.append(cur)
            cur = []
        cur.append(c)
    if cur:
        turns.append(cur)

    for turn in turns:
        pairs = [p for c in turn for p in c[3]]
        classes = classify_turn(pairs)
        n = len(classes)
        sym = COUNT_SYMBOL.get(n, "FOUR_PLUS_CLASSES")
        label = f"{turn[0][0]}..{turn[-1][0]}" if len(turn) > 1 else turn[0][0]
        emit("simultaneity", label, sym,
             f"{n} class(es): {','.join(sorted(classes)) or 'none'} "
             f"({len(turn)} commit(s))", log)



# ---------------------------------------------- sensor S2: accumulation (T2)
# Spec: hf7y/ecosim#3. Finding filed as issue #11: evaporation EXISTS on
# participation INTENSITY (weight-audit.sh decays weight toward a velocity
# tier) but NOT on participation itself -- the weight floor is 1, never 0;
# PARK is explicitly never auto-applied; parked lines are skipped entirely so
# the 0-state is never revisited; nothing removes a line.
#
# This is the COVERAGE half, which is computable now and does not need a
# trend to accumulate: for each participant line, is any decay mechanism in
# scope for it AT ALL? weight-audit.sh is hardcoded to _paced.conf and runs
# only on mandark, so a line that moves to _paced.dexter.conf leaves the
# domain of the only negative feedback in the ecosystem. That is T2's
# predicted condition arriving mechanically, per unit, at the moment it
# moves -- and it is silent, because accumulation is not an error state.

DECAY_TOOL = Path.home() / "Documents/Projects/realisateur/bin/weight-audit.sh"


def accumulation(log=None, mandark=None, dexter=None, tool=None):
    """Sensor S2, coverage half. Reads the decay tool to find WHICH rotation
    file it governs rather than assuming -- if that tool is ever pointed at
    both files, this sensor must notice instead of repeating a stale finding."""
    tp = tool or DECAY_TOOL
    try:
        src = tp.read_text()
    except OSError as e:
        emit("accumulation", str(tp), "BLIND_NO_DECAY_TOOL",
             f"cannot read the decay mechanism, so cannot say what it covers: {e}",
             log)
        return
    governs = set(re.findall(r'PACED_CONF="[^"]*/([^/"]+)"', src))
    covers_dexter = any("dexter" in g for g in governs)
    covers_mandark = any("dexter" not in g for g in governs)

    mp = mandark or SCHED / "schedule/_paced.conf"
    dp = dexter or SCHED / "schedule/_paced.dexter.conf"
    m, _ = parse_conf(mp)
    d, _ = parse_conf(dp)
    if m is None or d is None:
        emit("accumulation", "rotation files", "BLIND_NO_DECAY_TOOL",
             "a rotation file could not be read", log)
        return

    for name in sorted(set(m) | set(d)):
        me = m.get(name, (False, ""))[0]
        de = d.get(name, (False, ""))[0]
        if not me and not de:
            # weight-audit skips enabled=0 lines outright, so nothing will
            # ever re-evaluate this line. Deposited trace, no actor owning
            # its removal -- stigmergy's null case, not a decay mechanism.
            emit("accumulation", name, "NEVER_REVISITED",
                 "parked: the decay pass skips enabled=0, so nothing "
                 "re-evaluates it ever", log)
        elif (de and covers_dexter) or (me and covers_mandark):
            # Asked per line, against the file that line actually lives in.
            # The earlier form hardcoded "on dexter means uncovered", which
            # meant pointing the decay tool at both files could not clear the
            # finding -- a finding the world cannot retire is doctrine, not
            # measurement. Caught by the fixture that tried to retire it.
            emit("accumulation", name, "DECAY_IN_SCOPE",
                 f"weight decay applies (tool governs {sorted(governs) or '?'})",
                 log)
        else:
            where = "dexter" if de else "mandark"
            emit("accumulation", name, "DECAY_OUT_OF_SCOPE",
                 f"enabled on {where}; decay tool governs "
                 f"{sorted(governs) or '?'} only", log)



# --------------------------------------- sensor S1: unit state transitions
# Spec: hf7y/ecosim#2. THE CORE DATASET -- Zach's stated point of the whole
# exercise: "very important data for a more intelligent scheduler philosophy
# that's not simply about fair round robin turns." Duration is not decoration:
# "blocked for 4 hours" and "blocked for 40 seconds" are different states and
# a sensor emitting only BLOCKED collapses them.
#
# THE TRAP, quoted from the spec because it is the one that matters: "If this
# recorder derives VERIFIED_FROM_DEXTER from anything other than observing
# that push land on the ref -- a log line, an exit code, an agent's claim --
# it has become a proxy for the event rather than a record of it. Read the
# state from the ref, not from the runner."
#
# So each symbol below names the artifact it was read from, and
# VERIFIED_FROM_DEXTER is derived ONLY from a commit authored on dexter being
# present at origin. RUN_STARTED/RUN_COMMITTED come from the runner and say so.

def unit_states(log=None, host="dexter", probe=None, origin_probe=None):
    """Transitions per migration unit, each with the evidence it came from."""
    conf_at_origin, why = (None, "")
    if origin_probe:
        conf_at_origin, runlog, authored = origin_probe()
    else:
        rc, conf_at_origin = git("-C", str(SCHED), "show",
                                 "origin/main:schedule/_paced.dexter.conf")
        if rc != 0:
            emit("unit", "origin", "BLIND_NO_UNIT_EVIDENCE",
                 f"cannot read the rotation at origin: {conf_at_origin[:50]}", log)
            return
        try:
            pr = subprocess.run(
                ["ssh", "-o", "BatchMode=yes", host,
                 "cat ~/scheduler/schedule/_paced.dexter.conf 2>/dev/null; echo '---SPLIT---'; "
                 "grep -E '^2026' ~/.local/share/scheduler-paced-runner/run.log 2>/dev/null | tail -40"],
                timeout=40, capture_output=True, text=True)
            host_conf, _, runlog = (pr.stdout or "").partition("---SPLIT---")
        except (subprocess.TimeoutExpired, OSError) as e:
            emit("unit", host, "BLIND_NO_RUNLOG",
                 f"cannot read {host}'s runner log: {type(e).__name__}", log)
            return
        # commits authored ON dexter that are present AT ORIGIN -- the ref,
        # not the runner. This is the proof bar and nothing else substitutes.
        # Window deliberately NOT a flat "last 6 hours": that let a FAILED
        # run inherit an earlier run's proof, so unit 1 reported
        # VERIFIED_FROM_DEXTER on a cycle that had exited rc=1. Evidence must
        # be scoped to the run it is evidence FOR. The window opens at this
        # unit's most recent RUN_STARTED, read from the runner log.
        starts = [l.split()[0] for l in (runlog or "").splitlines()
                  if "DISPATCH" in l]
        since = starts[-1] if starts else "6 hours ago"
        authored = git("-C", str(SCHED), "log", "origin/main", f"--since={since}",
                       "--format=%an|%s")[1]
        conf_at_origin = (conf_at_origin, host_conf)

    queued, host_conf = conf_at_origin if isinstance(conf_at_origin, tuple) else (conf_at_origin, "")
    # BLIND is checked on the DATA, not inside one transport branch. These two
    # symbols were previously emitted only on the live-ssh path, so no fixture
    # could reach them: reachable in production and nowhere else, which is
    # indistinguishable from unreachable until production fails.
    if queued is None:
        emit("unit", "origin", "BLIND_NO_UNIT_EVIDENCE",
             "the rotation at origin could not be read -- no unit claim is "
             "possible either way", log)
        return
    if runlog is None:
        emit("unit", host, "BLIND_NO_RUNLOG",
             f"{host}'s runner log could not be read -- queue state is "
             f"knowable, run state is not", log)
        return
    for line in (queued or "").splitlines():
        s = line.split("#", 1)[0].strip()
        if not s or "|" not in s:
            continue
        f = s.split("|")
        name, enabled = f[0], f[1] == "1"
        if not enabled:
            continue
        emit("unit", name, "QUEUED", "line present and enabled at origin", log)
        if re.search(rf"^{re.escape(name)}\|1\|", host_conf or "", re.M):
            emit("unit", name, "SELECTED", f"{host} has pulled the line", log)
        else:
            emit("unit", name, "BLOCKED",
                 f"queued at origin but {host} has not pulled it yet", log)
            continue
        started = [l for l in (runlog or "").splitlines()
                   if "DISPATCH" in l and f" {name} " in l]
        if started:
            emit("unit", name, "RUN_STARTED",
                 f"runner: {started[-1].split()[0]} (from the runner, not the ref)", log)
        # Pair each DISPATCH with ITS OWN completion. Taking "the last DONE"
        # mixed runs: unit 1 reported BLOCKED from the cycle that ended at
        # 02:55:37 while RUN_PUSHED described the cycle that started at
        # 02:55:38. A DONE that PRECEDES the current dispatch is the previous
        # run's outcome, and reporting it as this one's is the same
        # two-world-states collapse in the time dimension. If no DONE follows
        # the dispatch, the run is still going -- which is a state, not an
        # absence of one.
        done = [l for l in (runlog or "").splitlines()
                if l.strip().startswith("2026") and f"DONE {name} " in l
                and (not started or l.split()[0] >= started[-1].split()[0])]
        if not done:
            emit("unit", name, "RUN_IN_FLIGHT",
                 f"dispatched at {started[-1].split()[0] if started else '?'}, "
                 f"no completion yet -- outcome unknown, not assumed", log)
        else:
            rcs = re.search(r"rc=(\d+)", done[-1])
            secs = re.search(r"\((\d+)s\)", done[-1])
            dur = f" after {secs.group(1)}s" if secs else ""
            if rcs and rcs.group(1) != "0":
                emit("unit", name, "BLOCKED",
                     f"run exited rc={rcs.group(1)}{dur}: {done[-1][:52]}", log)
            else:
                emit("unit", name, "RUN_COMMITTED",
                     f"runner reported success{dur} -- NOT yet proof it "
                     f"reached the ref", log)
        # RUN_COMMITTED and RUN_PUSHED are separate symbols ON PURPOSE: a
        # commit that never reached the ref the consumer clones is the single
        # most repeated failure in this ecosystem's history. This recorder
        # shipped with RUN_PUSHED declared and never emitted -- collapsing the
        # pair by omission, the exact failure the spec warned about, caught by
        # the alphabet ledger within a minute of the sensor landing.
        if (authored or "").strip():
            emit("unit", name, "RUN_PUSHED",
                 f"work reached the ref at origin since this run started "
                 f"({len((authored or '').splitlines())} commit(s)) -- read from "
                 f"the ref, not the runner", log)

        # THE BAR: a commit authored on the far host, visible at origin.
        landed = [l for l in (authored or "").splitlines()
                  if "dexter" in l.lower().split("|")[0]]
        if landed:
            emit("unit", name, "VERIFIED_FROM_DEXTER",
                 f"commit authored on {host} present AT ORIGIN: "
                 f"{landed[0].split('|', 1)[-1][:44]}", log)


# ------------------------------------------------------ sensor 4: histogram
def histogram(path=None, log=None, ledger=None):
    """Sensor 4 -- decides H-M0. Counts emissions per (sensor, symbol) and
    classifies every declared symbol into THREE states, because "never
    emitted" was itself two world-states wearing one symbol:

      PROVEN_LIVE       fired against the real ecosystem
      FIXTURE_ONLY      proven reachable by a named test, but its world-state
                        has not occurred yet (correct, and expected before the
                        migration moves anything)
      UNPROVEN_ANYWHERE never fired in a fixture OR live -- suspect the symbol
                        is unreachable in code, which is how the 19/19 probe
                        passed with an alphabet of {READY}

    Only the third is a defect. Collapsing it into the second is what let a
    genuinely unreachable BLIND_CONF_DIR_UNREADABLE sit declared in this file
    while an audit over a missing conf directory returned clean.
    """
    p = path or EVENTS
    counts, missing = {}, []
    try:
        lines = p.read_text().splitlines()
    except OSError as e:
        print(f"BLIND: cannot read event log {p}: {e}", file=sys.stderr)
        return 2
    for line in lines:
        if not line.strip():
            continue
        r = json.loads(line)
        counts[(r["sensor"], r["symbol"])] = counts.get((r["sensor"], r["symbol"]), 0) + 1
    try:
        proven = {tuple(x) for x in json.loads((ledger or FIXTURE_LEDGER).read_text())}
        have_ledger = True
    except (OSError, ValueError):
        proven, have_ledger = set(), False
    unproven = []
    for sensor, syms in ALPHABET.items():
        for s in syms:
            if counts.get((sensor, s), 0) == 0:
                missing.append((sensor, s))
                if not (sensor, s) in proven:
                    unproven.append((sensor, s))
    for (sensor, sym), n in sorted(counts.items()):
        print(f"{n:6d}  {sensor}.{sym}   PROVEN_LIVE")
    for sensor, sym in missing:
        if not have_ledger:
            tag = "NO_FIXTURE_LEDGER -- run --selftest first (BLIND)"
        elif (sensor, sym) in proven:
            tag = "FIXTURE_ONLY -- reachable, world-state has not occurred"
        else:
            tag = "UNPROVEN_ANYWHERE -- suspect unreachable in code"
        print(f"     0  {sensor}.{sym}   {tag}")
    if not have_ledger:
        print("\nBLIND: no fixture ledger, cannot tell FIXTURE_ONLY from "
              "UNPROVEN_ANYWHERE", file=sys.stderr)
        return 2
    print(f"\n{len(counts)} proven live, "
          f"{len(missing) - len(unproven)} fixture-only, "
          f"{len(unproven)} UNPROVEN ANYWHERE")
    return 1 if unproven else 0


# ------------------------------------------------------------- negative tests
def selftest():
    """The §4 bar: a known-bad input per symbol, asserting the failure symbol
    appears. Each assertion fails if its symbol is removed from the code."""
    tmp = Path(tempfile.mkdtemp(prefix="ecosim-selftest-"))
    fails = []
    seen = set()
    _IN_SELFTEST.append(seen)

    def want(sym, log, ctx):
        if not any(r["symbol"] == sym for r in log):
            fails.append(f"{ctx}: expected {sym}, got {sorted({r['symbol'] for r in log})}")

    try:
        # rotation: a project enabled on both hosts, and one enabled on neither
        (tmp / "m.conf").write_text(
            "dup|1|1|x\norphan|0|1|x\nfine|1|1|x\nchezz-sweep|1|x\naedile|0|x\n")
        (tmp / "d.conf").write_text("dup|1|1|x\norphan|0|1|x\nfine|0|1|x\n")
        # Fixtures that are not ABOUT divergence must have dexter's own copy
        # agree with mandark's, or they silently test a different scenario.
        def _mirror_d(_host):
            return parse_conf(tmp / "d.conf")[0], None

        # no baseline yet: "enabled nowhere" must be BLIND, not a verdict
        log = []
        rb = tmp / "rot-baseline.json"
        rotation(log, tmp / "m.conf", tmp / "d.conf", rot_baseline=rb,
                 freeze=tmp / "no-freeze",
                 conf_probe=_mirror_d)
        want("BLIND_NO_ROTATION_BASELINE", log, "rotation/no-baseline")
        if any(r["symbol"] in ("ORPHANED_IN_MIGRATION", "PARKED_AT_BASELINE")
               for r in log):
            fails.append("rotation: ruled on parked-vs-orphaned with no baseline")

        # Fixtures must not read the live ecosystem. This one caught itself:
        # when THE PLAY engaged a real freeze file, four fixtures that had
        # never mentioned freezing started failing, because rotation()'s
        # default freeze path is the live one. A test whose result depends on
        # production state is not a test.
        if "no-freeze" not in open(__file__).read():
            fails.append("selftest: rotation fixtures are not pinned away from "
                         "the live freeze file")

        # ROTATION_DIVERGED: the live 2026-07-29 case. mandark's copy of
        # _paced.dexter.conf says enabled; dexter's own says parked. The
        # sensor must report the disagreement AND judge from dexter's copy,
        # because that is the file dexter dispatches from.
        log = []
        rotation(log, tmp / "m.conf", tmp / "d.conf", rot_baseline=rb,
                 freeze=tmp / "no-freeze",
                 conf_probe=lambda h: ({"dup": (False, "dup|0|0|x")}, None))
        want("ROTATION_DIVERGED", log, "rotation/hosts-disagree")
        got = {r["subject"]: r["symbol"] for r in log if r["symbol"] != "ROTATION_DIVERGED"}
        if got.get("dup") == "IN_BOTH_ENABLED":
            fails.append("rotation: judged from mandark's copy after dexter's "
                         "own copy said parked -- reported a dup that dexter "
                         "does not have")

        # unreadable host conf must be BLIND and must SAY the fallback happened
        log = []
        rotation(log, tmp / "m.conf", tmp / "d.conf", rot_baseline=rb,
                 freeze=tmp / "no-freeze",
                 conf_probe=lambda h: (None, "ssh failed"))
        want("BLIND_HOST_CONF_UNREADABLE", log, "rotation/host-conf-unreadable")

        # FROZEN: an enabled project under an active freeze is NOT dispatching.
        # Reporting it IN_ONE is the null-discriminator the play created.
        fz = tmp / "FREEZE"
        fz.write_text("# hdr\nparticipants frozen for the bootstrap play\n"
                      "EXEMPT: fine\n")
        log = []
        rotation(log, tmp / "m.conf", tmp / "d.conf", rot_baseline=rb, freeze=fz)
        # the freeze is present on BOTH hosts
        log = []
        rotation(log, tmp / "m.conf", tmp / "d.conf", rot_baseline=rb, freeze=fz,
                 host_probe=lambda h: True,
                 conf_probe=_mirror_d)
        want("FROZEN", log, "rotation/frozen-participant")
        want("FROZEN_EXEMPT", log, "rotation/exempt-orchestrator")

        # host-scoped exemption: exempt on its own host, frozen on the other.
        # The bare form must still mean every host.
        fz.write_text("frozen\nEXEMPT: fine@dexter\n")
        log = []
        rotation(log, tmp / "m.conf", tmp / "d.conf", rot_baseline=rb, freeze=fz,
                 host_probe=lambda h: True,
                 conf_probe=_mirror_d)
        got = {r["subject"]: r["symbol"] for r in log}
        if got.get("fine") != "FROZEN":
            fails.append(f"rotation: fine is enabled on mandark and exempt only "
                         f"on dexter, so it must be FROZEN; got {got.get('fine')}")
        # `fine` is mandark-only, so an @mandark exemption must reach it
        fz.write_text("frozen\nEXEMPT: fine@mandark\n")
        log = []
        rotation(log, tmp / "m.conf", tmp / "d.conf", rot_baseline=rb, freeze=fz,
                 host_probe=lambda h: True,
                 conf_probe=_mirror_d)
        want("FROZEN_EXEMPT", log, "rotation/host-scoped-exempt")
        # and a duplicated line must not claim it "dispatches twice" while a
        # freeze is holding it
        if any(r["symbol"] == "IN_BOTH_ENABLED" and "would dispatch" not in r["detail"]
               for r in log):
            fails.append("rotation: asserted a dup dispatches twice while a "
                         "freeze was engaged")
        fz.write_text("frozen\nEXEMPT: fine\n")

        # the live 2026-07-29 case: engaged here, never pulled there. A
        # dexter-hosted project must NOT be reported frozen on the strength of
        # mandark's copy -- that is asserting over an unread domain.
        log = []
        rotation(log, tmp / "m.conf", tmp / "d.conf", rot_baseline=rb, freeze=fz,
                 host_probe=lambda h: False,
                 conf_probe=_mirror_d)
        want("FREEZE_NOT_PROPAGATED", log, "rotation/freeze-not-pulled")
        if any(r["symbol"] in ("FROZEN", "FROZEN_EXEMPT") for r in log):
            fails.append("rotation: claimed FROZEN for a host that never "
                         "received the freeze -- the abort handle's own "
                         "failure mode, reported as success")

        # host unreadable is BLIND, never "frozen" and never "will dispatch"
        log = []
        rotation(log, tmp / "m.conf", tmp / "d.conf", rot_baseline=rb, freeze=fz,
                 host_probe=lambda h: None,
                 conf_probe=_mirror_d)
        want("BLIND_FREEZE_UNKNOWN", log, "rotation/host-unreadable")
        if any(r["symbol"] in ("FROZEN", "FREEZE_NOT_PROPAGATED") for r in log):
            fails.append("rotation: guessed a freeze state for an unreadable host")

        log = []
        rotation(log, tmp / "m.conf", tmp / "d.conf", rot_baseline=rb, freeze=fz,
                 host_probe=lambda h: True,
                 conf_probe=_mirror_d)
        if any(r["symbol"] == "IN_ONE" for r in log):
            fails.append("rotation: reported IN_ONE under an active freeze -- "
                         "'dispatching' and 'refused at dispatch' collapsed")
        # word-boundary: a name CONTAINING an exempt name is not exempt
        fz.write_text("frozen\nEXEMPT: sched\n")
        log = []
        rotation(log, tmp / "m.conf", tmp / "d.conf", rot_baseline=rb, freeze=fz)
        if any(r["symbol"] == "FROZEN_EXEMPT" for r in log):
            fails.append("rotation: substring match exempted a project that was "
                         "not named -- absence of a name is not a match")

        # baseline captured with 'orphan' already off: it is PARKED, not lost
        log = []
        rotation(log, tmp / "m.conf", tmp / "d.conf", rot_baseline=rb,
                 snapshot=True, freeze=tmp / "no-freeze",
                 conf_probe=_mirror_d)
        want("PARKED_AT_BASELINE", log, "rotation/parked")
        want("IN_BOTH_ENABLED", log, "rotation/dup")
        want("IN_ONE", log, "rotation/fine")
        want("BLIND_BY_CONSTRUCTION", log, "rotation/aedile")

        # A deliberate park mid-migration is NOT a seam orphan. Both are
        # "enabled nowhere"; the attributing commit separates them.
        (tmp / "m.conf").write_text(
            "dup|1|1|x\norphan|0|1|x\nfine|0|1|x\nchezz-sweep|1|x\naedile|0|x\n")
        log = []
        rotation(log, tmp / "m.conf", tmp / "d.conf", rot_baseline=rb,
                 freeze=tmp / "no-freeze", conf_probe=_mirror_d,
                 why_probe=lambda n: "_paced.dexter.conf: park crt and wtul (by hand)")
        want("PARKED_DURING_MIGRATION", log, "rotation/deliberate-park")
        if any(r["symbol"] == "ORPHANED_IN_MIGRATION" for r in log):
            fails.append("rotation: a deliberate park was reported as a seam "
                         "orphan -- H-M6's headline symbol on a correct action")
        # and an unexplained disappearance is STILL an orphan
        log = []
        rotation(log, tmp / "m.conf", tmp / "d.conf", rot_baseline=rb,
                 freeze=tmp / "no-freeze", conf_probe=_mirror_d,
                 why_probe=lambda n: "refactor conf loader")
        want("ORPHANED_IN_MIGRATION", log, "rotation/unexplained-orphan")

        # now 'fine' is dropped from both files mid-migration -> ORPHANED.
        # Same file state as 'orphan' above; opposite meaning; different symbol.
        (tmp / "m.conf").write_text(
            "dup|1|1|x\norphan|0|1|x\nfine|0|1|x\nchezz-sweep|1|x\naedile|0|x\n")
        log = []
        # why_probe pinned: unpinned, this fixture ssh'd to the REAL dexter,
        # picked up its genuine park commit, and turned a seam-orphan test into
        # a deliberate-park test. Second time tonight a fixture silently read
        # production -- the first was the live freeze file.
        rotation(log, tmp / "m.conf", tmp / "d.conf", rot_baseline=rb,
                 freeze=tmp / "no-freeze",
                 conf_probe=_mirror_d, why_probe=lambda n: "")
        want("ORPHANED_IN_MIGRATION", log, "rotation/orphaned-in-migration")
        if any(r["subject"] == "fine" and r["symbol"] == "PARKED_AT_BASELINE"
               for r in log):
            fails.append("rotation: seam orphan collided into PARKED_AT_BASELINE")
        if not any(r["subject"] == "orphan" and r["symbol"] == "PARKED_AT_BASELINE"
                   for r in log):
            fails.append("rotation: deliberately parked project flagged as a hazard")
        if any(r["subject"] == "chezz-sweep" and r["symbol"].startswith("BLIND")
               for r in log):
            fails.append("rotation: 3-field line misparsed as BLIND (real "
                         "chezz-sweep line would flood the log)")

        # rotation: a garbage line must be reported, never silently skipped
        (tmp / "bad.conf").write_text("this is not a conf line\nfine|1|1|x\n")
        log = []
        rotation(log, tmp / "bad.conf", tmp / "d.conf", freeze=tmp / "no-freeze",
                 conf_probe=_mirror_d)
        want("BLIND_UNPARSEABLE_LINE", log, "rotation/garbage")

        # rotation: an unreadable file must be BLIND, and must NOT then go on
        # to assert anything about the projects it could not see
        log = []
        rotation(log, tmp / "does-not-exist.conf", tmp / "d.conf",
                 freeze=tmp / "no-freeze",
                 conf_probe=_mirror_d)
        want("BLIND_FILE_UNREADABLE", log, "rotation/missing-file")
        if any(r["symbol"] in ("IN_ONE", "IN_BOTH_ENABLED", "IN_NEITHER_ENABLED")
               for r in log):
            fails.append("rotation: asserted over a domain it could not read")

        # milestones: unrestored override, restored override, and a FOCUS.md
        # with no Current line (bibliothecaire is exactly this today)
        root = tmp / "projects"
        for name, body in (
                ("kept", "**Current:** bootstrap yourself on dexter\n"),
                ("gave-back", "**Current:** the real bar\n"),
                ("no-current", "# FOCUS\nno milestone line here\n"),
                ("untouched", "**Current:** steady\n")):
            (root / name / ".scheduler").mkdir(parents=True)
            (root / name / ".scheduler/FOCUS.md").write_text(body)
        (root / "no-focus").mkdir()
        NAMES = {"kept", "gave-back", "no-current", "untouched", "no-focus"}
        b = tmp / "baseline.json"
        b.write_text(json.dumps({"captured": "t", "projects": {
            "kept": {"symbol": "CAPTURED", "current": "**Current:** bootstrap yourself on dexter"},
            "gave-back": {"symbol": "CAPTURED", "current": "**Current:** bootstrap yourself on dexter"},
            "no-current": {"symbol": "CAPTURED", "current": "**Current:** was here"},
            "untouched": {"symbol": "CAPTURED", "current": "**Current:** steady"},
        }}))
        log = []
        milestones(diff=True, log=log, root=root, baseline=b, names=NAMES)
        want("UNRESTORED", log, "milestones/kept")
        want("CHANGED_OTHER", log, "milestones/gave-back")
        want("BLIND_NO_CURRENT_LINE", log, "milestones/no-current")
        want("BLIND_NO_FOCUS_FILE", log, "milestones/no-focus")
        want("UNCHANGED", log, "milestones/untouched")

        # milestones: OVERRIDDEN -- baseline holds the real bar, current holds
        # the override. This is the mid-migration state.
        b2 = tmp / "baseline2.json"
        b2.write_text(json.dumps({"captured": "t", "projects": {
            "kept": {"symbol": "CAPTURED", "current": "**Current:** the real bar"},
            "untouched": {"symbol": "CAPTURED", "current": "**Current:** steady"}}}))
        log = []
        milestones(diff=True, log=log, root=root, baseline=b2, names=NAMES,
                   events=tmp / "no-history.jsonl")
        want("OVERRIDDEN", log, "milestones/kept")
        want("CAPTURED", [{"symbol": read_milestone(root / "untouched")[0]}],
             "milestones/snapshot")

        # milestones: RESTORED -- same bytes as UNCHANGED, told apart ONLY by
        # the log remembering an earlier OVERRIDDEN. This assertion is what
        # proves the two states do not collide.
        hist = tmp / "history.jsonl"
        hist.write_text(json.dumps({"ts": "t", "sensor": "milestones",
                                    "subject": "kept", "symbol": "OVERRIDDEN"}) + "\n")
        (root / "kept" / ".scheduler/FOCUS.md").write_text("**Current:** the real bar\n")
        log = []
        milestones(diff=True, log=log, root=root, baseline=b2, names=NAMES,
                   events=hist)
        want("RESTORED", log, "milestones/kept-restored")
        if any(r["subject"] == "kept" and r["symbol"] == "UNCHANGED" for r in log):
            fails.append("milestones: RESTORED collided into UNCHANGED -- the "
                         "two world-states share one symbol")
        # ...and the same bytes with NO history must NOT claim RESTORED
        log = []
        milestones(diff=True, log=log, root=root, baseline=b2, names=NAMES,
                   events=tmp / "no-history.jsonl")
        if any(r["subject"] == "kept" and r["symbol"] == "RESTORED" for r in log):
            fails.append("milestones: claimed RESTORED with no override in the log")

        # S5: the 19/19 bug itself -- a failing remote MUST yield a nonzero
        # rc. This is the assertion that would have caught `ls-remote | head`.
        rc, _ = git("ls-remote", str(tmp / "definitely-not-a-repo.git"))
        if rc == 0:
            fails.append("dispatch_ref: a nonexistent remote returned rc=0 -- "
                         "this is the 19/19 failure exactly")
        sha, why = ls_remote_head(str(tmp / "definitely-not-a-repo.git"))
        if sha is not None:
            fails.append("dispatch_ref: ls_remote_head invented a sha for a "
                         "nonexistent remote")

        # S5: a conf with no REPO_URL must be BLIND, not skipped
        cd = tmp / "confs"; cd.mkdir()
        (cd / "noURL.conf").write_text("BATCH_TEST_CMD=\"true\"\n")
        log = []
        dispatch_ref(log, host=None, confs=cd, projects_root=tmp)
        want("BLIND_NO_REPO_URL", log, "dispatch_ref/no-url")

        # S5: an unreachable dispatch ref must say so, never EQUAL
        (cd / "gone.conf").write_text('REPO_URL="%s/nope.git"\n' % tmp)
        log = []
        dispatch_ref(log, host=None, confs=cd, projects_root=tmp)
        want("UNREACHABLE_FROM_HOST", log, "dispatch_ref/unreachable")
        if any(r["symbol"] == "EQUAL" for r in log):
            fails.append("dispatch_ref: reported EQUAL for an unreachable ref")

        # S5: a real BEHIND must be measured, not guessed. Build two repos
        # where one is a strict ancestor of the other.
        up = tmp / "up.git"; work = tmp / "work"
        git("init", "--bare", "-q", str(up))
        git("init", "-q", str(work))
        (work / "f").write_text("1")
        git("-C", str(work), "add", "f"); git("-C", str(work), "-c", "user.email=t@t",
            "-c", "user.name=t", "commit", "-qm", "one")
        git("-C", str(work), "remote", "add", "origin", str(up))
        git("-C", str(work), "push", "-q", "origin", "HEAD:refs/heads/main")
        old = git("-C", str(work), "rev-parse", "HEAD")[1]
        (work / "f").write_text("2")
        git("-C", str(work), "add", "f"); git("-C", str(work), "-c", "user.email=t@t",
            "-c", "user.name=t", "commit", "-qm", "two")
        new = git("-C", str(work), "rev-parse", "HEAD")[1]
        if git("-C", str(work), "merge-base", "--is-ancestor", old, new)[0] != 0:
            fails.append("dispatch_ref: ancestry probe cannot detect a real ancestor")
        if git("-C", str(work), "merge-base", "--is-ancestor", new, old)[0] == 0:
            fails.append("dispatch_ref: ancestry probe calls a descendant an ancestor "
                         "-- BEHIND and AHEAD would collide")


        # ---- S5 ancestry symbols. Until now AHEAD, DIVERGED,
        # INDETERMINATE_ANCESTRY, UNREACHABLE_GITHUB and BLIND_CONF_DIR_
        # UNREADABLE were declared but proven NOWHERE -- not live, not in a
        # fixture. A declared-but-unreachable symbol is how the 19/19 probe
        # passed: its alphabet contained READY and nothing else could ever be
        # reached. These fixtures make each one fire against real git repos.
        def _mkrepo(path, commits):
            git("init", "-q", "--bare", str(path) + ".git")
            w = Path(str(path) + ".work")
            git("init", "-q", str(w))
            git("-C", str(w), "remote", "add", "origin", str(path) + ".git")
            for c in commits:
                (w / "f").write_text(c)
                git("-C", str(w), "add", "f")
                git("-C", str(w), "-c", "user.email=t@t", "-c", "user.name=t",
                    "commit", "-qm", c)
            git("-C", str(w), "push", "-q", "origin", "HEAD:refs/heads/main")
            git("-C", str(path) + ".git", "symbolic-ref", "HEAD", "refs/heads/main")
            return w

        gitdir = tmp / "s5"
        gitdir.mkdir()
        confs2 = tmp / "confs2"
        confs2.mkdir()
        root2 = tmp / "root2"
        root2.mkdir()

        # EQUAL: dispatch ref and counterpart at the same sha
        w = _mkrepo(gitdir / "same", ["a"])
        git("clone", "-q", str(gitdir / "same.git"), str(root2 / "same"))
        (confs2 / "same.conf").write_text('REPO_URL="%s"\n' % (gitdir / "same.git"))

        # BEHIND: counterpart has one commit the dispatch ref lacks
        w = _mkrepo(gitdir / "behind", ["a"])
        git("clone", "-q", str(gitdir / "behind.git"), str(root2 / "behind"))
        ahead_repo = gitdir / "behind_gh.git"
        git("clone", "-q", "--bare", str(gitdir / "behind.git"), str(ahead_repo))
        git("-C", str(ahead_repo), "symbolic-ref", "HEAD", "refs/heads/main")
        (w / "f").write_text("b")
        git("-C", str(w), "add", "f")
        git("-C", str(w), "-c", "user.email=t@t", "-c", "user.name=t",
            "commit", "-qm", "b")
        git("-C", str(w), "push", "-q", str(ahead_repo), "HEAD:refs/heads/main")
        git("-C", str(root2 / "behind"), "fetch", "-q", str(ahead_repo))
        (confs2 / "behind.conf").write_text('REPO_URL="%s"\n' % (gitdir / "behind.git"))

        # DIVERGED: each side holds a commit the other does not
        w = _mkrepo(gitdir / "div", ["a"])
        git("clone", "-q", str(gitdir / "div.git"), str(root2 / "div"))
        div_gh = gitdir / "div_gh.git"
        git("clone", "-q", "--bare", str(gitdir / "div.git"), str(div_gh))
        git("-C", str(div_gh), "symbolic-ref", "HEAD", "refs/heads/main")
        (w / "f").write_text("left")
        git("-C", str(w), "add", "f")
        git("-C", str(w), "-c", "user.email=t@t", "-c", "user.name=t",
            "commit", "-qm", "left")
        git("-C", str(w), "push", "-qf", str(gitdir / "div.git"), "HEAD:refs/heads/main")
        git("-C", str(root2 / "div"), "fetch", "-q", str(gitdir / "div.git"))
        git("-C", str(w), "reset", "-q", "--hard", "HEAD~1")
        (w / "f").write_text("right")
        git("-C", str(w), "add", "f")
        git("-C", str(w), "-c", "user.email=t@t", "-c", "user.name=t",
            "commit", "-qm", "right")
        git("-C", str(w), "push", "-qf", str(div_gh), "HEAD:refs/heads/main")
        git("-C", str(root2 / "div"), "fetch", "-q", str(div_gh))
        (confs2 / "div.conf").write_text('REPO_URL="%s"\n' % (gitdir / "div.git"))

        # INDETERMINATE_ANCESTRY: differing shas, no local checkout to resolve
        (confs2 / "nocheckout.conf").write_text(
            'REPO_URL="%s"\n' % (gitdir / "behind.git"))

        # UNREACHABLE_GITHUB: dispatch ref fine, counterpart absent
        (confs2 / "noremote.conf").write_text(
            'REPO_URL="%s"\n' % (gitdir / "same.git"))

        def _gh(name):
            return {"same": str(gitdir / "same.git"),
                    "behind": str(ahead_repo),
                    "div": str(div_gh),
                    "nocheckout": str(ahead_repo),
                    "noremote": str(tmp / "no-such-remote.git")}.get(name, "")

        log = []
        dispatch_ref(log, host=None, confs=confs2, projects_root=root2, gh_url=_gh)
        want("EQUAL", log, "dispatch_ref/equal")
        want("BEHIND", log, "dispatch_ref/behind")
        want("DIVERGED", log, "dispatch_ref/diverged")
        want("INDETERMINATE_ANCESTRY", log, "dispatch_ref/no-checkout")
        want("UNREACHABLE_GITHUB", log, "dispatch_ref/absent-counterpart")
        for r in log:
            if r["subject"] == "same" and r["symbol"] != "EQUAL":
                fails.append(f"dispatch_ref: identical shas reported {r['symbol']}")
            if r["subject"] == "div" and r["symbol"] == "BEHIND":
                fails.append("dispatch_ref: DIVERGED collided into BEHIND -- "
                             "a clean repoint and a two-sided divergence are "
                             "different severities")

        # AHEAD: dispatch ref carries a commit the counterpart lacks. Same
        # fixture inverted -- proving the pair cannot collapse into one symbol.
        def _gh_inv(name):
            return {"behind": str(gitdir / "behind.git")}.get(name, "")
        (confs2 / "same.conf").unlink()
        (confs2 / "div.conf").unlink()
        (confs2 / "nocheckout.conf").unlink()
        (confs2 / "noremote.conf").unlink()
        (confs2 / "behind.conf").write_text('REPO_URL="%s"\n' % ahead_repo)
        log = []
        dispatch_ref(log, host=None, confs=confs2, projects_root=root2, gh_url=_gh_inv)
        want("AHEAD", log, "dispatch_ref/ahead")

        # BLIND_CONF_DIR_UNREADABLE: a conf directory that is not there
        log = []
        dispatch_ref(log, host=None, confs=tmp / "no-such-confdir",
                     projects_root=root2)
        want("BLIND_CONF_DIR_UNREADABLE", log, "dispatch_ref/no-confdir")


        # ---- S4 credential classifier. Every symbol fixtured in BOTH
        # directions, per the spec: the whole value of this sensor is telling
        # a dead credential from a repo-specific failure, and a test of only
        # one direction proves only that it can say something.
        cases = [
            ((0, "abc123\tHEAD"), (0, "abc123\tHEAD"), "CREDENTIAL_OK"),
            ((128, "fatal: Authentication failed for 'https://github.com/'"),
             (128, "fatal: Authentication failed"), "CREDENTIAL_GONE"),
            ((0, "abc123\tHEAD"),
             (128, "ERROR: Repository not found."), "REPO_SPECIFIC_FAILURE"),
            ((128, "ssh: Could not resolve host: github.com"),
             (128, "ssh: Could not resolve host: github.com"), "INDETERMINATE"),
            ((0, "abc123\tHEAD"),
             (124, "TimeoutExpired: probe timed out"), "INDETERMINATE"),
            ((128, "fatal: unable to access: SSL certificate problem"),
             (128, "whatever"), "INDETERMINATE"),
        ]
        for (crc, cout), (trc, tout), expect in cases:
            got, _ = classify_credential(crc, cout, trc, tout)
            if got != expect:
                fails.append(f"credential: canary={cout[:28]!r} target={tout[:28]!r} "
                             f"-> {got}, expected {expect}")

        # the two symbols that must never be confused, asserted as a pair
        gone, _ = classify_credential(128, "Authentication failed", 128, "Authentication failed")
        repo, _ = classify_credential(0, "abc\tHEAD", 128, "Repository not found")
        if gone == repo:
            fails.append("credential: CREDENTIAL_GONE and REPO_SPECIFIC_FAILURE "
                         "collapsed into one symbol -- the sensor's entire job")

        # end to end through the emitter, with an injected probe: a dead
        # credential must also emit the shared-fate '*' record, because one
        # credential failing is ONE world-state, not N independent ones
        log = []
        credential(log, host=None, canary="canary",
                   targets=["canary", "a", "b"],
                   probe=lambda u: (128, "fatal: Authentication failed"))
        want("CREDENTIAL_GONE", log, "credential/dead-token")
        if not any(r["subject"] == "*" for r in log):
            fails.append("credential: no shared-fate record for a dead credential")
        if len([r for r in log if r["subject"] in ("a", "b")]) > 0:
            fails.append("credential: kept probing after the credential was gone "
                         "-- N reports of one world-state")

        # INDETERMINATE must fire through the EMITTER, not only through the
        # pure classifier. It was proven as a function and unproven as a
        # symbol -- the ledger caught that within a minute of the sensor
        # landing, which is the entire argument for having the ledger.
        log = []
        credential(log, host=None, canary="canary", targets=["canary"],
                   probe=lambda u: (128, "ssh: Could not resolve host: github.com"))
        want("INDETERMINATE", log, "credential/network-fault")
        if any(r["symbol"] == "CREDENTIAL_GONE" for r in log):
            fails.append("credential: a network fault was reported as a dead "
                         "credential -- the one guess this sensor must not make")

        log = []
        credential(log, host=None, canary="canary", targets=["canary", "missing"],
                   probe=lambda u: (0, "abc\tHEAD") if u == "canary"
                   else (128, "ERROR: Repository not found."))
        want("REPO_SPECIFIC_FAILURE", log, "credential/one-repo")
        want("CREDENTIAL_OK", log, "credential/canary-fine")


        # ---- S4b: the API credential, read from the gate's own verdict line
        for code, expect in (("401", "API_CREDENTIAL_GONE"),
                             ("403", "API_CREDENTIAL_GONE"),
                             ("200", "API_CREDENTIAL_OK"),
                             ("", "API_INDETERMINATE")):
            log = []
            api_credential(log, probe=lambda h, c=code: (
                f"2026-07-29T06:00:03-05:00 HOLD (gate rc=2) verdict=ERROR "
                + (f"http_code={c}" if c else "reason=timeout")))
            want(expect, log, f"api_credential/http_{code or 'none'}")
        log = []
        api_credential(log, probe=lambda h: "")
        want("BLIND_NO_GATE_LINE", log, "api_credential/no-gate-line")

        # rate, not just the last sample: an intermittent fault and a current
        # outage produce the same final line. Reporting the first as the
        # second nearly produced a false migration finding.
        many = "\n".join(
            [f"2026-07-28T0{i}:00:00-05:00 verdict=ERROR http_code=401" for i in range(1, 5)]
            + [f"2026-07-29T0{i}:00:00-05:00 verdict=RUN http_code=200" for i in range(1, 6)])
        log = []
        api_credential(log, probe=lambda h: many)
        if not any("streak 0" in r["detail"] for r in log):
            fails.append("api_credential: healthy-now after past failures did "
                         "not report a zero streak")
        log = []
        api_credential(log, probe=lambda h: many + "\n"
                       "2026-07-29T07:00:00-05:00 verdict=ERROR http_code=401")
        got = [r for r in log if r["symbol"] == "API_CREDENTIAL_GONE"]
        if not got or "streak 1" not in got[0]["detail"]:
            fails.append("api_credential: a single fresh failure after healthy "
                         "samples must report streak 1, not an outage")
        # a short streak under a much worse historical one is NOT novel
        hist = "\n".join([f"2026-07-27T0{i}:00:00 verdict=ERROR http_code=401"
                           for i in range(1, 10)]
                          + ["2026-07-28T01:00:00 verdict=RUN http_code=200",
                             "2026-07-29T07:00:00 verdict=ERROR http_code=401"])
        log = []
        api_credential(log, probe=lambda h: hist)
        d = [r["detail"] for r in log if r["symbol"] == "API_CREDENTIAL_GONE"]
        if not d or "within prior behaviour" not in d[0]:
            fails.append("api_credential: a streak of 1 under a prior streak of "
                         "9 was not reported as within prior behaviour")
        # a quota HOLD is NOT a dead key
        log = []
        api_credential(log, probe=lambda h:
                       "2026-07-29T05:30:03-05:00 HOLD (gate rc=1) verdict=HOLD "
                       "http_code=200 # HOLD -- 7d window 36% used")
        if any(r["symbol"] == "API_CREDENTIAL_GONE" for r in log):
            fails.append("api_credential: a quota HOLD was reported as a dead "
                         "credential -- the gate distinguishes these and so must we")

        # ---- S3 staleness. The spec's required negative test: feed it a
        # claim known to be FALSE and assert EXPIRED. If it says HOLDS it is
        # reading the prose, not the world.
        doc = tmp / "stale.md"
        doc.write_text(
            "# fixture\n\n```\n"
            "$ command -v gh   → not installed\n"
            "$ git ls-remote https://example.invalid/x.git   → deadbeef\n"
            "$ rm -rf /   → nothing\n"
            "$ git status\n"
            "```\n")
        def _run(cmd):
            return {"command -v gh": (0, "/usr/bin/gh")}.get(cmd, (1, "no"))
        log = []
        staleness(log, docs=[doc], runner=_run)
        want("EXPIRED", log, "staleness/gh-claim")
        if any(r["symbol"] == "HOLDS" and "command -v gh" in r["subject"] for r in log):
            fails.append("staleness: read the prose instead of the world -- the "
                         "claim 'gh is not installed' is false and reported HOLDS")
        want("UNCHECKABLE", log, "staleness/unsafe-or-unfalsifiable")
        if not any(r["symbol"] == "UNCHECKABLE" and "rm -rf" in r["subject"] for r in log):
            fails.append("staleness: a destructive command was not refused")
        if any("rm -rf" in str(c) for c in _run.__dict__.get("calls", [])):
            fails.append("staleness: executed a non-allowlisted command")
        want("BLIND_DOC_UNREADABLE", log, "staleness/missing-doc") if False else None
        log2 = []
        staleness(log2, docs=[tmp / "no-such-doc.md"], runner=_run)
        want("BLIND_DOC_UNREADABLE", log2, "staleness/missing-doc")

        # EXPIRED_REF_ADVANCED: a sha that moved forward in this very repo.
        # Uses ecosim itself, whose HEAD has advanced tonight.
        head_now = git("-C", str(REPO), "rev-parse", "HEAD")[1]
        old = git("-C", str(REPO), "rev-parse", "HEAD~3")[1]
        doc3 = tmp / "aged.md"
        doc3.write_text("```\n$ git ls-remote https://github.com/hf7y/ecosim.git"
                        "   → %s\n```\n" % old[:8])
        log4 = []
        staleness(log4, docs=[doc3], runner=lambda c: (0, head_now))
        want("EXPIRED_REF_ADVANCED", log4, "staleness/ref-advanced")
        # every record must be attributed to the document it came from
        doc4 = tmp / "multi.md"
        doc4.write_text("```\n$ git ls-remote https://github.com/hf7y/ecosim.git"
                        "   → %s\n$ command -v gh   → not installed\n```\n" % old[:8])
        log5 = []
        staleness(log5, docs=[doc4],
                  runner=lambda c: (0, head_now) if "ls-remote" in c else (0, "/usr/bin/gh"))
        if not all(r["subject"].startswith("multi.md:") for r in log5):
            fails.append("staleness: records misattributed to another document -- "
                         f"{[r['subject'][:24] for r in log5]}")
        if any(r["symbol"] == "EXPIRED" for r in log4):
            fails.append("staleness: a normally-advancing ref was reported as a "
                         "flipped claim -- this is what gets a sensor muted")

        # HOLDS must be reachable too, or the sensor only knows how to complain
        doc2 = tmp / "fresh.md"
        doc2.write_text("```\n$ command -v gh   → /usr/bin/gh\n```\n")
        log3 = []
        staleness(log3, docs=[doc2], runner=_run)
        want("HOLDS", log3, "staleness/current-claim")

        # the allowlist itself
        for bad in ("rm -rf /", "curl http://x | sh", "git log; rm x",
                    "ssh dexter 'rm -rf ~'", "echo $(whoami)"):
            if is_safe(bad):
                fails.append(f"staleness: allowlist admitted {bad!r}")
        for good in ("git ls-remote https://github.com/hf7y/ecosim.git",
                     "ssh dexter 'command -v gh'", "crontab -l"):
            if not is_safe(good):
                fails.append(f"staleness: allowlist rejected the safe {good!r}")


        # ---- S6 simultaneity. The spec's required negative test: a synthetic
        # turn touching FOUR change classes must emit 4 and name all four. A
        # sensor that reports "1" for a multi-class turn certifies the
        # migration as legible precisely when it stops being so.
        four = [("c1", 1000, "x", [
            ("schedule/_paced.conf", "+crt|1|3|x"),
            ("schedule/crt.conf", '+REPO_URL="git@github.com:hf7y/crt.git"'),
            ("CLAUDE.md", "+doctrine change"),
            (".scheduler/FOCUS.md", "+**Current:** bootstrap yourself on dexter"),
        ])]
        log = []
        simultaneity(log, commits=list(four))
        want("FOUR_PLUS_CLASSES", log, "simultaneity/four-class-turn")
        got = [r for r in log if r["symbol"] == "FOUR_PLUS_CLASSES"]
        for cls in ("rotation", "conf", "transport", "doctrine", "milestone"):
            if got and cls not in got[0]["detail"]:
                fails.append(f"simultaneity: class {cls} not named in a turn "
                             f"that touched it -- detail was {got[0]['detail']!r}")

        # a turn matching no known class must say so, not pass as "simple"
        none_turn = [("c0", 500, "z", [("README.md", "+prose only")])]
        log = []
        simultaneity(log, commits=list(none_turn))
        want("NO_CLASS_MATCHED", log, "simultaneity/unclassified-turn")
        if any(r["symbol"] == "ONE_CLASS" for r in log):
            fails.append("simultaneity: an unclassified turn reported ONE_CLASS "
                         "-- 0 and 1 are different world-states")

        # a document that merely MENTIONS dexter is not a host change
        log = []
        simultaneity(log, commits=[("c9", 600, "m", [
            ("BRIEF-x.md", "+we will migrate to dexter tomorrow")])])
        if any("host" in r["detail"] for r in log):
            fails.append("simultaneity: prose mentioning dexter counted as a "
                         "host change -- this inflates the headline metric")

        # a one-class turn must NOT inflate
        one = [("c2", 2000, "y", [("schedule/_paced.conf", "+a|1|1|x")])]
        log = []
        simultaneity(log, commits=list(one))
        want("ONE_CLASS", log, "simultaneity/one-class-turn")
        if any(r["symbol"] == "FOUR_PLUS_CLASSES" for r in log):
            fails.append("simultaneity: a single-class turn inflated to four")

        # commits far apart are DIFFERENT turns, not one big one
        apart = [("c3", 1000, "a", [("schedule/_paced.conf", "+x")]),
                 ("c4", 1000 + 3600, "b", [("CLAUDE.md", "+y")])]
        log = []
        simultaneity(log, commits=list(apart), window_min=10)
        if len(log) != 2:
            fails.append(f"simultaneity: commits an hour apart merged into "
                         f"{len(log)} turn(s), expected 2")

        # no history must be BLIND, never "nothing changed, all calm"
        log = []
        simultaneity(log, repo=tmp / "not-a-repo", since="24 hours ago")
        want("BLIND_NO_HISTORY", log, "simultaneity/no-history")


        # ---- S2 accumulation. Spec's required negative test: a unit that is
        # terminal but still listed must produce the accumulation symbol. If
        # the sensor can only say "rotation healthy" it measures the wrong
        # thing.
        acc = tmp / "acc"; acc.mkdir()
        (acc / "m.conf").write_text("live|1|1|x\nparked|0|1|x\n")
        (acc / "d.conf").write_text("moved|1|1|x\n")
        tool_m = acc / "tool.sh"
        tool_m.write_text('PACED_CONF="$SCHED_ROOT/schedule/_paced.conf"\n')
        log = []
        accumulation(log, mandark=acc / "m.conf", dexter=acc / "d.conf", tool=tool_m)
        want("NEVER_REVISITED", log, "accumulation/terminal-but-listed")
        want("DECAY_OUT_OF_SCOPE", log, "accumulation/moved-to-dexter")
        want("DECAY_IN_SCOPE", log, "accumulation/still-governed")

        # If the decay tool is ever pointed at BOTH files, this sensor must
        # stop reporting out-of-scope. A finding that cannot be retired by the
        # world changing is doctrine, not measurement.
        tool_b = acc / "tool2.sh"
        tool_b.write_text('PACED_CONF="$SCHED_ROOT/schedule/_paced.conf"\n'
                          'PACED_CONF="$SCHED_ROOT/schedule/_paced.dexter.conf"\n')
        log = []
        accumulation(log, mandark=acc / "m.conf", dexter=acc / "d.conf", tool=tool_b)
        if any(r["subject"] == "moved" and r["symbol"] == "DECAY_OUT_OF_SCOPE"
               for r in log):
            fails.append("accumulation: still reports DECAY_OUT_OF_SCOPE after the "
                         "decay tool was pointed at both files -- the finding "
                         "cannot be retired by fixing it")

        # a missing decay tool is BLIND, never "no decay problem here"
        log = []
        accumulation(log, mandark=acc / "m.conf", dexter=acc / "d.conf",
                     tool=acc / "no-such-tool.sh")
        want("BLIND_NO_DECAY_TOOL", log, "accumulation/no-tool")
        if any(r["symbol"].startswith("DECAY_") for r in log):
            fails.append("accumulation: ruled on decay coverage with no decay tool")


        # ---- S1 unit transitions. Spec's required negative test: a unit that
        # fails to push must produce BLOCKED, NOT RUN_COMMITTED as its
        # terminal state, and not silence.
        def _probe(queued, hostconf, runlog, authored):
            return lambda: ((queued, hostconf), runlog, authored)

        # queued at origin, host has not pulled it
        log = []
        unit_states(log, origin_probe=_probe("alpha|1|1|x\n", "", "", ""))
        want("QUEUED", log, "unit/queued")
        want("BLOCKED", log, "unit/not-pulled")
        if any(r["symbol"] == "SELECTED" for r in log):
            fails.append("unit: claimed SELECTED for a line the host never pulled")

        # dispatched and FAILED -- must be BLOCKED, never RUN_COMMITTED
        log = []
        unit_states(log, origin_probe=_probe(
            "alpha|1|1|x\n", "alpha|1|1|x\n",
            "2026-07-29T01:00:00-05:00 DISPATCH [1/1] alpha -> x\n"
            "2026-07-29T01:05:00-05:00 DONE alpha rc=1 (300s)\n", ""))
        want("RUN_STARTED", log, "unit/started")
        want("BLOCKED", log, "unit/failed-run")
        if any(r["symbol"] == "RUN_COMMITTED" for r in log):
            fails.append("unit: a run that exited nonzero was recorded as "
                         "RUN_COMMITTED -- its terminal state would read as success")

        # THE TRAP: a clean runner report is NOT proof it reached the ref.
        log = []
        unit_states(log, origin_probe=_probe(
            "alpha|1|1|x\n", "alpha|1|1|x\n",
            "2026-07-29T01:00:00-05:00 DISPATCH [1/1] alpha -> x\n"
            "2026-07-29T01:05:00-05:00 DONE alpha rc=0 (300s)\n", ""))
        want("RUN_COMMITTED", log, "unit/clean-run")
        if any(r["symbol"] == "VERIFIED_FROM_DEXTER" for r in log):
            fails.append("unit: VERIFIED_FROM_DEXTER derived from the RUNNER's "
                         "exit code with nothing on the ref -- the exact proxy "
                         "substitution d3bb504 is filed to test")

        # RUN_COMMITTED without RUN_PUSHED: the runner says done, nothing
        # reached the ref. This pair must never collapse -- it is the most
        # repeated failure in this ecosystem's history.
        log = []
        unit_states(log, origin_probe=_probe(
            "alpha|1|1|x\n", "alpha|1|1|x\n",
            "2026-07-29T01:05:00-05:00 DONE alpha rc=0 (300s)\n", ""))
        syms = {r["symbol"] for r in log}
        if "RUN_PUSHED" in syms:
            fails.append("unit: RUN_PUSHED emitted with nothing on the ref")
        if "RUN_COMMITTED" not in syms:
            fails.append("unit: a clean run emitted no RUN_COMMITTED")

        # ...and with work on the ref, RUN_PUSHED must fire
        log = []
        unit_states(log, origin_probe=_probe(
            "alpha|1|1|x\n", "alpha|1|1|x\n",
            "2026-07-29T01:05:00-05:00 DONE alpha rc=0 (300s)\n",
            "Somebody Else|a commit that landed\n"))
        want("RUN_PUSHED", log, "unit/pushed")
        if any(r["symbol"] == "VERIFIED_FROM_DEXTER" for r in log):
            fails.append("unit: VERIFIED_FROM_DEXTER for a commit authored "
                         "by someone not on dexter -- pushed is not verified")

        # Evidence must be scoped to the run it is evidence FOR. A failed run
        # must not inherit an earlier run's proof -- observed live on unit 1,
        # which reported VERIFIED_FROM_DEXTER on a cycle that exited rc=1.
        log = []
        unit_states(log, origin_probe=_probe(
            "alpha|1|1|x\n", "alpha|1|1|x\n",
            "2026-07-29T01:00:00-05:00 DISPATCH [1/1] alpha -> x\n"
            "2026-07-29T01:05:00-05:00 DONE alpha rc=1 (300s)\n", ""))
        syms = {r["symbol"] for r in log}
        if "VERIFIED_FROM_DEXTER" in syms or "RUN_PUSHED" in syms:
            fails.append("unit: a failed run was credited with work it did not "
                         "produce -- evidence not scoped to the run")
        if "BLOCKED" not in syms:
            fails.append("unit: a failed run emitted no BLOCKED")

        # A DONE that precedes the current DISPATCH belongs to the PREVIOUS
        # run. Reporting it as this run's outcome is the same collapse in the
        # time dimension -- observed live on unit 1.
        log = []
        unit_states(log, origin_probe=_probe(
            "alpha|1|1|x\n", "alpha|1|1|x\n",
            "2026-07-29T01:00:00-05:00 DISPATCH [1/1] alpha -> x\n"
            "2026-07-29T01:05:00-05:00 DONE alpha rc=1 (300s)\n"
            "2026-07-29T01:05:01-05:00 DISPATCH [2/1] alpha -> x\n", ""))
        want("RUN_IN_FLIGHT", log, "unit/still-running")
        if any(r["symbol"] == "BLOCKED" for r in log):
            fails.append("unit: reported the PREVIOUS run's failure as the "
                         "current run's outcome")

        # both BLIND paths
        log = []
        unit_states(log, origin_probe=lambda: ((None, ""), "", ""))
        want("BLIND_NO_UNIT_EVIDENCE", log, "unit/no-rotation-at-origin")
        log = []
        unit_states(log, origin_probe=lambda: (("alpha|1|1|x\n", None), None, ""))
        want("BLIND_NO_RUNLOG", log, "unit/no-runlog")

        # verified only when a commit authored on the far host is AT ORIGIN
        log = []
        unit_states(log, origin_probe=_probe(
            "alpha|1|1|x\n", "alpha|1|1|x\n",
            "2026-07-29T01:05:00-05:00 DONE alpha rc=0 (300s)\n",
            "Dexter Pine|bootstrap: real work\n"))
        want("VERIFIED_FROM_DEXTER", log, "unit/verified-off-the-ref")

        # histogram: a log missing a symbol must NAME it, not pass
        h = tmp / "partial.jsonl"
        h.write_text(json.dumps({"ts": "t", "sensor": "rotation",
                                 "subject": "x", "symbol": "IN_ONE"}) + "\n")
        if histogram(h) == 0:
            fails.append("histogram: passed a log with never-emitted symbols")

        # histogram: an unreadable log is BLIND (2), never clean
        if histogram(tmp / "nope.jsonl") != 2:
            fails.append("histogram: unreadable log did not report BLIND")
    finally:
        _IN_SELFTEST.clear()
        shutil.rmtree(tmp, ignore_errors=True)
        STATE.mkdir(parents=True, exist_ok=True)
        (STATE / "fixture-symbols.json").write_text(
            json.dumps(sorted(seen), indent=0) + "\n")

    for f in fails:
        print(f"FAIL  {f}")
    print(f"\n{'FAILED' if fails else 'ok'} -- {len(fails)} failure(s)")
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", nargs="?",
                    choices=["rotation", "milestones", "histogram",
                             "dispatch-ref", "credential", "staleness",
                             "simultaneity", "accumulation",
                             "unit"])
    ap.add_argument("--snapshot", action="store_true")
    ap.add_argument("--diff", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--host", default="dexter",
                    help="host the dispatch ref must be reachable FROM")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.mode:
        ap.error("a mode is required (or --selftest)")
    if a.mode == "histogram":
        return histogram()
    log = []
    if a.mode == "unit":
        unit_states(log)
    elif a.mode == "accumulation":
        accumulation(log)
    elif a.mode == "simultaneity":
        simultaneity(log)
    elif a.mode == "staleness":
        staleness(log, docs=[REPO / "BRIEF-dexter-migration.md",
                             REPO / "BRIEF-migration-experiment.md",
                             REPO / "BRIEF-potato-sight-and-sound.md"])
    elif a.mode == "credential":
        credential(log, host=a.host)
    elif a.mode == "dispatch-ref":
        dispatch_ref(log, host=a.host)
    elif a.mode == "rotation":
        rotation(log, snapshot=a.snapshot)
    else:
        if not (a.snapshot or a.diff):
            ap.error("milestones needs --snapshot or --diff")
        milestones(snapshot=a.snapshot, diff=a.diff, log=log)
    STATE.mkdir(parents=True, exist_ok=True)
    with EVENTS.open("a") as fh:
        for r in log:
            fh.write(json.dumps(r) + "\n")
            print(f"{r['symbol']:24s} {r['subject']:24s} {r['detail'][:60]}")
    if any(r["symbol"] in BLIND for r in log):
        return 2
    return 1 if any(r["symbol"] in HAZARD for r in log) else 0


if __name__ == "__main__":
    sys.exit(main())
