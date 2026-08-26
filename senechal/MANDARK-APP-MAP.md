# mandark app map

Which installed apps on mandark are actually used. The register of what
gets removed is `senechal.json`'s `unused_software.items`, read by
`remedies/mandark-unused-software.sh` — add or reclassify an item there,
never here and never in the script.

## Method, and where the obvious method lies

**Binary `atime` is not evidence.** It is wrong for apps launched
through a wrapper or desktop file whose "first binary in `dpkg -L`" is
not the one the user runs, and directory mtime does not update when a
file inside a nested subdirectory changes. Recursive
`find -printf '%T@'` over each app's real config/data directory is what
settles it — several packages looked stale on binary atime alone and
turned out to be actively used.

The same trap applies to `~/.local/bin`: every file there shares one
atime, because something (shell completion, PATH indexing) bulk-touches
the whole directory. Evidence there is `~/.bash_history` and text
references under `~/Documents/Projects`.

## Judgments that are not derivable from the registry

- **A taskbar pin is real signal of intent, and does not mean keep.**
  Three apps with zero config evidence turned out to be pinned to the
  KDE panel; Zach confirmed the pin doesn't mean keep. The remedy
  therefore also strips the matching `applications:<id>` token from
  every panel `launchers=` line, edited section-precisely via
  `ini_get`/`ini_set`, never a blind file-wide `sed` — a plasma config
  repeats key names across many bracketed sections.
- **Real but old evidence is kept, not removed.** `ardour`, `hydrogen`,
  `yoshimi` each have at least one distinguishable session on record —
  a materially different shape from "installed, never opened". Left to
  Zach, not automated.
- **Tightly-coupled JACK-graph packages are kept** even on weak
  evidence: `csound` (`pd-csound` depends on it), `jack-keyboard`,
  `jack-mixer`, `qjackctl`, `mcpdisp`, `xjadeo`, `meterbridge`. Removal
  risk outweighs a few KB.
- **Ubuntu Studio meta-packages and docs-only packages are the OS
  flavor, not independently removable apps** — not touched.
- **Ambiguous cases are left alone, not guessed at** (`printlist`,
  `phomemo_printer`).

`apt-get remove` (not `purge`) is used, so config under `/etc` survives
a change of mind.

## Not investigated

Library/runtime/dev-toolchain packages, AppImages under `~/Applications`,
and the rest of `~/.local/bin` — Zach already has a self-retirement
pattern for the last (`~/.local/bin/retired-<date>/`).
