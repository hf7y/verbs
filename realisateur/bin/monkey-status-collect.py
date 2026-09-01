#!/usr/bin/env python3
"""Collect self-dev status for every account on the self-dev host.

RUN ON monkey, AS ROOT:  sudo -n python3 monkey-status-collect.py
Read-only: reads /etc/passwd, each account's crontab, git config and git log,
its scheduler run ledger, and its release-tick status file. Writes nothing,
dispatches nothing. Prints one JSON document on stdout -- the payload published
to https://hf7y.com/monkey/status.json by bin/monkey-watch.sh, which feeds this
file to monkey's python3 over stdin so the version that runs is the version in
the checkout. It runs FROM DEXTER on purpose: an empty accounts[] IS the
report, where a publisher refusing on ssh failure hides the outage (#274).

Every field is a probe of live state at generation time. A field this
script cannot read is null, never a guess: a missing ledger means the
account has never run, which is a finding, not a blank.
"""
import json, os, pwd, subprocess, time, urllib.request

UID_LO, UID_HI = 3000, 3100          # the self-dev band (provision-selfdev-user.sh)
CADENCE_H = 24                       # this page is republished daily
GRACE_H = 4
RUNS_KEPT = 5
OUTSIDE_MAX = 20                     # paths shown before the tail is counted
IDENT_MAX = 5                        # offending commits listed per clone
TICK_TAG = "realisateur:selfdev-release:TICK"
RUNNER_TAG = "scheduler:scheduler-paced-runner:RUNNER"
BOOTSTRAP_CLONES = {"scheduler"}  # land-selfdev.sh clones scheduler into EVERY account, so it is expected. realisateur is NOT: #134 stopped minting it per account, so a realisateur clone is now residue and must read as foreign. containment() keeps `{user, *BOOTSTRAP_CLONES}`, so realisateur@monkey's own checkout stays expected.
ROSTER_URL = os.environ.get(
    "SELFDEV_ROSTER_URL",
    "https://raw.githubusercontent.com/hf7y/scheduler/main/schedule/ROSTER")
HOME_ROOT = os.environ.get("SELFDEV_HOME_ROOT", "/home")          # fixture seams:
SUDOERS_D = os.environ.get("SELFDEV_SUDOERS_D", "/etc/sudoers.d")  # unset in production


