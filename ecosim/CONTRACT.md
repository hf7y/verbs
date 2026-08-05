# CONTRACT — `sonde`

**`sonde` — probe what cannot be seen.**

What `sonde` is obliged to do because of its role in this ecosystem: be the one organ that reports *"I could not look"* as a symbol distinct from *"nothing is there"*, and be held to that standard harder than anything it audits. Derived 2026-07-30 from `ecosim@main` (48 tracked files, 6842 lines of program), the scheduler registry conf, and `origin/bashified:CONTRACT.md`, which this **revises rather than replaces**.

Where this document and the code disagree, the document is right and the code is behind.

## How to read the HOW column

| HOW | meaning | exit when unmet | cost |
|---|---|---|---|
| **bash** | mechanized. Runs free, unattended, no model in the loop. | 5 if it ran and broke | free |
| **summon** | SHOULD DO — in scope, not yet mechanized. | 4 (GAP), naming its own escalation | metered, printed before spending |
| **refused** | WON'T DO — out of scope on principle. | 7 (REFUSED) | n/a, no summon exists |

`backed by` names a real file, subcommand, function or test where the HOW is `bash`, and says what is missing where it is not.

## The obligations

### The thesis, and the simulator that tests it

| obligation | HOW | backed by |
|---|---|---|
| refuse to register a hypothesis with no falsifier | bash | `sim/prereg.py:94` — `SystemExit("prereg: REFUSED -- no falsifier. An unfalsifiable ...")` |
| refuse to execute an unregistered hypothesis | bash | `sim/prereg.py` `require()` (`:109-113`), raising rather than defaulting |
| refuse to edit a hypothesis after it is registered | bash | `sim/prereg.py:86` raises on re-registration; `README.md` — *"prereg.py … refuses to edit one"* |
| record every post-hoc model change with its reason | bash | `sim/results/MODEL_CHANGELOG.md`, tracked |
| report a verdict as INCONCLUSIVE rather than picking a side | bash | `sim/results/STATUS.md` — H2 stands at 0 SUPPORTED / 0 FALSIFIED / 50 INCONCL |
| rebuild `STATUS.md`'s verdict table from `prereg.jsonl` + code alone, with the per-generation JSON deleted | summon | unbuilt. Milestone criterion 4; the per-generation files are gitignored, so if the table cannot be rebuilt the pruning was lossy and they must come back |
| carry the hypotheses to `bibliothecaire` for substantiation in the literature | summon | Zach, `.scheduler/QUESTIONS.md` 2026-07-28 answer: *"We need to route all of these hypotheses to bibliothecaire … Highly important to verify this."* The run-2 register and results landed (`bibliothecaire a9cac88`); the H1–H6 set this answer was about has no such record here |
| claim the correlated-blind-spots corollary as sourced | refused | `SENSOR-CONTRACT.md` §6.4 — bibliothecaire checked Ashby's primary text and did not find it, so it stays *"ecosim's own, to argue rather than cite"* |

### The contracted sensors (`ecosim.*`)

