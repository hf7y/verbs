#!/usr/bin/env bash
# fauche-test.sh -- exercises fauche's real code paths against temp trees.
#
# Never this machine's real config: every liveness surface fauche probes is
# a knob (FAUCHE_SYSTEMCTL, FAUCHE_CRONTAB_CMD, FAUCHE_CRON_D,
# FAUCHE_AUTOSTART_DIRS, FAUCHE_PATH, FAUCHE_VERB_BUILDS), and this suite
# points every one of them at a fixture under a mktemp dir. It reads a
# temporary git repository and a stub `systemctl`; it removes nothing, and
# it never calls `fauche script` output.
#
# It covers the two defects fauche shipped with:
#   gardien#10  a directory that does not exist reported KEEP + the exit
#               code of a checked-and-kept repository
#   gardien#11  REMOVABLE for repositories a timer, a cron-reachable
#               symlink and an installed verb were reading out of
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
FAUCHE="$ROOT/bin/fauche"
pass=0; fail=0
ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (want $3, got $2)"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (output lacked: $3)" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 (output contained: $3)" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"; trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# --- a repository that is genuinely recoverable ------------------------
PROJECTS="$TMP/projects"; REPO="$PROJECTS/widget"
mkdir -p "$REPO" "$TMP/vault" "$TMP/bin" "$TMP/cron.d" "$TMP/autostart" \
         "$TMP/verb-builds/2026-01-01/widget"
git init -q --bare "$TMP/origin.git"
git init -q -b main "$REPO"
printf 'echo widget\n' > "$REPO/run.sh"; chmod +x "$REPO/run.sh"
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@example -c user.name=t commit -qm init
git -C "$REPO" remote add origin "$TMP/origin.git"
git -C "$REPO" push -q origin main
: > "$TMP/crontab"

# The one place the fixture environment is declared. Each test overrides at
# most one knob, so a failure names exactly one surface.
fauche() {
  env FAUCHE_PROJECTS="$PROJECTS" \
      BIBLIOTHECAIRE_VAULT="$TMP/vault" \
      FAUCHE_BINDIR="$TMP/bin" \
      FAUCHE_PATH="$TMP/bin" \
      FAUCHE_VERB_BUILDS="$TMP/verb-builds" \
      FAUCHE_SYSTEMCTL="$TMP/systemctl-empty" \
      FAUCHE_CRONTAB_CMD="cat $TMP/crontab" \
      FAUCHE_CRON_D="$TMP/cron.d" \
      FAUCHE_CRONTAB_SYSTEM="$TMP/no-such-crontab" \
      FAUCHE_CRON_SPOOL="$TMP/no-such-spool" \
      FAUCHE_AUTOSTART_DIRS="$TMP/autostart" \
      "$@" 2>&1
}
# run <extra-env...> -- CHECK <args>: sets OUT and RC
run() {
  local -a pre=()
  while [ "$1" != "CHECK" ]; do pre+=("$1"); shift; done; shift
  OUT="$(fauche ${pre[@]+"${pre[@]}"} "$FAUCHE" check "$@")"; RC=$?
}

# A systemctl that knows nothing is live. Present, answering, empty.
cat > "$TMP/systemctl-empty" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
# A systemctl reporting one enabled TIMER whose triggered SERVICE execs a
# script inside the repository -- senechal's exact shape, where the service
# itself is static and invisible from the enabled list.
cat > "$TMP/systemctl-live" <<STUB
#!/usr/bin/env bash
scope="\$1"; shift
[ "\$scope" = --user ] || exit 0
case "\$1" in
  list-unit-files) printf 'widget-health.timer enabled enabled\n' ;;
  list-units)      : ;;
  show)
    case "\$*" in
      *"-p Unit --value"*) printf 'widget-health.service\n' ;;
      *) printf 'ExecStart={ path=$REPO/run.sh ; argv[]=$REPO/run.sh --quiet ; ignore_errors=no }\n'
         printf 'WorkingDirectory=!/home/nobody\n'
         printf 'Id=widget-health.service\n'
         printf 'FragmentPath=/home/nobody/.config/systemd/user/widget-health.service\n' ;;
    esac ;;
esac
STUB
chmod +x "$TMP/systemctl-empty" "$TMP/systemctl-live"

echo "=== fauche: blindness (gardien#10) and liveness (gardien#11)"; echo

# --- baseline: the fixture repo really is removable --------------------
run CHECK "$REPO"
check "a recoverable repo with nothing pointing at it is REMOVABLE (exit 0)" "$RC" 0
has   "...and says so in the verdict column" "$OUT" "REMOVABLE"

