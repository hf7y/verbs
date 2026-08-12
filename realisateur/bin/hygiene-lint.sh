#!/usr/bin/env bash
# hygiene-lint.sh -- offline-first (zero AI) build-hygiene scan across every
# scheduler-registered project. Since 2026-08-07 it is one of TWO surveys, not
# five: ecosystem-survey.sh, milestone-audit.sh and steward-survey.sh were
# retired as re-implementations of the same registry enumeration that nothing
# ran (bin/tests/guard-estate.test.sh records what that gave up), leaving this
# and precipitation-scan.sh. Same discipline as scheduler's
# docs/offline-first-checks.md: gather real signals with plain
# git/grep, surface them, and leave the JUDGMENT to a human or an AI reading
# the output -- this script never fixes anything and never decides a finding
# is real; a secret-looking string or a tracked binary might be intentional.
#
# GUARD: do the recurring build/deploy failure patterns appear in any registered project?
# RUNNER: bin/tests/hygiene-lint.test.sh
# GUARD-TEST: bin/tests/hygiene-lint.test.sh
# GATE: strict
# VERIFIED: 2026-08-07 via bash bin/hygiene-lint.sh (110 FLAGs over 13 projects) and its suite
#
# It checks for the recurring build/deploy failure patterns distilled in
# realisateur's BUILD-DISCIPLINE.md (itself generalized from
# crt/DEV-DISCIPLINE-RETROSPECTIVE-2026-07-23.md): secrets in tracked files,
# build debris tracked as source, finished-but-uncommitted work, missing exec
# bits, silent-pipeline smells, single-value config duplication, stamped-
# checklist drift, stale `verified <date>` claims, self-dev branch/convergence
# drift, and (once, ecosystem-wide) task-shaped entries rotting in scheduler's
# BLOCKERS.md.
#
# Usage:
#   hygiene-lint.sh            scan every registered project, print findings
#   hygiene-lint.sh <name>...  scan only the named project(s)
#                              (skips the ecosystem-wide BLOCKERS.md check)
#   hygiene-lint.sh --strict [<name>...]   exit 1 if any FLAG was printed
#
# Env overrides (used by the tests/fixtures, not normally set):
#   STALE_DAYS=7      age at which a `verified <date>` stamp is flagged
#   BLOCKERS_MD=...   path to the BLOCKERS.md to scan
#   SCHED_ROOT=...    scheduler repo (project registry lives in schedule/*.conf)
#   SHIM_INSTALLER=... path to the install-shims.sh check 10 shells out to
#   REACH_LINT=...      path to the reach-lint.sh check 11 shells out to
#   SILENCE_AUDIT=...   path to the silence-audit.sh check 12 shells out to
#   SELFDEV_BRANCH=main the one branch name all self-dev is expected to be on
#                     (check 8c). Set it here, once, for the whole ecosystem.
#
# Known false-positive class, left in deliberately: BUILD-DISCIPLINE.md's own
# prose DEFINES the `# verified <date> via <cmd>` format, so its example line
# ages like a real claim. Same stance as senechal's base64 test fixture --
# a documented recurring FLAG beats a special case that could hide a real one.
#
# Exit status is 0 by default -- findings are signals, not build failures
# (grep for "FLAG" in the output to
# gate on it, or pass --strict for a hard exit 1 when any FLAG was printed
# (exit 2, via lib/cli-guard.sh, is already "usage error" -- so --strict
# uses 1, matching reach-lint.sh/silence-audit.sh).
set -uo pipefail

CLI_NAME='hygiene-lint.sh'
CLI_SUMMARY='offline-first build-hygiene scan across scheduler-registered projects'
CLI_USAGE='  hygiene-lint.sh            scan every registered project, print findings
  hygiene-lint.sh <name>...  scan only the named project(s)
                             (skips the ecosystem-wide BLOCKERS.md check)
  hygiene-lint.sh --strict [<name>...]   exit 1 if any FLAG was printed'
CLI_FLAGS='--strict'
CLI_EXITS='  0  scanned; no --strict given, or --strict given and nothing FLAGged.
     FINDINGS ARE SIGNALS, NOT FAILURES without --strict -- grep the output
     for "FLAG" to gate on them yourself if you are not using --strict.
  1  --strict was given and at least one FLAG was printed'
