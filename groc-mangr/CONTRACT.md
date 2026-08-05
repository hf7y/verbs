# CONTRACT -- `mange`

> keep the larder: groceries in, fridge accounted for

This file is the deliverable. It states what `mange` is obliged to do
**because of its role in the ecosystem**, not what happens to be built.
Implementation is downstream of this document; when the two disagree,
this document is right and the code is behind.

Revised 2026-07-30. It replaces the `bashified`-branch contract of the
same date, whose subcommand table was empty and whose single row read
"*no shell tooling existed in this project*". That reading was true about
shell scripts and misleading about mechanization: `src/server.js`,
`src/store.js` and the `node --test` suite run free and unattended with
no model in the loop, which is exactly what `bash` means below. What
groc-mangr lacks is a **verb surface**, not mechanization. This revision
separates the two.

## How to read the HOW column

Every obligation is kept one of three ways, and the column says which.

| HOW | meaning | exit when unmet | cost |
|---|---|---|---|
| **bash** | mechanized. Runs free, unattended, no model in the loop. | 5 if it ran and broke | free |
| **summon** | **SHOULD DO** -- in scope, not yet mechanized. An agent does it by hand *now*, and the request is appended to a mechanization queue so the next build wires it into bash. | 4 (GAP), naming its own escalation | metered, printed before spending |
| **refused** | **WON'T DO** -- out of scope on principle. Will never be built. | 7 (REFUSED) | n/a, no summon exists |

The load-bearing rule: **`--summon` is available on 4 and forbidden on
7.** A gap names its escalation; a refusal offers none, because having
no escalation path is what refusing on principle *means*.

## The obligations

### Knowing the larder -- the core role

| obligation | HOW | backed by |
|---|---|---|
| Hold what is actually in the fridge/pantry, and what state each item is in (`ok`/`low`/`out`) | bash | `load()`/`save()` in `src/store.js`; `GET /api/items` (`src/server.js`). Served over HTTP only -- there is no `mange` CLI |
| Never report an unreadable larder as an empty one | bash | `recoverFromCorrupt()`, `src/store.js` -- a corrupt store is quarantined and reported, not silently replaced with `{}` |
| Survive a write interrupted mid-flight | bash | atomic write in `save()`, `src/store.js`; `tests/store.test.js` |
| Refuse an invalid status or expiry rather than storing it | bash | `isValidExpiry()` and status validation, `src/server.js`; `tests/api.test.js` |
| Answer "what is in the larder" from a shell, unattended | summon | **not built.** No `bin/` exists; `command -v mange` is empty. The scheduler conf's header prose claims a "generic `bin/scheduler-run` entrypoint" -- that claim is false against the tree, and is a finding, not a detail |

### Groceries in

| obligation | HOW | backed by |
|---|---|---|
| Turn a fridge item marked `low`/`out` into a shopping-list entry without being asked twice | bash | `upsertShoppingItem()`, `src/server.js`; `POST /api/items/:id/status` |
| Move a bought item back into the fridge carrying its qty/expiry | bash | `POST /api/items/:id/bought`, `src/server.js` |
| Capture an item in one tap, with no required fields | bash | `public/app.js` + `POST /api/items`. "Invisible" is the role, not a nicety (README) |
| Capture by barcode without a round trip to anyone | bash | native `BarcodeDetector` in `public/app.js`; unknown barcodes are named once and remembered in `localStorage` |
| Turn a receipt photo into candidate item names | bash | `public/receipt-parse.js` (merged `6e74864`), unit-tested by `tests/receipt-parse.test.js` independent of the camera |
| Decide which noisy OCR candidates are real items | summon | the parse is code; the confirmation is a human tap on the editable review list. Nothing chooses on the human's behalf, and nothing should without being asked |

### Accounting for the fridge over time

