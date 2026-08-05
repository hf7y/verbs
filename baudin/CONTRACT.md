# CONTRACT — `loge`

**house the configuration** — hold the authoritative, versioned record of what a live Home Assistant instance is configured to do, and keep that record honest against the machine.

Derived 2026-07-30 from `/home/zach/Documents/Project Archive/home_assistant` (the path `scheduler/schedule/home-assistant.conf` declares in `PROJECT_REPO_PATH`; there is no `Projects/home-assistant`). This **revises** the contract on `origin/bashified`, which listed one row — *"no shell tooling existed in this project"* — and an empty subcommand table.

That prior headline is very nearly right here, and this revision says so rather than manufacturing a table over it. There is exactly one program in the tree (`scripts/sync_welcome_dashboard.py`), it is not mode `755`, there is no `bin/`, no test directory, and `command -v loge` is empty. What the prior contract missed is the other direction: `loge`'s domain is not a codebase, it is a **live physical instance**, and most of what this project is obliged to do is obliged by that fact — not by any file. Those obligations exist whether or not code was ever written for them, which is why they are in this table as gaps rather than absent from it.

## How to read the HOW column

| HOW | meaning | exit when unmet | cost |
|---|---|---|---|
| **bash** | mechanized. Runs free, unattended, no model in the loop. | 5 if it ran and broke | free |
| **summon** | SHOULD DO — in scope, not yet mechanized. | 4 (GAP), naming its own escalation | metered, printed before spending |
| **refused** | WON'T DO — out of scope on principle. | 7 (REFUSED) | n/a, no summon exists |

## The obligations

### Housing the record

| obligation | HOW | backed by |
|---|---|---|
| version the instance's `automations.yaml`, `scenes.yaml`, `scripts.yaml`, `configuration.yaml`, `packages/` and `blueprints/` | bash | `config/` in the tree; 30 automations tracked (11 `double_flip_*`, 12 `circadian_red_ramp_*`, 7 `night_fade_light_*`), counted `grep -c '^- id:' config/automations.yaml` |
| keep instance-specific runtime data OUT of the record (`.storage/`, `home-assistant_v2.db*`, `*.log`, `.cloud/`, `deps/`, `tts/`) | bash | `.gitignore`, twelve rules; README "What's tracked here vs. not" states the same split in prose |
| state, for any config file, whether the record and the Pi currently agree | summon | undetermined — nothing computes this. Passes assert byte-identity in prose (2026-07-24: "24/24 automations now byte-identical") but no command reproduces the comparison |
| pull the live config off the instance into the record | summon | README "Syncing config": *"There's no automated sync yet."* The two documented routes are the File editor add-on and mounting the SD card — both are human hands |
| survive the human editing outside the record | summon | undetermined — Zach, the project's own QUESTIONS file: *"I will KEEP editing through the HA UI."* The obligation this creates (reconcile-before-write, never assume git is authoritative) is stated in prose and enforced by nothing |

### Deploying

| obligation | HOW | backed by |
|---|---|---|
| put a light onto a curated dashboard, idempotently, without touching its power state | bash | `scripts/sync_welcome_dashboard.py` — diffs `light.*` in the entity registry against what the view already references, appends only the missing, re-reads the saved config and prints `N/M lights shown`. Docstring: *"Editing a dashboard is display-only — it does NOT toggle or change any light, so it is safe overnight."* |
| verify the deploy landed rather than trusting the write | bash | same file: after `lovelace/config/save` it re-fetches `lovelace/config` and exits **2** if any light is still missing. This is the only exit-0-is-earned check in the repo |
| deploy an automation change to the Pi | summon | undetermined — the working path is `POST /api/config/automation/config/<id>` over the REST API (FOCUS.md item 0.5; SSH port 22 is refused, so file copy is not available). No script wraps it |
| be invocable as `loge` | summon | nothing. No `bin/`, no entry point, `command -v loge` empty. `scripts/sync_welcome_dashboard.py` is not mode `755` (`git ls-files -s` reports zero `100755` files) and is invoked as `HA_TOKEN=... python3 scripts/sync_welcome_dashboard.py` |
| speak the 4/5/6/7 exit vocabulary | summon | **absent and contradicted.** `sync_welcome_dashboard.py` uses `sys.exit(1)` for AUTH FAILED, dashboard-create failure and save failure alike (lines 64, 98, 130). So "the token is dead" (BLIND, 6) and "HA rejected the write" (BROKEN, 5) are indistinguishable to a caller. Its `sys.exit(2)` for missing lights is the one meaningful code and it does not match the vocabulary either |

### Seeing the instance