| obligation | HOW | backed by |
|---|---|---|
| a sensor may not emit a symbol it did not declare | bash | `lib/ecosim_sensor.py` `ContractViolation`; `test/test_contract.py::test_s3_1_undeclared_symbol_raises` |
| an alphabet with no BLIND symbol fails at construction | bash | `test_s3_1_alphabet_without_blind_raises` — the 19/19 probe, mechanized |
| every symbol carries a mandatory `meaning`, and BLIND helpers refuse non-BLIND symbols | bash | `test_s3_1_meaning_is_mandatory`, `test_s3_1_blind_helper_refuses_non_blind_symbol` |
| a declared symbol that no fixture makes fire is a violation, not a warning | bash | `selftest_all`; `test_s3_4_coverage_gate_fails_on_an_unfired_symbol` and `…_passes_when_all_fire` |
| BLIND beats CRIT in aggregation | bash | `test_s1_blind_is_three_and_beats_crit`; `bin/ecosim-sweep` `bump()` |
| a crashing probe reports BLIND, never silence | bash | `test_s1_crashing_probe_is_blind_not_silent` |
| `--help` does not exit success — a run that performed no check never reports OK | bash | `bin/ecosim-sensor` returns `EXIT_BLIND` for help; `test_s1_help_exits_blind_not_ok` |
| the line protocol stays cuttable: status field 1, symbol field 2, single-space, logfmt payload, a pipe delimiter before the human text | bash | `test_s2_field_positions_and_single_space`, `test_s2_grep_and_cut_actually_work`, `test_s2_logfmt_quotes_only_when_needed`, `test_s2_human_text_after_pipe_only` |
| data on stdout, diagnostics on stderr, SIGPIPE default | bash | `test_s2_data_on_stdout_diagnostics_on_stderr`, `test_s2_sigpipe_is_clean_under_head` |
| the declared alphabet is machine-readable and is the authority | bash | `ecosim-sensor contract`; `test_s4_contract_command_is_machine_readable` |
| no sensor writes outside this repo | bash | `test_s5_no_sensor_writes_outside_the_repo` |
| a sensor naming two hosts must declare them | bash | `Domain(hosts=…)`; `test_s3_2_domain_declares_hosts` |
| a sensor naming two hosts must actually READ both, or emit BLIND for the one it could not | summon | `SENSOR-CONTRACT.md` §3.2 states it and names it as three of the eight original defects; the test asserts only that hosts are *declared*. No check reads a probe's actual host coverage |
| piping inside a probe is banned, so no pipeline's exit status can be substituted | bash | `sh()` takes argv, not a shell string; `test_s3_3_sh_takes_argv_not_a_shell_string` |
| an unattended run's observations are recorded, not left on a terminal | bash | `ecosim-sensor run --log` → `sensors/events-v2.jsonl`, passed by `bin/ecosim-sweep` |
| bring the five legacy sensors (`dispatch-ref`, `credential`, `staleness`, `simultaneity`, `unit`) under the contract | summon | `.scheduler/FOCUS.md` 2026-07-29: they run every `bin/ecosim-sweep` pass but sit outside alphabet-closure and the coverage gate, so H-R2 is only evaluable over the contracted set |
| set thresholds or an alerting policy | refused | `SENSOR-CONTRACT.md` §5 — *"A sensor reports a world-state. What is worth waking someone for is the consumer's call."* |
| treat a clean run as evidence of a healthy ecosystem | refused | `SENSOR-CONTRACT.md` §5 — a clean run means every sensor that ran could read its domain; coverage is a separate question, and `aedile`/`vkv-inventory` are `BLIND_BY_CONSTRUCTION` in code so no run can forget it |

### The migration instrument

| obligation | HOW | backed by |
|---|---|---|
| observe the mandark→dexter migration and write nothing outside this repo | bash | `bin/migration-watch.py` docstring and `REPO`-rooted paths; `sensors/events.jsonl` |
| halt, gate or block a move it is observing | refused | `bin/migration-watch.py` — *"OBSERVER ONLY … cannot halt, gate or block a move"*; `.scheduler/FOCUS.md` 2026-07-28: *"YOUR ROLE IN THE DEXTER MIGRATION IS DECIDED — observer with no stop bit"* |
| name the domains it has never read as BLIND, never as absent and never as clean | bash | `BLIND_BY_CONSTRUCTION = {"aedile", "vkv-inventory"}`, `bin/migration-watch.py:38` |
| report a declared symbol that has never been observed as `NEVER_EMITTED` | bash | `ALPHABET` + sensor 4; *"what makes a clean reading auditable instead of self-certifying"* |
| ship every sensor with a negative test that makes its failure symbol appear | bash | `bin/migration-watch.py --selftest` |
| file one GitHub issue per migration unit, labelled `observation` and never `question` | summon | `schedule/ecosim.conf` declares `ANSWER_CHANNEL="issues"` and calls the label safety *load-bearing*; nothing in `bin/` calls `gh issue`. The instrument log is a declared channel with no writer |
| hourly briefs on the nomac office metabolism (burn-rate clock, ledger-derived quantities, the bid-well-deliver-little hole) | summon | requested `.scheduler/FOCUS.md` 2026-07-29 22:48. Not achievable as asked: `_paced.conf:245` has `ecosim|0|2` — dispatch is nightly and currently `enabled=0`. The request itself names the gap rather than hiding it; closing it is a steward change Zach has not made |
| probe the world twice — the cast is a view over the sensor, never a second sensor | bash | `bin/ecosim-cast.py` — *"a view that can disagree with its sensor is precisely the failure being studied, so there is no second sensor path here"* |
| truncate a line silently | refused | `bin/ecosim-cast.py` §2 rule 1 — over-wide `SEE` is truncated with a visible marker AND counted, and the count is itself cast |
| let a dark CRT mean "all clear" | refused | `bin/ecosim-cast.py` §2 rule 2 — a BLIND reading always produces a visible `SEE` line |

