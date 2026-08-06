#!/usr/bin/env python3
"""ecosim.hosts -- who dispatches, and how to reach them.

Two questions. Deliberately answered from two different sources, because
conflating them is what made this module necessary.

WHO DISPATCHES is `schedule/_paced.*.conf`. That glob is not a naming
convention this file hopes people follow -- it is what
`usage-paced-runner.sh` actually resolves at dispatch time
(`_paced.$(hostname -s).conf`, falling back to the shared `_paced.conf`).
Deriving the host set from the mechanism means a new host is sensed the
moment it has a rotation file, with no edit here and none in any sensor.

HOW TO REACH a host is a transport question, answered separately, and
allowed to fail. A host that cannot be reached is BLIND -- never absent.
The census must not depend on the network, because the moment it does, an
unreachable host silently stops being audited, and "not audited" reads
identically to "fine".

That is not hypothetical. It is the defect this module was written after:
`rotation` carried a hard-coded ("mandark", "dexter") and so never opened
`_paced.monkey.conf`. `ecosim` had dispatched from monkey every night
since 2026-08-03, and the sensor reported it PARKED -- an OK symbol, on
the one project that was running.

TAILSCALE IS A TRANSPORT HERE, NEVER THE CENSUS.

The instinct to take the host list from the tailnet is the right instinct
pointed at the wrong question, and the measurement says so. On 2026-08-04:

    tailnet    : mandark, dexter, homeassistant
    dispatches : mandark, dexter, monkey

The two sets differ in BOTH directions. `homeassistant` is on the tailnet
and dispatches nothing; `monkey` dispatches nightly and is not on the
tailnet at all. A census taken from `tailscale status` would have invented
a participant and dropped the only one that mattered -- reintroducing the
exact blindness described above, this time with a network dependency
underneath it.

As TRANSPORT the tailnet earns its place: it is the thing that makes an
arbitrary host reachable by name without an ssh config edit, so a host
that joins it becomes readable here automatically.
"""
from pathlib import Path
import json
import os
import re
import socket
import subprocess

SCHED = Path(os.environ.get(
    "ECOSIM_SCHEDULER_DIR", Path.home() / "Documents/Projects/scheduler"))

SHARED_CONF = "_paced.conf"
_CONF_RE = re.compile(r"^_paced\.(.+)\.conf$")


def local_host():
    """This host's short name -- the same string the runner keys on."""
    return (os.environ.get("ECOSIM_LOCAL_HOST")
            or socket.gethostname().split(".")[0])


def is_local(host):
    return host in ("", None, local_host())


def dispatch_hosts(sched=None):
    """Every host with a rotation file, plus this one. Sorted, local first.

    The local host is included even when it has no `_paced.<self>.conf`,
    because the runner falls back to the shared `_paced.conf` -- so a host
    without its own file still dispatches, and omitting it would be the
    same silence this module exists to prevent.
    """
    sched = Path(sched or SCHED)
    found = set()
    for p in sorted((sched / "schedule").glob("_paced.*.conf")):
        m = _CONF_RE.match(p.name)
        if m:
            found.add(m.group(1))
    found.add(local_host())
    me = local_host()
    return (me,) + tuple(sorted(h for h in found if h != me))


def conf_for(host, sched=None):
    """The rotation file that decides what `host` dispatches.

    Mirrors the runner's own resolution, including its fallback: a host
    with no file of its own is governed by the shared one.
    """
    sched = Path(sched or SCHED)
    own = sched / "schedule" / f"_paced.{host}.conf"
    return own if own.is_file() else sched / "schedule" / SHARED_CONF


def has_own_conf(host, sched=None):
    sched = Path(sched or SCHED)
    return (sched / "schedule" / f"_paced.{host}.conf").is_file()


def rotation_files(sched=None):
    """{filename: path} for every rotation file on disk, shared one included.

    Keyed by NAME because that is the unit a monitor's jurisdiction is
    expressed in (`PACED_CONF="$SCHED_ROOT/schedule/_paced.conf"`), and
    because two hosts without their own file share one.
    """
    sched = Path(sched or SCHED)
    out = {}
    shared = sched / "schedule" / SHARED_CONF
    if shared.is_file():
        out[SHARED_CONF] = shared
    for p in sorted((sched / "schedule").glob("_paced.*.conf")):
        out[p.name] = p
    return out


# -- transport --------------------------------------------------------------
_tailnet_cache = None


