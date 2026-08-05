# CONTRACT -- `garde`

> guard the estate's data: nightly backups and their proof

This file is the deliverable. It states what `garde` is obliged to do
**because of its role in the ecosystem**, not what happens to be built.
Implementation is downstream of this document; when the two disagree,
this document is right and the code is behind.

Derived 2026-07-30. Where there was no stated contract before, this is
the first one -- itself a finding about the old tree, recorded rather
than hidden.

## How to read the HOW column

Every obligation is kept one of three ways, and the column says which.
This is the whole design (Zach, 2026-07-30):

> What it *can* do in bash, it does, and we use it that way. What it
> can't? We invoke agents, do the task by hand, and mechanize it for
> next time.

| HOW | meaning | exit when unmet | cost |
|---|---|---|---|
| **bash** | mechanized. Runs free, unattended, no model in the loop. | 5 if it ran and broke | free |
| **summon** | **SHOULD DO** -- in scope, not yet mechanized. An agent does it by hand *now*, and the request is appended to a mechanization queue so the next build wires it into bash. | 4 (GAP), naming its own escalation | metered, printed before spending |
| **refused** | **WON'T DO** -- out of scope on principle. Will never be built. | 7 (REFUSED) | n/a, no summon exists |

The load-bearing rule: **`--summon` is available on 4 and forbidden on
7.** A gap names its escalation; a refusal offers none, because having
no escalation path is what refusing on principle *means*. Without that
rule `--summon` degrades into a general-purpose "do it anyway" flag,
which is the failure a spending flag wired to an agent invites hardest.

A `summon` row is a debt with a receipt, not a permanent arrangement.
Every summoned run appends to `~/.local/share/garde/mechanize.md`; that
file is the build queue, and a row that keeps appearing there is the
strongest possible argument for mechanizing it.

## The obligations

### Guarding data -- the core role

| obligation | HOW | backed by |
|---|---|---|
| Know every set that must be guarded, and where each is held | bash | `media list` |
| Copy a set to every destination it declares | bash | `media run` |
| **Prove** the copy landed, byte for byte, not trust rsync's exit code | bash | `media run` (md5 both sides) |
| Refuse to silently lose a file to a case-insensitive destination | bash | collision pre-flight, `lib/media.sh` |
| Report any set below its declared `min_copies` floor | bash | `media audit` |
| Survive a wifi link that HANGS rather than drops | bash | `--timeout` + `ServerAliveInterval` |
| Diagnose *why* a hash mismatch happened | summon | `media triage` -> `basheur run media-triage` |
| Decide whether two overlapping trees are duplicates | summon | not yet routed |
| Run the nightly snapshot rotation itself | summon | `gardien.py` has no argv contract (see GAPS.md) |
| Guard data to remote/offsite storage | summon | unbuilt by decision, not oversight |

### Universal clauses

Every subcommand, without exception:

- exits **0 only if the promise was kept**. Never an exit-0 no-op.
- exits **4 (GAP)** if in-scope tooling does not exist yet, says what is
  missing, and names the summon that can do it by hand meanwhile.
- exits **5 (BROKEN)** if it ran and produced a wrong or partial answer.
- exits **6 (BLIND)** if it cannot read its domain. "I cannot see" is
  never reported as "nothing to report" -- `media list` with no
  reachable destination is exit 6, **not** an empty table.
- exits **7 (REFUSED)** if asked for something out of scope by design.
- **cannot spend money** unless it declares `--summon`, which has no
  short form and is never implied.

### What garde WILL NOT do

Stated positively so silence is never mistaken for oversight.

| refusal | why |
|---|---|
| `media restore` | garde copies outward and proves the copy. Pulling files back has different failure modes and a different blast radius; it belongs to a different tool. |
| `media sync` | Two-way sync means a verb that can write *back* toward the source, and so can destroy the original. That is the one outcome a backup utility must be structurally incapable of. |

## Summoning goes through basheur, not through garde

DOCTRINE Law 3: the dev team lives outside the project. A project that
summons its own agent has re-animated itself, and its de-animation stops
being countable -- basheur's output is a ratio, and work that never passes
through it is invisible to that ratio.

So `media triage` execs `basheur run --summon media-triage`. When that
classification is mechanized on basheur's side, this call gets cheaper with
no change here at all, which is the entire point of routing it.

If basheur is absent, that is a **GAP (exit 4)**, not a crash: the
obligation is still in scope, it just has nothing behind it right now.

Still unrouted, and honestly so: `backup`, `media dedup` and `media remote`
call an agent directly. Each needs a basheur contract before it can route
the same way. Recorded in GAPS.md rather than quietly left.

## The cost boundary

`--summon` prints its cost before spending, and that cost is **read from
a recorded measurement, never typed in**. With no measurement yet,
`--help` says `UNMEASURED -- the next summon is the measuring run`, and
that run records what it cost so the next caller sees a number.

A summon flag that prints "unmeasured" indefinitely asks the human to
authorise an unknown amount -- weaker than the argument `lib/verb.sh`
makes at length about why `-s`/`-S` are rejected. Whether this
obligation binds all 19 bashified verbs is an open proposal to
realisateur (`PENDING-CROSS-WRITE-realisateur-summon-cost.md` on `main`);
until it is decided there, this branch is the only copy carrying it, and
that divergence is deliberate.

## The manifest is the topology

The live manifest is **`~/.config/gardien/garde.json`** (`$XDG_CONFIG_HOME`
if set; override with `GARDE_MANIFEST`). It is deliberately *not* stored
beside the code: it is gitignored, so no branch, build or clone carries
it, and a verb build is a replaceable directory that an ordinary upgrade
repoints away from. Keeping it next to `garde` cost this estate the file
once, on 2026-08-05 -- see the header of `lib/manifest.sh`.

`garde.json` (gitignored; see `garde.json.example`) holds
`destinations` -- **plural** -- and `sets`, each set naming which
destinations hold it plus a `min_copies` floor. This replaces
`gardien.json`'s single `raid_root` as the organizing idea (FOCUS.md
2026-07-30). A dedicated RAID server later is one more entry under
`destinations`, not a schema change.

Two fields carry real weight:

- **`case_insensitive`** belongs to the *destination*, not the caller.
  The guard that would have saved `Siddhartha/Homily.pdf` is a property
  of the drive, not something anyone has to remember to ask for.
- **`min_copies`** makes single-copy exposure a *queryable state*
  instead of a fact rediscovered by reading a status document.

Policy keys on size and replaceability. It never keys on file extension:
"media" is a proxy for "large and immutable", and an extension is a
proxy for that proxy. The `class` field is descriptive only.

## Verification

```
./test/contract-test.sh ./bin/garde garde   # the shared verb contract
./test/contract-test.sh ./bin/fauche fauche # the same contract, fauche
./test/media-test.sh                        # the media engine, 27 assertions
./test/fauche-test.sh                       # fauche's verdicts, 33 assertions
```

`fauche-test.sh` never reads this machine's real config: every liveness
surface `fauche` probes is a knob, and the suite points all of them at a
fixture tree under `mktemp -d`. It holds the two verdicts that were wrong
in the field: a path it cannot look at is `BLIND`/exit 6 rather than
`KEEP` (gardien#10), and a repository a timer, a cron line, a PATH
symlink or an autostart entry reads out of is kept (gardien#11).

`media-test.sh` never touches a real mount or a real host: destinations
are `kind: local` pointed at `mktemp -d` trees, the same rule
`test_gardien.py` held on `main`. The copy/verify/collision logic under
test is the same code the ssh path runs; only the transport differs.