| obligation | HOW | backed by |
|---|---|---|
| Warn before something in the fridge expires | summon | **undetermined** -- expiry is stored, validated and sorted on, but nothing notifies. What would settle it: a decision on where such a notice goes (in-app only, through `senechal`, or nowhere by choice). Recorded as undetermined rather than assumed: a stored field is not a promise |
| Know what was thrown out or never used | summon | **undetermined** -- the store schema has no consumption or waste record. What would settle it: whether Zach wants waste measured at all, given the milestone below explicitly distrusts in-app proxies |
| Stay usable when the phone is offline | bash | `public/sw.js` + `public/manifest.json`; PWA install is the stated one-handed use case |
| Prove it works by a human-sense witness, not by its own metrics | bash | `npm test` (`node --test`, `tests/api.test.js`, `store.test.js`, `receipt-parse.test.js`); `npm run test:visual` drives a real system Chromium and screenshots what rendered, skipping loudly if neither playwright-core nor Chromium is present |
| Hold the shared verb contract (exit vocabulary, `--summon`) under test | summon | **not built.** There is no `test/contract-test.sh` here and no code path that can emit 4/5/6/7 -- the HTTP surface answers in status codes and the npm scripts exit 0/1. Until that exists, every clause below is a stated obligation the tree cannot yet fail |

### Universal clauses

Every subcommand, without exception:

- exits **0 only if the promise was kept**. Never an exit-0 no-op.
- exits **4 (GAP)** if in-scope tooling does not exist yet, says what is
  missing, and names the summon that can do it by hand meanwhile.
- exits **5 (BROKEN)** if it ran and produced a wrong or partial answer.
- exits **6 (BLIND)** if it cannot read its domain. "I cannot see" is
  never reported as "nothing to report" -- a larder whose store file is
  unreadable is exit 6, **not** an empty list.
- exits **7 (REFUSED)** if asked for something out of scope by design.
- **cannot spend money** unless it declares `--summon`, which has no
  short form and is never implied.

## What mange WILL NOT do

Stated positively so silence is never mistaken for oversight.

| refusal | why |
|---|---|
| Measure its own stability milestone from inside the app | The bar Zach set 2026-07-28 is a behavioural counterfactual -- that he bought groceries *earlier than he otherwise would have*, confirmed in his own words. the project's own FOCUS file: "a proxy that COULD be measured from inside the app is exactly what this bar refuses." A tool that scores itself has replaced the question with a number it controls. |
| Accounts, login, multi-user | "Invisible means: no accounts, no setup screen, no required fields" (README). Single-household, single-device is the design, not a stage before a real one. |
| Look a barcode up against an external product database | The scanner is "own code, no external dependency or product-lookup service" (README). A lookup service makes the larder depend on someone else's uptime and tells them what is in the fridge. |
| Send a receipt image or its text anywhere off-device | OCR "runs entirely client-side -- no receipt image or text is ever sent anywhere" (README). A receipt is a purchase history; it does not leave the phone. |
| Act unilaterally on something irreversible | the project's own FOCUS file's only stop-and-wait bar: a real message to a person, spending real money, deleting something with no backup. Those go to the project's own QUESTIONS file, not through `mange`. |

## What is genuinely open, and stays open

Two forks are live and neither is resolved here, because resolving them
in this document would be inventing a promise:

- **Whether this stays a from-scratch tool or becomes a front end for the
  already-installed-but-unconfigured Grocy instance.** Closed as a
  *blocker* on 2026-07-29, not as a question: Zach's rule is to bail
  toward building fresh "if it takes more time to configure the existing
  tool than to build a new tool", with the build side estimated
  pessimistically -- an asymmetry that leans *toward* Grocy. It is a live
  cost comparison when a Grocy-shaped need arises, not a fork to settle
  in advance.
- **Who owns the OCR pipeline** (vs. `vkv-inventory`'s scan script,
  vs. `bibliothecaire`). Explicitly `(parked)` past the current
  milestone -- real, but no part of "Zach buys groceries earlier"
  runs through it.

## Verification

```
npm test              # node --test, 3 suites, no dependencies
npm run test:visual   # real Chromium, screenshots to tests/screenshots/
```

There is no `test/contract-test.sh` here, so the exit vocabulary above is
asserted by nothing. That is this contract's largest single gap and the
first thing a build should close: the clauses are only worth what a
failing test makes them worth.

## Standing footprint

`groc-mangr` sits `enabled=0` in scheduler's `_paced.conf`, with the
literal recorded reason "no stability milestone declared". That reason is
now stale -- a milestone was declared 2026-07-28 -- and re-admission to
the paced rotation is the project's own to request. One shell entry does
exist outside the repo: `~/.local/bin/groc-mangr-nightly-batch-loop.sh`,
which the registry names.
