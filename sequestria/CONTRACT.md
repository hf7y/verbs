# CONTRACT -- `capte`

> capture the brand: carbon, fizz, and the storefront

This file is the deliverable. It states what `capte` is obliged to do
**because of its role in the ecosystem**, not what happens to be built.
Implementation is downstream of this document; when the two disagree,
this document is right and the code is behind.

Derived 2026-07-30 from what is actually in the `sequestria` tree, its
scheduler registry entry, and the project's own FOCUS file / the project's own QUESTIONS file.
It **revises** the 2026-07-30 bashify-pass contract on `origin/bashified`
rather than replacing it. That contract's entire obligations table was one
row -- `*(none)* | -- | no shell tooling existed in this project` -- which
was true about shell scripts and misleading about the project. See the
closing finding.

`sequestria` is the ecosystem's only project that is not a tool. It is a
brand concept with a landing page, run as a deliberate experiment (Zach,
2026-07-22) in how a real-world business idea evolves out of a software-dev
workflow. Its verb's role follows from that: `capte` captures the brand --
the story, the people who raise a hand for it, and the record of the
process itself -- and it is fenced, harder than any other project here,
from the things that would make the capture real without a human present.

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
no escalation path is what refusing on principle *means*.

## The obligations

### Serving the concept -- making the brand concrete enough to react to

| obligation | HOW | backed by |
|---|---|---|
| Serve the landing page with no build step and no network | bash | `public/index.html` + `python3 -m http.server --directory public` (README) |
| Serve it with the waitlist store attached | bash | `server/waitlist-server.js`, `node server/waitlist-server.js [port]` |
| Keep working when no server is running at all | bash | `public/app.js` -- `localStorage` is the record; the POST is best-effort |
| Refuse to serve a path outside `public/` | bash | `serveStatic()` path normalization, `server/waitlist-server.js` |

### Capturing the waitlist -- the one place a real person touches this

| obligation | HOW | backed by |
|---|---|---|
| Store a signup durably, on disk, outside git | bash | `POST /api/waitlist` -> `data/waitlist.local.jsonl`; `.gitignore` |
| Reject a malformed address rather than storing it | bash | `EMAIL_RE` + HTTP 400, `handleWaitlistPost()` |
| Never send anything outward from a signup | bash | there is no mail path in the tree; `fetch` is same-origin only |
| Report how many people are on the list | bash | `GET /api/waitlist/count` |
| Report **exit 6 (BLIND)** when the list cannot be read, instead of zero | summon | **BROKEN today.** `const count = err ? 0 : ...` returns `{count: 0}` for an unreadable file. This is precisely "I cannot see" reported as "nothing to report" -- the universal clause below, violated in the one place it matters most |
| Never tell a person they are on the list when nothing was stored | summon | **not held today.** `app.js` prints "You're on the list." off the `localStorage` write alone; the server POST's failure is swallowed by `.catch(() => {})` |
| Speak the ecosystem exit vocabulary (4/5/6/7) at all | summon | undetermined -- nothing in this tree has an argv contract or an exit code beyond HTTP status. Settled by building the verb front door below |

### The verb surface

| obligation | HOW | backed by |
|---|---|---|
| Be invocable as `capte <subcommand>` | summon | `bin/capte` exists on `origin/bashified` with an **empty** subcommand table; nothing in the working tree |
| Reach the mechanized work above from a nightly job | summon | not built. Every bash row above is reachable only by a human typing `node` or `python3` -- mechanized, but not *addressable* |
| Be on `PATH` | refused | no shared-host footprint is wanted for a single-project brand site; `command -v capte` is empty and should stay empty until something outside this repo needs to call it |

### Building the storefront -- the stability milestone

The bar (Zach, 2026-07-28): one real Instagram ad against a real
storefront, and one real order from a real person who is not Zach. It is
not one obligation, and flattening it to one would hide the split.