### The null-discriminator (`silence-audit.sh`)

| obligation | HOW | backed by |
|---|---|---|
| audit MECHANISMS rather than projects, and name the domain each check read | bash | `bin/silence-audit.sh`, 11 `check_*` functions (`mute-null`, `self-witness`, `home-scoped`, `stderr-silenced`, `unwired`, `prose-only-rule`, `retirement-open`, `dirty-writer`, `worktree-backed`, `twin`, `subrepo-invisible`) |
| exit 3 (BLIND) when it parsed zero mechanisms, rather than printing nothing and looking clean | bash | `bin/silence-audit.sh:608`, with a self-test fixture — *"BLIND: zero mechanisms must exit 3, not 0"* |
| refuse to read its own mode flag from the environment | bash | `SELFTEST=0` with the comment recording the mute hang that caused it — *"an env-readable mode flag is the same class of defect this script audits"* |
| print a NOT WIRED banner naming itself, so the artifact cannot masquerade as coverage | bash | the *"am I wired to anything?"* section, `:554` |
| write anything, or run at any AI cost | refused | header: *"Offline-first (zero AI), writes nothing, exits 0 unless `--strict`"* |
| give every one of the checks a fixture asserting both its FLAG case and its BLIND case | summon | milestone criterion 1; `.scheduler/FOCUS.md` names `[unwired]` and `[stderr-silenced]` as the untested BLIND paths |
| say how many checks there are, consistently | summon | `README.md:42` and the milestone both say **7 checks**; `bin/silence-audit.sh` defines and runs **11**. One of the two is stale, and a null-discriminator that miscounts its own alphabet is the failure it exists to name |
| reproduce the 2026-07-28 headline (82 mechanisms / 26 FLAGs) from a second independent run, or explain every delta | summon | milestone criterion 3. `.scheduler/QUESTIONS.md` already records the drift — 84/25 from the refactored repo — and notes that two extra mechanisms do not explain a FLAG *disappearing* |
| pass `install-silence-audit.sh --test` from a clean clone, not only from the tree it was written in | summon | milestone criterion 2; no clean-clone run is recorded |

### Reaching outside this repo

| obligation | HOW | backed by |
|---|---|---|
| default to dry-run on every path that would write outside this repo | bash | `bin/decide.sh` `MODE="${2:---dry-run}"`; `bin/install-silence-audit.sh` likewise |
| print the revert line before acting | bash | `bin/decide.sh:156` and the per-option `REVERT:` lines |
| notify senechal when an option changes machine-wide config | bash | `bin/decide.sh:108-109,124-129` — option 2 and option 3 both call `notify-senechal` with what changed, where, and who owns it |
| refuse to install without the guard: no `--commit` unattended | refused | `.scheduler/FOCUS.md` **Hard fences**: *"Both are dry-run by default and that default is the guard … This is not a flag-and-proceed item."* Repeated in the project charter and in `schedule/ecosim.conf`'s READ THIS block |
| write a finding into another project's repo | refused | the project charter and the FOCUS fence: *"Audit output lands here."* `SENSOR-CONTRACT.md` §5: no cross-repo writes |
| run `check-project-busy` before any write it does make outside this repo | summon | prose only, in the project charter and the nightly-batch prompt. `grep -rn check-project-busy bin/ lib/` returns nothing — the guard is remembered, not mechanized, which is this project's own stated objection to rules |
| let a check ship without its BLIND path tested | refused | `.scheduler/FOCUS.md` fence: *"A new check ships with its BLIND path tested, or it does not ship."* |
| write `WIRING-DECISION.md` — for each of `decide.sh`'s 7 options: what it changes, what it costs if wrong, which are safe unattended, ending in a recommendation rather than a menu | summon | milestone criterion 5. `ls WIRING-DECISION.md` → absent |
| decide the wiring itself | refused | `.scheduler/FOCUS.md`: *"wiring is Zach's call and lives past the bar"*; `schedule/ecosim.conf`: *"Wiring is Zach's call and sits past the current stability milestone on purpose."* |

