# CONCERNS — cross-file intents senechal tracks as one thing

A *concern* is a named cluster of config files that only make sense
together: several files, in different formats, owned by different
programs, that jointly implement one thing Zach wanted. Editing one of
them alone is usually a bug, not a change.

`senechal.py` journals files **independently** — one entry per file,
diffed by path. That is the right primitive and this file does not
replace it. What the per-file journal cannot express is:

1. **Grouping.** "These four files are one attempt" lives nowhere in a
   snapshot. Without it, a half-finished change looks like four
   unrelated diffs.
2. **Contradiction.** Two watched files can each be individually
   plausible and still cancel each other out. A hash cannot see that.
3. **Liveness.** senechal reads *disk*. A config file no running process
   has re-read is journaled as "changed" while the machine still behaves
   the old way. **Disk state is not live state.**

## Policy

- **Watch the whole concern, or don't claim to watch it.** Every file a
  concern names goes into `senechal.json`'s `watch` list, even the ones
  that seem incidental. A concern half-covered by the watch list is
  worse than an uncovered one, because the journal looks complete.
- **Record the intent in prose, here, at the time it is observed.** One
  section per concern: what was wanted, which files participate, what
  makes disk state live.
- **State the liveness command explicitly per concern**, so a future
  reader knows the journal's "modified" does not imply "in effect."
- **Report contradictions; do not silently fix them.** When two files in
  a concern fight, the finding is the deliverable — which of the two
  intents wins is a preference, not a defect.
- **Drive to the finish line; leave the last step to Zach** (policy,
  2026-07-25): every fixable concern also gets `remedies/<concern>.sh`.
  Contract: `enable`/`verify`, `disable` if it installs anything durable; exit codes in `lib/common.sh`, shape checked by `health/remedy-shape.sh`.
- **Never let concern-tracking weaken redaction.** Files added to the
  watch list for a concern go through `looks_secret` like everything
  else. No exceptions.

## Concerns

### tmux → Konsole window/tab titles

**Wanted:** the Konsole tab/window caption should reflect what the shell
inside tmux is doing, not a static string.

**Files:** `~/.tmux.conf`, `~/.bashrc`,
`~/.local/share/konsole/Zach.profile`.

**Zach's call, 2026-07-25** ("whatever makes `tmux claude` just work,
fewer flags"): the title has a single owner — **tmux** — since it is the
only participant that knows the session name. `allow-rename off` is
load-bearing, not redundant: it stops the app running *inside* tmux
(Claude Code sets its own OSC title) from clobbering the session name.

**Liveness:** `tmux source-file ~/.tmux.conf` (or kill the server) —
only server start reads the config. `.bashrc` needs a new shell.
Konsole re-reads its profile per new window.

**Witness:** rename the session and watch the WM caption follow; both
tmux's title and Claude Code's are identically valued, so a static check
cannot tell them apart. Unattended runs cannot finish this witness —
cron has no `DISPLAY`, and `wmctrl -l | grep …` exits 0 with no display
because the pipeline reports `grep`'s status. Test `DISPLAY` first and
fail loud when it is absent.

**Caveat:** Konsole rewrites `Zach.profile` when settings change through
its GUI, so a journal diff reverting `LocalTabTitleFormat` is most
likely a real user choice — ask before "fixing" it.

**Remedy:** `remedies/tmux-konsole-title.sh`.

### App output paths defaulting to bare $HOME

**Wanted:** an app's save/export dialog should default somewhere scoped
(a `Documents/` subfolder it owns), not to `$HOME` itself.

**Files:** `senechal.json` `app_output_paths.apps[]` (which app, which
config file/section/key, which canonical dir); each registered app's own
config file. Cura is the only known case so far — a sweep of every other
app with a live config counterpart found no other instance.

**Liveness:** the app must be quit and relaunched; a config edit on disk
does not reach a running process.

**Remedy:** retired hf7y/senechal#451 step 3 -- `senechal.json`
`app_output_paths.apps[]` is already the content; applying it is manual
until a generic content-driven mechanism reads it.

### Home inventory — physical things at Zach's home (delegate-only)

**Zach, 2026-07-25:** "what Zach has at home, physically" is a real
domain and it is **not senechal's**. The estate registry tracks
computing devices only, on purpose. Owner: **vkv-inventory**.

**Files:** none, deliberately. File it (`scheduler -i vkv-inventory`),
never absorb it.

### Remote estate health over SSH — BatchMode key trust

**Intent:** check dexter and potato from the inside, not just by ping.
Unattended runs use `BatchMode=yes`, so the probe needs a dedicated
passphrase-less key each host trusts — not Zach's own key, so the grant
stays narrow and revocable (delete the labeled line from a host's
`authorized_keys` and that host is out).

**Files:** `senechal.json` `estate.devices[]` and
`health.remote_ssh_timeout` / `health.remote_ssh_identity`; each remote
host's `authorized_keys`.

**Remedy:** none, deliberately. `remedies/remote-health-keys.sh` shipped a
dedicated passphrase-less key for this and was retired in #636: its
founding symptom — dexter and potato both refusing BatchMode auth
unattended, 2026-07-26 — no longer reproduces, and it was never enabled.
`estate-health.sh` adds `-i` only when `health.remote_ssh_identity` names
a file that exists, so the probe falls back to whatever ssh already
offers.

**The rule this concern exists to leave behind:** the grant is now as wide
as Zach's own key, not narrow and per-host revocable. That is a live
trade, not an oversight — re-narrowing it means a dedicated key again, and
the reason to want one is blast radius, never function.

