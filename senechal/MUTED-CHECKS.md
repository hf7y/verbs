# MUTED CHECKS — what senechal has stopped surfacing, and how to unmute

A check listed here is **muted, not deleted**: the script, its test
harness and its registry are untouched and it still runs by hand. What
is switched off is the *surfacing* — the place in this repo that told a
session or a human to run it and to treat its exit code as work.

Muting is recorded rather than done as a silent doc deletion because a
check that vanishes from the checklists with no trace is
indistinguishable, six weeks later, from a check that was never built.
Every row carries the date, the reason, the exact layer, and the exact
command to put it back.

**The rule this file's own history left behind: every mute needs a probe
that fails when its premise dies.** A mute is a claim about the world.
Both mutes below were reversed only because a human or an agent happened
to notice; nothing re-checked the claim. A mute whose stated reason is
checkable, and unchecked, is indistinguishable six weeks later from a
check nobody built.

## Currently muted

None.

## Reversed

| check | muted | unmuted | why it came back |
|---|---|---|---|
| `health/no-self-dev.sh` | 2026-08-05, Zach-directed ("I don't look at them") | 2026-08-06, Zach-directed | he prioritised the mandark → monkey split, and this script is that migration's only executable definition of done, so "nobody looks at it" became the argument for the opposite |
| `silence-audit --strict` | 2026-08-05, Zach-directed | 2026-08-15 | the premise died upstream: realisateur `a3fe0a9` (#308) made it read the `.agent-project` registry instead of requiring a scheduler checkout, which was the entire cause of the BLIND the mute rested on |

Both were documentation/checklist-layer mutes only (`ESTATE.md`,
`registry/standing-answers.json`); neither script was ever changed. `no-self-dev.sh` is still
deliberately **not** wired into `health/estate-health.sh` and does not
ride the hourly timer — with work outstanding it would page hourly about
work in progress. Unmuting restored the reminder to run it, not an alert
channel.
