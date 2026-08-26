# senechal

**Majordomo of Zach's estate.** senechal manages the household of
devices — their configuration, their health, and who is responsible for
each — and delegates to the projects that own a given domain rather than
absorbing their work. See `ESTATE.md` for the device registry, the
delegation model, and current open findings.

Mission set by Zach, 2026-07-25:

> senechal should be the owner of my devices (their configs, health,
> etc.) it should delegate where appropriate, like to home-assistant. you
> are the majordomo; you manage the estate, the health of the home. the
> original dot file migration is just a primary case example of what to
> do. but it's not scope creep to give you more responsibilities to know
> and maintain devices.

Two responsibilities, then:

1. **Know the estate.** Journal how each device is configured, so a
   fresh machine can be reconstructed from the record instead of memory.
2. **Maintain the estate.** Watch device health and act on what it
   finds. senechal *acts*: reversible operational fixes it just does and
   reports; only privileged or hard-to-undo changes wait for Zach, as a
   `remedies/<concern>.sh`. Run `discipline` for the full authority and
   the ecosystem protocols — that text lives in realisateur's
   `BUILD-DISCIPLINE.md` and is read at the point of use, never copied.

From the original inbox note: "agent that observes my linux laptop
environment... records changes retrospectively... this is about making
sure I can start from scratch and drop back into my routines and
workflows as painlessly as possible. it's somewhat intimate; it needs to
guard my secrets, even from other agents."

The intimacy clause is not softened by the wider mission. A majordomo
that knows every device is a majordomo holding more secrets, so the
redaction invariant binds harder than before, not less.

## Running it

```
# One-time. The config lives in XDG config, NOT in this checkout
# (hf7y/senechal#67). Override the location with $SENECHAL_CONFIG.
mkdir -p ~/.config/senechal
cp senechal.json.example ~/.config/senechal/senechal.json && chmod 600 ~/.config/senechal/senechal.json
$EDITOR ~/.config/senechal/senechal.json   # edit the watch list
python3 senechal.py                      # scan + write today's snapshot, print diff vs. yesterday
python3 senechal.py --audit              # re-check every committed snapshot for leaked secrets

# Tests. The extglob below must stay UNQUOTED -- quoted, the shell never
# expands it, run-suites.sh gets the literal string and exits 127.
python3 -m unittest test_senechal -v
bash health/test-alerting.sh
shopt -s extglob; bash tools/run-suites.sh health/test-*.sh remedies/_test-*.sh tools/test-*.sh tools/test-*.py test/!(contract)-test.sh test_senechal.py
bash test/contract-test.sh ./bin/installe   # the verb contract; a harness, takes an argument
```

## Where the rules live

Nowhere in prose, deliberately. This repo deleted its `CLAUDE.md` and
`remedies/README.md` on 2026-08-25 after four of their factual claims
were measured wrong in a single session — a ship branch documented as
current that was 31,246 lines stale, a documented test command that
exited 127, a policy line superseded for three months that was still
steering agents into filing instead of fixing, and a section heading
that contradicted its own body. Claims about state rot; the fix is to
make them executable.

| what | where it is enforced |
|---|---|
| decisions Zach already gave | `tools/standing-answers.py` (`--audit` fails when a decision's mechanism is deleted) |
| land as a PR, not a direct push | `.githooks/pre-push`, installed by `remedies/git-push-guard.sh` |
| the verb build ships all of main | `health/bashified-ships-main.sh` |
| how a remedy must be shaped | `health/remedy-shape.sh` |
| where the config lives | `lib/common.sh`, exit 2 at source time |
| build discipline, ecosystem protocols | `discipline` (realisateur owns the text) |
| device registry, open findings | `ESTATE.md` |

`--audit` exists because redaction runs at write time: each snapshot was
only ever checked against the `SECRET_PATTERNS` of the day it was
written, and every `journal/*.json` is committed to git and kept
forever. It re-runs the *current* patterns over *every* snapshot, and
never reproduces the offending text, so the report doesn't become a
second copy of the leak. Wired into `health/estate-health.sh` so it runs
on the same hourly timer as everything else.

The invariant that matters most: secret-looking content must never reach
a snapshot as plaintext. Any new scanning path runs through
`looks_secret` (or equally conservative) first.

## What's genuinely open (not built yet)

- **`declared_footprint` has no automatic source.** `take_snapshot` can
  compare a declared-footprint list against what it actually finds, but
  nothing populates that list from other projects' own cross-write
  prose, and there is no agreed machine-readable convention for
  declaring a host footprint — building a parser now would mean
  inventing a schema every existing declaration would fail. Feeding it
  by hand is the open half.
- **Secret redaction is pattern-based, not exhaustive** — not a
  substitute for reviewing what's in the watch list before committing
  the journal somewhere shared.
- **No reconstruction/restore path** — this builds the observation
  journal, not a "replay this journal onto a fresh machine" tool.
- **Canonical-shared-location naming** ("lilypond scores all live in one
  shared-library place") is still out of scope; see `NAMING.md`.