### crt deploy-key trust on dexter — cross-project SSH grant

**Intent:** crt's automation reaches `zach@dexter` without a password
prompt, using a key crt generated. Cross-machine access is senechal's
domain even though the key belongs to crt.

**Files:** `~/.ssh/crt_deploy_key{,.pub}`; `~/.ssh/config` `Host dexter`;
dexter's `authorized_keys` (or `administrators_authorized_keys` — 
OpenSSH-on-Windows prefers the latter for admin accounts).

**Remedy:** `remedies/crt-dexter-ssh-key.sh`.

### Color-hashed user@host prompt — the first "taste" (2026-08-05)

**Wanted:** "bashrc that makes user and host colors hashes of ids thus
making each sessions terminal look unique. install on all systems."

**Why it is a registry and not three hand-edits:** a shell preference
that should apply *identically on every home*, survive a hand-edit to
the surrounding file, and pick up new homes automatically is a shape
that recurs. Doing it by hand would have solved the request and lost the
shape.

**Hashed separately, not as one `user@host` string** (Zach, 2026-08-05,
revising the original ask): a familiar user on an unfamiliar host should
be visible at a glance, which a single combined hash can't show. `@`
sits between them with a plain reset, so it takes the terminal's default
color rather than a third one.

**Files:** `senechal.json` `estate.taste`, `lib/taste-block.sh`,
`remedies/colorhash-prompt.sh`, `~/.bashrc` on each host.

**Drift rule:** a hand-edit *outside* the markers is nobody's business
and is reported nowhere; a hand-edit *through* the markers is a FAIL,
never silently re-adopted as the new "correct".

**Liveness:** `source ~/.bashrc`, or a new terminal, on each host.

### Claude slash commands in every home Zach agents from (2026-08-06)

**Wanted** (Zach, 2026-08-06): `/bashify`, `/cloture` and `/ideate` in
**every home where he might interactively call an agent**, tracked by
**something other than `installe`**.

**Why not `installe`** (his reasoning, recorded because it is the part
that decays): `installe` owns PATH symlinks out of a verb build. Slash
commands are a different artifact class with a different lifecycle —
per-home files under `~/.claude/commands/`, needed in homes that may
have no verb build at all. Routing them through `installe` would couple
"Zach can type `/ideate` here" to "this account has a build", two facts
that are not the same fact.

**Homes, not hosts.** monkey carries one UNIX account per self-dev
project plus `zach` as the hands account. `zach@monkey` wants these
commands; the other accounts run agents non-interactively and must not
get them. A host list cannot say that; `homes: [{host, account}]` can.
`hosts` is still accepted as shorthand for `{host, account: "zach"}`.

**Ownership is the load-bearing detail.** realisateur *generates* these
commands; senechal holds no copy and must not become a second source of
truth for their text. The remedy calls realisateur's generator into a
scratch dir and treats the output as canonical, so a fourth
`scope: user` command needs no edit here. senechal's value-add is the
question nobody was asking: realisateur's own check only ever inspects
the host it runs on.

**"The directory is empty" and "the host is dark" must never share an
exit code.** The remote probe always exits 0 and prints a sentinel; only
ssh's own failure means unreachable. Locked down in
`health/test-slash-commands.sh`.

**Liveness:** Claude Code reads `~/.claude/commands` at session start.

### Lid close: suspend, unless something is working

**Files watched:** `~/.config/lid-inhibit/{patterns,excludes}.conf`,
`~/.local/bin/lid-inhibit-{daemon,watch}`,
`~/.config/systemd/user/lid-inhibit-daemon.service`,
`~/.config/powermanagementprofilesrc`,
`/etc/systemd/logind.conf.d/10-lid-inhibit.conf`. The unit is named for
the daemon and runs `lid-inhibit-watch` — which is what it logs as, so
that is the name to ask the journal for.

**Intent:** closing the lid suspends the laptop, *except* while a
watched process (Claude, by default) is working — and beeps when it
holds, so a held lid is distinguishable from a suspended one.

**The rule this concern exists to leave behind:** an inhibitor list is a
statement of intent by whoever took the lock, not evidence anything
consumed it. To ask whether an inhibitor works, read the outcomes in the
journal — and check the query returns anything at all, because a journal
filter that matches nothing reads exactly like a lid that never moved.

**Liveness:** `systemctl --user restart lid-inhibit-daemon`; PowerDevil
reparses on the `org.kde.Solid.PowerManagement.reparseConfiguration`
D-Bus call `enable` makes, and `enable` refuses while System Settings'
power page is open, since saving there rewrites the file wholesale.

**Remedy:** `remedies/lid-inhibit-honoured.sh`.

### Intel PSR display corruption workaround (hf7y/senechal#157)

**Files watched:** `/etc/default/grub`.

**Intent:** this machine's iGPU shows display corruption under Panel
Self Refresh; `i915.enable_psr=0` on the kernel command line is the
standard workaround. Zach asked for a reversible install/uninstall pair
rather than a hand-edit.

**Liveness:** editing `/etc/default/grub` does nothing until
`sudo update-grub`, and the running kernel's `/proc/cmdline` does not
change until the next reboot — so `verify` WARNs rather than claiming a
queued change is live.

**Remedy:** retired hf7y/senechal#451 step 3 (one kernel parameter
string, content rather than code) -- `sudo update-grub` after adding
`i915.enable_psr=0` to `/etc/default/grub`'s `GRUB_CMDLINE_LINUX_DEFAULT`
by hand until a generic content-driven mechanism reads it.