### This project's own footprint — where it audits itself worst

| obligation | HOW | backed by |
|---|---|---|
| keep the claim *"Nothing here is wired. No cron entry, no systemd unit, no `~/.local/bin` symlink"* true, or retract it | summon | `README.md` says it; `ls -l ~/.local/bin/*ecosim*` shows `ecosim-sensor -> …/Projects/ecosim/bin/ecosim-sensor` (2026-07-29) and `ecosim-nightly-batch-loop.sh` (404b, untracked, 2026-07-28). Milestone criterion 6 — *"Nothing in this repo is installed, symlinked, or crontabbed"* — is already false. No crontab line exists (`crontab -l | grep ecosim` → nothing), so the stale half is the symlink half |
| clear the live `[worktree-backed]` flag it raises against itself | summon | `~/.local/bin/silence-audit -> /home/zach/Documents/Projects/realisateur-staging-silence-audit/bin/silence-audit.sh` — a git worktree (`git -C realisateur worktree list`), which is exactly `check_worktree_backed`'s named pattern. It also **differs** from this repo's `bin/silence-audit.sh` (`diff -q` reports differ), so the machine-wide `silence-audit` on PATH is not the audited copy |
| retire the two source worktrees, verifying content is present where the consumer reads it first | summon | Zach, `.scheduler/QUESTIONS.md`: *"Yes. Not great. In general, as long as something loses nothing, go for it."* Both `realisateur-research-ecosim` and `realisateur-staging-silence-audit` are still checked out today |
| declare the shared-host footprint in this project's own FOCUS.md | summon | the build-discipline row in the project charter requires it; three live entries under `~/.local/bin` are named in FOCUS.md only in passing, and the README asserts the opposite |
| speak one exit vocabulary across its own instruments | summon | four dialects, observed: `SENSOR-CONTRACT.md` §1 / `bin/ecosim-sensor` / `bin/ecosim-sweep` use Nagios (**3 = BLIND**); `bin/migration-watch.py` docstring says *"0 clean, 1 hazard, **2 BLIND**"*; `bin/ecosim-cast.py` says *"2 BLIND, 3 the sink was absent"*; `bin/silence-audit.sh` uses 3 for BLIND and 2 for an unknown flag. A caller aggregating them maps two world-states onto one integer — the thesis, inside the instruments that state it |
| mint an exit-code dialect where a standard exists | refused | `SENSOR-CONTRACT.md` §1 — the Monitoring Plugins codes are adopted *"verbatim … rather than minting a dialect, so ecosim output is consumable by anything that already speaks it"*, and changing them is a v2 breaking change |
| reconcile the Nagios codes with this runtime's 4/5/6/7 vocabulary at the `sonde` boundary | summon | undetermined — the two collide (`3 = BLIND` here, `6 = BLIND` in the universal clauses below) and the refusal above forbids ecosim from moving. Settled only by a decision from realisateur or Zach about which vocabulary the verb wrapper speaks and how it translates |

### The verb itself