# ==================================================================== #10
# "I could not check this" and "I checked this and it must stay" are
# different answers and must share neither the verdict word nor the exit
# code. A sweep from the wrong directory returned twelve confident KEEPs.
run CHECK "$TMP/definitely-not-a-real-repo"
check "a nonexistent path exits 6 (BLIND), not 0 and not a kept repo's 5" "$RC" 6
has   "a nonexistent path prints the BLIND verdict token" "$OUT" "BLIND"
hasnt "a nonexistent path never prints the word a kept repo prints" "$OUT" "KEEP"
has   "a nonexistent path still names the reason" "$OUT" "no such directory"

run CHECK "$TMP"
check "a directory that is not a git repository is BLIND (exit 6)" "$RC" 6
hasnt "a non-git directory is not reported as KEEP" "$OUT" "KEEP"

mkdir -p "$TMP/locked"; chmod 000 "$TMP/locked"
run CHECK "$TMP/locked"
check "an unreadable directory is BLIND (exit 6), not KEEP" "$RC" 6
chmod 755 "$TMP/locked"

# The distinction is only worth anything if the two codes differ in the
# same run. This is the assertion the sweep needed and did not have.
run FAUCHE_SYSTEMCTL="$TMP/systemctl-live" CHECK "$REPO" "$TMP/definitely-not-a-real-repo"
check "blind wins over keep when both appear in one run" "$RC" 6
has   "...and the kept repo is still reported as KEEP" "$OUT" "KEEP"
has   "...and the unlookable path is still reported as BLIND" "$OUT" "BLIND"

# A relative path that DOES resolve must keep working: the canonicalisation
# fix of 2026-08-01 is what makes `fauche check widget` mean anything.
OUT="$(cd "$PROJECTS" && fauche "$FAUCHE" check widget)"; RC=$?
check "a relative path that resolves is still checked (exit 0, not blind)" "$RC" 0
has   "...and is judged, not refused" "$OUT" "REMOVABLE"

# ==================================================================== #11
# 1. systemd: an enabled timer whose service execs inside the clone.
run FAUCHE_SYSTEMCTL="$TMP/systemctl-live" CHECK "$REPO"
check "a systemd timer's service exec'ing inside the repo blocks removal" "$RC" 5
has   "...naming the unit as evidence" "$OUT" "widget-health.service"
has   "...naming the path it execs" "$OUT" "$REPO/run.sh"

# 2. cron: a line reaching into the clone.
printf '*/30 * * * * %s/run.sh # a comment\n' "$REPO" > "$TMP/crontab"
run CHECK "$REPO"
check "a crontab line running a script inside the repo blocks removal" "$RC" 5
has   "...quoting the cron line as evidence" "$OUT" "*/30 * * * * $REPO/run.sh"
: > "$TMP/crontab"

printf 'MAILTO=""\n17 3 * * * %s/run.sh\n' "$REPO" > "$TMP/cron.d/widget"
run CHECK "$REPO"
check "a /etc/cron.d file reaching into the repo blocks removal" "$RC" 5
has   "...naming the cron.d file" "$OUT" "$TMP/cron.d/widget"
rm -f "$TMP/cron.d/widget"

# 3. PATH: a verb served from the clone blocks; from a build it does not.
ln -sfn "$REPO/run.sh" "$TMP/bin/widget-run"
run CHECK "$REPO"
check "a PATH symlink resolving into the clone blocks removal" "$RC" 5
has   "...naming the symlink" "$OUT" "$TMP/bin/widget-run"
has   "...and where it lands" "$OUT" "$REPO/run.sh"
rm -f "$TMP/bin/widget-run"

# gardien#3: BINDIR was assigned and never read -- ~/.local/bin was invisible
# to the PATH-symlink check above. Fixed since (SEARCH_PATH falls back to
# "$PATH:$BINDIR" when FAUCHE_PATH is unset), but every test above sets
# FAUCHE_PATH explicitly, which always shadows BINDIR's contribution and
# would pass whether or not BINDIR were ever read. Isolate it: unset
# FAUCHE_PATH (empty triggers the same bash default as unset) so the only
# way this symlink is seen is through BINDIR.
mkdir -p "$TMP/bindir-only"
ln -sfn "$REPO/run.sh" "$TMP/bindir-only/widget-run"
run FAUCHE_PATH= FAUCHE_BINDIR="$TMP/bindir-only" CHECK "$REPO"
check "FAUCHE_BINDIR alone (FAUCHE_PATH unset) still catches a live symlink (gardien#3)" "$RC" 5
has   "...naming the symlink" "$OUT" "$TMP/bindir-only/widget-run"
rm -f "$TMP/bindir-only/widget-run"

