#!/usr/bin/env python3
"""ecosim.bashification -- is a coined verb actually reachable from a prompt?

WHY THIS SENSOR EXISTS, and like `sync` it is an error already made rather
than a predicted one.

On 2026-08-01 a bashify pass coined `ausculte` for ecosim after checking
`command -v ausculte` and finding the name unclaimed. It was not unclaimed:
senechal had coined it on 2026-07-30 and simply never installed it. The
availability check was structurally incapable of catching the collision.

    "NEVER COINED" AND "COINED BUT NOT INSTALLED" ARE TWO WORLD-STATES
    THAT SHARE ONE SYMBOL, AND THAT SYMBOL IS `command -v` SAYING NOTHING.

The bashification process runs on exactly that distinction. A verb's life has
three stages -- coined on a `bashified` branch, installed onto the path,
matching between the two -- and a pass that only looks at the path sees the
first stage as identical to not having happened. That is the fault this
project exists to detect, committed inside the process meant to end it.

So this sensor never reports reachability without reporting whether what is
reachable is what was coined, and never reports a name as free without having
read the branches where names are coined.
"""
from pathlib import Path
import hashlib
import os
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from ecosim_sensor import (  # noqa: E402
    Alphabet, Domain, Sensor, Symbol, register,
    EXIT_OK, EXIT_WARN, EXIT_CRIT, EXIT_BLIND,
)

PROJECTS = Path(os.environ.get(
    "ECOSIM_PROJECTS_DIR", Path.home() / "Documents/Projects"))
SCHED = Path(os.environ.get(
    "ECOSIM_SCHEDULER_DIR", Path.home() / "Documents/Projects/scheduler"))
BINDIR = Path(os.environ.get(
    "ECOSIM_BINDIR", Path.home() / ".local/bin"))
MANIFEST = Path(os.environ.get(
    "INSTALLE_MANIFEST",
    Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
    / "installe/manifest.tsv"))

# The utility repos, read off realisateur/WAITING-ROOM.md (Zach-decided,
# 2026-08-01). Project repos parked there are deliberately NOT in this domain:
# their verbs are not supposed to be reachable, so reporting them unreachable
# would be a WARN for a state someone chose.
UTILITY_REPOS = {
    "scheduler": SCHED,
    "realisateur": PROJECTS / "realisateur",
    "senechal": PROJECTS / "senechal",
    "gardien": PROJECTS / "gardien",
    "ecosim": PROJECTS / "ecosim",
    "vim-arcade": PROJECTS / "vim-arcade",
}

BRANCH = "origin/bashified"
LOCAL = "bashified"


def _sh(*args, cwd=None):
    """Like ecosim_sensor.sh but returning bytes, since verbs are compared
    byte-for-byte and a decode would make two different files look equal."""
    import subprocess
    try:
        p = subprocess.run(args, cwd=cwd, capture_output=True, timeout=30)
    except Exception:                                   # noqa: BLE001
        return 1, b""
    return p.returncode, p.stdout


def _digest(data):
    return hashlib.sha256(data).hexdigest()[:12] if data is not None else None


