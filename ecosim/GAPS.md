# GAPS -- what `sonde` cannot yet do

Recorded 2026-07-30 during the bashify pass. These are to be closed
later; they are written down now so the utility never pretends.

## Python that was never given a shell contract (15 files)

These do real work but are not reachable through the verb, because they
have no stated argv/output promise to wrap:

- `bin/ecosim-cast.py`
- `bin/migration-watch.py`
- `lib/ecosim_sensor.py`
- `lib/sensors/__init__.py`
- `lib/sensors/boundary.py`
- `lib/sensors/quota.py`
- `lib/sensors/rotation.py`
- `lib/sensors/sync.py`
- `sim/clone_sup.py`
- `sim/ecosim.py`
- `sim/experiment.py`
- `sim/prereg.py`
- `sim/register_h.py`
- `sim/supervisor.py`
- `test/test_contract.py`

## Standing gap: the cost baseline

No before-measurement exists for what the previous implementation cost
per call, so the saving from mechanising it is **unmeasured, not zero
and not assumed**. Closing this needs a real measurement, not an estimate.

---

## Found 2026-08-01, during the second pass

### ~~The branch depends on the tree it purged~~ — CLOSED 2026-08-05

`bin/sonde` and `bin/ausculte` both read `LEGACY_ROOT`, defaulting to the
**main checkout's working tree** at an absolute path. So this "total purge"
branch does not carry the tooling it fronts: check out `bashified` alone,
or move the repository, and every subcommand exits 4.

That is honest — exit 4 is exactly the right symbol, and it is not an
exit-0 no-op — but it means these verbs are front doors, not a rewrite.
`SONDE_LEGACY_ROOT` / `AUSCULTE_LEGACY_ROOT` exist so the dependency is
declared and overridable rather than hidden. Closing this means porting
`ecosim-sensor`, `ecosim-sweep` and `silence-audit.sh` into the branch,
which is a rewrite, not a wiring job.

**Closed 2026-08-05.** The port was done, because the dev clone on
`mandark` is being removed and a hardcoded `/home/zach/Documents/Projects/
ecosim` in a *build* is exactly what makes a clone unremovable. Carried
onto this branch: `bin/ecosim-sensor`, `bin/ecosim-sweep`,
`bin/migration-watch.py`, `bin/silence-audit.sh`, `lib/ecosim_sensor.py`,
`lib/hosts.py`, `lib/sensors/*.py`, and the four baseline/fixture JSON
files under `sensors/`. `SONDE_LEGACY_ROOT` now defaults to `$SELF`.

Measured, not asserted — on mandark, 2026-08-05:

| | installed `sonde` (clone) | ported `sonde` (this branch) |
|---|---|---|
| `run` | rc=6 (BLIND) | rc=6 (BLIND) |
| `selftest` | rc=0, 43 symbols, 0 violations | rc=0, 43 symbols, 0 violations |
| `test/contract-test.sh` | — | 7 passed, 0 failed, 0 gaps |

One design change came with the port, and it is not cosmetic. The tooling
**writes**: `ecosim-sensor run --log` appends `sensors/events-v2.jsonl`,
`migration-watch.py` appends `sensors/events.jsonl`, and `--snapshot`
rewrites the baselines. A build directory is replaced wholesale by the next
`install-verb-build.sh --apply`, so those writes would be records that die
with the build that wrote them. Every writer now targets `ECOSIM_STATE_DIR`
(`$XDG_STATE_HOME/ecosim`, set by `sonde`); every baseline READ prefers a
snapshot in that state dir and falls back to the copy carried here. Called
directly out of a clone with the variable unset, behaviour is byte-for-byte
what it was.

**Still not closed by this: `ausculte silence`.** See the next section.

### The exit dialects collided, and one of them was already spent

The fronted tooling speaks Monitoring Plugins (`0 OK / 1 WARN / 2 CRIT /
3 BLIND`). This ecosystem reads 3 as **needs-summon**. A pass-through
wrapper would have reported this project's own BLIND — its entire thesis —
as a request for money. Both verbs now translate instead.

Second collision, caught by reading `CONTRACT.md` rather than inventing:
**7 was already promised as REFUSED.** WARN and CRIT therefore took 8 and
9, and `ausculte install`'s precondition abort — "net prose would not
decrease" — correctly landed on 7, which is what it always was.

