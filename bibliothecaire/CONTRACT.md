# CONTRACT — `range`

`range` — shelve, catalogue and retrieve the ecosystem's texts.

Revised 2026-07-30 from the `bashified` branch's contract of the same date. **This revision contradicts that document's central claim.** The prior contract listed two subcommands — `install-intake-share` and `install` — and its `GAPS.md` filed the five Python programs in `bin/` as "Python that was never given a shell contract." Read as an inventory of *shell scripts* that is accurate. Read as an account of what this project has mechanized it is badly wrong: `bin/validate-quotes.py` is a loud, negative-tested, six-gate schema and citation checker; `bin/intake.py` runs a live SMB-to-OCR-to-reap pipeline on a 15-minute timer and deletes files off Zach's disk; `bin/find-open-copy.py` is a no-model open-access prober. All of that is `bash` by the only test the HOW column applies — it runs free, unattended, with no model in the loop — regardless of the language it is written in.

The correction runs the other way too, and it is the sharper half. `bin/quote-stream.py` calls the model on every default invocation. It is therefore a **metered** obligation, and `bin/range` declares `VERB_CAN_SUMMON=0`, which means the verb as shipped has no flag with which to authorise it. The single most load-bearing finding of this revision is that this project's mechanized surface is large, its verb surface is two subcommands wide, and the one thing it does that costs money is on the wrong side of both.

## How to read the HOW column

| HOW | meaning | exit when unmet | cost |
|---|---|---|---|
| **bash** | mechanized. Runs free, unattended, no model in the loop. | 5 if it ran and broke | free |
| **summon** | SHOULD DO — in scope, not yet mechanized. | 4 (GAP), naming its own escalation | metered, printed before spending |
| **refused** | WON'T DO — out of scope on principle. | 7 (REFUSED) | n/a, no summon exists |

`--summon` is available on 4 and forbidden on 7. A gap names its escalation; a refusal offers none, because having no escalation path is what refusing on principle means.

## The obligations

### Publish — the consumer contract

Consumers read the published file. That is the whole interface, and it is the source of most of what follows.

| obligation | HOW | backed by |
|---|---|---|
| enforce the published schema — id, text, author, work, year, locator, theme, status — and fail loud on violation | bash | `bin/validate-quotes.py`; the project's declared test command in `schedule/bibliothecaire.conf` (`BATCH_TEST_CMD="bin/validate-quotes.py --sources"`) |
| keep quote ids stable, because briefs cite by id | bash | uniqueness enforced by `bin/validate-quotes.py`; "don't renumber existing entries" stated in README.md's consumer contract |
| publish only what is publishable — `verified` or `verified-secondary`, never `seed-unverified` | bash | the status filter in `bin/validate-quotes.py --export` |
| regenerate `quotes/quotes.txt` rather than let it be hand-edited | bash | `bin/validate-quotes.py --export`; "never hand-edit" in README.md |
| hold the exported line format steady across schema widenings | bash | README.md records that the `text — author, work` line did not change when `verified-secondary` was added 2026-07-27; provenance stayed in the JSON |
| reject a `verified-secondary` entry whose `quoted_in` carries no page or section | bash | `bin/validate-quotes.py`, negative-tested per `.scheduler/FOCUS.md`'s milestone checklist ("`quoted_in` with no page/section" fails) |
| report verified-quotes-per-theme against the ≥2 bar without failing | bash | `bin/validate-quotes.py --coverage` |
| gate on that bar when asked | bash | `bin/validate-quotes.py --require-coverage` |
| push a selected quote to a watching consumer without the model ever authoring one | summon | `bin/quote-stream.py` — built, tested on both negative paths, and **metered**: default selection is a one-shot the model call. Not reachable through `range`, and `bin/range` sets `VERB_CAN_SUMMON=0`, so the verb cannot authorise it |
| offer the same stream free when no model is wanted | bash | `bin/quote-stream.py --no-agent` (least-recently-streamed) |

### Catalogue — briefs, maxims, and keeping the two apart

