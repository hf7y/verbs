# CONTRACT — realisateur's verbs

Derived 2026-07-30 from the tooling that actually existed, and rewritten
2026-08-18 when the last six shims became verbs.

## The promise

Each verb keeps whatever its implementation on `main` promised. The
implementation is the contract; this file states what is true of **all** of
them, which is the part a caller can rely on without reading any of them.

Every verb, without exception:

- exits **0 only if the promise was kept**. Never an exit-0 no-op.
- exits **2** on a usage error, before touching anything.
- exits **4 (GAP)** if the tooling it needs does not exist, and says what is
  missing.
- reports **BLIND** rather than clean if it could not read its domain.
  "I cannot see" is never reported as "nothing to report". The code is 3 or
  6 depending on the verb; unifying them is hf7y/realisateur#334.
- **cannot spend money** unless it declares `--summon`, which has no short
  form and is never implied.
- resolves its own location with `readlink -f`. A verb is installed as a
  symlink into the build, so a bare `dirname "${BASH_SOURCE[0]}"` yields
  `/usr/local` and the verb dies on every invocation.

## What was here before

This file used to be the contract for `juge`, a single verb with nineteen
subcommands — one per script in the legacy tree. Eleven of those scripts have
since been deleted, and `juge` itself was retired 2026-08-18 for having no
caller at all (hf7y/realisateur#382).

The answer turned out not to be one verb that bundles the tools. It is six
front doors, each of which a person actually types.

## Verification

```
./test/contract-test.sh <command>
```

The same assertions run against the implementation on `main` and against the
verb here. That is what makes "keeps the same contract" a measurement.
