# ESTATE — the devices senechal keeps

senechal is majordomo of Zach's estate: it **knows and maintains the
devices** — their configuration, their health, and who is responsible
for each.

**Data lives in `senechal.json`, not here.** `estate.devices[]` is the
device registry (add a device there, never here):

```sh
jq '.estate.devices' senechal.json
```

**Work lives in GitHub issues, not here.** Findings are tracked as
issues labelled `finding` — filing is not closing, so an issue stays
open until senechal has re-probed its own close check and it passes:

```sh
gh issue list --repo hf7y/senechal --label finding --state open
```

This file is the delegation model, the standing decisions behind it, and
a one-line pointer at each mechanism — so a reader knows which script
governs a given concern instead of reading a second, driftable copy of
it here.

## Trust boundary

**dexter is a trusted secret-holder, equal to mandark** (Zach,
2026-07-25: "dexter is my machine too and can own my secrets just
fine"). dexter may hold the journal, watch-list previews, and anything
else senechal knows. This does **not** loosen redaction — `looks_secret`
still applies to everything written to `journal/`, on every host; the
trust decision is about *which machines may hold senechal's records*,
not about what may be recorded in plaintext. potato, ha-pi, and network
gear were never proposed as hosts and aren't covered by it.

## Delegation model — coordinate, and own the gaps

Zach's call, 2026-07-25. **This retires nothing.** Sibling projects keep
full ownership of their domains; senechal holds the registry, notices
when something in someone's domain is broken, and files it to them:

```sh
scheduler -i gardien "BACKUPS ARE NOT RUNNING -- ..."
```

**senechal owns the gaps** — anything with no project: host health on
mandark/dexter, network gear, mail delivery, orphaned scripts/autostarts.

Boundaries worth stating, because they are easy to blur:

- **gardien** owns backups. senechal watches *whether they happened* and
  reports; it does not back anything up.
- **home-assistant** owns automation and everything on the HA Pi.
  senechal tracks that Pi's liveness only.
- **crt** owns the console app on potato/dexter. senechal watches the
  hosts, not the app.
- **realisateur** turns ideas into projects. When senechal finds a gap
  that deserves its own project, it goes to realisateur.

## Mechanisms

Exit codes, thresholds and behaviour live in the scripts and in
`senechal.json`; this is only the index.

- `health/estate-health.sh` — read-only estate health check, cron-safe.
  Writes `~/.local/state/senechal/health-latest.txt` and
  `health-history.tsv` independent of any delivery channel.
- `health/dead-config.sh` / `health/undeclared-footprint.sh` — the two
  halves of `estate.footprint`: is what we declared still there, and is
  anything here undeclared. Neither ever removes anything — deleting a
  live service is the irreversible-against-a-real-host class that stays
  human-confirmed.
- `health/secret-registry.sh` — `estate.secrets` is **where a credential
  lives, what it is for, and how to mint a new one**, never the value.
  **Nothing here is backed up, on purpose** (Zach, 2026-08-13): if the
  answer to a lost credential is always "reissue it", the copy is pure
  liability. Every registered credential is `recovery: remint`. The one
  genuinely irreplaceable thing is Zach's GitHub account recovery (2FA
  backup codes), which is not a file on any host here.
- `health/no-self-dev.sh` — self-dev is leaving mandark for **monkey**
  (`self_dev.destination_host`). senechal’s own clone landed there
  2026-08-16: unix account `senechal` (uid 3014), cloned from GitHub, its
  config at `~/.config/senechal/senechal.json`, suites green. Both hosts
  run concurrently until the mandark clone is removed — that is the
  intended intermediate state, not drift (#348 phase 5). Inventory lives in `senechal.json`'s
  `self_dev` block, two-sided on purpose: `must-be-absent` items FAIL
  while installed, `must-remain` items FAIL when *gone*, because a
  teardown measured only by what it removed overshoots.
- `lib/taste-block.sh` + `estate.taste` — not "what exists" but "what
  Zach wants every one of his homes to look like". Onboarding a new home
  is one line: add its device to `estate.devices`, add it to a taste's
  `homes`, `enable`. Full writeup: `CONCERNS.md`.
- `health/printer-black-channel.sh` — **the HP 8710 prints no black, and
  every automated signal says it does.** See the finding below. The check
  hardcodes no queue names: it asserts the *property* that the default
  destination goes through the `k2c:` backend, so it survives a rename and
  still catches queues cups-browsed invents from DNS-SD by itself.
- `tools/export-registry.py --write` — copies `estate`/`health` to
  `registry/senechal-registry.json`, committed, so the untracked live
  config's *contents* get git history. Refuses to write if any value
  looks like a credential.

## Open finding — the HP 8710 prints no black (2026-08-25)

**Print to `HP8710_K2CMY`. Every other queue on this printer silently
drops the black.**

The K nozzle row is dead. Measured off the printer's *own*
`pqDiagnosticsPage`, with CUPS out of the loop: the black block came out
at peak row density 12.4 against cyan's 176, and the page printed none of
its own text. `rgb 0,0,0` and `DeviceGray 0` both scan as literal
(255,255,255) — blank paper, not faint. A black *tint* below ~50% is
composited out of CMY instead, and with magenta at 20% that lands orange,
so partial-grey artwork comes back wrong rather than missing.

**Nothing detects this by asking.** `lpstat` reports the queue idle and
enabled; `marker-levels` reports K at **90%**, the fullest of the four;
`ConsumableConfigDyn.xml` reports the printhead `ConsumableState: ok`. All
three said exactly that while the diagnostics page came out blank. A job
sent to the wrong queue is accepted, reported successful, and handed back
with the black gone — no error anywhere. This is the
`guards-that-go-quiet` shape, so the guard is the routing, not a probe.

The queues, named to say what they do:

| queue | what happens |
|---|---|
| `HP8710_K2CMY` | **use this.** Black remapped onto C/M/Y, palette rotating so no one supply carries it |
| `HP8710_BROKEN_K` | reaches the printer, eats black. Must exist — `HP8710_K2CMY` feeds it |
| `HP_OfficeJet_Pro_8710_F3466A` | eats black. cups-browsed recreates it from DNS-SD; deleting it does not stick |

History that cost real ink, so it is not repeated: the K cartridge was a
nonHP one delivering *nothing*, and it hid a clogged head behind it. A
genuine HP cartridge restored flow and only then exposed 18 dropout bands.
A level-1 clean then made it **worse** — peak row density 97.0 before, 12.4
after. Cleaning cycles on this printer are not colour-scoped (one shared
CMYK head, one service station), so that pass spent cyan and magenta at 20%
to make black worse. Swap cartridges before cleaning, not after.

Replacement head is **M0H91A** (kit, includes C/M/Y/K starter cartridges;
`M0H90A` is the bare head), fits 8710/8715/8720/8725/8730/8740/8745. The
fitted one is PAULINA, installed 2016-06-30. Retire the whole workaround —
both remedies, the health check, and this section — once the K exercise
strip on the bottom of every `HP8710_K2CMY` page prints solid.

## Known gap

- **The RAID array has no health check.** `gh issue view 165`.
