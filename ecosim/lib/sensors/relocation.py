#!/usr/bin/env python3
"""ecosim.relocation -- does a project still live where the ecosystem says it does?

WHY THIS SENSOR EXISTS, before any move it watches.

`scheduler` moved out of `Project Archive` on 2026-08-01, and `wtul` follows.
scheduler's path was written into 21 files under `~/.local/bin`, into four
symlinks, and into its own tracked scripts. Neither move is the risk; the risk
is the half-move.

    A DIRECTORY THAT ARRIVED AND A REFERENCE THAT FOLLOWED IT ARE TWO
    WORLD-STATES, AND `mv` REPORTS SUCCESS FOR BOTH.

That is the shape this ecosystem keeps recording: the act succeeds, and the
thing that pointed at the old location keeps pointing at it until the next
scheduled run fails at 03:14 with a path error nobody is awake for.

This sensor is built BEFORE the move rather than after it, because "did the
move break anything" is unanswerable without a reading from before. A sensor
that first runs after the act it measures reports a world, not a change.

WHAT IT DOES NOT DO. It has no opinion about whether a move SHOULD happen --
that is `transplante check`, which is a different question asked by a
different tool with a stop bit. This one only reports whether the ecosystem's
declared paths and the disk agree, on every host that holds a declaration.

SUBJECTS COME FROM TWO SOURCES, because registration and existence are not the
same fact. The registry says what dispatches; the tree `fauche` governs says
what is here. `wtul` is live, unregistered, and was invisible to this sensor
until the second source was added -- see _in_tree.

RULE 4 BITES HERE. mandark and dexter each carry their own rotation files and
their own copies of these paths. A relocation confirmed on mandark says
nothing about dexter's copy, and the three original defects this contract was
built from were all assertions about a host whose copy the sensor never read.
So each host is read separately, and the one that cannot be read is BLIND for
that host alone -- never absorbed into the other's verdict.
"""
from pathlib import Path
import os
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import hosts  # noqa: E402
from ecosim_sensor import (  # noqa: E402
    Alphabet, Domain, Sensor, Symbol, register, sh,
    EXIT_OK, EXIT_WARN, EXIT_CRIT, EXIT_BLIND,
)

SCHED = Path(os.environ.get(
    "ECOSIM_SCHEDULER_DIR", Path.home() / "Documents/Projects/scheduler"))

# Where a reference to a project's path can hide on a host. Named in ONE
# place. A location absent from this tuple is a location this sensor does not
# read, which is a limit of its domain rather than a clean result.
REF_ROOTS = ("~/.local/bin",)

# The tree `fauche` governs. Repositories here are subjects of this sensor
# whether or not any conf declares them -- see _in_tree.
PROJECT_TREE = Path(os.environ.get(
    "ECOSIM_PROJECT_TREE", Path.home() / "Documents/Projects"))


