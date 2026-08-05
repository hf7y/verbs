# CONTRACT -- `chante`

> make the nine nodes sing, and listen to each other

This file is the deliverable. It states what `chante` is obliged to do
**because of its role in the ecosystem**, not what happens to be built.
Implementation is downstream of this document; when the two disagree,
this document is right and the code is behind.

Revised 2026-07-30 from the 2026-07-30 bashify-pass contract, which is
superseded. That contract recorded "no shell tooling existed at all",
zero subcommands, and every promise a gap. The finding was literally
true and materially wrong in exactly the way `cueille`'s was: it
searched for *shell scripts*, and `nine_speakers/` is a 10-module
simulation with a real argv contract (`python3 -m nine_speakers.sim`,
eight flags) and a 97-test suite that runs free, unattended, with no
model in the loop. The HOW column asks whether a model is in the loop,
not which language the loop is written in. Corrected, this project's
headline is not "none of it was ever mechanized" but: **the simulation
is mechanized; the thing the project is now actually judged on -- nine
channels of audio in a real room -- has no mechanism at all, and one of
its preconditions is a question nobody has answered.**

The second correction is larger. On 2026-07-28 Zach reframed the
project's bar (the project's own FOCUS file, his own `/ideate` pass) from the
simulation to the physical rig. FOCUS.md states the consequence plainly:
`node.py`, `ca_model.py`, the timing-vs-CA comparison and the sim
visualisation are **PARKED**. A contract derived from the tree alone
would be a contract about the parked half. This one is not.

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

## The obligations

### Simulating nine nodes that sense each other -- the mechanized core