| obligation | HOW | backed by |
|---|---|---|
| require all four brief sections — Claim, Sources, Maps onto, Where it breaks | bash | `bin/validate-quotes.py --require-briefs`; negative-tested 2026-07-27 against missing section, empty section and missing brief |
| reject a brief citing a quote id that does not exist or is not publishable | bash | same gate, same negative test |
| report brief coverage without failing, so the gate can stay out of the default run | bash | `bin/validate-quotes.py --briefs` |
| never let an in-house aphorism sit in the quotes namespace | refused | `bin/file-maxim.py --check` fails on an id collision or byte-identical text; separate file, schema, id namespace and export by construction |
| refuse a maxim with no occasion | bash | `bin/file-maxim.py --add` rejects it; "a maxim with no occasion is a slogan" in that file's own docstring |
| resolve every `related_quotes` / `related_briefs` reference a maxim carries | bash | `bin/file-maxim.py --check` |
| ship a brief with no named disanalogy | refused | `.scheduler/nightly-batch.md` and `.scheduler/FOCUS.md`: "a brief with no named disanalogy is a flattering story about the ecosystem, and those are worse than no brief" — say so in QUESTIONS.md instead of softening it |
| decide whether a concept's analogy holds and where it breaks | summon | judgment. No file can do this; the milestone that produced fourteen briefs was agent work, and the gate above only checks that the section exists |

### Retrieve — sourcing, and the honesty policy as control flow

| obligation | HOW | backed by |
|---|---|---|
| probe the open-access finding aids for a work without spending a model | bash | `bin/find-open-copy.py` — OpenAlex, HAL, Unpaywall, archive.org metadata; "No AI, no judgment" in its docstring |
| never conflate a failed probe with "no open copy" | bash | `bin/find-open-copy.py` exits 1 on probe failure and 0 on found-or-not-found, stated in its docstring as the reason |
| cap fetches per work so one unreachable text cannot spend the night | bash | 20-fetch cap per work in `bin/find-open-copy.py` |
| hold the research posture — sequential, 2s apart, honest UA, bounded, open sources | summon | stated in README.md, the project charter and the scheduler `BATCH_PROMPT`, and enforced inside `bin/find-open-copy.py` for its own probes only. Nothing checks a run's total fetch count against the declared budget; the ≤60 milestone allowance and its return to ≤20 are prose |
| widen those limits during an unattended run | refused | "Never widen these unattended" — README.md and the project charter, stated identically in both |
| invent, "improve," or attribute a quote from memory | refused | README.md's honesty policy; the seed set is marked `seed-unverified` for exactly this reason and is never published |
| treat a blog, content farm, LLM output or quote aggregator as a source at any tier | refused | README.md: "not sources at any tier … If the only route to a famous line is an aggregator, the line does not ship" |
| work around a bot wall, unwrap DRM, fake a session, replay a human's cookies or script a login page | refused | README.md's source-access amendment, 2026-07-27 |
| retain a licensed copy after the quote is taken | refused | README.md: "The rule is not 'never download'; it is **never retain**" |
| write a brief about a concept whose primary text is gated, from memory or summary | refused | `.scheduler/nightly-batch.md`, Zach's standing call 2026-07-27: skip it, do not reach for a secondary source or recollection |
| check a quote's wording against the primary text and record `verified_via` and a locator | summon | judgment, per run. The validator checks that the fields are *present* and well-formed; only a reader can check that the wording is right |
| reach licensed material through an authenticated front door | summon | undetermined — permission exists (Tulane/OpenAthens terms support machine-assisted research); the plumbing does not. A human fetches and drops into `sources/` today. `.scheduler/drafts/tulane-tdm-request.md` was sent; no reply as of the last recorded run |
| own the deletion of licensed material rather than leaving it to a habit | summon | undetermined — README.md names `gardien` as likely owner (backup-exclude + timed reap), and `.scheduler/FOCUS.md` records the handoff as **parked deliberately** by Zach, "not a dropped obligation, it's a scheduled-later one." Today `sources/` is gitignored but not backup-excluded |
| reconcile `sources/` on disk against `sources/LEDGER.md` | bash | `bin/validate-quotes.py --sources` (reports) and `--require-sources` (gates); made clone-aware 2026-07-28 via the untracked `sources/.source-cache` marker, after it reported nine held sources as gone from a clone with an empty gitignored `sources/` |
| catch a source file that is empty or partial rather than counting it as held | bash | `--require-sources`; it currently fails on three real files — a 0-byte stigmergy PDF, a 114-byte Beer "PDF", and an `anjF8-6H.pdf.part` |
| repair those three | summon | `.scheduler/FOCUS.md` carries them as open; "none is fixed yet" |