| obligation | HOW | backed by |
|---|---|---|
| Render `public/index.html` mechanically from content + a company-name parameter | summon | decided, not built. the project's own FOCUS file "Implementation queue": *"HTML generation must be mechanical, not AI-driven on nightly passes"* -- `config.yml` + render script, queued for `/cloture`. No `config.yml` in the tree |
| Make the company name a build-time swap (`Media Arts Collective` -> post-filing entity) | summon | same queue item 2; nothing in the tree parameterizes it |
| Stand up a storefront that can take an order, on a free tier | summon | in scope since the 2026-07-28 fence revision (*"provided it costs nothing"*); unbuilt |
| Build checkout plumbing | summon | in scope, free-tier only; unbuilt |
| Prepare the ad creative up to the point of purchase, and stop there | summon | FOCUS.md: *"may take the storefront and the ad creative all the way to the point of purchase and then stop, with a clear handoff"* |
| Iterate brand copy, typography, logo, bottle illustration | summon | judgment work by design. `public/logo.svg`, `public/bottle.svg`, `public/style.css` are the current state |
| Record whether the milestone is reached | summon | undetermined -- `status: not-started` is hand-maintained prose in the project's own FOCUS file. Settled by deciding whether anything mechanical may stamp it; the `$100` provision keys off that stamp |

### Capturing the process -- a standing scope item, not a side effect

| obligation | HOW | backed by |
|---|---|---|
| Document the tension between autonomous nightly iteration and business/brand judgment | summon | `PROCESS.md`; standing scope item confirmed by Zach 2026-07-22 -- *"a future nightly pass building brand/copy work here should also be adding to that documentation as it goes"* |
| Extract workflow patterns reusable by later business-shaped ideas | summon | same 2026-07-22 answer; no extracted-pattern artifact exists yet |
| Make a no-change pass produce no commit, so re-verification cannot look like progress | summon | undetermined -- FOCUS.md 2026-07-26 asks for exactly this (*"a pass producing no `public/` diff makes no commit"*); nothing enforces it, and the file itself notes the last several commits were self-logging rather than product |
| Fold answered `QUESTIONS.md` blocks into `FOCUS.md` and clear them | summon | **overdue and observable.** Both 2026-07-28 questions carry Zach's inline `>` answers and are still sitting unfolded; `/nightly-batch` owns this |
| Route DAC-supplier and certification research to `bibliothecaire` | summon | Zach, 2026-07-28: *"delegate research to bibliothecaire for now"*. Not routed -- no cross-project request exists in either repo |

### Refusals -- stated positively, so silence is never mistaken for oversight

At least one refusal is expected here, and this project has more of them
than mechanized rows. That is not a defect: the fences are the most
carefully argued documents in the repo, and they are load-bearing because
this is the only project whose actions can reach a stranger's inbox or
Zach's bank account.

| obligation | HOW | backed by |
|---|---|---|
| Spend real money -- domain, trademark, company formation, paid hosting, a paid plan, an ad buy | refused | **FENCE 1**, the project's own FOCUS file, absolute: *"no matter how small the amount or how clearly it unblocks the milestone. 'It was only $12' is the exact reasoning this fence exists to refuse."* No `--summon` may authorize it |
| Buy the Instagram ad the milestone requires | refused | the named live tension: the seed capital unlocks only *after* the sale the ad is meant to produce, so *"the ad buy specifically is Zach's act."* Stopping at that line is a **complete** run, not a blocked one |
| Route around Fence 1 via free credit, a promotion, or a cheaper channel that bills anything | refused | FOCUS.md, stated pre-emptively: *"It may not find a workaround, a free-credit promotion, or a cheaper channel that happens to bill something"* |
| Send mail to a real person on the waitlist | refused | Zach, the project's own QUESTIONS file 2026-07-28, choosing option (a): a run may compose and queue; **Zach sends.** A sent email cannot be un-landed, which is why this one has no escalation flag |
| Present an unverified DAC supplier or carbon certification as verified fact to someone who can buy | refused | **FENCE 2**, kept deliberately as an *honesty* fence rather than a scope fence, and independently required by the milestone (*"every environmental/supplier claim visible to that customer is TRUE and verified"*) |

