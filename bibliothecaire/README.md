# bibliothecaire, bashified

*the library, as verbs*

This is the **bashified** branch of `bibliothecaire`. It contains plain shell
utilities and nothing else.

```
bin/fonde        admit material into the library only on a citation that checks out
bin/verse        carry a scanned book from the drop share to a citable excerpt
bin/cueille      report where one work is readable without payment
bin/range        shelve, catalogue and retrieve the ecosystem's texts
bin/glane        harvest page ninety-two from many public-domain texts
bin/accroche     hang the harvested pages side by side for arrangement by hand
bin/trie         put the morning's accounts in the order a missed message costs most

man/*.1        the contract each utility is judged against
ACCOUNTS.md    the account inventory -- `trie`'s only input, filled by hand
CONTRACT.md    the promise the library as a whole must keep
GAPS.md        what the utilities cannot do yet
test/          the contract test, runnable against any implementation
```

Each `man` page was written **before** its utility worked. The page is the
promise; the utility is an attempt to satisfy it. When the two disagree, the
utility is what changes.

## `glane` and `accroche` came from a project that no longer exists

They were `quatre-vingt-douze`, a found-text art project: harvest page 92
from many public-domain books, lay the pages out, arrange them by hand into
an emerging work. It folded into this library on 2026-07-31, which unwound a
2026-07-26 rename that had split it out of the original library drop.

**The constraint that travelled with it, carried rather than paraphrased:**

> user judgment IS the product, and the merge must not quietly automate the
> arranging.

That is why hanging the pages is a separate verb from harvesting them, and
why `accroche` refuses to sort, group, rank or reorder with exit 2 rather
than exit 4 -- exit 4 would file the refusal as tooling that does not exist
yet, and so promise it later. There is nothing to promise.

`cueille` and `glane` are siblings and not duplicates, which is worth stating
because they look alike: `cueille` asks the finding aids whether one *named*
work is reachable and fetches no full text; `glane` names no work at all,
draws a bounded run of texts from one archive, and keeps one page from each.

## `trie` came from `secretaire`, for the same reason

Moved here 2026-08-02. `secretaire` is a **product**, not a utility: its
milestone names an event outside the computer, and a verb is a utility's
finished form (`realisateur/WAITING-ROOM.md`). Its `bashified` branch is
retired to the tag `parked/bashified` in that repository. This verb is the
half worth keeping, so it moved rather than died.

It was called `range` there. Two things about the name, because the record
would otherwise read as a reversal:

- `trie` was retired *into* `range` on 2026-07-31, but the objection was to
  the **summary** -- *"sort the mail **and** decide what deserves an answer"*
  -- whose "and" bound a table sort to something needing eight mailboxes.
  **That summary does not come back.** The one-clause summary above is
  `range`'s, and it stands.
- Only the name returns, because `range` is already this library's own verb
  and one name cannot mean two things on one `PATH`. That collision was live:
  both projects declared `range`, `secretaire`'s won on `PATH`, and this
  library's was unreachable by name until now.

The refusal travelled intact: `trie` holds no credential, opens no mailbox and
reaches no network. Its whole domain is `ACCOUNTS.md`, a tracked file. Deciding
*per message* whether something deserves an answer is refused in CONTRACT.md,
not filed as a gap -- a refusal filed as a gap becomes a backlog item, which is
how a boundary quietly stops being one.

## Why this is a branch and not a repository

The purge here is **total**. Everything these trees used to carry beyond the
tools themselves is gone from these files. It is not lost: it is on the
`main` branch of this same repository, one `git log main` away.

**That is the only reason a total purge is safe.** Extracting this branch
into a standalone repository would destroy the archive that justifies the
purge, and leave defensive code standing with no visible cause -- which is
how hard-won guards get deleted by the next reader. Do not do it.

## Verify

```
./test/contract-test.sh bin/glane     glane
./test/contract-test.sh bin/accroche  accroche
./test/contract-test.sh bin/trie      trie
./test/trie-test.sh                   # the trie man page, executed
./test/reaped-test.sh                 # what "bibliothecaire has been reaped" means
python3 -m pytest test/test_page92.py # the pagination rule
```