### Shelve — the scanner intake, which is live machinery that deletes files

| obligation | HOW | backed by |
|---|---|---|
| drain the write-only SMB drop box on a timer | bash | `bin/intake.py --accept` on `systemd/bibliothecaire-intake.timer`, 15 minutes |
| identify items by content, not by filename | bash | sha256 identity in `bin/intake.py`; README.md's reason — "a Mac writes `Untitled 3.pdf` more than once" |
| never snapshot an image-only scan | bash | the `needs-ocr` state in `bin/intake.py`'s lifecycle; an empty snapshot would still satisfy the reaper's gate, i.e. license deleting the only copy |
| never snapshot without a pinned quote found verbatim in the extracted text | bash | `bin/intake.py --snapshot`; README.md calls it "the honesty policy expressed as control flow" |
| never delete an original without proof gardien holds it | bash | `bin/intake.py --reap` / `--check-backup-proof`; proof is gardien's own `.gardien-snapshot-complete` marker, written only after a successful rsync |
| read an unanswerable backup probe as "no" | bash | `bin/intake.py` — unreachable host, stale snapshot, or a file outside the backed-up path each exit nonzero and delete nothing. Scans accumulate, which README.md names as the correct failure direction |
| re-probe the live pipeline and say what it saw, per check | bash | `bin/intake.py --healthcheck` prints one `I looked and I saw` / `I looked and I did NOT see` / `I could not look` line per check |
| report `I could not look` as anything but red | refused | the project charter rule 2: "UNKNOWN is red. Silencing a privileged probe turns 'denied' into 'clean'" — this is the BLIND clause, already enforced |
| report this pipeline's state from a document, including its own attestation log | refused | the project charter rule 1. The attestation records when someone last looked; "if you did not run the command this session, you do not know" |
| notice when the health timer itself has stopped | bash | `bin/intake.py --healthcheck` goes red if the newest attestation is over 26h old |
| carry the delegated root-only check with its age and the `not re-probed here` qualifier | bash | `bin/intake.py --healthcheck` unprivileged path; `bibliothecaire-intake-health.timer` runs it as root daily at 10:00 |
| detect drift between the installed units and this repo | bash | unit-drift check inside `--healthcheck` |
| distinguish a real printed page from an EPUB estimate, three times over | bash | the `form` field (`text` / `image` / `text-estimated`) in `published/manifest.json`, the `-estimated` filename suffix, and the file's own header stating the parameters |
| install and retire its own machine footprint | bash | `smb/install-intake-share.sh` and `systemd/install.sh`, each with `--uninstall`; reachable through the verb as `range install-intake-share` and `range install` — the only two subcommands that exist |
| bound OCR so it cannot take the host down | summon | `.scheduler/FOCUS.md`, 2026-07-28: a 03:00 OCR batch hit global OOM on mandark, killing plasmashell and two an assistant processes. Three asks filed — cap `ocrmypdf --jobs`, put `MemoryMax` on the unit, and dispatch through scheduler rather than self-dispatching. None recorded as done. `ocrmypdf` **is** installed on this host (`command -v ocrmypdf`), so README.md's "not yet installed" note is stale |

### The verb itself

| obligation | HOW | backed by |
|---|---|---|
| expose this project's real tooling through `range` | summon | `GAPS.md` on the `bashified` branch lists all five programs in `bin/` as unreachable. `bin/range` wraps only the two installers. This is the project's largest gap and it is a gap in the *front door*, not in the mechanization |
| declare a summon on the one subcommand that spends | summon | `bin/range` sets `VERB_CAN_SUMMON=0`; `bin/quote-stream.py` calls the model. Wiring stream selection into the verb without also setting the flag would produce a utility whose `--help` says it cannot cost money while it does |
| speak the exit vocabulary — 4 GAP, 5 BROKEN, 6 BLIND, 7 REFUSED | summon | `lib/verb.sh` on the `bashified` branch defines the whole vocabulary and `bin/range` uses `verb_gap`. Below it, every Python program signals failure with `sys.exit(1)` (`bin/intake.py:74`, `bin/validate-quotes.py:129`, `bin/quote-stream.py:48,200`, `bin/file-maxim.py:46`), so "the ledger is unreadable" (BLIND) and "the schema is violated" (BROKEN) are indistinguishable to a caller |
| be invocable as a verb at all | summon | `command -v range` returns nothing. Nothing from this project is on `PATH`; wiring was left past the bashify pass |
| keep the mechanized promises inside a repo | summon | `~/.local/bin/bibliothecaire-nightly-batch-loop.sh` is a 420-byte executable on the shared host, owned by this project, tracked in no repo. It would vanish with the home directory |
| know what mechanizing this cost, or saved | summon | undetermined — `GAPS.md`'s standing gap. No before-measurement of the previous implementation exists, so the saving is unmeasured. Closing it needs a measurement, not an estimate |