Two refusals above carry conditions Zach has already written down, and a
refusal with a condition is still a refusal until the condition is
recorded as met -- not something a run may judge for itself mid-flight:

- **Fence 1 relaxes to a provisional `$100`** when the milestone is
  stamped `reached`. Until then, *"the $100 does not exist"*. Note the
  ordering: the sale comes first, the money second.
- **The waitlist-mail refusal sunsets** on Zach's own terms -- *"a) with
  sunset clause being zach sends three drafts with no edits then (c"* --
  i.e. after three consecutive drafts Zach sends unedited, it becomes
  fully lifted. **Nothing in this repo counts those drafts**, so the
  sunset cannot currently fire. That counter is a gap, and until it
  exists the refusal stands unconditionally.

Fence 2 was also amended rather than lifted (Zach, 2026-07-28): *"lets
write copy in the most sales-pitchy way possible with the caveat that we
will roll claims back with asterisks if we cannot get the actual
certifications. this is an art project and that is part of the aesthetic
gesture."* So the refusal is narrowed to the **unasterisked** claim shown
to a paying customer. That amendment implies an asterisk/rollback
mechanism, and:

| obligation | HOW | backed by |
|---|---|---|
| Mark every environmental claim as conceptual-or-verified, visibly and per claim | summon | undetermined -- nothing in `public/` implements an asterisk or claim-status mechanism. Settled by deciding whether it is markup in the content file or a build-time pass over rendered copy |
| Enumerate the claims currently on the page and their status | summon | not built; would be a mechanical scan once claims live in a content file rather than in hand-written HTML |

### Universal clauses

Every subcommand, without exception:

- exits **0 only if the promise was kept**. Never an exit-0 no-op.
- exits **4 (GAP)** if in-scope tooling does not exist yet, says what is
  missing, and names the summon that can do it by hand meanwhile.
- exits **5 (BROKEN)** if it ran and produced a wrong or partial answer.
- exits **6 (BLIND)** if it cannot read its domain. "I cannot see" is
  never reported as "nothing to report" -- an unreadable
  `data/waitlist.local.jsonl` is exit 6, **not** a count of zero.
- exits **7 (REFUSED)** if asked for something out of scope by design.
- **cannot spend money** unless it declares `--summon`, which has no
  short form and is never implied. Here that flag is weaker than the
  fence above it: on this project, `--summon` still cannot buy anything.

## Verification

```
./test/contract-test.sh ./bin/capte capte
```

No test exists in the working tree; the assertion above is on
`origin/bashified` only, and it tests the verb's shape rather than the
brand. The registry declares no `BATCH_TEST_CMD`, so nothing gates a
nightly run here at all -- itself a gap, recorded rather than hidden.

## The state this contract describes

Counted from the tables above, not estimated: **8 bash, 19 summon, 6
refused**.

Three findings the count makes visible:

1. **The prior contract's headline was wrong in a specific way.** "No
   shell tooling existed" is true; "nothing was ever mechanized" is not.
   Eight obligations run free, unattended, with no model in the loop --
   static serving, signup storage, email validation, the count endpoint,
   the offline fallback, path containment. HOW=bash asks *is a model in
   the loop*, not *is it written in bash*. What is missing is the **verb
   surface**, not the mechanization.

2. **The two exit-vocabulary violations are in the mechanized half, not
   the unbuilt half.** An unreadable waitlist reports `0`, and a person
   is told they are on a list whose durable write may have failed
   silently. These are the two cheapest things to fix in this document
   and the two with a real human on the other end of them.

3. **The refusals outnumber anything else per unit of argument.** Six
   refused rows, five of them quotable verbatim from files Zach wrote or
   answered in, plus two conditional relaxations neither of which can
   currently fire because nothing counts what they key on. For a project
   whose scope boundary is the entire product, that is the contract
   working: `capte` captures the brand right up to the line where
   capturing it would cost money or reach a stranger, and stops.