def tailnet():
    """{short name: (dns name, online)} from `tailscale status --json`.

    An absent or logged-out tailscale is not an error here. It means one
    transport is unavailable, and `reach` says so in the reason string
    rather than turning it into a claim about the host.
    """
    global _tailnet_cache
    if _tailnet_cache is not None:
        return _tailnet_cache
    out = {}
    try:
        r = subprocess.run(["tailscale", "status", "--json"],
                           capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            d = json.loads(r.stdout)
            for node in [d.get("Self") or {}] + list((d.get("Peer") or {}).values()):
                name = (node.get("HostName") or "").split(".")[0]
                if not name:
                    continue
                dns = (node.get("DNSName") or "").rstrip(".") or name
                out[name] = (dns, bool(node.get("Online", True)))
    except (OSError, ValueError, subprocess.SubprocessError):
        out = {}
    _tailnet_cache = out
    return out


def _ssh_config_names():
    """Literal `Host` aliases in ~/.ssh/config.

    Declared limit: patterns containing * or ? are skipped, and `Include`
    is not followed. A name this misses degrades to "unreachable", which
    is a BLIND -- the safe direction.
    """
    names = set()
    try:
        for line in (Path.home() / ".ssh/config").read_text().splitlines():
            s = line.strip()
            if s[:5].lower() == "host " :
                for tok in s[5:].split():
                    if "*" not in tok and "?" not in tok:
                        names.add(tok)
    except OSError:
        pass
    return names


def _resolves(name):
    try:
        socket.getaddrinfo(name, None)
        return True
    except (socket.gaierror, UnicodeError, OSError):
        return False


def reach(host):
    """(ssh_target, reason). target None means: no transport, so BLIND.

    ORDER MATTERS, and it is not the obvious one. An ~/.ssh/config alias
    wins over the tailnet name, because the alias carries the PORT, USER
    and IDENTITY that the bare address does not.

    Learned by breaking it. Preferring the MagicDNS name sent dexter's
    read to `dexter.tail893f2c.ts.net:22` -- dexter's WINDOWS sshd --
    instead of the alias's `:2223` with `id_dexter_gardien`, and turned a
    host that had been read successfully for weeks into a BLIND. The two
    are not alternatives: the alias's own HostName IS the tailnet name, so
    following the alias uses the tailnet AND keeps the port and key.

    The tailnet therefore serves hosts that have no alias yet, which is
    the case this whole module is generalising for.
    """
    if is_local(host):
        return "", None
    if host in _ssh_config_names():
        return host, None
    tn = tailnet()
    if host in tn:
        dns, online = tn[host]
        if online:
            return dns, None
        return None, (f"{host} is a tailnet member but reports offline; "
                      f"not substituting another route for it")
    if _resolves(host):
        return host, None
    peers = ",".join(sorted(tn)) or "none"
    return None, (f"no transport to {host}: no ~/.ssh/config alias, not a "
                  f"tailnet peer (peers: {peers}), and the name does not "
                  f"resolve")


def ssh_read(host, remote_cmd, timeout=35):
    """Run a read-only command on `host`. (text, err); text None on failure.

    Transport failure and command failure are returned the same way on
    purpose -- both mean "this host's copy was not read", which is one
    BLIND -- but the reason string always says which.
    """
    target, why = reach(host)
    if target is None:
        return None, why
    if target == "":
        return None, "ssh_read called for the local host"
    r = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
         target, remote_cmd],
        capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        return None, (r.stderr or r.stdout or "ssh failed").strip()[:70]
    return r.stdout, None


# -- where a host keeps the scheduler it dispatches from ---------------------
#
# /srv/scheduler FIRST: the system-wide, root-owned, world-readable install
# (Zach-directed 2026-08-04). One copy per host that every account READS and
# none OWNS, so a monitor never reaches into a project user's 0700 home.
#
# The fallbacks are for hosts not yet migrated. dexter keeps its checkout at
# ~/scheduler; monkey before /srv had NO checkout owned by the login account
# at all -- every clone belonged to a project user, behind 0700.
#
# THE GLOB MUST EXPAND UNDER SUDO, not before it. `/home/*/Documents/...` is
# expanded by the CALLING shell, which cannot traverse a 0700 home, so the
# pattern stays literal and every test on it fails. That mistake, made by hand
# at a prompt, is what first suggested monkey had no checkouts at all.
_SCHED_PROBE = (
    'for d in /srv/scheduler "$HOME/scheduler" '
    '        "$HOME/Documents/Projects/scheduler"; do '
    '  [ -d "$d/schedule" ] && { echo "$d cat"; exit 0; }; done; '
    'p=$(sudo -n sh -c \'for d in /home/*/Documents/Projects/scheduler; do '
    '  [ -d "$d/schedule" ] && { echo "$d"; exit 0; }; done\' 2>/dev/null); '
    '[ -n "$p" ] && { echo "$p sudo"; exit 0; }; '
    'echo "no scheduler checkout this account can read; project homes are '
    '0700 and sudo -n is $(sudo -n true 2>/dev/null && echo ok || '
    'echo unavailable)" >&2; exit 9')

_sched_cache = {}


def remote_scheduler(host):
    """((path, reader), None) or (None, reason) for a REMOTE host.

    `reader` is "cat" or "sudo -n cat". Cached per host per process: four
    sensors ask this now, and it is one ssh round trip each time.
    """
    if host in _sched_cache:
        return _sched_cache[host]
    out, err = ssh_read(host, _SCHED_PROBE)
    if out is None or not out.strip():
        res = (None, err or "no readable scheduler checkout")
    else:
        path, _, mode = out.strip().splitlines()[0].rpartition(" ")
        res = ((path, "sudo -n cat" if mode == "sudo" else "cat"), None)
    _sched_cache[host] = res
    return res


def reset_cache():
    """Fixtures call this; the tailnet is probed once per process otherwise."""
    global _tailnet_cache
    _tailnet_cache = None
    _sched_cache.clear()
