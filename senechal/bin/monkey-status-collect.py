#!/usr/bin/env python3
import json, os, pwd, re, subprocess, time  # RUN ON monkey AS ROOT (sudo -n python3 -), fed over stdin by bin/monkey-watch.sh (#274); an unreadable field is null, never a guess

UID_LO, UID_HI = 3000, 3100          # the self-dev band (provision-selfdev-user.sh)
CADENCE_H = 24                       # this page is republished daily
GRACE_H = 4
RUNS_KEPT = 5
OUTSIDE_MAX = 20                     # paths shown before the tail is counted
TICK_TAG = "realisateur:selfdev-release:TICK"
RUNNER_TAG = "scheduler:scheduler-paced-runner:RUNNER"
HOME_ROOT = os.environ.get("SELFDEV_HOME_ROOT", "/home")          # fixture seams:
SUDOERS_D = os.environ.get("SELFDEV_SUDOERS_D", "/etc/sudoers.d")  # unset in production


def sh(*cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else ""


def sh_rc(*cmd):  # (returncode, stdout): sh()'s empty string conflates "could not look" with "found nothing"
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout


def accounts():
    return sorted(p.pw_name for p in pwd.getpwall() if UID_LO <= p.pw_uid < UID_HI)


def cron(user):
    return [l.strip() for l in sh("crontab", "-l", "-u", user).splitlines()
            if l.strip() and not l.lstrip().startswith("#")]


def last_runs(user):
    d = f"{HOME_ROOT}/{user}/.local/share/scheduler-runs"
    recs = []
    for name in os.listdir(d) if os.path.isdir(d) else []:
        if not name.endswith(".jsonl"):
            continue
        with open(os.path.join(d, name)) as fh:
            for line in fh:
                try:
                    recs.append(json.loads(line))
                except json.JSONDecodeError:
                    pass                      # a torn tail line is not a run
    recs.sort(key=lambda r: r.get("started_at") or "")
    keep = ("run_id", "job", "started_at", "ended_at", "elapsed_s", "rc",
            "status", "commits_added", "issues_opened", "issues_closed",
            "prs_opened", "prs_merged", "verdict_computed", "claimed_verdict",
            "claimed_reason")
    return [{k: r.get(k) for k in keep} for r in recs[-RUNS_KEPT:]][::-1]


def release_tick(user, cron_lines):  # TRAP: retire_cadence() drops the cron line but leaves the status file -- reads as a stopped clock, pin=...T183347Z, 12 days stale
    if not any(TICK_TAG in l for l in cron_lines):
        return None
    p = f"{HOME_ROOT}/{user}/.local/state/selfdev-release-tick.status"
    if not os.path.exists(p):
        return None
    lines = [l.strip() for l in open(p) if l.strip()]
    return lines[-1] if lines else None


def armed(cron_lines):  # TRAP: a bare "runner"/"scheduler" substring also matches sync-crontab.sh -- match the tag, not the substring
    return any(RUNNER_TAG in l for l in cron_lines)


def containment(user, uid):
    home = f"{HOME_ROOT}/{user}"
    out = {"foreign_clones": [], "outside_home": [], "sudoers": []}

    projects = f"{home}/Documents/Projects"  # TRAP: git as root over another user's checkout refuses "dubious ownership" and prints NOTHING; safe.directory=* is what lets it look
    for name in sorted(os.listdir(projects)) if os.path.isdir(projects) else []:
        d = os.path.join(projects, name)
        url = sh("git", "-c", "safe.directory=*", "-C", d,
                 "config", "--get", "remote.origin.url").strip()
        if url and not url.rstrip("/").endswith(f"/{user}") and not url.endswith(f"/{user}.git"):
            out["foreign_clones"].append({"path": d, "origin": url})

    rc, found = sh_rc("find", HOME_ROOT, "/etc", "/usr/local", "/srv", "/var", "-xdev",  # TRAP: find exits non-zero on an unreadable tree; sh() read that as "found nothing"
                      "-uid", str(uid), "-not", "-path", home, "-not", "-path", f"{home}/*",
                      "-not", "-path", f"/var/spool/cron/crontabs/{user}", "-print")
    if rc != 0:
        return None                           # could not look: BLIND, not clean
    hits = [l for l in found.splitlines() if l.strip()]
    out["outside_home"] = hits[:OUTSIDE_MAX]
    if len(hits) > OUTSIDE_MAX:
        out["outside_home"].append(f"... and {len(hits) - OUTSIDE_MAX} more")

    for f in sorted(os.listdir(SUDOERS_D)) if os.path.isdir(SUDOERS_D) else []:
        path = os.path.join(SUDOERS_D, f)
        try:
            if any(l.split() and l.split()[0] == user for l in open(path)):
                out["sudoers"].append(path)
        except OSError:
            return None                       # could not read: BLIND, not clean
    return out


def clocksource():  # senechal#530/#562: the NEM wedge's leading indicators, read in one journal pass; a clocksource stall and a soft lockup don't always co-occur (#530: two lockups fired with the readout counter unchanged), so both are counted rather than just the readout; absent means could-not-look, never a guessed zero
    rc, out = sh_rc("journalctl", "-k", "-b", "-o", "cat")
    if rc != 0:
        return None
    lines = [l for l in out.splitlines() if l.strip()]
    readout = [l for l in lines if "Long readout interval" in l]
    lockup = [l for l in lines if "soft lockup" in l]
    ns_seen = [int(m.group(1)) for l in readout
               for m in [re.search(r"(?:cs|wd)_nsec=(\d+)", l)] if m]
    return {
        "long_readout_count": len(readout),
        "max_ns": max(ns_seen) if ns_seen else 0,
        "soft_lockup_count": len(lockup),
        "sampled_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def credentials(user):  # mode of each credential this account reads; absent and world-readable must not share a symbol
    paths = {
        "app_key": "/etc/selfdev/app.pem",
        "claude_token": "/etc/selfdev/claude-token",
        "claude_settings": f"{HOME_ROOT}/{user}/.claude/settings.json",
    }
    modes = {}
    for k, p in paths.items():
        try:
            modes[k] = oct(os.stat(p).st_mode & 0o777)
        except OSError:
            modes[k] = None
    return modes



if __name__ == "__main__":            # importable per function; `python3 - <file` still enters
    now = time.time()
    out = {
        "schema": 2,
        "host": os.uname().nodename,
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "valid_until": time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                     time.gmtime(now + (CADENCE_H + GRACE_H) * 3600)),
        "cadence_hours": CADENCE_H,
        "grace_hours": GRACE_H,
        "verb_build": os.path.basename(  # via `current` symlink, not a pin file naming one verb
            os.path.realpath("/usr/local/share/verb-builds/current"))
        if os.path.exists("/usr/local/share/verb-builds/current") else None,
        "accounts": [],
    }

    cs = clocksource()
    if cs is not None:  # absent, not zero, when the journal could not be read at all
        out["clocksource"] = cs

    for u in accounts():
        c = cron(u)
        runs = last_runs(u)
        out["accounts"].append({
            "account": u,
            "uid": pwd.getpwnam(u).pw_uid,
            "armed": armed(c),
            "cron": c,
            "release_tick": release_tick(u, c),
            "runs": runs,
            "last_run": runs[0] if runs else None,
            "containment": containment(u, pwd.getpwnam(u).pw_uid),
            "credentials": credentials(u),
        })

    print(json.dumps(out, indent=2))