| obligation | HOW | backed by |
|---|---|---|
| find the Pi before doing anything | summon | FOCUS.md item 0 has the full ordered fallback in prose — `https://homeassistant.local:8123` (HTTPS, not http), then `192.168.0.39`, then `https://baudin.duckdns.org/` (external 443 → the Pi's 8123). Nothing executes it; every pass re-derives the ladder by hand |
| report "I cannot see the instance" as such, never as "nothing to report" | summon | undetermined — the 23rd pass ran entirely off-LAN with `192.168.0.39` at 100% packet loss and said so, but that was an agent's judgment. No code distinguishes unreachable from healthy |
| know which bulbs are `unavailable` and for how long | summon | recorder history over the REST API; every count in FOCUS.md (`office_2` ~9.5d, `living_big_1/2` ~5.0d) was gathered by hand on the night it was written. `python3`, `curl` and `jq` are all present on this host, so this is not-done rather than not-possible |
| re-probe rather than quote a prior claim of health | summon | the rule is in the project charter (realisateur baseline, "Claims about system state **re-probed, not quoted**") and its value is proven in-tree: `docs/FOCUS-milestone-patch-2026-07-27.md` records five consecutive passes asserting a the project's own agent file edit was permanently blocked, and the 23rd pass re-probing and finding it was not. Enforced by nothing |

### The unattended pass

| obligation | HOW | backed by |
|---|---|---|
| run nightly against the live instance without a human present | summon | **permanently so.** a project command file dispatched via `scheduler`; a model is in the loop by construction, so it is metered no matter how well it works. Built and firing tonight is not the same question as free |
| clone the record at the branch that exists | bash | `BRANCH="master"` in `~/.local/bin/home-assistant-nightly-batch-loop.sh` line 34 (verified present 2026-07-30). Before 2026-07-25 this was unset, `sweep-loop-common.sh` defaulted it to `main`, baudin has only `master`, and **every pass logged `error: pathspec 'main' did not match any file(s)` while reporting success** |
| fail loud when a pass commits but does not push | bash | `sweep-loop-common.sh`'s `WARNING: local commit made but NOT pushed`. Pass 13 emitted it while its own summary said *"Everything's committed, pushed, and reports are in sync"* — the guard fired and the narrative overrode it, which is why the guard belongs to the harness and not to the prose |
| leave a report a human reads once, the next morning | summon | `~/reports/home-assistant/LATEST.md` + a dated file; five present as of 2026-07-30. Written by the model each pass, so metered |
| carry an unresolved item forward instead of dropping it | summon | undetermined — the project's own QUESTIONS file is append-only by convention ("never overwritten or trimmed") and Zach's own 2026-07-24 reply is *"mine for not looking in the -qs and letting them get stale?"*. Whether staleness should escalate, and after how long, is his call and is not written anywhere |

### The house is real

| obligation | HOW | backed by |
|---|---|---|
| prefer reading state/logs/config over actuating a physical device when both would answer the question | summon | a project command file §intro, stated in full. Held in practice — FOCUS.md: *"No physical actuation was needed for either half — both were closed by reading the recorder against real-world events"* — but held by an agent reading a paragraph, not by a guard |
| treat a device doing something neither this project nor a human commanded as ghost behavior to investigate | summon | undetermined — Zach states the rule and its trigger verbatim in the project's own QUESTIONS file (*"if this project did not order the command AND a human did not command it, that is ghost behavior"*, escalate when tracing costs 100× a manual override). It needs a command log this project does not keep, so the rule cannot currently be evaluated at all |
| hand a hardware problem back rather than working around it in software | bash | *kept by omission, and that is the honest reading.* The sole open milestone item is the `unavailable` bulbs, and FOCUS.md closes the question in the file itself: *"there is no software lever left — stop re-probing it every pass."* Nothing enforces the stop; what makes this a kept promise is that no software workaround was ever built for `binary_sensor.rpi_power_status` being `on` since 2026-07-17 |

### Secrets and footprint

| obligation | HOW | backed by |
|---|---|---|
| keep credentials out of the record while surviving a fresh clone | bash | `.session-handoff/` is gitignored; `scheduler/schedule/home-assistant.conf`'s `SECRETS_SRC_DIR` copies it into the job's dedicated clone before each run, via `lib/sweep-loop-common.sh`'s generic support |
| ship a template instead of the secret | bash | `config/secrets.yaml.example` tracked, `config/secrets.yaml` gitignored |
| declare what this project puts on the shared host | summon | **the footprint exists and is undeclared in the shape the baseline asks for.** `~/.local/bin/home-assistant-nightly-batch-loop.sh` is a real 4081-byte executable that is *untracked in any repo* — FOCUS.md notes this itself: *"the wrapper is untracked — it exists only in `~/.local/bin`, so this fix has no git history of its own."* A machine-wide script owned by a project with no record of it is the exact case `notify-senechal` exists for |
| verify a credential still works before trusting it | summon | a project command file §1 says so explicitly for `ha_token` / `ha_ssh_key` / `tuya_iot_creds`. No check exists; `GET /api/` → 200 is the one-line test nobody has written down as a command |

### What `loge` WILL NOT do

| obligation | HOW | backed by |
|---|---|---|
| flip real lights on and off as a test between ~10pm and 7am | refused | a project command file: *"avoid actions that would visibly disrupt the house at night … unless the change is inert with the house empty."* The domain is a house with people asleep in it; a test that wakes them has already failed |
| troubleshoot the AC / `climate.*` gap | refused | FOCUS.md, stated twice: *"the AC/`climate.*` gap is explicitly being handled in a separate chat, not this repo"* and *"a **separate chat**, do NOT troubleshoot it in the nightly job."* `config/packages/climate.yaml` is a commented-out example and stays one |
| report on schedules held inside the bulbs' vendor clouds | refused | the project's own QUESTIONS file 2026-07-19: *"Bulb-internal schedules live in the Tuya/Smart Life cloud and are not visible via the HA API — this can only be checked in the phone app, not by the nightly job."* Not a gap: no amount of building reaches them, so no summon can be offered |
| wire a new device integration unattended | refused | FOCUS.md item 10: *"don't wire either one in unattended without confirming the approach first, since adding a device integration is the kind of judgment call FOCUS.md's other entries flag rather than just do."* Applies to OctoPrint, the 2D printer and the GE AC alike |
| pick one wall-switch alternative and deploy it | refused | FOCUS.md: *"research and propose, don't just pick one unilaterally … surface options with tradeoffs rather than deploying a fix unprompted."* It may require a purchase; spending Zach's money on a hardware opinion is not this project's call |
| track the recorder database, `.storage/`, or `config/secrets.yaml` | refused | `.gitignore` + README: instance-specific runtime data *"stays on the SD card only."* Versioning device registries and auth tokens would make the record a liability rather than a record |
| assume git is authoritative over the live instance | refused | the project's own QUESTIONS file 2026-07-19: *"Git drifted behind live AGAIN this run, so for now the nightly always pull-and-reconciles first and never assumes git is authoritative."* A `reset --hard` toward git would silently delete automations a human built in the UI — and Zach has said he will keep building them there |

**Not refused, and deliberately not listed above:** the six PARKED ideas in FOCUS.md's milestone — the sun-matched circadian rework, kitchen task-lighting circadian, "half the bulbs off at deepest night", wall-switch *detection* (as distinct from unilaterally deploying one, refused above), new device integrations as a class, and cosmetic entity re-id. Each is parked against a *bar*, not against a reason, and two of them carry open questions addressed to Zach ("which half", "which switch"). Filing them as refusals would record a decision he has not made. They are summons nobody has spent yet, and this paragraph exists so their absence from the table does not read as an oversight.

## Universal clauses

Every subcommand of `loge`, without exception:

- exits **0 only if the promise was kept**. Never an exit-0 no-op. A pass that could not reach the Pi has not verified anything.
- exits **4 (GAP)** if the tooling does not exist, says what is missing, and names its own escalation. `--summon` is available on 4.
- exits **5 (BROKEN)** if it ran and broke.
- exits **6 (BLIND)** if it cannot read its domain. "I cannot see the instance" is never reported as "nothing to report" — the single most load-bearing clause for this project, whose domain is a Pi that has been unreachable for whole passes and whose bulbs go `unavailable` for days.
- exits **7 (REFUSED)** for anything in the WILL NOT table. `--summon` is **forbidden** on 7. A gap names its escalation; a refusal offers none, because having no escalation path is what refusing on principle means.
- **cannot spend money** unless it declares `--summon`, which has no short form and is never implied.

## The finding

**9 bash, 17 summon, 7 refused** (counted, not estimated: `sed -n '/^## The obligations/,$p' CONTRACT.md | awk -F'|' '/^\|/ && NF>=4 {gsub(/[ \t*`]/,"",$3); print $3}' | sort | uniq -c`). Of the 9 bash rows, 4 are the record itself (`config/` + `.gitignore` + the secrets split), 2 are one Python script, 2 belong to a harness that lives outside this repo, and 1 is a promise kept by never having built the workaround. The shape that matters:

1. **`loge` has no front door.** Not "thin" — absent. One unmarked Python file, no `bin/`, no test directory, nothing on `PATH`. The prior contract's "no shell tooling existed" was accurate about the tree.

2. **The mechanized rows are not the interesting half.** What `.gitignore` and `config/` do is real and holds; what is missing is everything that would let the record *check itself against the machine*. "House the configuration" is currently one-directional: files are stored, and whether they still describe the Pi is decided by a model each night.

3. **The one place mechanization already earned its keep was the harness, not the repo.** The `BRANCH="master"` fix and the not-pushed warning each caught a pass that was reporting success while broken. Both live in an untracked file in `~/.local/bin`.

4. **The exit vocabulary is claimed nowhere and violated once.** The only program in the tree collapses auth failure and write failure into `exit 1`. This is the fourth project in this pass with that exact shape.

5. **The cheapest two summons**, if anyone spends here: give `sync_welcome_dashboard.py` a `loge` front door with the 4/5/6/7 codes, and write the reach-the-Pi ladder from FOCUS.md item 0 as a script that exits 6. Both are lookup and both are load-bearing every single night.
