#!/usr/bin/env python3
"""senechal: apply typed front-door filings to their canonical store, unattended.

GUARD: notices that arrived typed but were never absorbed
RUNNER: health/estate-health.sh (dry run), .claude/commands/nightly-batch.md
GUARD-TEST: tools/test-absorb-notices.py

WHY THIS EXISTS (2026-08-16)
----------------------------
`notify-senechal` used to take free text and file a prose issue. Every
consumer downstream reads structure -- health/dead-config.sh reads
estate.footprint, health/hosts-unregistered.sh reads estate.devices -- so
every filing needed a HUMAN to translate the paragraph into the schema.
health/unabsorbed-notices.sh exists only to nag about the backlog of
untranslated prose; the nag is the symptom, the prose door was the defect.

The note already knows its type where it is written:
remedies/window-spawn-desktop.sh files "these two symlinks now exist,
senechal owns them" -- a footprint record with kind/target/host/owner,
flattened into a sentence and re-parsed by a human days later. So the
caller now sends the object (registry/front-doors.json is the contract it
validates against), and this reads it back and writes it in.

The transport stays a GitHub issue. That was never the problem: which
STORE a filing lands in was (hf7y/senechal#369) -- see below.

WHERE A FILING LANDS (hf7y/senechal#411, resolves #369)
--------------------------------------------------------
tools/boundary.py's CONFIG_KEYS classifies every door's target
(footprint -> estate.footprint, crontab -> estate.crontab, ...) fleet or
taste, the same axis health/*.sh's own fleet/taste split reads. THAT
classification decides the destination, not which host happens to run
this:

  fleet   registry/senechal-registry.json, in THIS checkout. It already
          ships to every host inside the verb build (#406), so which
          host runs the absorb stops mattering -- it never writes to a
          host's disk at all. #369's original bug (7 footprint filings
          landed on monkey's sandbox config, invisible to every other
          host) cannot recur: there is no host-local copy to land on.
  taste   the live config (~/.config/senechal/senechal.json), and only
          when this host is the taste host (mandark by default,
          $SENECHAL_TASTE_HOST to override) -- a laptop preference has
          exactly one canonical copy, and it was never git's job to
          hold it (#67). A taste filing that arrives anywhere else is
          left open (DEFER), not applied and not rejected as malformed.

An unclassified target defaults to fleet -- the same "ambiguous is
expensive the wrong way" rule #396 applies everywhere else: a taste fact
wrongly in fleet is dead weight, a fleet fact wrongly in taste is a
broken unattended run on some other host.

Committing the branch this leaves in the working tree as a PR is a
separate, deliberate step (`git`/`gh`, the same way every other change
in this repo lands) -- not automated here. #411 named one open question
ahead of automating that part: does the absorb PR need human review, or
can it auto-merge? That is not this script's call, so it makes neither
choice -- it leaves registry/senechal-registry.json modified on disk and
says so, the same way tools/export-registry.py already leaves its output
for a human (or CI) to commit.

WHAT IT WILL NOT DO
-------------------
It never edits an entry that already exists -- an id/name already in the
registry is reported and skipped, not overwritten. A door can add a fact
senechal did not have; changing one senechal already recorded is a human
edit, because the existing row may carry a retirement history no filing
knows about.

It never invents. A payload missing a required field, naming an unknown
door, or carrying a value outside a declared enum is REJECTED and left
open, with the reason -- rather than absorbed half-formed.

EXIT CONTRACT (lib/common.sh: 0 pass / 1 real / 2 could-not-look / 3 warn)
  0  nothing pending, or --write applied everything cleanly
  1  a filing was rejected: it is malformed and no one is coming for it
  2  could not look -- no gh, gh failed, or registry/front-doors.json (the
     doors contract, always required) is missing or unparseable
  3  DRY RUN found absorbable filings waiting, or a clean filing was
     DEFERRED because this host cannot apply it (the nag)

USAGE
  tools/absorb-notices.py             # DRY RUN: what is waiting, and where it would land
  tools/absorb-notices.py --write     # apply: fleet -> registry/, taste -> live config
  tools/absorb-notices.py --write --close   # ...and close each absorbed issue
"""
import argparse
import json
import os
import re
import socket
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import boundary  # tools/boundary.py: which door targets are fleet vs taste

RC_PASS, RC_FAIL, RC_INCOMPLETE, RC_WARN = 0, 1, 2, 3

REPO = "hf7y/senechal"
# The caller fences the payload so the issue stays readable to a human and
# parseable to this. Anything outside the fence is commentary.
FENCE_RE = re.compile(r"```senechal-door\s*\n(.*?)\n```", re.DOTALL)

