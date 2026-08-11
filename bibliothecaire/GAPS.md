# GAPS -- what `range` cannot yet do

Recorded 2026-07-30 during the bashify pass. These are to be closed
later; they are written down now so the utility never pretends.

## Python that was never given a shell contract (6 files)

These do real work but are not reachable through the verb, because they
have no stated argv/output promise to wrap:

- `bin/file-maxim.py`
- `bin/find-open-copy.py`
- `bin/intake.py`
- `bin/quote-stream.py`
- `bin/validate-quotes.py`
- `test_intake.py`

## Standing gap: the cost baseline

No before-measurement exists for what the previous implementation cost
per call, so the saving from mechanising it is **unmeasured, not zero
and not assumed**. Closing this needs a real measurement, not an estimate.

---

# GAPS -- what `glane` and `accroche` cannot yet do

Recorded 2026-07-31, when `quatre-vingt-douze` folded into this library.

## `accroche sheets` is contracted and SUMMON-BACKED (no longer a gap)

`accroche.1` contracts `sheets`: render the hung surface to paper and count
the sheets that come out. Nothing here does it *yet*, so it exits **3** and
prints the summon it would have made, spending nothing. With `--summon` it
routes through `basheur run --summon print-sheet-count`, which performs the
render and leaves behind the mechanism that performs it without an agent next
time. `accroche list` reports it `AGENT` until that lands, `MECHANIZED` after.

**This entry used to say it exits 4, and that was wrong.** Recorded rather
than quietly corrected, because the mistake has a name: exit 4 means "no
contract for this exists at all", and `sheets` HAS one — it is on the page.
Filing it as 4 declared a promise to be an absence and foreclosed the way this
verb was meant to build itself from the inside.

The general rule, stated because this pass got it backwards: **a contracted
action with no mechanism is exit 3, not exit 4.** Exit 4 is for when there is
nothing to summon *toward*.

This one matters more than a missing convenience. The paper form has twice
been reported as working on the strength of the stylesheet existing, and
twice a real render found defects that were silent at exit 0 -- a print
`display: flex` fragmenting every density to one page per sheet, and a
`:last-of-type` rule losing on specificity so every print ended on a blank
sheet. **The sheet count is the witness; the stylesheet is not.** Until
`sheets` is wired, that witness is produced by hand or not at all.

## `accroche status` cannot tell you if the surface is stale

**Open, and wrong under both implementations tried.** Do not trust the
`hung` line.

- Comparing the surface's mtime to the harvest's reports STALE from any fresh
  checkout, because git writes every file at essentially the same instant in
  arbitrary order. It measures the checkout, not the work. (This is the
  version currently shipped.)
- Testing whether each page's *file stem* appears in the surface reports every
  page missing, because the surface references pages by title and source URL
  and never by stem. Tried, and reverted, in the same pass that introduced the
  first one.

The second was strictly worse: the first lies once after a clone, the second
lies permanently. It was backed out rather than patched a second time in one
pass, and the defect recorded here instead.

A correct check compares the surface against the manifest by the identifier
the surface actually carries. Until then, `hung` is the one line of `accroche
status` that is not a witness — which matters, because a false alarm on a loud
channel teaches the reader to ignore the word, and STALE has to still mean
something on the day the surface really is behind.

## `accroche sheets` still routes to an agent that no longer exists