printf 'echo built\n' > "$TMP/verb-builds/2026-01-01/widget/run.sh"
ln -sfn "$TMP/verb-builds/2026-01-01/widget/run.sh" "$TMP/bin/widget-built"
run CHECK "$REPO"
check "a verb served from a verb BUILD does not block removal" "$RC" 0
rm -f "$TMP/bin/widget-built"

# gardien#13: a build that execs BACK into the clone via a LEGACY_ROOT-style
# default is a live consumer of the clone even though the build itself is a
# copy -- ausculte's exact shape (LEGACY_ROOT="${AUSCULTE_LEGACY_ROOT:-<clone>}").
mkdir -p "$TMP/verb-builds/2026-01-01/legacy-widget"
cat > "$TMP/verb-builds/2026-01-01/legacy-widget/run.sh" <<SCRIPT
#!/usr/bin/env bash
WIDGET_LEGACY_ROOT="\${WIDGET_LEGACY_ROOT:-$REPO}"
exec "\$WIDGET_LEGACY_ROOT/run.sh" "\$@"
SCRIPT
chmod +x "$TMP/verb-builds/2026-01-01/legacy-widget/run.sh"
ln -sfn "$TMP/verb-builds/2026-01-01/legacy-widget/run.sh" "$TMP/bin/legacy-widget"
run CHECK "$REPO"
check "a build script exec'ing back into the clone via LEGACY_ROOT blocks removal (gardien#13)" "$RC" 5
has   "...naming the build script as evidence" "$OUT" "legacy-widget (verb build) references"
has   "...and the clone path it references" "$OUT" "$REPO"
rm -f "$TMP/bin/legacy-widget"

# A build script mentioning a clone path that is NOT under $PROJECTS (some
# other tool's temp file, say) must not be treated as a legacy reference --
# only a literal path rooted at $PROJECTS is evidence of this shape.
mkdir -p "$TMP/verb-builds/2026-01-01/clean-widget"
printf '#!/usr/bin/env bash\necho "cache at /var/tmp/whatever"\n' \
  > "$TMP/verb-builds/2026-01-01/clean-widget/run.sh"
chmod +x "$TMP/verb-builds/2026-01-01/clean-widget/run.sh"
ln -sfn "$TMP/verb-builds/2026-01-01/clean-widget/run.sh" "$TMP/bin/clean-widget"
run CHECK "$REPO"
check "a build script with no reference under \$PROJECTS does not block removal" "$RC" 0
rm -f "$TMP/bin/clean-widget"

# 4. autostart .desktop entries.
printf '[Desktop Entry]\nType=Application\nExec=%s/run.sh --now\n' "$REPO" \
  > "$TMP/autostart/widget.desktop"
run CHECK "$REPO"
check "an autostart entry running from the repo blocks removal" "$RC" 5
has   "...naming the .desktop file" "$OUT" "widget.desktop"
rm -f "$TMP/autostart/widget.desktop"

# --- an unreadable domain is never a pass ------------------------------
# The rule the whole verb rests on: a check that cannot READ what it needs
# keeps the repository and says why, rather than scoring silence as "clear".
run FAUCHE_SYSTEMCTL="$TMP/no-such-systemctl" CHECK "$REPO"
check "an unreadable systemd domain keeps the repo instead of passing" "$RC" 5
has   "...and says which domain it could not read" "$OUT" "systemd could not be read"

run FAUCHE_CRONTAB_CMD=false CHECK "$REPO"
check "an unreadable crontab keeps the repo instead of passing" "$RC" 5
has   "...and says cron liveness is unknown" "$OUT" "crontab could not be read"

# An empty crontab is an ANSWER ("nothing scheduled"), not a blank.
run FAUCHE_CRONTAB_CMD="$TMP/systemctl-empty" CHECK "$REPO"
check "an empty crontab is an answer, not blindness" "$RC" 0

# --- the emitted script never covers a live repository -----------------
OUT="$(fauche FAUCHE_SYSTEMCTL="$TMP/systemctl-live" "$FAUCHE" script "$REPO")"
hasnt "fauche script emits no rm for a repo with a live consumer" "$OUT" "rm -rf"