### Archive — the receiving wing

| obligation | HOW | backed by |
|---|---|---|
| receive another project's retired prose and file it under `archive/<project>/<date>-<topic>.md` | summon | `archive/INDEX.md` and `archive/README.md` exist and two scheduler drops are filed; the writing is a per-drop judgment and `intake/` is specified as "a door, not a shelf" — anything still sitting there after a run or two is a finding, and nothing checks that |
| export an ingest command that other projects call | refused | `.scheduler/FOCUS.md`, 2026-07-28, answering scheduler's delegated question: "files committed IN, no ingest command exported OUT … an exported verb would make this repo a runtime dependency of all 18 registered projects, which is that rule's own failure mode at 18× scale" |
| quote anything in `archive/` into `quotes/quotes.json`, or cite it from a brief | refused | `archive/README.md`: operational records, no author, no locator, not under the honesty policy |
| summarize or reach into another project's prose | refused | the wing is "a **receiving** archive only, never an active summarizer reaching into" other repos |
| write into a consumer's repo rather than flagging the handoff | refused | the project charter hard rule; crt's the project's own agent file-gated FOCUS.md line is carried as a human-only step rather than written |
| fork crt's scan, grade or STT code for the book-catalog wing | refused | README.md and the project charter: wing (b) is greenfield and "shares at most `books.db`'s data" |
| build the book-catalog wing | summon | undetermined — a LATER milestone by the founding drop, with no obligations stated beyond the greenfield constraint above. What would settle it is a milestone declaration naming what the wing owes crt |

### Housekeeping the repo cannot currently answer

| obligation | HOW | backed by |
|---|---|---|
| exit a run with a clean tree | summon | the working tree is dirty right now — `bin/validate-quotes.py`, `quotes/quotes.json` and `quotes/quotes.txt` modified and uncommitted. Per BUILD-DISCIPLINE a dirty tree at exit is a failed run |
| know who wrote a commit | summon | undetermined — the last two commits before this pass are `scheduler sweep: adopted dirty …` backstops with author unknown, twice in one night. `.scheduler/FOCUS.md` flags it and nothing establishes it |
| cite a text with enough detail that a human can pull it manually | summon | Zach, `.scheduler/QUESTIONS.md`: "I'd need the title and year and author inline to pull manually. Let's wire up a citation mechanism that ensures texts are always referenced properly." The schema carries the fields; the mechanism he asked for is not identified |
| park a stale download rather than let it block later work | summon | Zach, `.scheduler/QUESTIONS.md`: "we need a system for parking stale downloads. They shouldn't hold up later work necessarily once they've been flagged and Zach has touched the flag." No parking state exists in `--require-sources`, which fails on all three bad files with no way to acknowledge one |
| dispatch heavy jobs from an always-on host under usage guardrails | summon | Zach, `.scheduler/QUESTIONS.md`, on the OCR shape: heavy jobs "need to run from always on dexter, with usage guardrails … dispatched as non-ai workflow, something scheduler and senechal can own." Also asks for the trigger that would warrant a new project, "and find a way to make it loud." Neither exists |
| duplicate the library to make it reachable | refused | Zach, `.scheduler/QUESTIONS.md`, on the rsync proposal: "duplicating a library like that feels sketchy pending gardien's ability to reap. Try symlinking." |

### Triage — the morning account order (verb: `trie`)