def sh(*cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else ""


def sh_rc(*cmd):
    """(returncode, stdout) -- for probes where "could not look" and "found
    nothing" are different answers and sh()'s empty string conflates them."""
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout


def accounts():
    return sorted(p.pw_name for p in pwd.getpwall() if UID_LO <= p.pw_uid < UID_HI)


# TRAP: this list is not a census of the host. Work runs outside the band --
# two wrappers fired from /home/svc-vaporwave/bin/ on uid 1001 while
# scheduler/examples/vkv-inventory-bug-sweep-loop.sh:8 recorded "none,
# verified" (hf7y/scheduler#368). Published so a reader cannot infer coverage.
def accounts_scope():
    return (f"uid {UID_LO}-{UID_HI - 1} only. Accounts outside this band are NOT "
            f"enumerated: this list is not a census of everything on the host that "
            f"runs work. Service accounts (e.g. uid 1001) are invisible here.")


def cron(user):
    """The account's own crontab, comments stripped."""
    return [l.strip() for l in sh("crontab", "-l", "-u", user).splitlines()
            if l.strip() and not l.lstrip().startswith("#")]


def last_runs(user):
    """Most recent run records from this account's scheduler ledger."""
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


def release_tick(user, cron_lines):
    """Last line of the account's verb-build release-tick status log -- but
    only while the account still HAS a release tick.

    TRAP: retire_cadence() (selfdev-release-tick.sh) removes the cron line and
    the private build root and leaves the status file behind. Published on its
    own, that file is a stopped clock: every row read pin=2026-08-12T183347Z
    while the host was serving a build twelve days newer. No tick line in the
    crontab, no status: null, which the page renders as an absence."""
    if not any(TICK_TAG in l for l in cron_lines):
        return None
    p = f"{HOME_ROOT}/{user}/.local/state/selfdev-release-tick.status"
    if not os.path.exists(p):
        return None
    lines = [l.strip() for l in open(p) if l.strip()]
    return lines[-1] if lines else None


def dispatch_line(cron_lines):
    """Whether the account has a scheduler-paced-runner dispatch line.

    TRAP: a substring test over "runner" or "scheduler" also matches a line
    that only runs sync-crontab.sh out of the scheduler clone -- that syncs
    the crontab, it arms nothing, and reading it as armed reports a live
    dispatcher where there is none. Match the cron tag the line is actually
    written with instead."""
    return any(RUNNER_TAG in l for l in cron_lines)


def roster_states(host):
    try:
        raw = urllib.request.urlopen(ROSTER_URL, timeout=10).read().decode()
    except Exception:
        return None
    out = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        f = [c.strip() for c in line.split("|")]
        if len(f) < 4:
            continue
        acct, _, h = f[1].partition("@")
        if h == host:
            out[acct] = f[3]
    return out or None


def armed(cron_lines, states, account):
    if not dispatch_line(cron_lines):
        return False
    if states is None:
        return None
    return states.get(account) == "live"


def containment(user, uid):
    """What this account reaches outside its own home. Three lists, and a
    null when the probe itself could not run -- an unreadable tree is not an
    empty one."""
    home = f"{HOME_ROOT}/{user}"
    out = {"foreign_clones": [], "outside_home": [], "sudoers": []}

    # A clone whose origin is not this account's own repo.
    #
    # TRAP: git run as root over another user's checkout refuses with "dubious
    # ownership" and prints NOTHING, so every account reads as having no
    # clones at all -- the silent zero this estate has paid for before.
    # safe.directory=* is what makes the probe able to look.
    projects = f"{home}/Documents/Projects"
    for name in sorted(os.listdir(projects)) if os.path.isdir(projects) else []:
        d = os.path.join(projects, name)
        url = sh("git", "-c", "safe.directory=*", "-C", d,
                 "config", "--get", "remote.origin.url").strip()
        expected = {user, *BOOTSTRAP_CLONES}
        if url and not any(url.rstrip("/").endswith(f"/{e}") or url.endswith(f"/{e}.git")
                            for e in expected):
            out["foreign_clones"].append({"path": d, "origin": url})

    # TRAP: find exits non-zero on an unreadable tree and sh() read that as
    # "found nothing"; -quit made the list 0 or 1 long, so ARGUMENT ORDER chose.
    rc, found = sh_rc("find", HOME_ROOT, "/etc", "/usr/local", "/srv", "/var", "-xdev",
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


def identity_drift(user):
    """Not committing as itself (realisateur#841): a local user.email that is
    not the account's, or an unpushed commit whose COMMITTER is neither."""
    home = f"{HOME_ROOT}/{user}"
    rc, mail = sh_rc("git", "config", "--file", f"{home}/.gitconfig",
                     "--get", "user.email")
    mail = mail.strip()
    if rc != 0 or not mail:
        return None
    out = {"declared": mail, "clones": []}
    projects = f"{home}/Documents/Projects"
    for name in sorted(os.listdir(projects)) if os.path.isdir(projects) else []:
        d = os.path.join(projects, name)
        if not os.path.exists(os.path.join(d, ".git")):
            continue
        local = sh("git", "-c", "safe.directory=*", "-C", d,
                   "config", "--local", "--get", "user.email").strip()
        rc, log = sh_rc("git", "-c", "safe.directory=*", "-C", d, "log",
                        "--branches", "--not", "--remotes",
                        "--format=%h\x1f%cn\x1f%ce\x1f%cI")
        if rc != 0:
            return None                       # could not read: BLIND, not clean
        known = {mail, local} - {""}
        bad = [f.split("\x1f") for f in log.splitlines() if f.strip()]
        bad = [f for f in bad if len(f) == 4 and f[2] not in known]
        if not bad and (not local or local == mail):
            continue
        out["clones"].append({
            "path": d,
            "local_identity": local if local and local != mail else None,
            "count": len(bad),
            "commits": [f"{h} {n} <{e}> {t}" for h, n, e, t in bad[:IDENT_MAX]],
        })
    return out


def credentials(user):
    """The permission mode of each credential this account reads, or null
    where it is absent. An absent credential and a world-readable one are
    opposite findings and must not share a symbol."""
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
        "schema": 3,
        "host": os.uname().nodename,
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "valid_until": time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                     time.gmtime(now + (CADENCE_H + GRACE_H) * 3600)),
        "cadence_hours": CADENCE_H,
        "grace_hours": GRACE_H,
        # The verb build this host actually serves -- resolved through the
        # `current` symlink, not read from a pin file that nothing proves was
        # adopted.
        #
        # TRAP: resolving one named verb makes the whole build read as missing the
        # day that verb is retired. The build root is what is being asked about.
        "verb_build": os.path.basename(
            os.path.realpath("/usr/local/share/verb-builds/current"))
        if os.path.exists("/usr/local/share/verb-builds/current") else None,
        "accounts": [],
        "accounts_scope": accounts_scope(),
    }

    states = roster_states(os.uname().nodename)
    out["roster_read"] = states is not None
    for u in accounts():
        c = cron(u)
        runs = last_runs(u)
        out["accounts"].append({
            "account": u,
            "uid": pwd.getpwnam(u).pw_uid,
            "armed": armed(c, states, u),
            "dispatch_line": dispatch_line(c),
            "roster_state": (states or {}).get(u) if states is not None else None,
            "cron": c,
            "release_tick": release_tick(u, c),
            "runs": runs,
            "last_run": runs[0] if runs else None,
            "containment": containment(u, pwd.getpwnam(u).pw_uid),
            "identity": identity_drift(u),
            "credentials": credentials(u),
        })

    print(json.dumps(out, indent=2))