# --- the vault knob: flag beats env beats default ----------------------
# One fact, three sources, so the ORDER is what is asserted. Until 2026-08-12
# the default was $HOME/ecosystem1/ecosystem1, which made this check report
# "the vault cannot be read" for every repository on monkey (gardien#18).
mkdir -p "$TMP/vault2/widget"
# The env fixture points at $TMP/vault (which has no widget/ entry, hence the
# consignment reason); --vault must be able to override that mid-argv.
OUT="$(fauche "$FAUCHE" check --vault "$TMP/vault2" "$REPO")"
hasnt "--vault beats BIBLIOTHECAIRE_VAULT" "$OUT" "cannot be read"
OUT="$(fauche "$FAUCHE" check --vault="$TMP/vault2" "$REPO")"
hasnt "--vault=PATH is the same knob" "$OUT" "cannot be read"
OUT="$(fauche "$FAUCHE" check --vault "$TMP/no-such-vault" "$REPO")"
has   "a --vault pointing nowhere is reported, not ignored" "$OUT" "cannot be read"

# gardien#18 asked whether an unreadable vault should read BLIND instead of
# KEEP, the way a missing repo path does (#10). Investigated and decided:
# no. An unreadable vault is the same shape as the unreadable systemd/cron
# domains checked further down (a surface this one host/account cannot
# currently reach, not "this repo cannot be investigated at all"), and
# those are KEEP reasons on purpose -- see the CRON_SPOOL comment in
# bin/fauche for why BLIND was rejected there: making a per-host/account
# reachability gap read BLIND fires estate-wide on every affected host,
# which is exactly what #18's own report hit before the vault default
# moved (gardien#19). Locking in KEEP here so a future pass does not
# "fix" it back to BLIND without re-reading this reasoning.
OUT="$(fauche "$FAUCHE" check --vault "$TMP/no-such-vault" "$REPO")"; rc=$?
check "an unreadable vault is KEEP (exit 5), not BLIND (gardien#18, decided)" "$rc" 5
has   "...and prints the KEEP verdict token" "$OUT" "KEEP"
hasnt "...never the word a repo this verb could not investigate at all prints" "$OUT" "BLIND"

OUT="$(fauche "$FAUCHE" check "$REPO" --vault 2>&1)"; rc=$?
check "--vault with no path is a usage error" "$rc" 2

# The default is the FHS location and not a home directory. Read from the
# source: running with a clean env would depend on whether this machine
# happens to have /srv/ecosystem1-vault.
has   "the default vault is /srv/ecosystem1-vault" "$(cat "$FAUCHE")" "VAULT_DEFAULT=/srv/ecosystem1-vault"
hasnt "no vault path under a home directory remains" "$(grep -v '^[[:space:]]*#' "$FAUCHE")" 'ecosystem1/ecosystem1'

# --- the search path is a LIST, and /srv is in the default (#20) -------
has   "the default search path includes /srv" "$(cat "$FAUCHE")" \
      'FAUCHE_PROJECTS:-$HOME/Documents/Projects:/srv'

SRV="$TMP/srv"; SREPO="$SRV/served"
mkdir -p "$SREPO"
git init -q -b main "$SREPO"
printf 'x\n' > "$SREPO/f.txt"
git -C "$SREPO" add -A
git -C "$SREPO" -c user.email=t@example -c user.name=t commit -qm init
git -C "$SREPO" remote add origin "$TMP/origin.git"
git -C "$SREPO" push -q origin main:served

OUT="$(fauche FAUCHE_PROJECTS="$PROJECTS:$SRV" "$FAUCHE" list)"
has "a repo under the second root is graded, not invisible" "$OUT" "served"
has "...and the first root is still graded" "$OUT" "widget"

# --- the vault does not consign itself (#20) --------------------------
# Point BOTH the vault and a search root at the same tree: without the
# exemption the vault is graded as a project and asked to file a note in
# itself for every one of its own prose files.
VREPO="$TMP/vault-repo"
mkdir -p "$VREPO"
git init -q -b main "$VREPO"
printf '# note\n' > "$VREPO/note.md"
git -C "$VREPO" add -A
git -C "$VREPO" -c user.email=t@example -c user.name=t commit -qm init
git -C "$VREPO" remote add origin "$TMP/origin.git"
git -C "$VREPO" push -q origin main:vaultrepo

OUT="$(fauche BIBLIOTHECAIRE_VAULT="$VREPO" "$FAUCHE" check "$VREPO")"
hasnt "the vault is not asked to consign its own prose" "$OUT" "no note in the vault"

echo
printf -- '--- fauche: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
