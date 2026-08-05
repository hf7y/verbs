# GAPS -- what `garde` SHOULD do but cannot yet

Recorded 2026-07-30 during the bashify pass; revised the same day when
`media` landed. Everything here is **SHOULD DO**: in scope for garde's
role, not built yet, legitimately summon-able, and meant to DRAIN.

Things garde will *never* do are not gaps and are not listed here -- see
the "What garde WILL NOT do" section of `CONTRACT.md` (exit 7). Keeping
those out of this file is what lets this list stay a signal.

## Python that was never given a shell contract (2 files)

These do real work but are not reachable through the verb, because they
have no stated argv/output promise to wrap:

- `gardien.py` -- the snapshot rotator itself. This is the big one: the
  actual point of the repo has no verb surface, so `garde` currently
  wraps the scaffolding around gardien rather than gardien.
- `test_gardien.py`

Both live on `main`, not on this branch.

## Remote / offsite storage

In scope for a verb whose role is guarding the estate's data, and
deliberately unbuilt until needed (Zach, 2026-07-30). The manifest's
`destinations` map already accommodates it without a schema change -- a
new entry with a different `kind`.

**It is no longer summon-gated** (Zach, 2026-08-02): designing it is a
one-shot, so `media remote` reports GAP and the question is written out
under "Design question 1" below rather than re-asked of a model per call.

## Second local destination

Every set currently sits at **one copy** and `min_copies: 2` is violated
across the board. This is not a gap in the code -- `media audit` reports
it correctly and loudly -- it is a gap in the hardware. Pegasus is parked
indefinitely (FOCUS.md 2026-07-30), so closing this needs a decision
about a different second destination, not a build.

## One obligation that still summons directly (Law 3) — was three

**Revised 2026-08-02 on Zach's ruling: "agree to remove one-shots, or
deprecate."** Two of the three were never contract-shaped, and are now
`verb_gap` (exit 4) with no summon path. Their design questions moved into
this file, below, which is where a question asked *once* belongs.

`media triage` and `coverage` route through `basheur run`. What is left:

| call site | state |
|---|---|
| `media dedup` | **still summons.** Genuinely recurring: "are these two trees duplicates" is asked repeatedly with a checkable output shape. Needs a `media-dedup` contract, structurally close to the existing `media-triage` (positional paths → classified report). |
| `media remote` | **de-summoned** 2026-08-02 → `verb_gap`. Design question below. |
| `backup` | **de-summoned** 2026-08-02 → `verb_gap`. Design question below. |

**Why a one-shot must not be a contract.** basheur's model is a contract
invoked repeatedly, with a `verify:` checking the output shape each time.
"Propose what a `kind: s3` entry would need" has no repeat semantics: once
answered, the gap should be *built*, not re-asked. Freezing a one-off design
request into a recurring-service shape would have made the ratio basheur
reports meaningless — work that never converges is not work being mechanized.

Law 3 closes when `media-dedup` is authored and `media dedup` routes through
it; at that point `lib/verb.sh` can be re-synced to the union skeleton and
gardien joins the other six.

### Design question 1 — `media remote`, offsite destinations

Stated here rather than asked of a model per invocation. garde has no offsite
destination support built. The manifest already models `destinations` as a
plural map keyed by `kind`, so no schema change is needed. **To answer:** what
would a `kind: s3` or `kind: rclone` entry have to carry (credentials
reference, bucket/remote, path prefix, cost ceiling?), and what changes in
`lib/media.sh` to copy *and hash-verify* against it — remote hashing is the
hard half, since the current verify shells out to `md5sum` on the far side.

### Design question 2 — `backup`, an argv contract for `gardien.py`

`gardien.py` (on `main`, not this branch) is a config-driven rsync + hardlink
snapshot rotator with no stated argv/output contract, so the verb cannot wrap
it. **To answer:** the minimal argv + exit-code contract that would let a bash
verb drive it while keeping its existing behaviour. Until then `garde backup`
reports GAP, which is honest — the rotation is real, the *verb surface* is not.

## Standing gap: the cost baseline

No before-measurement exists for what the previous implementation cost
per call, so the saving from mechanising it is **unmeasured, not zero
and not assumed**. Closing this needs a real measurement, not an estimate.

The *forward* half of this is now closed by construction:
`VERB_SUMMON_COST` is read from a recorded measurement and the first
summon records what it cost. The backward half -- what the old way cost
-- remains open.

---

## `fauche` -- what the reap verb cannot yet decide (2026-08-01)

`fauche` decides whether a repository is **recoverable** and emits a
removal script for a human to run. It never deletes. These are the things
it does not yet know, written down now so it never pretends:

- ~~It has no man page yet.~~ **CLOSED the same night.** `man/fauche.1` was
  written by `bashify page --summon` and scores **9 of 9 rows**, `bashify
  check` exit 0. Two things had to be undone first: the summon was refused
  four times by basheur's residue lock while another session ran
  back-to-back `verb-page` summons, and then refused at exit 7 because
  `fauche` had already been installed onto PATH -- `verb-page` writes the
  page for a verb that does not exist yet. It was retired, paged, and
  reinstalled in that order.

- **An AGENT-backed contract can report a refusal as success.** The
  refused attempt above printed "REFUSED -- exit 7" as prose on *stdout*
  and exited 0, so basheur scored it as a kept promise and the refusal
  text was very nearly committed as a man page. Caught by `bashify check`
  (exit 6, BLIND), not by the contract store. This is not a `fauche` gap;
  it is recorded here because this is where it was found.

- **`.scheduler/` prose is excluded from the consigned-prose check, and
  that exclusion is not a solution.** `scheduler/focus/<project>.md` and
  `questions/<project>.md` are **symlinks** into a project's own
  `.scheduler/`, so removing a repo leaves two dangling links behind it --
  which has already happened on both reaps run so far. `fauche` neither
  sweeps them nor refuses because of them. It should do one or the other.

- **"Pushed to origin" is not "recoverable".** The check compares each
  local branch against its `origin/` ref on this host. It does not verify
  the remote is reachable, that the push landed, or that anyone else can
  clone it. A remote that is itself a directory on this same disk would
  pass. Closing this means contacting the remote, which is the one thing
  the check deliberately does not do yet.

- **It cannot see a repository that is not a git repository.** Those are
  reported KEEP with the reason, which is correct, but it means `fauche`
  has nothing to say about the material most at risk: a directory that was
  never under version control at all.

- **Untracked-but-ignored files are invisible.** `git status --porcelain`
  honours `.gitignore`, deliberately, so build debris does not block a
  removal. A secret or a database parked in an ignored path is therefore
  removable as far as this check is concerned.