@register
class BashificationSensor(Sensor):
    name = "bashification"

    domain = Domain(
        describes="whether each verb coined on a utility repo's bashified "
                  "branch is reachable from a prompt, governed by installe, "
                  "and byte-identical to what was coined -- never "
                  "reachability alone",
        reads=(f"git ls-tree {BRANCH} bin/ in each utility repo",
               str(BINDIR), str(MANIFEST)),
        hosts=("mandark",),
    )

    alphabet = Alphabet(
        Symbol("REACHABLE", EXIT_OK,
               "coined on the bashified branch, on the path, owned by "
               "installe, and byte-identical to what was coined -- the only "
               "state in which the prompt and the repository agree"),
        Symbol("COINED_UNREACHABLE", EXIT_WARN,
               "coined on the bashified branch and absent from the path. "
               "`command -v` reports this exactly as it reports a name that "
               "was never coined, which is how one verb got coined twice"),
        Symbol("REACHABLE_UNGOVERNED", EXIT_WARN,
               "on the path but absent from installe's manifest, so "
               "`installe retire` refuses it: reachable by one command and "
               "unwirable only by archaeology"),
        Symbol("DRIFTED", EXIT_CRIT,
               "on the path, and its bytes match NO commit on the bashified "
               "branch -- the prompt reaches something the repository does "
               "not say anywhere, in any direction"),
        Symbol("UNPUSHED", EXIT_WARN,
               "on the path and byte-identical to the LOCAL bashified branch, "
               "which is ahead of origin. This host's verb is correct and no "
               "other host can obtain it; what is missing is a push, not a "
               "fix. Found by this sensor's own first defect: it scored "
               "ahead-of-origin as CRIT drift, which is stale-and-ahead "
               "collapsed onto one symbol"),
        Symbol("BROKEN_LINK", EXIT_CRIT,
               "on the path with its target gone: the name resolves, the "
               "verb does not run, and nothing that reads the path can tell"),
        Symbol("BLIND_BRANCH_UNREADABLE", EXIT_BLIND,
               "the repo's bashified branch could not be read, so what it "
               "coined is unknown and no claim about that repo is possible"),
        Symbol("BLIND_NO_MANIFEST", EXIT_BLIND,
               "installe's manifest could not be read, so whether a "
               "reachable verb is governed cannot be told from whether it is "
               "merely present"),
    )

    def __init__(self, reader=None, manifest_reader=None):
        super().__init__()
        self._read = reader or self._read_repo
        self._read_manifest = manifest_reader or self._read_manifest_file

    # -- reading the world ------------------------------------------------
    @staticmethod
    def _read_repo(project, repo):
        """(verb -> (origin_bytes, local_bytes)) for the bashified branch, or
        None.

        BOTH refs are read, because "the path is stale" and "the path is
        ahead of origin" are two world-states and only origin can tell them
        apart. Reading origin alone reports the second as the first, which
        this sensor did on its first run.

        None means the branch could not be read AT ALL. An empty dict means
        it was read and coined nothing, which is a different fact and must
        not be reported as blindness.
        """
        rc, out = _sh("git", "-C", str(repo), "ls-tree", "--name-only",
                      BRANCH, "bin/")
        if rc != 0:
            return None
        verbs = {}
        for path in out.decode("utf-8", "replace").split():
            name = path.rsplit("/", 1)[-1]
            if not name:
                continue
            rc2, blob = _sh("git", "-C", str(repo), "show", f"{BRANCH}:{path}")
            if rc2 != 0:
                return None
            rc3, local = _sh("git", "-C", str(repo), "show", f"{LOCAL}:{path}")
            verbs[name] = (blob, local if rc3 == 0 else None)
        return verbs

    @staticmethod
    def _read_manifest_file():
        """{name: target} that installe owns, or None if unreadable."""
        try:
            text = MANIFEST.read_text()
        except OSError:
            return None
        owned = {}
        for line in text.splitlines():
            parts = line.split("\t")
            if len(parts) >= 2:
                owned[parts[0]] = parts[1]
        return owned

    @staticmethod
    def _on_path(verb):
        """(present, target_bytes_or_None). target_bytes None with present
        True is a name that resolves to nothing readable -- a broken link."""
        p = BINDIR / verb
        if not p.is_symlink() and not p.exists():
            return False, None
        try:
            return True, p.read_bytes()
        except OSError:
            return True, None

    # -- the classification -----------------------------------------------
    def probe(self):
        owned = self._read_manifest()
        if owned is None:
            yield self.blind("BLIND_NO_MANIFEST", "installe",
                             f"{MANIFEST} unreadable; governance of every "
                             f"reachable verb is unknown")
            owned = {}

        for project, repo in sorted(UTILITY_REPOS.items()):
            coined = self._read(project, repo)
            if coined is None:
                yield self.blind("BLIND_BRANCH_UNREADABLE", project,
                                 f"{BRANCH} unreadable in {repo}",
                                 project=project)
                continue
            for verb, (blob, local) in sorted(coined.items()):
                yield from self._classify(project, verb, blob, local, owned)

    def _classify(self, project, verb, coined_blob, local_blob, owned):
        present, installed = self._on_path(verb)
        if not present:
            yield self.emit("COINED_UNREACHABLE", verb,
                            f"coined in {project}, absent from {BINDIR}",
                            project=project, coined=_digest(coined_blob))
            return
        if installed is None:
            yield self.emit("BROKEN_LINK", verb,
                            f"{BINDIR / verb} resolves to nothing readable",
                            project=project)
            return
        if _digest(installed) != _digest(coined_blob):
            if local_blob is not None and _digest(installed) == _digest(local_blob):
                yield self.emit("UNPUSHED", verb,
                                f"matches {project}'s local {LOCAL} "
                                f"({_digest(local_blob)}); {BRANCH} still has "
                                f"{_digest(coined_blob)}",
                                project=project, on_path=_digest(installed),
                                origin=_digest(coined_blob))
                return
            yield self.emit("DRIFTED", verb,
                            f"path has {_digest(installed)}, "
                            f"{project} coined {_digest(coined_blob)}",
                            project=project, on_path=_digest(installed),
                            coined=_digest(coined_blob))
            return
        if verb not in owned:
            yield self.emit("REACHABLE_UNGOVERNED", verb,
                            f"on the path, not in installe's manifest",
                            project=project)
            return
        yield self.emit("REACHABLE", verb,
                        f"coined in {project}, installed, governed",
                        project=project, coined=_digest(coined_blob))

    # -- fixtures ---------------------------------------------------------
    def fixtures(self):
        blob = b"#!/usr/bin/env bash\n# a verb\n"
        other = b"#!/usr/bin/env bash\n# a DIFFERENT verb\n"

        def mk(coined, path_state, manifest):
            s = BashificationSensor(
                reader=lambda p, r: coined,
                manifest_reader=lambda: manifest)
            s._on_path = lambda v, _st=path_state: _st  # noqa: SLF001
            return lambda: list(s.probe())

        third = b"#!/usr/bin/env bash\n# neither of the above\n"
        # (origin_blob, local_blob). level = origin and local agree.
        level = {"veille": (blob, blob)}
        ahead = {"veille": (blob, other)}     # local has moved, origin has not
        owns = {"veille": "/somewhere/veille"}
        return [
            # REACHABLE -- coined, installed, byte-identical, governed
            mk(level, (True, blob), owns),
            # COINED_UNREACHABLE -- the ausculte case
            mk(level, (False, None), {}),
            # REACHABLE_UNGOVERNED -- present, installe does not own it
            mk(level, (True, blob), {}),
            # UNPUSHED -- path matches LOCAL bashified, which is ahead. The
            # case that made this sensor's own first version wrong.
            mk(ahead, (True, other), owns),
            # DRIFTED -- path matches NEITHER ref: genuinely unaccounted for
            mk(ahead, (True, third), owns),
            # BROKEN_LINK -- name resolves, target gone
            mk(level, (True, None), {"veille": "/gone/veille"}),
            # BLIND_BRANCH_UNREADABLE -- branch unreadable, no claim made
            mk(None, (False, None), {}),
            # BLIND_NO_MANIFEST -- governance unknowable
            mk({}, (False, None), None),
        ]
