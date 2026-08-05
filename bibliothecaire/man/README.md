# `man/` — the verbs' contracts, written before the verbs

Each page here is a **promise**, not documentation of a finished tool. The
utility is judged against its page; the page is not updated to match
whatever the utility turned out to do. Changing a promise is a separate,
gated act — `bashify amend`, four gates — and is never done by editing a
page quietly.

Written 2026-07-31 through `bashify page … --summon`, whose own escalation
(`basheur run --summon verb-page`) was built the same session because the
call site exited 4 and named it. Not hand-written, and not written around
the front door.

## They do not pass yet, and the reason is structural

| page | `bashify check` | scored against |
| --- | --- | --- |
| `fonde.1` | 5 of 9 | `bin/validate-quotes.py` |
| `verse.1` | 6 of 9 | `bin/intake.py` |
| `cueille.1` | 6 of 9 | `bin/find-open-copy.py` |

Every failing row fails for one reason: **the verb does not exist yet.**
NAME fails on the name mismatch (`page names 'fonde', command under test is
'validate-quotes.py'`); SURFACE fails because the legacy program's `--help`
offers none of the verb's flags; EXAMPLES fails because the doctests invoke
a binary that is not on PATH.

That is the page test working as designed and the doctrine straining: this
ecosystem says the page comes first, and the test cannot score a page whose
subject does not exist. **6 of 9 is the ceiling at page-writing time.** The
open question — whether `verb-page` should score those three rows against
`<verb>` instead of `<command>`, or state the ceiling in its own contract —
is recorded in `basheur/residue/verb-page.sh` across four runs.

**One failure is NOT structural and is a real finding:** `EXIT: codes
returned but not documented: 1`. The Python programs behind these verbs
signal every failure with `sys.exit(1)`, so "the ledger is unreadable" and
"the schema is violated" are indistinguishable to a caller. The pages
document the shared vocabulary (2 usage, 4 GAP, 5 BROKEN, 6 BLIND,
7 REFUSED). The programs must move to it; the pages do not move back.