| obligation | HOW | backed by |
|---|---|---|
| exist as a command | summon | `command -v sonde` → nothing. `bin/sonde`, `lib/verb.sh` and `man/sonde.1` exist only on `origin/bashified`; `main` has no `bin/sonde` and the two branches have not been reconciled |
| promise something a caller can rely on, per subcommand | summon | `origin/bashified:CONTRACT.md`'s table reads *"whatever `bin/decide.sh` promised"* five times over. A pass-through is a name, not a promise; the argv/output/exit contract of each is undeclared at the verb level |
| reach the fifteen Python programs `GAPS.md` filed as unreachable | summon | `origin/bashified:GAPS.md` lists 15 files *"not reachable through the verb"*. All fifteen run free — `a grep for vendor/model markers across bin/ lib/ sim/ test/` returns **zero** matches in code — so this is a wiring gap, not a mechanization gap, and the prior contract's framing understates what exists |
| run the nightly job prompt this project actually needs | summon | a project command file is realisateur's, verbatim: it instructs the run to scan an *inbox*, scaffold new sibling projects, run `bin/ecosystem-survey.sh` / `precipitation-scan.sh` / `hygiene-lint.sh` / `milestone-audit.sh` / `steward-survey.sh` — none of which exist in this repo. `schedule/ecosim.conf` says nightly work here *"is expected to be fixtures, reproducibility and the wiring-decision memo"*. The dispatched prompt and the declared job are different documents |
| quote a cost saving from mechanizing any of the above | refused | `origin/bashified:GAPS.md` — no before-measurement exists, so the saving is *"unmeasured, not zero and not assumed"*. Closing it needs a measurement, not an estimate |

### What is deliberately NOT refused

Two backlog items are **parked with a reason** and would ordinarily read as refusals; they are written as neither, because the reason given is scope, not principle:

- *run the simulator past 550 generations* and *generalise `silence-audit.sh` beyond this ecosystem* (`.scheduler/FOCUS.md`, both `(parked)`) — parked against the current milestone bar, not argued against. Filing them as refusals would record a decision Zach has not made.
- *generate `_paced.*.conf` from per-project `HOST=` fields* (`.scheduler/QUESTIONS.md` 2026-07-28, still `> (answer inline here)`) — the recommendation is *"do not build it yet"* with three reasons and an explicitly recorded argument in favour. That is an open question addressed to Zach, and it stays one.

## Universal clauses

Every subcommand of `sonde`, without exception:

- exits **0 only if the promise was kept**. Never an exit-0 no-op.
- exits **4 (GAP)** when the obligation is in scope and not yet mechanized, and names its own escalation.
- exits **5 (BROKEN)** when it ran and broke.
- exits **6 (BLIND)** when it cannot read its domain. *"I cannot see"* is never reported as *"nothing to report"*.
- exits **7 (REFUSED)** for anything out of scope on principle.
- cannot spend money without `--summon`, which has no short form and is never implied.

`--summon` is available on **4** and forbidden on **7**. A gap names its escalation; a refusal offers none, because having no escalation path is what refusing on principle means.

*(See the exit-vocabulary rows above: these codes are stated here as the runtime requires, and they collide with the Nagios codes `ecosim` adopts on principle. That collision is an open obligation, not a resolved one.)*

## The finding

**31 bash rows, 22 summon rows, 13 refused rows** over 48 tracked files (counted, not estimated — `awk` over this table's HOW column).

The split is not "mechanized vs unbuilt". Everything in `ecosim` runs free: there is no model in the loop anywhere in the tree, and the contracted-sensor half is the most rigorously mechanized promise-keeping seen in this ecosystem — a coverage gate that fails on a symbol no fixture makes fire, a banned pipeline inside probes, a test that a crashing probe reports BLIND rather than nothing. The prior `GAPS.md`'s headline, that fifteen Python programs were *"never given a shell contract"*, understates them: they have a contract, in `SENSOR-CONTRACT.md`, enforced by `test/test_contract.py`. What they lack is a front door.

The summons cluster in three places, and two of them are the project auditing everyone but itself:

1. **The verb does not exist on `main`.** `bin/sonde` lives only on `origin/bashified` and promises *"whatever `bin/X` promised"*. Cheapest set of summons on the page, and the one that unlocks the rest.
2. **`ecosim` has a shared-host footprint it says it does not have.** A symlink into this repo, a nightly loop wrapper tracked in no repo, and a machine-wide `silence-audit` resolving into a git worktree that differs from the audited copy — which is `check_worktree_backed`'s own named pattern, live, against itself.
3. **Four exit-code dialects inside the one project whose thesis is that two world-states must not share a symbol.** BLIND is 3 in three programs and 2 in two others. No prose file mentions it.

None of the three is a defect of judgment; each is the instrument turned outward and never turned back. That is worth stating plainly, because this is the only project in the ecosystem whose own subject matter makes it a reportable finding rather than ordinary drift.
