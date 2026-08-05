# Reap record — 2026-08-01: five repositories cleared from mandark

The first reap decided by `fauche` and executed by Zach's own instruction
("fauche it"), same night the verb was built.

## What was removed, and how it is recovered

| repository | size on disk | recover with |
|---|---|---|
| crt | 1.1 G | `git clone https://github.com/hf7y/crt.git` |
| front-door | 1.4 M | `git clone https://github.com/hf7y/front-door.git` |
| groc-mangr | 1.2 M | `git clone https://github.com/hf7y/groc-mangr.git` |
| nine-speakers | 1.7 M | `git clone https://github.com/hf7y/nine-speakers.git` |
| sequestria | 1.5 M | `git clone https://github.com/hf7y/sequestria.git` |

**~1.1 GB freed**, essentially all of it `crt`.

## What was checked before anything was deleted

`fauche` refuses a repository unless **all** of these hold, and it reports
the reason when it refuses:

- every local branch exists on `origin` and is 0 commits ahead of it;
- the working tree is clean, tracked and untracked alike;
- no git worktree outside the repository depends on its object store —
  removing one of those breaks an installed verb silently, at the next call;
- every prose file has a note in the vault.

Then, independently and by a **different method**, immediately before the
deletion: `git rev-list --count --branches --not --remotes` returned **0**
for all five, and `git ls-remote --heads origin` reached every remote and
found 2–3 branches on each. A remote that was merely configured, or a push
that had not landed, would have failed that second check and not the first.

## The hazard that did not fire, checked rather than assumed

`bashify`'s doctrine warns that `scheduler/focus/<project>.md` and
`questions/<project>.md` are **symlinks** into each project's own
`.scheduler/`, so a reap leaves dangling links behind it — which had
happened on both previous reaps. Swept after the removal:

```
for f in focus/*.md questions/*.md; do [ -e "$f" ] || echo "DANGLING: $f"; done
```

**Nothing dangled.** These five were unregistered from the scheduler when
they were parked on 2026-08-01, so their links had already gone with the
confs. The check was still run, because "it should be fine" is how the
previous two went unnoticed for a day.

## What this changes about the waiting room

`WAITING-ROOM.md` states that **parking is not reaping** and that a parked
repository "stays on disk, its prose stays in place, its `bashified` branch
stays pushed." For `crt` and `sequestria` that promise has now moved: the
prose is in the vault, the branches are on origin, and the bytes are one
`git clone` away rather than present. `front-door`, `groc-mangr` and
`nine-speakers` went the same way.

That is a real change to a written promise, made on Zach's instruction and
recorded here rather than left for a reader of WAITING-ROOM.md to discover
by finding the directory missing.

## Prose consigned first, not after

**150 documents** were consigned to the vault earlier the same night
through `fonde consign`, which routed to the MECHANIZED `consign-prose`
impl and spent nothing — 65 of them `crt`'s alone. Consigning *before*
deciding removability is what made these five removable at all; the check
reports unconsigned prose as a refusal, so the order was forced by the
tool rather than remembered by the operator.