def taste_host():
    """The one host a taste filing may be applied to -- see the module docstring.

    $SENECHAL_TASTE_HOST exists for the same reason health/*.sh's own
    THIS_HOST override does: a test fixture or a future second taste host.
    A function, not a module constant, so a test can change it mid-run.
    """
    return os.environ.get("SENECHAL_TASTE_HOST", "mandark")


def config_path():
    if os.environ.get("SENECHAL_CONFIG"):
        return os.environ["SENECHAL_CONFIG"]
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "senechal", "senechal.json")


def registry_path():
    return os.path.join(HERE, "..", "registry", "senechal-registry.json")


def doors_path():
    return os.path.join(HERE, "..", "registry", "front-doors.json")


def this_host():
    if os.environ.get("SENECHAL_HOSTNAME"):
        return os.environ["SENECHAL_HOSTNAME"]
    return socket.gethostname().split(".")[0]


def destination_class(target):
    """-> 'fleet' or 'taste' for a door's dotted target, e.g. 'estate.footprint'.

    Unclassified defaults to fleet -- #396's own rule, applied here too.
    """
    got = boundary.classify_config_key(target)
    return got[0] if got else "fleet"


def parse_payload(body):
    """-> (payload, None) or (None, reason). Body is an issue's markdown."""
    m = FENCE_RE.search(body or "")
    if not m:
        return None, "no ```senechal-door block -- filed by something that is not a door"
    try:
        payload = json.loads(m.group(1))
    except ValueError as e:
        return None, "the senechal-door block is not JSON: %s" % e
    if not isinstance(payload, dict):
        return None, "the payload is %s, expected an object" % type(payload).__name__
    return payload, None


def validate(payload, doors):
    """-> (door_name, fields, None) or (None, None, reason)."""
    name = payload.get("door")
    door = doors.get(name)
    if door is None:
        return None, None, "unknown door %r -- known doors: %s" % (
            name, ", ".join(sorted(doors)))
    fields = payload.get("fields")
    if not isinstance(fields, dict):
        return None, None, "door %s: `fields` is missing or not an object" % name
    missing = [f for f in door["required"] if not str(fields.get(f, "")).strip()]
    if missing:
        return None, None, "door %s: missing required field(s): %s" % (
            name, ", ".join(missing))
    extra = [f for f in fields if f not in door["required"]]
    if extra:
        return None, None, "door %s: unknown field(s): %s" % (name, ", ".join(sorted(extra)))
    for field, allowed in door.get("enums", {}).items():
        if fields[field] not in allowed:
            return None, None, "door %s: %s=%r is not one of: %s" % (
                name, field, fields[field], ", ".join(allowed))
    return name, fields, None


def apply_filing(config, door, fields):
    """Add `fields` to the door's target list. -> (True, None) or (False, reason).

    Mutates `config`. A duplicate key is a skip, never an overwrite.
    """
    section, key = door["target"].split(".", 1)
    rows = config.setdefault(section, {}).setdefault(key, [])
    keyfield = door["key"]
    for row in rows:
        if row.get(keyfield) == fields[keyfield]:
            return False, "%s %s=%s is already registered -- editing an existing entry is a human edit" % (
                key, keyfield, fields[keyfield])
    rows.append(dict(sorted(fields.items())))
    return True, None


def gh_notices():
    """-> (issues, None) or (None, reason). Open, door-labelled, oldest first."""
    if not _which("gh"):
        return None, "gh is not on PATH -- cannot read the notice queue"
    p = subprocess.run(
        ["gh", "issue", "list", "--repo", REPO, "--label", "door", "--state", "open",
         "--json", "number,title,body,comments"],
        capture_output=True, text=True)
    if p.returncode != 0:
        return None, "gh issue list failed (exit %d): %s" % (
            p.returncode, " ".join(p.stderr.split()))
    try:
        issues = json.loads(p.stdout or "[]")
    except ValueError as e:
        return None, "could not parse gh's JSON: %s" % e
    return sorted(issues, key=lambda i: i.get("number", 0)), None


def _which(cmd):
    from shutil import which
    return which(cmd)


def close_issue(number, message):
    subprocess.run(["gh", "issue", "close", str(number), "--repo", REPO,
                    "--comment", message], capture_output=True, text=True)