### Row 9 of the page test is not mechanized

`test/page-test.sh` checks rows 1, 2, 3, 4, 5, 6, 7 and 8 by machine. Row 9
(present tense only) is reported `UNCHECKED`, never counted as a pass. A
row verified by reading is a row that will drift, and this one is still
verified by reading.

### `decide` is not offered

`bin/decide.sh` in the legacy tree is a menu built for one past research
pass. It is documented in `sonde(1)` as not offered and exits 4, rather
than being quietly absent.

### Standing gap: the cost baseline

Unchanged from 2026-07-30. No before-measurement exists for what the
previous implementation cost per call, so the saving from mechanising it is
**unmeasured, not zero and not assumed**.


## `ausculte` is senechal's, and was removed here (2026-08-01)

This project coined `ausculte` on 2026-08-01 after `command -v ausculte`
came back unclaimed. It was not unclaimed: **senechal coined the same verb
on 2026-07-30** and simply never installed it. An availability check that
reads `PATH` sees installed verbs, not coined ones, so the check was
structurally incapable of catching it.

Zach ruled the two are one domain: the estate includes its own instruments,
so a mechanism that cannot tell silence from clean is unhealthy estate
machinery, and senechal's NAME line already covers it in one clause. The
silence audit is now reachable as **`ausculte silence`**, from senechal.

Removed here: `bin/ausculte` and `man/ausculte.1`. `sonde` is unaffected.

**Not moved: the implementation.** `bin/silence-audit.sh` still lives in
this project and senechal reaches it by a declared path
(`AUSCULTE_SILENCE_AUDIT`). Relocating the file touches realisateur's
installed `silence-audit` shim and the propagated `CLAUDE.md` checklist row
that cites this project's flag classes by name, so it is a separate decision
and is deliberately not taken here.

### `ausculte silence` is the one thing that still pins the dev clone

Added 2026-08-05, during the pass that removed every other reason to keep
`~/Documents/Projects/ecosim` on mandark.

`senechal/bin/ausculte` line 22 reads

    SILENCE_AUDIT="${AUSCULTE_SILENCE_AUDIT:-/home/zach/Documents/Projects/ecosim/bin/silence-audit.sh}"

That default is an absolute path into a **development clone**, resolved
from inside an immutable build. It is the same defect `sonde` had and the
port above closed — but it lives in senechal's repository, so it cannot be
closed from here.

`bin/silence-audit.sh` is now carried on this branch, so after the next
build cut the file exists at
`~/.local/share/verb-builds/current/ecosim/bin/silence-audit.sh`. The
remaining change is one line in senechal:

    SILENCE_AUDIT="${AUSCULTE_SILENCE_AUDIT:-$(dirname "$SELF")/ecosim/bin/silence-audit.sh}"

or an equivalent that resolves within the build. Until that lands,
`ausculte silence` — and only `ausculte silence` — requires the clone.

Two facts worth recording, because they were measured rather than assumed:

1. **The clone the estate is auditing is stale.** On 2026-08-05 the mandark
   checkout was **12 commits behind `origin/main`**, so the
   `silence-audit.sh` that `ausculte silence` has been running is 12 commits
   old. A build would be pinned to a named sha instead.
2. **There are three copies of this file, and they differ.** `~/.local/bin/
   silence-audit` is a realisateur-owned shim that execs
   `realisateur/bin/silence-audit.sh` (18546 bytes) — a *different* file
   from `ecosim/bin/silence-audit.sh` (37573 bytes on `origin/main`), which
   is what `ausculte silence` runs. The ecosim copy has four checks the
   realisateur copy lacks (`dirty-writer`, `worktree-backed`, `twin`,
   `subrepo-invisible`); the realisateur copy has a short-flag guard the
   ecosim copy lacks. This is `check_twin`'s own named pattern, live,
   against the file that implements it — already recorded in `CONTRACT.md`
   and still true. Deciding which copy is canonical is a prerequisite for
   the senechal change, not a detail of it.

**The generalisable finding:** a new verb's availability check must scan
every project's `bashified` man pages, not just `PATH`. Nothing does that
today — `installe audit` reads `PATH`, and `recense` takes a census of
installed executables. Proposed rather than built, so it lands as one check
inside an existing tool rather than a rival to it.
