# hf7y/verbs — assembled verb builds

**Generated. Do not hand-edit.** Every file outside `.github/` and this
README is written by `.github/workflows/build-verbs.yml`, which runs
`bin/cut-verb-build.sh` out of `hf7y/realisateur`. An edit made here is
erased by the next nightly build without comment.

The design, the reasoning and the failures it is built to refuse are in
**`realisateur/VERB-DISTRIBUTION.md`**. This file is only what you need to
read the contents.

## What is in here

```
manifest.tsv          project <TAB> verb <TAB> sha <TAB> repo_url
BUILD_ID              the id of the build in the working tree
<project>/            the whole `bashified` tree of that project, at that sha
```

A **build** is a dated manifest naming an exact sha per project, tagged
`build/<id>`. That is the whole idea: every user path installs *the same
named thing*, holds it while agents merge past it, and steps back to
yesterday's by name. Install by tag, never by branch — `main` here moves.

The per-project directory is the **entire** bashified tree, not just `bin/`
and `man/`. Verbs source `lib/verb.sh` from their own project root and each
project carries its own already-forked copy; a build carrying only the
executables passed every existence check and every verb in it was broken.

## Consuming it

`realisateur/bin/install-verb-build.sh`:

```sh
install-verb-build.sh --check              # is a newer build out? exit 3 = BLIND
install-verb-build.sh --latest --apply     # install it and switch, atomically
install-verb-build.sh --list               # what is here, and what is current
install-verb-build.sh --rollback <id>      # a build already on disk, no network
```

`--link` (writing `~/.local/bin`) is **off by default**: `installe` owns that
directory and its manifest, and this script reports what installe owns
rather than clobbering it. Reconciling the two is a deliberate sitting —
`VERB-DISTRIBUTION.md` §7.

## Reading a build critically

- **A shrinking build is refused** unless `--allow-shrink` was passed. A
  verb lost to a flaked API call is indistinguishable, in a manifest, from
  one genuinely retired.
- **A verb name may be declared by exactly one project.** Two claimants
  fails the build here, once, for everyone. `range` was declared twice on
  2026-07-30; `cueille` on 2026-08-04.
- **A project leaves the build by being archived.** Deriving live from the
  account means a dormant repository would otherwise declare its verbs
  forever. `gh repo unarchive` puts it back.
- **A nightly run that finds no project moved cuts no tag.** Identical
  content under a new name is not a new build.

## Retiring this

Delete this repository. Nothing else in the ecosystem depends on it until
`installe` is taught to read a build, which as of 2026-08-04 has not
happened.