def main(argv=None, issues=None, doors=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--write", action="store_true",
                    help="apply: fleet filings to --registry, taste filings to --config")
    ap.add_argument("--close", action="store_true", help="close each absorbed issue")
    ap.add_argument("--config", default=None, help="the live (taste) config")
    ap.add_argument("--registry", default=None, help="the fleet registry, registry/senechal-registry.json")
    args = ap.parse_args(argv)

    if doors is None:
        try:
            with open(doors_path()) as fh:
                doors = json.load(fh)["doors"]
        except (OSError, ValueError, KeyError) as e:
            print("could not look: %s" % e)
            return RC_INCOMPLETE

    reg_path = args.registry or registry_path()
    try:
        with open(reg_path) as fh:
            fleet = json.load(fh)
    except (OSError, ValueError) as e:
        print("could not look: %s -- the fleet registry is a tracked file, this checkout is broken" % e)
        return RC_INCOMPLETE

    # The taste config is loaded best-effort: a host with no reachable live
    # config (monkey, dexter, ...) can still absorb every fleet filing --
    # that is the entire point of #369/#411. It only matters if a taste
    # filing actually shows up, checked per-filing below.
    cfg_path = args.config or config_path()
    taste, taste_err = None, None
    try:
        with open(cfg_path) as fh:
            taste = json.load(fh)
    except (OSError, ValueError) as e:
        taste_err = str(e)

    if issues is None:
        issues, err = gh_notices()
        if err:
            print("could not look: %s" % err)
            return RC_INCOMPLETE

    absorbed, rejected, deferred = [], [], []
    for issue in issues:
        num = issue.get("number", "?")
        payload, err = parse_payload(issue.get("body", ""))
        if err is not None:
            rejected.append((num, err))
            print("REJECT  #%s  %s" % (num, err))
            continue
        name, fields, err = validate(payload, doors)
        if err is not None:
            rejected.append((num, err))
            print("REJECT  #%s  %s" % (num, err))
            continue

        door = doors[name]
        cls = destination_class(door["target"])
        if cls == "fleet":
            store, dest = fleet, "fleet"
        elif this_host() != taste_host():
            msg = ("door %s targets the live (taste) config, but this host "
                   "(%s) is not %s -- leaving open for a run there"
                   % (name, this_host(), taste_host()))
            deferred.append((num, msg))
            print("DEFER   #%s  %s" % (num, msg))
            continue
        elif taste is None:
            msg = "door %s targets the live (taste) config, but it could not be read: %s" % (name, taste_err)
            deferred.append((num, msg))
            print("DEFER   #%s  %s" % (num, msg))
            continue
        else:
            store, dest = taste, "taste"

        ok, err = apply_filing(store, door, fields)
        if not ok:
            # A skip-because-duplicate and a malformed payload both land here;
            # both are a human's problem, and both must be said rather than
            # counted.
            rejected.append((num, err))
            print("REJECT  #%s  %s" % (num, err))
            continue
        absorbed.append((num, name, fields[door["key"]], len(issue.get("comments") or []), dest))
        print("ABSORB  #%s  %s: %s -> %s" % (num, name, fields[door["key"]], dest))

    if not issues:
        print("no open %s notices labelled door" % REPO)

    fleet_absorbed = [a for a in absorbed if a[4] == "fleet"]
    taste_absorbed = [a for a in absorbed if a[4] == "taste"]

    if args.write:
        if fleet_absorbed:
            # sort_keys=True to match tools/export-registry.py's own
            # formatting of this exact file -- it is already written that
            # way, so this stays a real diff instead of a reformat.
            with open(reg_path, "w") as fh:
                json.dump(fleet, fh, indent=2, sort_keys=True)
                fh.write("\n")
            print("wrote %d fleet filing(s) into %s" % (len(fleet_absorbed), reg_path))
            print("next: commit %s and open a PR -- never auto-merged here (hf7y/senechal#411)"
                  % os.path.relpath(reg_path))
        if taste_absorbed:
            with open(cfg_path, "w") as fh:
                # indent=2 and NO sort_keys: that is byte-for-byte how the
                # live config is already formatted, so an absorb shows up as
                # the lines it added and nothing else. sort_keys reorders
                # the whole file and buries the one change in a 2,000-line
                # diff.
                json.dump(taste, fh, indent=2)
                fh.write("\n")
            print("wrote %d taste filing(s) into %s" % (len(taste_absorbed), cfg_path))
        if args.close:
            for num, name, key, ncomments, _dest in absorbed:
                # A comment is a human talking. The janitor already refuses to
                # touch an issue carrying one; closing here would bury an answer
                # nothing else reads. Say it loudly rather than skipping quietly.
                if ncomments:
                    print("KEPT OPEN  #%s  absorbed, NOT closed: has %d comment(s) -- "
                          "read them, they may be Zach's answer" % (num, ncomments))
                    continue
                close_issue(num, "Absorbed into `%s` as `%s`. Closing IS the acknowledgement."
                            % (doors[name]["target"], key))

    if rejected:
        return RC_FAIL
    if deferred:
        print("%d filing(s) deferred -- see DEFER lines above" % len(deferred))
    if absorbed and not args.write:
        print("DRY RUN -- %d filing(s) waiting; rerun with --write" % len(absorbed))
    if deferred or (absorbed and not args.write):
        return RC_WARN
    return RC_PASS


if __name__ == "__main__":
    sys.exit(main())