| obligation | HOW | backed by |
|---|---|---|
| Run nine nodes for N ticks and print what each one believes | bash | `python3 -m nine_speakers.sim --ticks N`; `world.World.step()` |
| Reproduce a named run exactly | bash | `--seed`; verified 2026-07-30, `--ticks 3 --seed 1` twice, identical |
| Deliver every broadcast with a real propagation delay, not instantly | bash | `bus.Bus.tick`, sub-tick `deliver_tick` passed to handlers |
| Attenuate what a node hears by distance **and** by frequency | bash | `acoustics.py` -- spherical spreading + air absorption, applied by `Bus` to every `Utterance` |
| Model occlusion as frequency-dependent, and cost it delay as well as amplitude | bash | `acoustics.occlusion_loss_db`, `occlusion_extra_distance_m` (capped at the direct path's own length); `--obstacles none\|corner\|wall` |
| Hide ground truth from the nodes | bash | positions live in `World`; `Node` receives only events and utterances |
| Offer more than one belief model against the same scaffolding | bash | `--model timing\|ca`; `node.Node` and `ca_model.CANode` share the `World`/`Bus` interface |
| Recover real inter-node distance with no shared external stimulus | bash | `node.on_neighbor_utterance` + `distance_snapshot()`; end-to-end test against `Bus.distance` |
| Keep correlation-confidence and measured distance as separate axes | bash | `selfmodel.estimate()` returns `role` and `distance_role` independently (eighth-pass decision, 2026-07-24) |
| Stay numerically bounded over a long run | bash | `tests/test_world.py` 20k-tick boundedness test |
| Prove a refactor changed nothing, byte-for-byte, rather than asserting it | bash | `tests/test_audio.py::test_layer_zero_is_pure_sine_unchanged`; obstacles default off == prior behavior |
| Decide which belief model is *the* model | refused | see refusals |

### Making sound, not printing numbers

| obligation | HOW | backed by |
|---|---|---|
| Render a run to real audio with no third-party dependency | bash | `audio.py` (stdlib `wave` + `math`); `sim.py --render-audio DIR` |
| Write one track **per node**, never a mixed-down master | bash | `audio.render_tracks_to_dir` -> `node{id}.wav`; per-node is what lets nine real speakers reproduce the physics |
| Give each register its own timbre and playing feel | bash | `audio.LAYER_HARMONICS`, `audio.LAYER_ENVELOPES` |
| Keep nodes off each other's register | bash | `node.Node` layer selection; `_effective_heat`'s id-derived preference breaks the lockstep symmetry a stress test found |
| Fail loudly when a render produces no tracks | summon | **not implemented.** `sim.py:106` prints `Wrote 0 audio track(s)` and exits 0. This is the exit-0 no-op the universal clauses forbid, present in the tree today; it should be exit 5. |
| Sound like an actual sound language rather than four parameters | summon | undetermined -- `Utterance` (pitch, volume, rhythm_density, layer) is a placeholder README calls open. Settled by what the piece should *say*, which is Zach's call, not a modelling one. |

### The physical rig -- the current bar, and the whole of the gap

The 2026-07-28 milestone: *nine channels of audio actually playing in
the office, levels balanced by microphone measurement rather than by ear
or by simulation.* Every row here is unmechanized. That is the honest
measure of this project against the bar it is now judged by.

| obligation | HOW | backed by |
|---|---|---|
| Drive nine discrete, independently addressable output channels | summon | **nothing exists.** No hardware, driver, or routing code in the tree (`grep` for Pi/PIR/ALSA/JACK: zero hits). README: "no Pi/PIR/speaker code at all." |
| Drive them from a real, re-openable Pure Data patch | summon | **nothing exists.** No `.pd` file is tracked. Milestone item 2. |
| Balance levels from **measured** microphone input, with before/after recorded | summon | **nothing exists.** No capture, no analysis, no measurement record. Milestone item 3, and the one it names explicitly as not-by-ear. |
| Name the Focusrite 2x2's role in the signal path | summon | undetermined -- **and deliberately so.** A 2i2 has two outputs and cannot drive nine channels. FOCUS.md records the mic-input reading as *"a reading, not a confirmation"* and instructs: "Do not build against either reading until Zach says which." Settled only by Zach naming the interface. |
| Calibrate the sim against the four real office speakers | summon | undetermined -- the 2026-07-20 idea (measured-vs-simulated attenuation in a real corner). No measurement exists, so the sim's acoustics are unvalidated against any room. |
| Report a level balance derived from simulation or from listening | refused | see refusals |
| Declare the milestone met | refused | see refusals -- item 5 is `(waiting: Zach)`, a human-sense witness |

### Working unattended, and reporting it honestly

| obligation | HOW | backed by |
|---|---|---|
| Re-verify before building on prior work rather than trusting a prior run's claims | bash | a project command file §2 -- `pytest tests/ -q` and a real `sim` run; 97 passed, 20.45s, re-run 2026-07-30 |
| Push every meaningful change, not merely commit it | bash | nightly-batch.md §7; standing push permission, the project charter 2026-07-22 |
| Treat a `> ` reply in QUESTIONS.md as authoritative and remove the block once acted on | bash | nightly-batch.md §1; the convention is documented in QUESTIONS.md's own header |
| Never re-ask an unanswered question indefinitely -- make the default call and mark it a default | bash | kept **by precedent only**: the eighth pass, 2026-07-24, after five unanswered passes, decided and labelled it *"a default, not a confirmed answer."* Nothing enforces this; the `backed by` column has to say so or the row lies. |
| Write a dated report and keep `LATEST.md` matching | summon | **stale, and the staleness is the finding.** `~/reports/nine-speakers/` holds exactly `2026-07-24.md` and `LATEST.md`. Nothing checks that LATEST matches the newest dated file, and nothing noticed six days of silence. |
| Distinguish "the run found nothing to do" from "the run did not happen" | summon | undetermined -- the project has been `enabled=0` in scheduler's `_paced.conf:214` since 2026-07-24, so the empty report directory means *parked*, not *idle*. Nothing in this repo can tell those apart from the inside. |
| Order hardware, or spend money, on its own initiative | refused | see refusals |

### The verb front door and the exit vocabulary

| obligation | HOW | backed by |
|---|---|---|
| Expose the simulation through `chante` | summon | **`bin/chante` (on `origin/bashified`) wires zero subcommands.** `verb_subcommands()` returns empty. The sim's argv contract already exists and is stable; closing this is wrapping it, not designing it. |
| Exit non-zero when it ran and broke | summon | **not implemented anywhere.** `grep -rn sys.exit nine_speakers/` returns nothing but the `argparse` import line. `sim.main()` returns `None` on every path; the only non-zero exit this project can produce is an argparse usage error (2) or an uncaught traceback (1). |
| Distinguish BLIND (cannot read its domain) from GAP (nothing built yet) | summon | **not implemented, and about to matter.** Today the domain is in-process and cannot be unreadable. The moment a microphone or an audio interface is in the path, "the interface is not plugged in" becomes exit 6 and must never be reported as a balanced room. Write this check *with* the first hardware code, not after. |
| Refuse to spend without `--summon` | summon | **no flag parsing for it exists** outside the bashified branch's `lib/verb.sh`, which no working code path reaches. |
| Report a cost baseline for what mechanization saved | summon | undetermined -- no before-measurement exists. Unmeasured, **not zero and not assumed**; closing it needs a measurement, not an estimate. |

### Universal clauses

Every subcommand, without exception:

- exits **0 only if the promise was kept**. Never an exit-0 no-op.
- exits **4 (GAP)** if in-scope tooling does not exist yet, says what is
  missing, and names the summon that can do it by hand meanwhile.
- exits **5 (BROKEN)** if it ran and produced a wrong or partial answer.
- exits **6 (BLIND)** if it cannot read its domain. "I cannot see" is
  never reported as "nothing to report" -- an absent audio interface or
  a dead microphone is exit 6, **not** a room reported as balanced.
- exits **7 (REFUSED)** if asked for something out of scope by design.
- **cannot spend money** unless it declares `--summon`, which has no
  short form and is never implied.

## What chante WILL NOT do

Stated positively so silence is never mistaken for oversight.

| refusal | why |
|---|---|
| Choose which belief model -- timing-correlation or CA -- wins | README states it directly: *"that's still a judgment call, not an engineering one."* Both run against the same scaffolding precisely so the comparison stays available to a person. A tool that picks has thrown away the alternative it was built to preserve. |
| Report a level balance obtained by ear or from the simulation | The milestone's own words: *"'Sounds right' is not the bar; a measurement is."* This is the one refusal that protects the current bar from being met on paper. A simulated attenuation curve is a hypothesis about the room, not a reading of it. |
| Declare the milestone met | Item 5 is `(waiting: Zach)` -- *he* hears the balanced nine-channel setup and confirms. A human-sense witness cannot be delegated to the thing being witnessed. |
| Build against an unconfirmed reading of the hardware topology | FOCUS.md, 2026-07-28, verbatim: *"Do not build against either reading until Zach says which."* The 2i2's two outputs cannot be nine; guessing which side of that the interface sits on would produce a signal chain nobody chose. This is `refused` rather than `summon` **as currently stated** -- Zach's answer lifts it into an ordinary obligation. |
| Make sound in the office unattended | The scheduler registry justifies this project's own autonomy on exactly this basis: *"unattended-safe because ... purely a simulation/design project (no hardware, no live deployment) -- everything it touches is code and reversible."* Audio in a room at 3am is neither reversible nor unnoticed. Note the tension: the current milestone is hardware, so **the registry's stated safety basis expires the day the first row of the rig section is built**, and that conf needs rewriting before it is. |
| Order parts, or spend money, to advance the rig | nightly-batch.md §5 names this as the archetypal judgment call: *"if the sim reaches a point where building real hardware seems genuinely justified, that IS a real judgment call -- flag it rather than ordering parts."* |
| Re-enable itself in scheduler's pacing table | `_paced.conf:214` sets `enabled=0`, parked 2026-07-24 as a throughput reallocation. Capacity is `dose`'s domain, not `chante`'s. A parked project that can unpark itself is not paced. |

*Two of these seven are conditional rather than principled and are
marked as such: the hardware-topology row (Zach's answer lifts it) and
the unattended-sound row (which expires with the registry justification
it rests on). The other five are refusals on principle: no summon exists
for any of them.*

## Verification

```
python3 -m pytest tests/ -q          # 97 passed, 20.45s, re-run 2026-07-30
python3 -m nine_speakers.sim --ticks 40 --seed 1
```

The suite is real and it is the strongest thing this project has: it
pins the bus's delay and attenuation, confidence and layer selection,
echolocation against `Bus.distance` ground truth, CA excitation, the
self-model's two axes, the ASCII renderer, both topologies including
single-node and 20k-tick edge cases, and byte-identity of the audio
path across three refactors.

It asserts **nothing about the exit vocabulary above**, because none of
that vocabulary is implemented. That is the first assertion to write
when the front door closes, so that `bash` in this document means
measured rather than claimed.

## Shared-host footprint

**One entry, and it is untracked.**
`~/.local/bin/nine-speakers-nightly-batch-loop.sh` (418 bytes,
`-rwxrwxr-x zach zach`, dated 2026-07-20) is a live executable on the
shared host that belongs to this project and exists in **no git repo**
(`~/.local/bin` is not a working tree). It `exec`s
`scheduler-run nine-speakers batch`. It is currently dormant only
because `_paced.conf:214` disables dispatch -- the file itself would run
today if re-enabled.

The verb is not installed: `command -v chante` -> not found. Nothing
else here is on `PATH`, symlinked, crontabbed, or registered as a
systemd unit.