Moved here from `secretaire` on 2026-08-02, obligations carried across intact rather than re-derived. `secretaire` is a product, not a utility, so its `bashified` branch is retired to the tag `parked/bashified`; `trie` is the half worth keeping. It was called `range` there — the name changed because `range` is already this library's verb, and one name cannot mean two things on one `PATH`. The **summary** did not change; see README.md for why that distinction matters.

`trie` declares `VERB_CAN_SUMMON=0`. It cannot spend money and carries no `--summon` flag, so `--help` alone answers what a run can cost. That is not an oversight: its refusals are about **credentials and sending**, and a spending flag able to reach them would defeat the refusal and the three places that state it at once.

| obligation | HOW | backed by |
|---|---|---|
| Say which account to open first, in what order, and why | bash | `bin/trie`, ranked on the `stakes` column of `ACCOUNTS.md` |
| Break ties so two runs over an unchanged inventory agree | bash | secondary sort on address; asserted in `test/trie-test.sh` |
| Emit that order in a form another surface can render | bash | `--markdown`, `--json` |
| Name, per account, what currently goes wrong there | bash | the `pain` column is carried onto each line |
| Surface accounts that cannot be ranked, rather than dropping them | bash | unranked rows print as `?.`; dropping them would report a smaller inventory than the one on disk |
| Refuse to invent an order it cannot see | bash | exit 6 with the row count, never an empty list |
| Decide, per message, whether it deserves an answer | refused | needs message-level facts, which needs credentials. No flag lifts it |
| Read, send, or store mail | refused | past the autonomy bar this verb was written under. No credential is held anywhere in this tree |

## What is deliberately not refused

Four things that look like refusals and are not, listed so that their absence from the refused rows does not read as an oversight:

- **The parked directions in `.scheduler/FOCUS.md`** — the gardien backup-exclusion for `sources/` is parked with a reason, but Zach's own words make it a schedule, not a boundary: "this is not a dropped obligation, it's a scheduled-later one." Filed `summon`.
- **Wing (b), the crt book-catalog.** Parked as a later milestone. Only the *never forks crt's code* half is a refusal; the wing itself is a milestone nobody has declared.
- **The head-librarian-with-subagents direction** Zach sketches in `.scheduler/QUESTIONS.md` ("bibliothecaire is evolving into the head librarian of a research institution with many subagents. That's proper."). It is an approved direction with no stated obligations yet, and inventing them here would put promises in his mouth.
- **The two `.scheduler/QUESTIONS.md` blocks still awaiting a `> ` answer.** Unanswered questions are a fact about this project, not blanks to fill.

## Universal clauses

Every subcommand of `range`, without exception:

- exits **0 only if the promise was kept**. Never an exit-0 no-op.
- exits **4 (GAP)** when the obligation is in scope and not yet mechanized, and **names its own escalation**.
- exits **5 (BROKEN)** when it ran and broke.
- exits **6 (BLIND)** when it cannot read its domain. "I cannot see" is never reported as "nothing to report" — and in this project that clause has a name and a mechanism already: `I could not look` is red, never clean.
- exits **7 (REFUSED)** for anything in the refused rows above. There is no `--summon` for a 7.
- **cannot spend money** unless it declares `--summon`, which has **no short form and is never implied**.

## The closing finding

Thirty-one `bash` rows, twenty-one `summon` rows, sixteen `refused` rows — counted by script, not by hand. The shape they make is the point:

1. **The prior contract's headline was wrong in both directions.** This project mechanized far more than "two installers" — and one of the things it mechanized, quote-stream selection, is metered and was filed as if it were free. Language is not the test; a model in the loop is.
2. **The mechanization is deep and the front door is two subcommands wide.** Every gap in the "verb itself" section is a wiring gap, not a building gap. That is the cheapest set of summons on this page and the one that unlocks the rest.
3. **The refusals are this project's densest asset.** Sixteen of them, nearly all quoted rather than reasoned out, from README.md's honesty policy, the project charter's hard rules, and Zach's own `> ` answers. A project this clear about what it will not do has already done the expensive half of writing a contract.
4. **The exit vocabulary is claimed above and absent below.** `lib/verb.sh` defines 4/5/6/7; five Python programs speak only exit 1. The one exception is instructive — `bin/intake.py --healthcheck` has the BLIND clause fully built, in words, per check. It knows how. It just does not say so in a number.