Recorded 2026-08-06, found while repairing `fonde consign`, and **not fixed in
that pass**. The entry above says `sheets` "routes through `basheur run
--summon print-sheet-count`". `basheur` was retired on 2026-08-05 and is on no
PATH here, so that route now ends in exit 4 instead of a render, and
`accroche list` reports a contract state it cannot read. Unlike `consign-prose`
there is **no impl to carry**: `print-sheet-count` was never mechanized, so
this cannot be repaired by vendoring and needs a decision about where a render
comes from now. The sheet count is still the witness and it is still produced
by hand or not at all.

## The scanned page ninety-two does not exist here

`glane` implements the stated deterministic rule: 38 lines to the page after
boilerplate, page 92 = lines 3459-3496. The alternative -- the true page 92
of a scanned book, from page images -- is not implemented, and is not
silently substituted. It needs its own polite-fetch design against a
different archive.

This is an **open question for Zach, not a backlog item**: the two rules are
different artworks, and both can coexist. It travelled here unanswered from
the folded project and is not closed by the fold.

## `--json` is honoured by `list` alone

Both verbs parse `--json` and honour it only for `list`. Asked of any other
subcommand it exits 4 rather than being accepted and dropped. That is honest,
but it is still a gap: the flag is on the page for every subcommand's sake
and satisfied for one.

## Standing gap: the cost baseline

No before-measurement exists for what the folded project cost per call, so
the saving from mechanising it is **unmeasured, not zero and not assumed**.
Closing this needs a real measurement, not an estimate.

# GAPS -- what `trie` cannot yet do

Carried across from `secretaire`'s branch on 2026-08-02 when the verb moved
here, rather than re-derived. A gap is named at the call site and exits
nonzero; it is never an exit-0 no-op.

## The inventory is blank, so the verb is BLIND in production

`ACCOUNTS.md` carries one address and no `stakes` value, so a real run exits 6
today. That is the correct answer -- the ranking column is the input, and it
has not been filled -- but it means the ordering path is exercised only by
`test/trie-test.sh` fixtures until a human fills the table. Nothing here can
close this: filling it is the human's half of the contract.

## Per-account rules are not held anywhere

"Archive anything from X" is buildable with no credential and nothing builds
it. It is the nearest real gap, and it would be a second verb, not a
subcommand of this one: holding a rule is not ordering a list.

## Refused, not missing

"Decide what deserves an answer" is **not** a gap. It is a refusal, recorded
as one in CONTRACT.md. A refusal filed as a gap becomes a backlog item, which
is how a boundary quietly stops being one.

## No cost baseline

No before-measurement exists for what this cost per call as `secretaire`'s
Python (`triage.py`), so the saving from the rewrite is **unmeasured -- not
zero, and not assumed**. Closing this needs a measurement, not an estimate.

# GAPS -- what `fonde` cannot yet do

Recorded 2026-08-06, when `consign` stopped routing through `basheur`.

## `lib/consign-prose.sh` is a SECOND COPY, and second copies drift

`basheur` still holds `impl/consign-prose` at `hf7y/basheur` on GitHub; this
branch now carries a copy of it. That is deliberate -- the agent is retired,
its clone is gone from mandark, and a verb that needs a tree nobody guarantees
stops working the day that tree is cleared. But it is two copies of one
mechanism, and nothing here notices if they diverge.

The copy names its origin blob (`2d02c1c...`) in its own header, so the drift
is *checkable*: `gh api repos/hf7y/basheur/contents/impl/consign-prose --jq
.sha` against that string. Nothing runs that check. **If a contract store
returns to PATH** -- basheur revived, or a successor -- the right move is to
route to it again and delete this copy, not to keep both.

## The deposit misfiles when run from a git worktree

Carried unchanged from the mechanism's own record (bibliothecaire
`.scheduler/QUESTIONS.md`, 2026-08-01). The destination is derived from the
path relative to `git rev-parse --show-toplevel`, which in a linked worktree
is the worktree, so the same document deposits under a different name than it
would from the primary checkout. Not repaired here: it is the deposit's
contract, and changing where a note lands is a contract change.

## Reaped `.scheduler/` prose lands where Obsidian cannot see it

Also carried: Obsidian does not index dot-directories, so every `.scheduler`
document deposited so far is preserved byte-perfect and invisible to the
linking that is the stated reason for a vault. `fauche` skips `.scheduler/*`
when it counts unconsigned prose, so nothing forces the issue; the three
options and why none was taken in passing are in `.scheduler/QUESTIONS.md`.
