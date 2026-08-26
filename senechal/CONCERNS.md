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
  Contract: `enable`/`verify`, exit codes in `lib/common.sh`, shape checked by `health/remedy-shape.sh`.
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

**Remedy:** `remedies/app-output-paths.sh`.

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
`health.remote_ssh_timeout` / `health.remote_ssh_identity`;
`~/.ssh/senechal-estate-ed25519`; each remote host's `authorized_keys`
(comment `senechal-estate-health@mandark`).

**Remedy:** `remedies/remote-health-keys.sh`. A host that is off cannot
witness key trust — SKIP, never a pass.

### crt deploy-key trust on dexter — cross-project SSH grant

**Intent:** crt's automation reaches `zach@dexter` without a password
prompt, using a key crt generated. Cross-machine access is senechal's
domain even though the key belongs to crt.

**Files:** `~/.ssh/crt_deploy_key{,.pub}`; `~/.ssh/config` `Host dexter`;
dexter's `authorized_keys` (or `administrators_authorized_keys` — 
OpenSSH-on-Windows prefers the latter for admin accounts).

**Remedy:** `remedies/crt-dexter-ssh-key.sh`.

### Where a newly-spawned window lands (KDE virtual desktops)

**Wanted** (Zach, 2026-07-25): a window opens on the desktop it was
*spawned from*, and chromium profiles stop reopening wherever that
profile last happened to be.

**Two faults that present as one**, and only one is a config question:

1. **Placement is decided at map time, not exec time.** KWin assigns a
   new window to whatever desktop is current the instant the client maps
   it; a browser takes 1–3s. There is no KWin setting for this and there
   cannot be one — KWin never learns which desktop the launching shell
   was on. Something outside the WM has to remember: `tools/spawn-here`.
2. **The browser restores its own geometry, per profile, and wins.**
   Chromium applies `browser.window_placement` after KWin places the
   window, so the only thing that beats it is moving the window *after*
   it maps.

**Files:** `~/.config/kwinrulesrc`, `~/.config/kwinrc` `[Desktops]`,
each chromium profile's `Preferences`, `senechal.json`
`windows.profiles`, `tools/spawn-here`, `tools/browse`.

**Browser-agnostic by construction:** everything works at the EWMH level
(`wmctrl`/`xprop`), never through a browser flag. The PID trap is worth
remembering — `--profile-directory` and `firefox -P` hand the request to
the running instance and exit, so the new window belongs to a process
that existed *before* the launch; matching on `_NET_WM_PID` looks
correct and fails exactly here. `spawn-here` matches on "top-level that
wasn't in `_NET_CLIENT_LIST` before", which holds either way.

**Witness:** `tools/test-spawn-here.sh --live` is a control/treatment
pair — it first *reproduces* the bug with a bare `konsole`, then shows
`spawn-here` holding the window under the identical race. Asserting only
"the window is on desktop N" would pass in a run where the race never
happened. Needs `$DISPLAY` and ≥2 desktops, so cron exits 2.

**Remedy:** `remedies/window-spawn-desktop.sh`.

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

**Files watched:** `~/.config/lid-inhibit/patterns.conf`,
`~/.config/lid-inhibit/excludes.conf`, `~/.local/bin/lid-inhibit-daemon`,
`~/.local/bin/lid-inhibit-hold`,
`~/.config/systemd/user/lid-inhibit-daemon.service`,
`~/.config/powermanagementprofilesrc`,
`/etc/systemd/logind.conf.d/10-lid-inhibit.conf`.

**Intent:** closing the lid suspends the laptop, *except* while a
watched process (Claude, by default) is working — and beeps when it
holds, so a held lid is distinguishable from a suspended one.

**The rule this concern exists to leave behind:** an inhibitor list is a
statement of intent by whoever took the lock. It is not evidence that
anything consumed it. To ask whether an inhibitor works, read the
outcomes in the journal. A check built on the lock's *presence* passed
this setup for eleven days while the machine suspended anyway.

**Liveness:** `systemctl --user restart lid-inhibit-daemon`; PowerDevil
reparses on an `org.kde.Solid.PowerManagement.reparseConfiguration`
D-Bus call, which `enable` makes. System Settings' power page rewrites
that file wholesale on save, so `enable` refuses to run while it is
open.

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

**Remedy:** `remedies/i915-disable-psr.sh`.

### Snap-free mandark: the four mechanical swaps (hf7y/senechal#285–#288)

**Files watched:** `/var/lib/tailscale/tailscaled.state`,
`/etc/apt/sources.list.d/charm.list`, `/etc/apt/keyrings/charm.gpg`.

**Intent:** four of mandark's snaps have a real native package on the
other side and no decision left in them. They only make sense as one
cluster: one sudo prompt, one verify pass, one end state (#292,
`apt purge snapd`), which stays blocked on chromium (#290) and cups
(#291) regardless.

**Liveness:** tailscale's node identity is a file, not a config value.
Remove the snap first and it is gone, and the machine silently drops off
the tailnet. `enable` copies the state across *before* removing the
snap, and `verify` checks `tailscale status`, not just that the package
is installed.

**Remedy:** `remedies/snap-free-mandark.sh`. No `disable`: the undo is
reinstalling a snap.

### Snap-purge fallout: printing, and a queue that lives only in RAM (2026-08-16)

**Files watched:** `/etc/cups/printers.conf`, `/etc/cups/ppd/M02.ppd`.

**Intent:** `apt purge plasma-discover-backend-snap libsnapd-glib-2-1
libsnapd-qt-2-1` (18:24) cascaded into 23 purges, because
`libsnapd-glib-2-1` is a dependency of the printing and Ubuntu Studio
stacks. It took out cups, flipped audio to PulseAudio, and pulled ~55
i386 packages in as an alternative-dependency side effect. Zach's two
follow-up installs restored audio and the cups core; `bluez-cups`,
`hplip`, `printer-driver-hpcups`, `printer-driver-splix` and the M02
queue were still gone.

**Liveness:** `purge` removes conffiles, so `/etc/cups/printers.conf`
and `/etc/cups/ppd/` were deleted — but `lpstat -v` kept reporting the
M02 label printer for hours afterwards, because the cupsd process
predates the purge and holds the queue in memory. It is gone from disk
and dies at the next restart. So `verify` asserts the **on-disk**
definition and its PPD, never `lpstat` against a live daemon. Same class
as "enabled is not started": a running process is not evidence the thing
exists. `verify` also asserts `dpkg --audit` is clean — the 18:24 run
ended with a dpkg error that left `cups-browsed` half-purged.

**No remedy.** One was written and deleted on 2026-08-16 (#351, Zach's
call: "delete rather than fix") — it ran `lpadmin` before cupsd had
loaded the reinstalled config, hung on a root password prompt nothing
could satisfy, and its `verify` FAILed on a root-only file it could not
read. The repair itself was completed by hand and confirmed. What
survives is the liveness rule above, not the script.