CLI_POSITIONAL=any
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
cli_guard "$@"

SCHED_ROOT="${SCHED_ROOT:-${INSTALLE_PROJECTS:-$HOME/Documents/Projects}/scheduler}"

# --strict is a mode flag, not a project name -- strip it before building
# the positional project-filter list (cli_guard validated it but never
# consumes args, per its own contract; each script parses its own).
STRICT=0
want=()
for a in "$@"; do
  case "$a" in
    --strict) STRICT=1 ;;
    *)        want+=("$a") ;;
  esac
done

# --- discover registered projects -----------------------------------------
projects=()
for conf in "$SCHED_ROOT"/schedule/*.conf; do
  name="$(basename "$conf" .conf)"
  case "$name" in _*) continue ;; esac
  grep -q '^PROJECT_REPO_PATH=' "$conf" || continue
  if [ "${#want[@]}" -gt 0 ]; then
    skip=1; for w in "${want[@]}"; do [ "$w" = "$name" ] && skip=0; done
    [ "$skip" -eq 1 ] && continue
  fi
  projects+=("$name")
done
cli_require_matched want projects

echo "hygiene-lint -- $(date '+%Y-%m-%d %H:%M')"
echo "(offline-first: no claude calls -- findings are SIGNALS, not verdicts;"
echo " an intentional binary or a test fixture will show up here. A human/AI"
echo " decides what's real. See realisateur/BUILD-DISCIPLINE.md for the rules."
echo " Grep 'FLAG' to count; this script never edits or fixes anything.)"
echo
echo "== scanning ${#projects[@]} project(s): $(printf '%s,' "${projects[@]}" | sed 's/,$//') =="

# BLIND, ADDED 2026-08-07. Until this existed, an unreadable or absent registry
# produced "== scanning 0 project(s) ==", a full run of every section over
# nothing, and exit 0. Found by bin/tests/guard-estate.test.sh check D, which
# pointed this script at an empty SCHED_ROOT and got `1 total FLAG(s) across 0
# project(s)` with exit 0 -- so it was simultaneously (a) exiting clean having
# looked at nothing and (b) printing section 12's FLAG accusing SILENCE-AUDIT
# of exactly that defect. The null-discriminator was itself undiscriminating.
#
# Exit 3, matching bin/silence-audit.sh's BLIND code. Not 2: 2 is a usage
# error via lib/cli-guard.sh, and "you typed the command wrong" and "the
# registry is not where I was told to look" are different answers.
if [ "${#projects[@]}" -eq 0 ]; then
  echo
  echo "  BLIND: no registered project was readable under $SCHED_ROOT/schedule/"
  echo "  This is 'I could not look', NOT 'nothing to report'. Scanning nothing"
  echo "  and reporting clean is the defect section 12 below exists to detect."
  exit 3
fi

total_flags=0

# Baseline checklist row count, read from the ONE source (BUILD-DISCIPLINE.md's
# own "## Build discipline (realisateur baseline" block) rather than retyped
# here -- check 7b compares each project's stamped copy against it.
BD_MD="$(cd "$(dirname "$0")/.." && pwd)/BUILD-DISCIPLINE.md"
BASELINE_ROWS=0
if [ -f "$BD_MD" ]; then
  BASELINE_ROWS="$(awk '/^## Build discipline \(realisateur baseline/{f=1} f&&/^- \[ \]/{c++} END{print c+0}' "$BD_MD")"
fi

for name in "${projects[@]}"; do
  conf="$SCHED_ROOT/schedule/$name.conf"
  repo="$(grep -oP '(?<=PROJECT_REPO_PATH=")[^"]*' "$conf")"
  # Every conf writes PROJECT_REPO_PATH="$HOME/Documents/Projects/<name>", and
  # grep hands back the LITERAL `$HOME`. Until 2026-08-06 that string was used
  # as a path directly, so `[ -d "$repo/.git" ]` was false for all thirteen
  # registered projects and every per-project check (1-8) `continue`d with
  # "(no git repo at that path -- skipped)". The scan still PRINTED, because
  # checks 10/11/12 shell out to sibling tools that read live state -- so it
  # looked like a working linter reporting a quiet ecosystem. It was reporting
  # nothing at all. BUILD-DISCIPLINE pattern "fails silent"; found by adding
  # check 8c and noticing it never fired anywhere.
  #
  # Expanded by SUBSTITUTION, not eval: a conf is config, and `eval`-ing a
  # path out of it would make a registry entry a code-execution surface.
  # Only the two forms the confs actually use are honored; anything else is
  # left alone and will fail the -d test loudly below.
  case "$repo" in
    '$HOME'/*)  repo="$HOME/${repo#\$HOME/}" ;;
    '${HOME}'/*) repo="$HOME/${repo#\$\{HOME\}/}" ;;
    '~'/*)      repo="$HOME/${repo#\~/}" ;;
  esac
  echo
  echo "############################################################"
  echo "# $name  ($repo)"
  if [ ! -d "$repo/.git" ]; then
    echo "  FLAG [registry] PROJECT_REPO_PATH in $(basename "$conf") does not resolve to a git repo: $repo"
    echo "  (per-project checks skipped for $name -- this is a finding, not a clean result)"
    total_flags=$((total_flags + 1))
    continue
  fi

  n=0  # per-project flag count
  flag() { echo "  FLAG [$1] $2"; n=$((n+1)); }

  # -- tracked files list, reused across checks --
  tracked="$(git -C "$repo" ls-files 2>/dev/null)"

  # 1. SECRETS: tracked files whose NAME looks like a credential/key -----------
  # "secret(s)" must be followed by a non-letter so it can't match "secretary".
  secre='(^|/)([^/]*(secrets?([^a-z]|$)|credential|creds|passwd|apikey|api[_-]key)[^/]*|id_rsa|.*\.(pem|key|p12|pfx|keystore))$'
  # Drop obvious templates -- an *.example/*.sample/*.template secret file is
  # the CORRECT way to ship a config shape without the real value.
  tracked_sec="$(echo "$tracked" | grep -vE '\.(example|sample|template|dist)$')"
  echo "$tracked_sec" | grep -iE "$secre" \
    | while read -r f; do [ -n "$f" ] && echo "  FLAG [secret-file] tracked: $f"; done
  sfiles="$(echo "$tracked_sec" | grep -icE "$secre")"
  [ "${sfiles:-0}" -gt 0 ] && n=$((n+sfiles))

  # 1b. SECRETS: high-signal password/token assignments inside tracked TEXT ----
  # Limit to text files git knows, cap matches so a fixture file can't flood.
  sec_hits="$(git -C "$repo" grep -InE \
      '(password|passwd|secret|api[_-]?key|access[_-]?token|bearer)[[:space:]]*[:=][[:space:]]*.?[A-Za-z0-9/+_-]{12,}' \
      -- . ':(exclude)*.md' ':(exclude)tests/*' ':(exclude)test/*' 2>/dev/null | head -8)"
  if [ -n "$sec_hits" ]; then
    echo "$sec_hits" | while IFS= read -r line; do echo "  FLAG [secret-value] $line"; done
    n=$((n + $(echo "$sec_hits" | grep -c .) ))
  fi

  # 2. BUILD DEBRIS tracked as source (disk images, firmware, archives) --------
  echo "$tracked" | grep -iE '\.(img|img\.xz|img\.gz|iso|efi|dmg|deb|rpm|apk|exe|msi|zip|tar|tar\.gz|tgz|bin)$' \
    | while read -r f; do [ -n "$f" ] && echo "  FLAG [debris] tracked binary/artifact: $f"; done
  dcount="$(echo "$tracked" | grep -icE '\.(img|img\.xz|img\.gz|iso|efi|dmg|deb|rpm|apk|exe|msi|zip|tar|tar\.gz|tgz|bin)$')"
  [ "${dcount:-0}" -gt 0 ] && n=$((n+dcount))

  # 3. FINISHED-BUT-UNCOMMITTED: untracked scripts sitting in bin/ -------------
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in bin/*|*/bin/*) echo "  FLAG [uncommitted] untracked script in bin/: $f"; n=$((n+1)) ;; esac
  done < <(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null | grep -iE '\.(sh|py|pl|rb|js|ts)$')

  # 4. MISSING EXEC BIT: tracked script with a shebang stored non-executable ---
  # git tracks mode: 100644 = non-exec, 100755 = exec. A shebang'd script that
  # is 100644 silently fails to launch (crt hit this twice).
  # Scoped to bin/ -- scripts meant to be *launched* directly (the crt bug
  # class). Test files usually run via a runner, so a non-exec test isn't this.
  while read -r mode _ _ path; do
    case "$mode" in
      100644)
        case "$path" in
          bin/*.sh|bin/*.py|bin/*.pl|bin/*.rb)
            first="$(git -C "$repo" show ":$path" 2>/dev/null | head -c 2)"
            [ "$first" = "#!" ] && { echo "  FLAG [exec-bit] tracked non-executable but has shebang: $path"; n=$((n+1)); }
            ;;
        esac
        ;;
    esac
  done < <(git -C "$repo" ls-files -s 2>/dev/null)

  # 5. SILENT-PIPELINE SMELL: pipefail + an audio/stream tool that SIGPIPEs -----
  # (the exact crt stt-feed.sh bug: pipefail made every arecord|sox pipeline
  # register as failed and silently drop output). Heuristic -- flags for review.
  for sh in $(echo "$tracked" | grep -E '\.sh$' | grep -vE '(^|/)tests?/'); do
    body="$(git -C "$repo" show ":$sh" 2>/dev/null)"
    # Skip this linter itself: it names the audio tools inside its own
    # detection regex, which would otherwise self-flag. Any script that
    # emits the FLAG marker is a silent-pipe *detector*, not a target.
    if echo "$body" | grep -q 'pipefail' \
       && echo "$body" | grep -qE '\b(arecord|aplay|sox|ffmpeg|parec|pacat)\b' \
       && ! echo "$body" | grep -qF 'FLAG [silent-pipe]'; then
      echo "  FLAG [silent-pipe] pipefail + audio/stream pipe (SIGPIPE guard?): $sh"
      n=$((n+1))
    fi
  done

  # 6. CONFIG DUPLICATION: a 4-digit port hardcoded across >=3 tracked files ---
  # Light heuristic for the "same value retyped everywhere" pattern.
  git -C "$repo" grep -hoE ':[0-9]{4}\b|\bport[[:space:]]*[=:][[:space:]]*[0-9]{4}\b' -- . 2>/dev/null \
    | grep -oE '[0-9]{4}' | sort | uniq -c | sort -rn | \
    while read -r cnt port; do
      [ -z "$port" ] && continue
      files="$(git -C "$repo" grep -lE "[:= ]$port\b" -- . 2>/dev/null | wc -l)"
      [ "${files:-0}" -ge 3 ] && echo "  NOTE [config-dup] port $port appears in $files tracked files (single-source it?)"
    done

  # 9. DISPATCH PARITY: a mechanism wired into SOME command files, not all ----
  # BUILD-DISCIPLINE pattern 13's partial-wiring case. Pattern 13 proper is a
  # decision recorded where NOTHING dispatches from; this is the sibling that
  # looks done and isn't -- recorded on the dispatch path you happened to be
  # editing, missing from the one that actually runs unattended.
  #
  # Live case 2026-07-26: precipitation-scan.sh was wired into
  # documented in .claude/commands/ideate.md, but NOT
  # in nightly-batch.md -- so every unattended pass printed promotion-signal
  # reports with no doctrine attached, which is exactly the run with no human
  # present to catch a false positive. Same shape as the .claude/->.scheduler/
  # trace two days earlier.
  #
  # Rule: a script under the project's own bin/ that some command file names
  # should be named by ALL of them. Advisory (NOTE) -- asymmetry is sometimes
  # deliberate (an interactive-only tool), and this script never decides.
  cmd_dir="$repo/.claude/commands"
  if [ -d "$cmd_dir" ]; then
    cmd_files=(); while IFS= read -r c; do cmd_files+=("$c"); done < <(find "$cmd_dir" -maxdepth 1 -name '*.md' | sort)
    if [ "${#cmd_files[@]}" -ge 2 ]; then
      while IFS= read -r script; do
        [ -n "$script" ] || continue
        base="$(basename "$script")"
        naming=(); missing=()
        for c in "${cmd_files[@]}"; do
          if grep -q -- "$base" "$c"; then naming+=("$(basename "$c")"); else missing+=("$(basename "$c")"); fi
        done
        # only interesting if SOME name it and SOME don't
        if [ "${#naming[@]}" -gt 0 ] && [ "${#missing[@]}" -gt 0 ]; then
          echo "  NOTE [dispatch-parity] $base named in $(printf '%s,' "${naming[@]}" | sed 's/,$//') but NOT in $(printf '%s,' "${missing[@]}" | sed 's/,$//')"
        fi
      done < <(git -C "$repo" ls-files 'bin/*.sh' 2>/dev/null)
    fi
  fi

  # 7. BUILD-DISCIPLINE checklist present in CLAUDE.md? ------------------------
  if echo "$tracked" | grep -qx 'CLAUDE.md'; then
    if ! git -C "$repo" grep -qi 'Build discipline' -- CLAUDE.md 2>/dev/null; then
      echo "  NOTE [no-checklist] CLAUDE.md exists but lacks the build-discipline checklist"
    fi
  else
    echo "  NOTE [no-claude-md] no root CLAUDE.md tracked"
  fi

  # 7b. STAMPED-CHECKLIST DRIFT ------------------------------------------------
  # BUILD-DISCIPLINE.md's baseline checklist is COPIED into each project's
  # CLAUDE.md at scaffold time; when the baseline gains a row, every stamped
  # copy silently lags and nothing detects it (incident: three rows added
  # 2026-07-25, nothing noticed). Compare row counts, not text -- a project
  # may legitimately append its OWN rows, so only a SHORTFALL is reported.
  if [ "${BASELINE_ROWS:-0}" -gt 0 ] && echo "$tracked" | grep -qx 'CLAUDE.md'; then
    have="$(git -C "$repo" show ":CLAUDE.md" 2>/dev/null \
            | awk '/^## Build discipline/{f=1} f&&/^- \[ \]/{c++} END{print c+0}')"
    if [ "$have" -gt 0 ] && [ "$have" -lt "$BASELINE_ROWS" ]; then
      echo "  NOTE [checklist-drift] CLAUDE.md checklist has $have row(s), baseline has $BASELINE_ROWS -- restamp from BUILD-DISCIPLINE.md"
    fi
  fi

  # 7c. UNWIRED DEPLOY KEY ------------------------------------------------------
  # A repo whose origin is a bare `git@github.com:` URL while a matching
  # deploy key + ssh alias ALREADY EXIST for it. The key was built and never
  # wired, so every push falls through to the passphrase-protected default
  # identity: interactive sessions get prompted, and an UNATTENDED run blocks
  # on a passphrase prompt nobody is there to answer -- a hang that reads
  # like a network error.
  #
  # Incident (2026-07-26): restamp-discipline.sh --apply pushed to 17 repos
  # and spammed Zach with password prompts. Four of the five SSH repos had a
  # deploy-key alias sitting unused in ~/.ssh/config; `scheduler`, the one
  # that DID use its alias, was silent. This is the build-but-don't-wire
  # pattern applied to credentials.
  #
  # Deliberately checks only for an alias that exists -- it never proposes
  # creating a key, which is a credential decision, not a lint's call.
  origin_url="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
  case "$origin_url" in
    git@github.com:*)
      alias_hit=""
      while read -r h; do
        case "$h" in
          *"$name"*) alias_hit="$h" ;;
        esac
      done < <(grep -oP '(?<=^Host )github-\S+' "$HOME/.ssh/config" 2>/dev/null || true)
      if [ -n "$alias_hit" ]; then
        echo "  FLAG [ssh-remote] origin is bare github.com but alias '$alias_hit' exists -- unused deploy key, pushes will prompt for a passphrase (unattended runs BLOCK)"
        echo "                    fix: git -C \"$repo\" remote set-url origin git@$alias_hit:<path>"
        n=$((n+1))
      else
        echo "  NOTE [ssh-remote] origin is bare github.com with no deploy-key alias -- pushes use the default identity and will prompt"
      fi
      ;;
  esac

  # 8. STALE VERIFIED-CLAIMS ---------------------------------------------------
  # BUILD-DISCIPLINE requires a written claim about system state to carry a
  # `# verified <date> via <command>` stamp. A stamp doesn't expire on its own:
  # the incident was an assertion about another host's crontab that outlived
  # its truth by a day and became an audit's #1 finding. Flag stamps older
  # than STALE_DAYS so the claim gets re-probed rather than re-quoted.
  # Excludes this linter (it names the stamp format in its own prose).
  STALE_DAYS="${STALE_DAYS:-7}"
  now_s=$(date +%s)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    d="$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)"
    [ -z "$d" ] && continue
    then_s="$(date -d "$d" +%s 2>/dev/null)" || continue
    age=$(( (now_s - then_s) / 86400 ))
    [ "$age" -le "$STALE_DAYS" ] && continue
    flag "stale-claim" "$age days old, re-probe: $(echo "$line" | cut -c1-140)"
  done < <(git -C "$repo" grep -InE 'verified[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}' \
             -- . ':(exclude)bin/hygiene-lint.sh' 2>/dev/null | head -8)

  # 8b. UNSTAMPED STATE ASSERTIONS in config comments (advisory) ---------------
  # Heuristic half of the same rule: a .conf comment asserting a fact about
  # the live system with NO stamp at all. Noisier than 8 (prose varies), so
  # NOTE not FLAG -- it points at a line to stamp, it doesn't claim it's wrong.
  git -C "$repo" grep -InE '^[[:space:]]*#.*\b(confirmed|no crontab|does not exist|already (exists|installed|running)|is (running|enabled|empty))\b' \
      -- '*.conf' 2>/dev/null | grep -viE 'verified[[:space:]]+[0-9]{4}' | head -4 \
    | while IFS= read -r l; do [ -n "$l" ] && echo "  NOTE [unstamped-claim] $(echo "$l" | cut -c1-140)"; done

  # 8c. SELF-DEV BRANCH DISCIPLINE + CONVERGENCE ------------------------------
  # Zach's Decision 3 (2026-08-06): all self-dev on ONE consistently named
  # branch, `main` for now -- stated as an ecosystem convention rather than a
  # per-project fix, "because git branch discipline is severely lacking on
  # Zach's side, so the solution must anticipate that." A convention that only
  # exists as prose anticipates nothing; this is the checkable form of it.
  #
  # TWO checks, because the vim-arcade case proved one is not enough. That
  # project was ALREADY on main -- Decision 3's stated action was a no-op --
  # and it still could not converge, because a read-only deploy key turns every
  # local commit into a permanent PULL WARNING (scheduler#38). So the branch
  # NAME is only half the question; the other half is whether the branch can
  # actually reach its remote. An unpushed-ahead count that never falls is the
  # observable form of "this checkout is diverging from where the batch reads".
  #
  # SELFDEV_BRANCH overrides the convention for the whole ecosystem, from one
  # place, if `main` is ever traded for a development branch (Zach's stated
  # second preference). Do not special-case a project by editing this script.
  SELFDEV_BRANCH="${SELFDEV_BRANCH:-main}"
  cur_branch="$(git -C "$repo" branch --show-current 2>/dev/null)"
  if [ -z "$cur_branch" ]; then
    flag "branch" "detached HEAD -- self-dev commits here reach no branch at all"
  elif [ "$cur_branch" != "$SELFDEV_BRANCH" ]; then
    flag "branch" "checked out on '$cur_branch', ecosystem convention is '$SELFDEV_BRANCH' (SELFDEV_BRANCH to change it ecosystem-wide)"
  fi
  # Convergence: ahead-of-upstream is only meaningful against a real upstream.
  # No upstream at all is itself the finding -- a self-dev checkout whose
  # commits have nowhere to land. Deliberately NOT fetching: this script is
  # offline-first, so this reads the last-known remote state and says so.
  up="$(git -C "$repo" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)"
  if [ -z "$up" ]; then
    flag "branch-noremote" "'${cur_branch:-HEAD}' tracks no upstream -- self-dev commits have nowhere to land"
  else
    ahead="$(git -C "$repo" rev-list --count "$up..HEAD" 2>/dev/null || echo 0)"
    if [ "${ahead:-0}" -gt 0 ]; then
      flag "branch-unpushed" "$ahead commit(s) ahead of $up (offline count, not re-fetched) -- if this never falls to 0, the push path is broken, not the branch (cf. scheduler#38, read-only deploy key)"
    fi
  fi

  if [ "$n" -eq 0 ]; then
    echo "  clean -- no mechanical flags (NOTEs above, if any, are advisory)"
  else
    echo "  -> $n FLAG(s) for this project"
  fi
  total_flags=$((total_flags+n))
done

# 9. TASK-SHAPED ENTRIES IN scheduler's BLOCKERS.md --------------------------
# Mechanical half of BUILD-DISCIPLINE failure pattern 13 ("a decision without
# a dispatch path"). BLOCKERS.md is by standing rule NOT a work queue -- it is
# where things blocked ON THE HUMAN are surfaced. A task-shaped entry parked
# there is rot by definition: nothing dispatches from that file, so the work
# is invisible to every project's own runs. Incident: the 2026-07-24
# `.scheduler/` migration decision sat there 2 days while three projects
# independently re-derived it.
#
# Ecosystem-scoped (one shared file), so it runs ONCE after the per-project
# loop rather than per project. An entry is exempt if it carries a `> ` answer
# (the human replied) or names a dispatch path (OBLIGATION / dispatch / queued
# / routed / filed in <project>'s FOCUS) -- that's the difference between rot
# and a deliberate pointer.
BLOCKERS_MD="${BLOCKERS_MD:-$SCHED_ROOT/BLOCKERS.md}"
if [ "${#want[@]}" -eq 0 ] && [ -f "$BLOCKERS_MD" ]; then
  echo
  echo "############################################################"
  echo "# scheduler BLOCKERS.md  ($BLOCKERS_MD)"
  bl_out="$(awk '
    function emit(   i) {
      if (!inentry) return
      if (body ~ /(filed for an async pass|NOT DONE|not done|not completed|TODO|next step:)/ &&
          body !~ /(^|\n)[[:space:]]*> / &&
          body !~ /(OBLIGATION|dispatch|queued|routed)/)
        printf "  FLAG [blockers-task] %s:%d (## %s) %s\n", "BLOCKERS.md", start, sect, first
      inentry = 0; body = ""
    }
    /^## /   { emit(); sect = substr($0, 4) }
    /^- /    { emit(); inentry = 1; start = NR; first = substr($0, 1, 100); body = $0; next }
    inentry  { body = body "\n" $0 }
    END      { emit() }
  ' "$BLOCKERS_MD")"
  if [ -n "$bl_out" ]; then
    echo "$bl_out"
    bl_n="$(echo "$bl_out" | grep -c .)"
    total_flags=$((total_flags + bl_n))
  else
    echo "  clean -- no task-shaped entries without a dispatch path"
  fi
fi

# 10. INSTALLED-SHIM DRIFT ---------------------------------------------------
# The user-level /ideate and /cloture in ~/.claude/commands and the PATH
# shims in ~/.local/bin are RENDERED from this repo. Editing the source
# without rerunning the installer leaves every other repo running the old
# text -- silently, since the stale copy still works. This is the wiring
# that makes bin/install-shims.sh a real path rather than a one-shot deploy.
echo
echo "== 10. INSTALLED SHIM / USER-COMMAND DRIFT =="
SHIM_INSTALLER="${SHIM_INSTALLER:-$(dirname "${BASH_SOURCE[0]}")/install-shims.sh}"
if [ ! -x "$SHIM_INSTALLER" ]; then
  echo "  FLAG [shim-drift] install-shims.sh missing or not executable -- cannot verify"
  total_flags=$((total_flags + 1))
else
  shim_out="$("$SHIM_INSTALLER" --check 2>&1)"
  if [ $? -eq 0 ]; then
    echo "  clean -- ~/.local/bin shims and ~/.claude/commands match this repo"
  else
    echo "$shim_out" |  grep '^FLAG:' | sed 's|^FLAG: |  FLAG [shim-drift] |'
    shim_n="$(echo "$shim_out" | grep -c '^FLAG:')"
    total_flags=$((total_flags + shim_n))
    echo "  -> rerun: bin/install-shims.sh"
  fi
fi

# 11. COMMAND SCOPE + REACH -------------------------------------------------
# Pattern 13c: an instruction file whose named commands the reading executor
# cannot resolve. Check 10 above catches an installed copy drifting from
# source; this catches the question that was never asked in the first place
# (should this command be user-level?) and the case where a user-level file
# names something that only resolves inside realisateur.
echo
echo "== 11. COMMAND SCOPE / REACH =="
REACH_LINT="${REACH_LINT:-$(dirname "${BASH_SOURCE[0]}")/reach-lint.sh}"
if [ ! -x "$REACH_LINT" ]; then
  echo "  FLAG [reach] reach-lint.sh missing or not executable -- cannot verify"
  total_flags=$((total_flags + 1))
else
  reach_out="$("$REACH_LINT" 2>&1 | grep '^  FLAG ')"
  if [ -z "$reach_out" ]; then
    echo "  clean -- every command file declares a scope; all user-level names resolve"
  else
    echo "$reach_out"
    total_flags=$((total_flags + $(echo "$reach_out" | grep -c .) ))
    echo "  -> full report: bin/reach-lint.sh"
  fi
fi

# Pattern 2 (build-but-don't-wire): silence-audit asks whether a mechanism
# can tell "nothing there" apart from "could not look" and "did not look".
# It is dispatched HERE because its own self-wiring banner tests exactly
# three things -- a crontab line, a systemd unit, or a hygiene-lint check --
# and a PATH shim satisfies none of them. An auditor of unwired mechanisms
# that is itself unwired is the joke writing itself, in its own words.
#
# The exit code is READ, not discarded. The staging draft of this block ended
# in `|| true`, which would have made a null-discriminator incapable of
# reporting a null -- exit 3 is BLIND ("parsed zero mechanisms"), and that is
# the one result that must never render as clean.
echo
echo "== 12. NULL-DISCRIMINATION (silence-audit) =="
SILENCE_AUDIT="${SILENCE_AUDIT:-$(dirname "${BASH_SOURCE[0]}")/silence-audit.sh}"
if [ ! -x "$SILENCE_AUDIT" ]; then
  echo "  FLAG [silence] silence-audit.sh missing or not executable -- cannot verify"
  total_flags=$((total_flags + 1))
else
  sa_out="$("$SILENCE_AUDIT" 2>&1)"; sa_rc=$?
  sa_flags="$(printf '%s\n' "$sa_out" | grep '^  FLAG ')"
  sa_n="$(printf '%s\n' "$sa_flags" | grep -c . )"
  if [ "$sa_rc" -eq 3 ]; then
    echo "  FLAG [silence-blind] silence-audit parsed ZERO mechanisms -- domain unreadable."
    echo "    This is NOT a clean result; it is the defect silence-audit detects."
    total_flags=$((total_flags + 1))
  elif [ "$sa_n" -eq 0 ]; then
    echo "  clean -- every audited mechanism can distinguish empty from unreadable"
  else
    printf '%s\n' "$sa_flags" | head -8
    [ "$sa_n" -gt 8 ] && echo "    ... $(( sa_n - 8 )) more"
    total_flags=$((total_flags + sa_n))
    echo "  -> full report: bin/silence-audit.sh"
  fi
fi

echo
echo "############################################################"
echo "== $total_flags total FLAG(s) across ${#projects[@]} project(s) =="
echo "FLAGs are candidates, not confirmed problems -- a human/AI confirms"
echo "each before acting. NOTEs are advisory. See BUILD-DISCIPLINE.md."
[ "$STRICT" = 1 ] && [ "$total_flags" -gt 0 ] && exit 1
exit 0
