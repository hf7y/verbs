# CONTRACT

Per-verb promise tables. A verb gets a section here when it SHIPS.

`recense` ships here; `veille` stays quarantined until it gets its own real backing work. `debarrasse` and `lance` shipped 2026-09-02 (#405) and were reversed 2026-09-05 (#699) -- the 2026-08-27 reap order they had quietly undone stands.

Universal clauses and the exit vocabulary are in `lib/verb.sh`, which is executable and therefore cannot drift from what ships.

---

# CONTRACT -- `installe`

govern what is reachable from a prompt

Coined 2026-07-31. Real, not a wrapper. It is the answer to a gap the `recense` pass measured: **1 of 18 coined verbs was reachable from a prompt.** Seventeen contracts were written, tested, and unspeakable.

## The promise

```
installe <path> | verb <project> <name> | retire <name> | list | audit
```

| subcommand | promises | backed by |
|---|---|---|
| *(a path)* | one executable reachable by its basename, by symlink | `bin/installe` (real) |
| `verb` | a bashified verb reachable, pinning the project's `bashified` worktree if needed | `bin/installe` (real) |
| `retire` | one name off the path and out of the manifest; the target untouched | `bin/installe` (real) |
| `list` | what `installe` owns | `bin/installe` (real) |
| `audit` | every entry in the install directory, classified by provenance | `bin/installe` (real) |

## The safety property

**`installe` removes only what it installed** -- anything absent from the manifest is refused (exit **7**); `--force` takes the decision back. **`retire` removes links, never targets**, asserted by test.

## Verification

```
./test/contract-test.sh bin/installe    # the universal assertions
./test/installe-test.sh                 # THE PAGE TEST + the safety properties
```

Safety assertions inspect disk state, not exit codes, inside a sandbox install directory.

---

# CONTRACT -- `recense`

census what is reachable from a prompt (#405); read-only on principle.

| subcommand | promises |
|---|---|
| *(none)* | every name reachable from a prompt, first match per name |
| `where` | the one path a name resolves to, or that it doesn't |
| `paths` | every `$PATH` directory in order; an unreadable entry is **BLIND (6)** |

```
./test/contract-test.sh bin/recense && ./test/recense-test.sh
```

---

