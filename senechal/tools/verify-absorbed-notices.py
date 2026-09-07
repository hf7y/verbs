#!/usr/bin/env python3
"""senechal: an absorber-closed (#547) fleet filing never registered is MISSING; revisited (#531) is REVISIT."""
import importlib.util
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("an", os.path.join(HERE, "absorb-notices.py"))
an = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(an)

RC_PASS, RC_FAIL, RC_INCOMPLETE, RC_WARN = 0, 1, 2, 3


def gh_closed_door_issues():
    if not an._which("gh"):
        return None, "gh is not on PATH -- cannot read the notice queue"
    p = subprocess.run(
        ["gh", "issue", "list", "--repo", an.REPO, "--label", "door", "--state", "closed",
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


def registered(fleet, door, fields):
    section, key = door["target"].split(".", 1)
    rows = fleet.get(section, {}).get(key, [])
    want = an.door_key_value(door, fields)
    return any(an.door_key_value(door, row) == want for row in rows)


def absorb_close_comments(comments, door, fields):
    prefix = "Absorbed into `%s` as `%s`. Closing IS the acknowledgement." % (
        door["target"], an.door_key_display(door, fields))
    return [c for c in comments if str(c.get("body", "")).startswith(prefix)]


def main(argv=None, issues=None, doors=None, fleet=None):
    if doors is None:
        try:
            with open(an.doors_path()) as fh:
                doors = json.load(fh)["doors"]
        except (OSError, ValueError, KeyError) as e:
            print("could not look: %s" % e)
            return RC_INCOMPLETE

    if fleet is None:
        try:
            with open(an.registry_path()) as fh:
                fleet = json.load(fh)
        except (OSError, ValueError) as e:
            print("could not look: %s -- the fleet registry is a tracked file, this checkout is broken" % e)
            return RC_INCOMPLETE

    if issues is None:
        issues, err = gh_closed_door_issues()
        if err:
            print("could not look: %s" % err)
            return RC_INCOMPLETE

    missing, revisit, checked, skipped_taste, skipped_not_absorbed, unparseable = \
        [], [], 0, 0, 0, 0
    for issue in issues:
        num = issue.get("number", "?")
        payload, err = an.parse_payload(issue.get("body", ""))
        if err is not None:
            unparseable += 1
            continue
        name, fields, err = an.validate(payload, doors)
        if err is not None:
            unparseable += 1
            continue
        door = doors[name]
        if an.destination_class(door["target"]) != "fleet":
            skipped_taste += 1
            continue
        checked += 1
        if registered(fleet, door, fields):
            continue
        comments = issue.get("comments") or []
        closes = absorb_close_comments(comments, door, fields)
        if not closes:
            skipped_not_absorbed += 1
            continue
        key = an.door_key_display(door, fields)
        if len(comments) > 1:
            revisit.append((num, name, key))
            print("REVISIT #%s  %s: %s -- closed by the absorber, not in %s, and commented on "
                  "again after closing -- read it, it may be a deliberate reversal (e.g. #531)"
                  % (num, name, key, door["target"]))
        else:
            missing.append((num, name, key))
            print("MISSING #%s  %s: %s -- closed by the absorber, never revisited, but not in %s"
                  % (num, name, key, door["target"]))

    print("%d closed fleet filing(s) checked, %d taste-targeted (skipped), %d closed "
          "some other way (skipped), %d unparseable (not a landed-or-not question)"
          % (checked, skipped_taste, skipped_not_absorbed, unparseable))

    if missing:
        print("%d filing(s) closed but never landed -- re-file, or hand-restore the row and say so on the issue"
              % len(missing))
        return RC_FAIL
    if revisit:
        print("%d filing(s) closed, unregistered, and revisited after closing -- read each before acting"
              % len(revisit))
        return RC_WARN
    print("every closed fleet filing's key is registered")
    return RC_PASS


if __name__ == "__main__":
    sys.exit(main())