@register
class RelocationSensor(Sensor):
    name = "relocation"

    domain = Domain(
        describes="whether every repository this ecosystem knows of -- declared "
                  "in the registry OR present in the tree fauche governs -- "
                  "exists where its path says, and whether anything on that "
                  "host still names a path that does not: the half-move, "
                  "which mv reports as success",
        reads=("schedule/*.conf PROJECT_REPO_PATH", "~/Documents/Projects") + REF_ROOTS,
        hosts=hosts.dispatch_hosts(),
    )

    alphabet = Alphabet(
        Symbol("AT_DECLARED", EXIT_OK,
               "the repository is present at the path its registration "
               "declares, and nothing on this host names a path that is "
               "missing -- declaration and disk agree"),
        Symbol("REFS_ORPHANED", EXIT_WARN,
               "the repository is present where declared, but files on this "
               "host still name a path that no longer exists: the move landed "
               "and the registration was updated while these were not"),
        Symbol("DECLARED_ABSENT", EXIT_CRIT,
               "the declared path does not exist on this host and nothing "
               "names it either -- the registration points at a hole, so "
               "dispatch resolves nothing and no caller reveals it"),
        Symbol("MOVED_DANGLING", EXIT_CRIT,
               "the declared path does not exist and files on this host still "
               "name it -- live callers point at somewhere nothing is, which "
               "stays silent until each next runs"),
        Symbol("BLIND_CONF_UNREADABLE", EXIT_BLIND,
               "a registration file could not be read, so no claim about the "
               "projects declared in it is possible"),
        Symbol("BLIND_HOST_UNREADABLE", EXIT_BLIND,
               "this host's own copy could not be read, so its paths are "
               "unknown -- never inherited from the host that could be read"),
    )

    def __init__(self, reader=None, host_list=None):
        super().__init__()
        self._read = reader or self._read_host
        # Pinned in fixtures; derived in production. See lib/hosts.py.
        self._hosts = tuple(host_list) if host_list else hosts.dispatch_hosts()

    @staticmethod
    def _declared(confdir):
        """{project: declared_path} read from the registry, or None."""
        try:
            confs = sorted(Path(confdir).glob("*.conf"))
        except OSError:
            return None
        if not confs:
            return None
        out = {}
        for conf in confs:
            if conf.name.startswith("_"):
                continue
            try:
                text = conf.read_text()
            except OSError:
                continue
            for line in text.splitlines():
                if line.startswith("PROJECT_REPO_PATH="):
                    out[conf.stem] = line.split("=", 1)[1].strip().strip('"\'')
                    break
        return out or None

    @staticmethod
    def _in_tree(declared):
        """{name: path} for repositories in PROJECT_TREE the registry omits.

        REGISTERED AND EXISTS ARE TWO DIFFERENT FACTS, and deriving subjects
        from schedule/*.conf alone conflated them. `wtul` is a live repository
        that no conf declares, so this sensor could not see it at all -- and a
        sensor blind to a whole class of subject reports on the ones it can
        read with exactly the same confidence.

        The tree scanned is the one `fauche` governs, deliberately: that is
        already the ecosystem's answer to "which repositories live here",
        so this adds no second opinion about membership.
        """
        known = {os.path.realpath(p) for p in declared.values()}
        found = {}
        try:
            children = sorted(PROJECT_TREE.iterdir())
        except OSError:
            return found
        for child in children:
            if not child.is_dir() or child.name.startswith("."):
                continue
            if not (child / ".git").exists():
                continue
            if os.path.realpath(child) in known:
                continue
            found[child.name] = str(child)
        return found

    @classmethod
    def _read_host(cls, host):
        """(declared, present, refs) or (None, None, reason).

        declared: {project: path}
        present:  {project: bool}
        refs:     {path: n_files_naming_it}  -- counted per FILE, never per
                  project: one unresolved reference strands one live job, and
                  a per-project count hides how many.
        """
        if hosts.is_local(host):
            declared = cls._declared(SCHED / "schedule")
            if declared is None:
                return None, None, "registry unreadable"
            declared.update(cls._in_tree(declared))
            present = {p: Path(path).is_dir() for p, path in declared.items()}
            refs = {}
            for path in set(declared.values()):
                n = 0
                for root in REF_ROOTS:
                    r = Path(os.path.expanduser(root))
                    if not r.is_dir():
                        continue
                    # No pipeline: a pipe's exit status is the LAST command's,
                    # and `grep -rl ... | wc -l` reports 0 files and success
                    # when grep itself failed to run.
                    rc, out = sh("grep", "-rlI", "--", path, str(r), timeout=30)
                    if rc not in (0, 1):
                        return None, None, f"reference scan failed under {root}"
                    n += len([l for l in out.splitlines() if l.strip()])
                    # A SYMLINK NAMES THE PATH IN ITS TARGET, which is not file
                    # content, so grep cannot see it. Added 2026-08-01 after the
                    # scheduler move: grep counted 19 files while four symlinks
                    # -- including the one putting `scheduler` itself on PATH --
                    # named the path invisibly. A census blind to the most
                    # load-bearing reference class reports a smaller number with
                    # exactly the same confidence.
                    rc2, out2 = sh("find", str(r), "-maxdepth", "1", "-type",
                                   "l", "-lname", f"*{path}*", timeout=30)
                    if rc2 != 0:
                        return None, None, f"symlink scan failed under {root}"
                    n += len([l for l in out2.splitlines() if l.strip()])
                refs[path] = n
            return declared, present, refs

        # WHERE the registry lives is asked once, in lib/hosts.py, and is
        # /srv/scheduler on a migrated host. Hardcoding ~/scheduler is what
        # kept this sensor blind to monkey after rotation could already see
        # it: monkey's login account owns no checkout at all.
        found, why = hosts.remote_scheduler(host)
        if found is None:
            return None, None, why
        sroot, reader = found

        # A remote host is read over ssh, in one call, argv-style.
        script = (
            f"for c in {sroot}/schedule/*.conf; do "
            "  case $(basename $c) in _*) continue;; esac; "
            f"  p=$({reader} $c | sed -n 's/^PROJECT_REPO_PATH=//p' | head -1 | tr -d '\"'); "
            "  [ -n \"$p\" ] || continue; "
            # EXPAND $HOME, or refuse to guess. Registrations declare
            # PROJECT_REPO_PATH="$HOME/Documents/Projects/<p>", and the shell
            # that reads them here is NOT the shell that will run the job. On
            # a one-user-per-project host $HOME means THAT PROJECT'S home, so
            # it is resolved from the passwd entry named by the conf.
            #
            # Left literal, `[ -d "$HOME/..." ]` is false for every project and
            # the sensor reports a CRIT wall of DECLARED_ABSENT about repos
            # that are all present -- seven of them on monkey, which is how
            # this was found. Where the user does not exist the path is marked
            # UNRESOLVED and becomes BLIND: unknown, never "absent".
            "  u=$(basename $c .conf); "
            "  case $p in *'$HOME'*) "
            "    h=$(getent passwd \"$u\" | cut -d: -f6); "
            "    if [ -n \"$h\" ]; then p=$(printf '%s' \"$p\" | sed \"s|[$]HOME|$h|\"); "
            "    else echo \"$u|UNRESOLVED|0|0\"; continue; fi;; esac; "
            "  n=$(grep -rlI -- \"$p\" ~/.local/bin 2>/dev/null | wc -l); "
            # PRESENT / ABSENT / CANNOT-SEE are three states, not two. A plain
            # `[ -d ]` run by the login account returns false for anything
            # inside a 0700 project home -- so every repo on monkey read as
            # "does not exist on this host", a CRIT about three repositories
            # that are all present. Absence must be ESTABLISHED, not inferred
            # from a failed look.
            "  if [ -d \"$p\" ]; then d=1; "
            "  elif sudo -n test -d \"$p\" 2>/dev/null; then d=1; "
            "  elif [ -r \"$(dirname \"$p\")\" ] || sudo -n true 2>/dev/null; then d=0; "
            "  else d=?; fi; "
            "  echo \"$u|$p|$d|$n\"; done"
        )
        out, err = hosts.ssh_read(host, script, timeout=45)
        if out is None:
            return None, None, (err or "ssh failed")[:70]
        declared, present, refs, unresolved = {}, {}, {}, []
        for line in out.splitlines():
            parts = line.strip().split("|")
            if len(parts) != 4:
                continue
            proj, path, d, n = parts
            if path == "UNRESOLVED":
                # Its registration names $HOME and no such unix user exists
                # here, so this host cannot say where the repo should be. That
                # is BLIND, and reporting it as absent would be a CRIT built
                # on a variable nobody expanded.
                unresolved.append(proj)
                continue
            declared[proj] = path
            if d == "?":
                # Could not look, and could not establish that we could have.
                unresolved.append(proj)
                continue
            present[proj] = (d == "1")
            refs[path] = int(n)
        if unresolved and not declared:
            return None, None, ("registrations name $HOME and no matching unix "
                                f"user exists on {host}: "
                                f"{','.join(sorted(unresolved)[:6])}")
        if not declared:
            # Reachable, but nothing to read. Naming the path searched is the
            # difference between a report an operator can act on and one that
            # says only "no". Verified 2026-08-01: dexter answers ssh as zach
            # in WSL2 and has no ~/scheduler at all -- its crontab was emptied
            # 2026-07-29 for THE PLAY run 3 -- so this is the true state of
            # that host, not a transport failure wearing a registry error.
            return None, None, (f"reachable, but no registry: "
                                f"~/scheduler/schedule/*.conf declares nothing "
                                f"on {host}")
        return declared, present, refs

    def probe(self):
        for host in self._hosts:
            declared, present, refs = self._read(host)
            if declared is None:
                reason = refs
                # A registry that cannot be read is a different blindness from
                # a host that cannot be reached, and collapsing them would hide
                # which of the two happened.
                sym = ("BLIND_CONF_UNREADABLE"
                       if "registry" in str(reason)
                       else "BLIND_HOST_UNREADABLE")
                yield self.blind(sym, host, str(reason), host=host)
                continue

            for proj in sorted(declared):
                path = declared[proj]
                here = present.get(proj, False)
                naming = refs.get(path, 0)
                if here:
                    # Present where declared. The remaining question is whether
                    # anything on this host names a path that is NOT present --
                    # the residue of an earlier move.
                    orphans = sum(n for p, n in refs.items()
                                  if n and not present.get(
                                      _owner(declared, p), True))
                    if orphans:
                        yield self.emit(
                            "REFS_ORPHANED", proj,
                            f"{path} present; {orphans} file(s) on {host} name "
                            f"a declared path that is missing",
                            host=host, path=path, orphan_refs=orphans)
                    else:
                        yield self.emit(
                            "AT_DECLARED", proj,
                            f"{path} present; {naming} file(s) name it",
                            host=host, path=path, refs=naming)
                elif naming:
                    yield self.emit(
                        "MOVED_DANGLING", proj,
                        f"{path} does not exist on {host}, and {naming} "
                        f"file(s) there still name it",
                        host=host, path=path, refs=naming)
                else:
                    yield self.emit(
                        "DECLARED_ABSENT", proj,
                        f"{path} does not exist on {host} and nothing names it",
                        host=host, path=path, refs=0)

    def fixtures(self):
        def mk(declared, present, refs):
            s = RelocationSensor(reader=lambda h: (declared, present, refs),
                                 host_list=("mandark",))
            return lambda: list(s.probe())

        old = "/home/zach/Documents/Projects/scheduler"
        new = "/home/zach/Documents/Projects/scheduler"

        return [
            # AT_DECLARED -- the pre-move baseline, and the post-move goal.
            mk({"scheduler": old}, {"scheduler": True}, {old: 21}),
            # MOVED_DANGLING -- the half-move this sensor exists for: the
            # directory went to `new`, the conf was not updated, 21 shims
            # still name `old`.
            mk({"scheduler": old}, {"scheduler": False}, {old: 21}),
            # DECLARED_ABSENT -- conf points at a hole nobody references.
            mk({"scheduler": old}, {"scheduler": False}, {old: 0}),
            # REFS_ORPHANED -- scheduler moved and its conf was updated, but
            # wtul's declared path is gone and files still name it.
            mk({"scheduler": new, "wtul": "/home/zach/Documents/wtul"},
               {"scheduler": True, "wtul": False},
               {new: 0, "/home/zach/Documents/wtul": 4}),
            # BLIND_CONF_UNREADABLE
            mk(None, None, "reachable, but no registry: ~/scheduler/schedule/*.conf declares nothing on dexter"),
            # BLIND_HOST_UNREADABLE
            mk(None, None, "ssh: connect to host dexter port 2223: timed out"),
        ]


def _owner(declared, path):
    """Which project declares `path`. Used to ask whether a referenced path is
    one the registry still expects to exist."""
    for proj, p in declared.items():
        if p == path:
            return proj
    return None
