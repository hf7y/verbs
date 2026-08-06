#!/usr/bin/env bash
# silence-audit.sh -- the ecosystem's NULL-DISCRIMINATOR.
#
# Offline-first (zero AI), writes nothing, exits 0 unless --strict.
#
# WHAT IS MISSING THAT THIS SUPPLIES
# ----------------------------------
# Every existing survey here answers "what is the state of the projects?".
# None answers "can this sensor tell the difference between nothing-there,
# could-not-look, and did-not-look?". Those are three distinct world-states
# and every mechanism in this ecosystem currently maps all three onto one
# output symbol: silence. Ashby's Law is usually applied to the regulator's
# effectors -- R's variety must match D's. It binds just as hard on the
# SENSOR: a sensor with one output symbol cannot regulate a domain with
# three states, and no quantity of added checks fixes that. You must add
# output symbols. That is the entire thesis of this script, and it is why
# it audits MECHANISMS rather than projects.
#
# The cost of getting this wrong is asymmetric in the expensive direction
# (BUILD-DISCIPLINE pattern 14): these tools fail toward alarm, and alarm is
# routed to the scarcest organ in the system, which is Zach's attention.
#
# CHECKS -- each names the domain it read, and reports BLIND when it could
# not read that domain rather than reporting clean.
#
#   [mute-null]         a script scans a domain and has no branch for the
#                       domain being empty -- so "found nothing" and "the
#                       glob did not match" print identically (nothing).
#   [self-witness]      a scheduled entry sends all output to /dev/null, so
#                       the only evidence it ran is what it writes about
#                       itself. Pattern 9 moved down a level: the actor is
#                       sole source of truth for whether it RAN.
#   [home-scoped]       a sensor resolves job state under $HOME while the
#                       ecosystem dispatches from more than one account, so
#                       it silently reports on half the ecosystem as if it
#                       were the whole. Found live 2026-07-28.
#   [stderr-silenced]   a privileged/probing command with 2>/dev/null --
#                       turns "permission denied" into "clean". Its own
#                       domain read (repo/bin) is subject to the same rule:
#                       an unreadable bin/ is BLIND, not a clean scan.
#   [unwired]           an executable mechanism named by no crontab, no
#                       command file, no systemd unit and no other script.
#                       Built, never dispatched. Same BLIND rule as above --
#                       an unreadable bin/ cannot be asserted "named nowhere".
#   [prose-only-rule]   a doc asserts a checkable rule for which no
#                       executable check exists -- an unretired layer
#                       waiting to happen.
#   [retirement-open]   a change claims a retirement (RETIRES:/Retires:)
#                       whose literal is still live somewhere. "Names what
#                       it retires" is satisfied by the thing being GONE,
#                       not by a commit message saying so.
#
# The four below were added 2026-07-28, after one interactive session ran
# bin/decide.sh options 1,2,4,5,6,7 and produced four distinct failures that
# every check above was blind to. Each names its motivating incident,
# because a check whose original failure is not recorded gets deleted by the
# next person who finds it noisy.
#
#   [dirty-writer]      a script edits files in OTHER repos and has no
#                       commit path of its own, so a successful run leaves N
#                       dirty trees and calls that done.
#                       install-silence-audit.sh left 19; the */15 sweep
#                       then adopted them under a different identity.
#   [worktree-backed]   an installed ~/.local/bin entry resolves into a git
#                       WORKTREE rather than a permanent checkout. Merge the
#                       branch, prune the worktree, and a machine-wide
#                       command dies silently. Live 2026-07-28:
#                       ~/.local/bin/silence-audit -> a staging worktree.
#   [twin]              byte-identical executables, or a mechanism copied
#                       instead of sourced, in two places. Copies drift:
#                       aedile's hand-pasted dead-man switch lost the
#                       notify-send and the renewal gotcha that the shared
#                       lib's version carries, on the day it was pasted.
#   [subrepo-invisible] a registered project whose PROJECT_REPO_PATH is not
#                       a repo ROOT. Every [ -d "$repo/.git" ] test in the
#                       ecosystem skips it, so it is exempt from sweeps and
#                       health checks while still looking registered. aedile
#                       stayed dirty through a sweep that cleaned 15 siblings.
#
# Usage:
#   silence-audit.sh                  audit the whole ecosystem
#   silence-audit.sh <project>        audit one registered project
#   silence-audit.sh --strict         exit 1 if any FLAG (for hooks/CI)
#   silence-audit.sh --self-test      run the built-in fixtures, exit 1 on fail
#
# Exit codes: 0 clean-or-advisory, 1 --strict with FLAGs or self-test fail,
#             3 BLIND (parsed zero mechanisms -- see below).
#
# BLIND is non-negotiable and is the whole point. A checker that scans an
# empty domain and prints nothing reads exactly like a checker that scanned
# everything and found everything healthy. If this script parses zero
# mechanisms it exits 3 and says so, because that is the same defect it
# exists to find, and a tool that commits its own named failure mode is
# worth nothing.
set -uo pipefail

SCHED_ROOT="${SCHED_ROOT:-$HOME/Documents/Projects/scheduler}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || REPO=""

STRICT=0
ONLY=""
SELFTEST=0   # deliberately NOT read from the environment. It used to be, and
             # the self-test's own child invocations inherited it and recursed
             # until the harness killed them -- a mute hang, found 2026-07-28
             # while building this. An env-readable mode flag is the same
             # class of defect this script audits: a state the caller cannot
             # see from the outside.
case "${1:-}" in
  --strict)    STRICT=1 ;;
  --self-test) SELFTEST=1 ;;
  -h|--help)   sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
  "")          ;;
  --*)         echo "unknown flag: $1" >&2; exit 2 ;;
  *)           ONLY="$1" ;;
esac

flags=0
mechanisms=0
projects_seen=0
flag() { echo "  FLAG [$1] $2"; flags=$((flags+1)); }
note() { echo "  NOTE [$1] $2"; }

# ---------------------------------------------------------------- domains
# Everything below reports the domain it actually read. A negative is only
# ever asserted over that domain, never over "the ecosystem".

read_crontabs() {
  # Returns "account<TAB>line" for every crontab we can actually read.
  # Domain is reported by the caller; an account we cannot read is BLIND,
  # NOT clean -- that distinction is the reason this function exists.
  #
  # CRONTAB_LIST, if set, is a file of pre-built "acct<TAB>line" rows read
  # verbatim instead of the live crontab. It exists only so self-witness and
  # home-scoped -- both keyed on crontab content -- can be fixtured
  # hermetically instead of depending on whatever this account's real
  # crontab happens to contain today. Unset in every real run.
  if [ -n "${CRONTAB_LIST:-}" ]; then
    cat "$CRONTAB_LIST" 2>/dev/null
    return
  fi
  local acct
  crontab -l 2>/dev/null | sed "s/^/$(id -un)\t/"
  for acct in $(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1}'); do
    [ "$acct" = "$(id -un)" ] && continue
    if sudo -n -u "$acct" crontab -l >/dev/null 2>&1; then
      sudo -n -u "$acct" crontab -l 2>/dev/null | sed "s/^/$acct\t/"
    else
      echo -e "$acct\t#BLIND# cannot read crontab for $acct (no NOPASSWD sudo)"
    fi
  done
}

project_repos() {
  local conf name repo
  for conf in "$SCHED_ROOT"/schedule/*.conf; do
    [ -f "$conf" ] || continue
    name="$(basename "$conf" .conf)"
    case "$name" in _*) continue ;; esac
    [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue
    # Sourced, not grepped: confs write PROJECT_REPO_PATH="$HOME/..." (portable
    # by design), so a static grep -oP extraction returns the literal
    # unexpanded string and every [ -d "$repo" ] silently misses -- the same
    # BLIND-as-clean defect install-silence-audit.sh had (fixed 36b20aa).
    # Matches scheduler/bin/sync-crontab.sh's own established pattern.
    repo="$(unset PROJECT_REPO_PATH; . "$conf" 2>/dev/null; echo "${PROJECT_REPO_PATH:-}")"
    [ -n "$repo" ] && [ -d "$repo" ] && echo -e "$name\t$repo"
  done
}

project_repos_and_worktrees() {
  # project_repos plus every git worktree of those repos. Separate from
  # project_repos on purpose: worktrees are NOT registered projects and must
  # not inflate projects_seen (the BLIND denominator). Only checks that
  # genuinely care about on-disk copies use this.
  local name repo wt
  while IFS=$'\t' read -r name repo; do
    [ -z "${repo:-}" ] && continue
    printf '%s\t%s\n' "$name" "$repo"
    while IFS= read -r wt; do
      [ -n "$wt" ] || continue
      [ "$wt" = "$repo" ] && continue
      [ -d "$wt/bin" ] || continue
      printf '%s\t%s\n' "$name(worktree)" "$wt"
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null \
               | awk '/^worktree /{print $2}')
  done < <(project_repos)
}

# Counted ONCE, up front, so BLIND is keyed on the domain this script is
# actually about (registered projects) rather than on a total that other
# checks can quietly inflate. The first cut of this script keyed BLIND on a
# global mechanism counter, and real crontab lines kept the count above zero
# even when zero projects were parsed -- so an unreadable schedule/ dir
# reported "clean". That is the defect, committed by the detector.
projects_seen="$(project_repos | grep -c . || true)"

# ---------------------------------------------------------------- checks

check_mute_null() {
  # A script that iterates a discovered domain must have SOME branch for
  # that domain being empty. Low-false-positive form: we only look at
  # scripts that clearly scan (mapfile from a process substitution, or a
  # for-loop over a glob/command substitution), and we accept any of the
  # recognised empty-signals as satisfying the check.
  local name repo sh body
  while IFS=$'\t' read -r name repo; do
    [ -z "${repo:-}" ] && continue
    if [ -d "$repo/bin" ] && [ ! -r "$repo/bin" ]; then
      note blind "mute-null: $name/bin exists but is not readable -- NOT audited"
      continue
    fi
    while IFS= read -r sh; do
      [ -f "$sh" ] || continue
      mechanisms=$((mechanisms+1))
      body="$(cat "$sh" 2>/dev/null)" || continue
      # does it scan a domain?
      echo "$body" | grep -qE 'mapfile -t [A-Za-z_]+ < <\(|for [A-Za-z_]+ in .*\*|for [A-Za-z_]+ in \$\(' || continue
      # does it have any empty-domain signal at all?
      echo "$body" | grep -qiE 'BLIND|NOT[- ]PROBEABLE|no .* found|nothing to |none found|-eq 0 \]|\[ -z "\$' && continue
      flag mute-null "$name: $(basename "$sh") scans a domain with no empty-domain branch"
    done < <(find "$repo/bin" -maxdepth 1 -name '*.sh' -type f 2>/dev/null)
  done < <(project_repos)
}

check_self_witness() {
  # A cron line that discards all output has no witness but itself.
  local acct line cmd
  while IFS=$'\t' read -r acct line; do
    case "$line" in \#BLIND#*) note blind "crontab: $line"; continue ;; esac
    case "$line" in ''|\#*) continue ;; esac
    mechanisms=$((mechanisms+1))
    cmd="${line#*[0-9] }"
    if echo "$line" | grep -qE '>[[:space:]]*/dev/null[[:space:]]*2>&1|>/dev/null 2>&1'; then
      flag self-witness "$acct: cron entry discards all output -- only self-written logs witness it: ${cmd:0:70}"
    fi
  done < <(read_crontabs)
}

check_home_scoped() {
  # Count dispatch accounts first. With one account, $HOME-scoping is
  # correct and this check must stay quiet -- it is only a defect when the
  # ecosystem actually spans accounts.
  local accts name repo sh
  accts="$(read_crontabs | grep -cE $'\t[0-9*]' || true)"
  local n_acct
  n_acct="$(read_crontabs | grep -E $'\t[0-9*]' | cut -f1 | sort -u | wc -l)"
  if [ "${n_acct:-0}" -lt 2 ]; then
    note home-scoped "single dispatch account -- \$HOME-scoped sensors are correct here, check skipped"
    return
  fi
  while IFS=$'\t' read -r name repo; do
    [ -z "${repo:-}" ] && continue
    if [ -d "$repo/bin" ] && [ ! -r "$repo/bin" ]; then
      note blind "home-scoped: $name/bin exists but is not readable -- NOT audited"
      continue
    fi
    while IFS= read -r sh; do
      [ -f "$sh" ] || continue
      # reads per-job run state under $HOME, but never mentions another account
      if grep -qE '\$HOME/\.local/share|~/\.local/share' "$sh" 2>/dev/null \
         && ! grep -qE 'CRON_ACCOUNT|sudo -n -u|-u "\$acct"' "$sh" 2>/dev/null; then
        flag home-scoped "$name: $(basename "$sh") reads job state under \$HOME only, but $n_acct accounts dispatch"
      fi
    done < <(find "$repo/bin" -maxdepth 1 -name '*.sh' -type f 2>/dev/null)
  done < <(project_repos)
}

check_stderr_silenced() {
  local name repo hit
  while IFS=$'\t' read -r name repo; do
    [ -z "${repo:-}" ] && continue
    if [ -d "$repo/bin" ] && [ ! -r "$repo/bin" ]; then
      note blind "stderr-silenced: $name/bin exists but is not readable -- NOT audited"
      continue
    fi
    while IFS= read -r hit; do
      [ -n "$hit" ] && flag stderr-silenced "$name: $hit"
    done < <(
      grep -rnE '(sudo|systemctl|crontab|ssh|journalctl)[^|;]*2>[[:space:]]*/dev/null' \
        "$repo/bin" 2>/dev/null | grep -vE '^\s*#' | cut -c1-160 | head -5
    )
  done < <(project_repos)
}

check_unwired() {
  # A mechanism nothing names. Domain read: this project's own bin/, every
  # readable crontab, this project's command files, and every other script
  # in the same repo.
  local name repo sh base crontab_blob
  crontab_blob="$(read_crontabs)"
  while IFS=$'\t' read -r name repo; do
    [ -z "${repo:-}" ] && continue
    if [ -d "$repo/bin" ] && [ ! -r "$repo/bin" ]; then
      note blind "unwired: $name/bin exists but is not readable -- NOT audited"
      continue
    fi
    while IFS= read -r sh; do
      [ -f "$sh" ] || continue
      base="$(basename "$sh")"
      # named anywhere?
      grep -qF "$base" <<<"$crontab_blob" && continue
      grep -rqF "$base" "$repo" --include='*.md' --include='*.conf' \
        --include='*.service' --include='*.timer' 2>/dev/null && continue
      grep -rqF "$base" "$repo/bin" --include='*.sh' \
        --exclude="$base" 2>/dev/null && continue
      grep -rqF "$base" "$SCHED_ROOT/schedule" 2>/dev/null && continue
      flag unwired "$name: bin/$base is named by no crontab, doc, conf, unit or sibling script"
    done < <(find "$repo/bin" -maxdepth 1 -name '*.sh' -type f 2>/dev/null)
  done < <(project_repos)
}

check_dirty_writer() {
  # Incident 2026-07-28: install-silence-audit.sh --commit edited CLAUDE.md
  # in 19 registered repos and contained no `git add` and no `git commit`.
  # It exited 0. "Success" and "left 19 dirty trees" were the same symbol --
  # which is this script's whole thesis, applied to a writer instead of a
  # sensor. CLAUDE.md already calls a dirty tree at exit a failed run; this
  # is that rule, checkable.
  #
  # Narrow on purpose: only scripts that BOTH reach across repos (they read
  # the scheduler's registry or iterate project paths) AND mutate files in
  # place. A script that writes only inside its own repo is not this.
  local name repo sh base
  while IFS=$'\t' read -r name repo; do
    [ -z "${repo:-}" ] && continue
    if [ -d "$repo/bin" ] && [ ! -r "$repo/bin" ]; then
      note blind "dirty-writer: $name/bin exists but is not readable -- NOT audited"
      continue
    fi
    while IFS= read -r sh; do
      [ -f "$sh" ] || continue
      base="$(basename "$sh")"
      # (a) does it reach across repos?
      grep -qE 'PROJECT_REPO_PATH|schedule/\*\.conf|SCHED_ROOT' "$sh" 2>/dev/null || continue
      # (b) does it mutate files in place?
      grep -qE '(sed -i|tee "?\$|>[[:space:]]*"\$\{?(repo|REPO|target|TARGET)|mv -f|cp .* "\$)' "$sh" 2>/dev/null || continue
      # (c) does it have ANY commit path of its own?
      grep -qE 'git .*commit|focus-commit' "$sh" 2>/dev/null && continue
      flag dirty-writer "$name: bin/$base edits other repos but never commits -- a clean exit leaves dirty trees indistinguishable from success"
    done < <(find "$repo/bin" -maxdepth 1 -name '*.sh' -type f 2>/dev/null)
  done < <(project_repos)
}

check_worktree_backed() {
  # Incident 2026-07-28: ~/.local/bin/silence-audit was installed as a
  # symlink into realisateur-staging-silence-audit, a git worktree on branch
  # staging/silence-audit. Merging that branch and pruning the worktree
  # removes a machine-wide command with no error anywhere -- the install
  # looks permanent and is not.
  #
  # Domain: ~/.local/bin. Unreadable domain is BLIND, never clean.
  local bindir="${LOCAL_BIN:-$HOME/.local/bin}" entry target dir gitdir
  if [ ! -d "$bindir" ]; then
    note blind "worktree-backed: $bindir does not exist or is unreadable -- NOT audited"
    return
  fi
  while IFS= read -r entry; do
    [ -L "$entry" ] || continue
    target="$(readlink -f "$entry" 2>/dev/null)" || continue
    [ -n "$target" ] && [ -e "$target" ] || {
      flag worktree-backed "$(basename "$entry") -> DANGLING ($(readlink "$entry"))"
      continue
    }
    dir="$(dirname "$target")"
    # A worktree's .git is a FILE containing "gitdir: ...", not a directory.
    gitdir="$(git -C "$dir" rev-parse --git-dir 2>/dev/null)" || continue
    if [ -f "$dir/.git" ] || [ -f "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)/.git" ]; then
      flag worktree-backed "$(basename "$entry") -> $target lives in a git WORKTREE, not a permanent checkout -- pruning the worktree deletes this command silently"
    fi
  done < <(find "$bindir" -maxdepth 1 -type l 2>/dev/null)
}

check_twin() {
  # Incident 2026-07-28, two shapes in one day:
  #   (a) bin/silence-audit.sh byte-identical in ecosim and in a realisateur
  #       worktree, with the live PATH symlink pointing at the copy;
  #   (b) the dead-man switch hand-pasted into aedile's wrapper while
  #       lib/sweep-loop-common.sh already implemented it -- and the copy
  #       immediately differed (no notify-send, no "bumping EXPIRY_DAYS does
  #       not renew" warning).
  # Only (a) is mechanically detectable from file content, so that is what
  # this checks. It does NOT claim to find every copied mechanism, and says
  # so rather than implying coverage it lacks.
  #
  # Scans registered repos AND their git worktrees. The worktree half is not
  # decoration: the first cut of this check scanned registered repos only,
  # and so did NOT catch the very duplicate that motivated it -- the second
  # copy of this file lives in a worktree, which is not a registered project.
  # A check blind to its own founding incident is worse than no check,
  # because it reports clean over the case you built it for.
  local name repo sh sum base
  local -a sums=() paths=() owners=()
  while IFS=$'\t' read -r name repo; do
    [ -z "${repo:-}" ] && continue
    if [ -d "$repo/bin" ] && [ ! -r "$repo/bin" ]; then
      note blind "twin: $name/bin exists but is not readable -- NOT audited"
      continue
    fi
    while IFS= read -r sh; do
      [ -f "$sh" ] || continue
      sum="$(md5sum "$sh" 2>/dev/null | cut -d' ' -f1)"
      [ -n "$sum" ] || continue
      local i found="" found_owner="" owner
      # Owner = the PROJECT, with any "(worktree)" suffix stripped. A repo and
      # its own worktree share files by definition -- flagging that is pure
      # noise, and the first live run produced a screenful of it. The real
      # signal is the same file in two DIFFERENT projects, which is what the
      # founding incident was (ecosim's silence-audit.sh vs a realisateur
      # worktree's copy).
      owner="${name%(worktree)}"
      for i in "${!sums[@]}"; do
        if [ "${sums[$i]}" = "$sum" ] && [ "${owners[$i]}" != "$owner" ]; then
          found="${paths[$i]}"; found_owner="${owners[$i]}"; break
        fi
      done
      if [ -n "$found" ]; then
        base="$(basename "$sh")"
        flag twin "$owner: bin/$base is byte-identical to $found_owner's copy at $found -- two projects, one file, and only one of them will get the next edit"
      fi
      sums+=("$sum"); paths+=("$sh"); owners+=("$owner")
    done < <(find "$repo/bin" -maxdepth 1 -name '*.sh' -type f 2>/dev/null)
  done < <(project_repos_and_worktrees)
}

check_subrepo_invisible() {
  # Incident 2026-07-28: the */15 scheduler sweep committed dirty CLAUDE.md
  # in 15 repos and skipped aedile, whose PROJECT_REPO_PATH points at a
  # SUBDIRECTORY of the wavebucks monorepo. bin/scheduler's git-health test
  # is [ -d "$repo_path/.git" ], a literal directory test that a monorepo
  # subdirectory always fails. The project stays registered, stays dispatched,
  # and is silently exempt from every repo-level check. Known since
  # 2026-07-24 and still live.
  local name repo top
  while IFS=$'\t' read -r name repo; do
    [ -z "${repo:-}" ] && continue
    top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || continue
    [ -n "$top" ] || continue
    if [ "$top" != "$repo" ]; then
      flag subrepo-invisible "$name: PROJECT_REPO_PATH=$repo is not a repo root (root is $top) -- every [ -d \$repo/.git ] check in the ecosystem skips it while it still reads as registered"
    fi
  done < <(project_repos)
}

check_prose_only_rule() {
  # A checklist line asserting a rule, in a repo that has a bin/, where no
  # script mentions the rule's distinctive literal. Deliberately narrow:
  # only checklist rows ("- [ ] ...") in discipline docs, only when the row
  # carries a backticked literal we can actually search for.
  local name repo doc lit row
  while IFS=$'\t' read -r name repo; do
    [ -z "${repo:-}" ] && continue
    [ -d "$repo/bin" ] || continue
    if [ ! -r "$repo/bin" ]; then
      note blind "prose-only-rule: $name/bin exists but is not readable -- NOT audited"
      continue
    fi
    for doc in "$repo/BUILD-DISCIPLINE.md" "$repo/CLAUDE.md"; do
      [ -f "$doc" ] || continue
      mechanisms=$((mechanisms+1))
      while IFS= read -r row; do
        lit="$(grep -oP '(?<=`)[^`]{4,40}(?=`)' <<<"$row" | head -1)"
        [ -z "${lit:-}" ] && continue
        grep -rqF -- "$lit" "$repo/bin" 2>/dev/null && continue
        flag prose-only-rule "$name: $(basename "$doc") asserts \`$lit\` but no script in bin/ checks it"
      done < <(grep -E '^- \[ \]' "$doc" 2>/dev/null)
    done
  done < <(project_repos)
}

check_retirement_open() {
  # A retirement claim whose literal is still live. This is the mechanical
  # form of "names what it retires": satisfaction means GONE, not stated.
  local name repo claim lit live
  while IFS=$'\t' read -r name repo; do
    [ -z "${repo:-}" ] && continue
    while IFS= read -r claim; do
      lit="$(sed -E 's/.*RETIRES:[[:space:]]*//; s/[[:space:]]*$//' <<<"$claim")"
      [ -z "${lit:-}" ] && continue
      mechanisms=$((mechanisms+1))
      # count live occurrences OUTSIDE any line that is itself a retirement notice
      live="$(grep -rF -- "$lit" "$repo" \
                --include='*.md' --include='*.sh' --include='*.conf' 2>/dev/null \
              | grep -vF 'RETIRES:' | wc -l)"
      if [ "${live:-0}" -gt 0 ]; then
        flag retirement-open "$name: claims to retire \`$lit\` -- $live live occurrence(s) remain"
      fi
    done < <(grep -rhE 'RETIRES:' "$repo" --include='*.sh' --include='*.md' 2>/dev/null)
  done < <(project_repos)
}

# ---------------------------------------------------------------- self-test
# Fixtures, not exit codes. Each asserts the check FIRES on a known-bad
# input and STAYS QUIET on a known-good one -- a lint that only ever passes
# is the mute-null defect wearing a lint's clothes.
self_test() {
  local tmp rc=0 out out2acct
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/proj/bin"

  t() { # name expected_regex actual
    if grep -qE "$2" <<<"$3"; then echo "  ok   $1"; else
      echo "  FAIL $1 (expected /$2/)"; rc=1; fi
  }
  tn() { # name unexpected_regex actual
    if grep -qE "$2" <<<"$3"; then echo "  FAIL $1 (should not have matched /$2/)"; rc=1
    else echo "  ok   $1"; fi
  }

  echo "== self-test =="

  # --- mute-null fires on a scanner with no empty branch
  cat >"$tmp/proj/bin/bad.sh" <<'EOF'
#!/usr/bin/env bash
for f in /etc/*.conf; do echo "$f"; done
EOF
  cat >"$tmp/proj/bin/good.sh" <<'EOF'
#!/usr/bin/env bash
n=0
for f in /etc/*.conf; do echo "$f"; n=$((n+1)); done
[ "$n" -eq 0 ] && echo "BLIND: no conf files read"
EOF
  SCHED_ROOT="$tmp/sched" ; mkdir -p "$tmp/sched/schedule"
  printf 'PROJECT_REPO_PATH="%s/proj"\n' "$tmp" >"$tmp/sched/schedule/proj.conf"
  out="$(SCHED_ROOT="$tmp/sched" ONLY="" bash "${BASH_SOURCE[0]}" 2>&1)"
  t  "mute-null fires on unguarded scanner"  'mute-null.*bad\.sh'  "$out"
  tn "mute-null quiet on guarded scanner"    'mute-null.*good\.sh' "$out"

  # --- retirement-open fires while the retired literal is still live
  printf '# RETIRES: LEGACY_TOKEN_XYZ\n' >"$tmp/proj/bin/new.sh"
  printf 'we still use LEGACY_TOKEN_XYZ here\n' >"$tmp/proj/OLD.md"
  out="$(SCHED_ROOT="$tmp/sched" bash "${BASH_SOURCE[0]}" 2>&1)"
  t "retirement-open fires while literal is live" 'retirement-open.*LEGACY_TOKEN_XYZ' "$out"
  rm -f "$tmp/proj/OLD.md"
  out="$(SCHED_ROOT="$tmp/sched" bash "${BASH_SOURCE[0]}" 2>&1)"
  tn "retirement-open clears once literal is gone" 'retirement-open' "$out"

  # --- stderr-silenced fires on a privileged probe
  printf '#!/usr/bin/env bash\nsudo -n crontab -l 2>/dev/null\n[ -z "$x" ] && echo none found\n' \
    >"$tmp/proj/bin/probe.sh"
  out="$(SCHED_ROOT="$tmp/sched" bash "${BASH_SOURCE[0]}" 2>&1)"
  t "stderr-silenced fires on silenced privileged probe" 'stderr-silenced.*probe\.sh' "$out"

  # --- dirty-writer: cross-repo editor with no commit path of its own
  cat >"$tmp/proj/bin/installer.sh" <<'EOF'
#!/usr/bin/env bash
for conf in "$SCHED_ROOT"/schedule/*.conf; do
  repo="$(grep -oP '(?<=PROJECT_REPO_PATH=")[^"]*' "$conf")"
  sed -i 's/old/new/' "$repo/CLAUDE.md"
done
EOF
  out="$(SCHED_ROOT="$tmp/sched" bash "${BASH_SOURCE[0]}" 2>&1)"
  t "dirty-writer fires on cross-repo editor with no commit" 'dirty-writer.*installer\.sh' "$out"
  # ...and goes quiet the moment it commits what it wrote
  printf 'git -C "$repo" commit -m x\n' >>"$tmp/proj/bin/installer.sh"
  out="$(SCHED_ROOT="$tmp/sched" bash "${BASH_SOURCE[0]}" 2>&1)"
  tn "dirty-writer clears once the writer commits" 'dirty-writer.*installer\.sh' "$out"
  rm -f "$tmp/proj/bin/installer.sh"

  # --- twin: byte-identical executables in two registered repos
  mkdir -p "$tmp/proj2/bin"
  printf '#!/usr/bin/env bash\necho identical\n' >"$tmp/proj/bin/dup.sh"
  cp "$tmp/proj/bin/dup.sh" "$tmp/proj2/bin/dup.sh"
  printf 'PROJECT_REPO_PATH="%s/proj2"\n' "$tmp" >"$tmp/sched/schedule/proj2.conf"
  out="$(SCHED_ROOT="$tmp/sched" bash "${BASH_SOURCE[0]}" 2>&1)"
  t "twin fires on byte-identical executables" 'twin.*dup\.sh' "$out"
  printf '\n# now different\n' >>"$tmp/proj2/bin/dup.sh"
  out="$(SCHED_ROOT="$tmp/sched" bash "${BASH_SOURCE[0]}" 2>&1)"
  tn "twin clears once the copies diverge" 'twin.*dup\.sh' "$out"
  rm -f "$tmp/proj/bin/dup.sh" "$tmp/proj2/bin/dup.sh" "$tmp/sched/schedule/proj2.conf"

  # --- worktree-backed: BLIND when the bin dir cannot be read, never clean
  out="$(SCHED_ROOT="$tmp/sched" LOCAL_BIN="$tmp/nonexistent-bin" bash "${BASH_SOURCE[0]}" 2>&1)"
  t "worktree-backed reports BLIND on an unreadable bin dir" 'blind.*worktree-backed' "$out"
  # ...and a dangling symlink is a FLAG, not silence
  mkdir -p "$tmp/lbin"; ln -sfn "$tmp/gone-forever" "$tmp/lbin/ghost"
  out="$(SCHED_ROOT="$tmp/sched" LOCAL_BIN="$tmp/lbin" bash "${BASH_SOURCE[0]}" 2>&1)"
  t "worktree-backed fires on a dangling install" 'worktree-backed.*ghost.*DANGLING' "$out"

  # --- subrepo-invisible: a registered path that is not a repo root
  mkdir -p "$tmp/mono/sub/bin"
  git -C "$tmp/mono" init -q 2>/dev/null
  printf 'PROJECT_REPO_PATH="%s/mono/sub"\n' "$tmp" >"$tmp/sched/schedule/sub.conf"
  out="$(SCHED_ROOT="$tmp/sched" bash "${BASH_SOURCE[0]}" 2>&1)"
  t "subrepo-invisible fires on a monorepo subdirectory" 'subrepo-invisible.*not a repo root' "$out"
  rm -f "$tmp/sched/schedule/sub.conf"

  # ...and clears when the registered path IS the repo root. Fire-only
  # coverage until now: every other fixture project in this file is not a
  # git repo at all, so check_subrepo_invisible's own `git rev-parse
  # --show-toplevel` fails and it `continue`s -- silently skipped, not
  # proven quiet. This is the first fixture that actually exercises the
  # non-firing branch.
  mkdir -p "$tmp/repo-root/bin"
  git -C "$tmp/repo-root" init -q 2>/dev/null
  printf 'PROJECT_REPO_PATH="%s/repo-root"\n' "$tmp" >"$tmp/sched/schedule/repo-root.conf"
  out="$(SCHED_ROOT="$tmp/sched" bash "${BASH_SOURCE[0]}" 2>&1)"
  tn "subrepo-invisible clears when the registered path is the repo root" 'subrepo-invisible.*repo-root' "$out"
  rm -f "$tmp/sched/schedule/repo-root.conf"

  # --- unwired: FLAG-fire fixture. Only the BLIND path (unreadable bin/)
  # had coverage until now; this is the first assertion that the check
  # actually fires on a real orphan.
  printf '#!/usr/bin/env bash\necho orphan\n' >"$tmp/proj/bin/orphan-mechanism.sh"
  out="$(SCHED_ROOT="$tmp/sched" bash "${BASH_SOURCE[0]}" 2>&1)"
  t "unwired fires on a script named by no crontab, doc, conf, unit or sibling" \
    'unwired.*orphan-mechanism\.sh' "$out"
  rm -f "$tmp/proj/bin/orphan-mechanism.sh"

  # --- self-witness: needs a hermetic crontab, not this account's real one.
  printf 'acct1\t* * * * * /opt/thing.sh >/dev/null 2>&1\n' >"$tmp/crontab-fire.tsv"
  out="$(SCHED_ROOT="$tmp/sched" CRONTAB_LIST="$tmp/crontab-fire.tsv" bash "${BASH_SOURCE[0]}" 2>&1)"
  t "self-witness fires on a cron line that discards all output" 'self-witness.*thing\.sh' "$out"
  printf 'acct1\t* * * * * /opt/thing.sh >>/var/log/thing.log 2>&1\n' >"$tmp/crontab-clear.tsv"
  out="$(SCHED_ROOT="$tmp/sched" CRONTAB_LIST="$tmp/crontab-clear.tsv" bash "${BASH_SOURCE[0]}" 2>&1)"
  tn "self-witness clears on a cron line witnessed by its own log" 'self-witness.*thing\.sh' "$out"

  # --- home-scoped: needs >=2 dispatch accounts, which only a fixtured
  # crontab can guarantee (the check goes quiet by design under 1 account,
  # and this machine's real crontab count is not something a fixture
  # should depend on).
  mkdir -p "$tmp/proj4/bin"
  printf 'PROJECT_REPO_PATH="%s/proj4"\n' "$tmp" >"$tmp/sched/schedule/proj4.conf"
  printf 'acct1\t* * * * * /a.sh\nacct2\t* * * * * /b.sh\n' >"$tmp/crontab-2acct.tsv"
  printf '#!/usr/bin/env bash\ncat "$HOME/.local/share/thing/state.json"\n' >"$tmp/proj4/bin/reader.sh"
  out="$(SCHED_ROOT="$tmp/sched" CRONTAB_LIST="$tmp/crontab-2acct.tsv" bash "${BASH_SOURCE[0]}" 2>&1)"
  t "home-scoped fires on a \$HOME-only state read when 2+ accounts dispatch" \
    'home-scoped.*reader\.sh' "$out"
  printf '#!/usr/bin/env bash\n# CRON_ACCOUNT aware\ncat "$HOME/.local/share/thing/state.json"\n' >"$tmp/proj4/bin/reader.sh"
  out="$(SCHED_ROOT="$tmp/sched" CRONTAB_LIST="$tmp/crontab-2acct.tsv" bash "${BASH_SOURCE[0]}" 2>&1)"
  tn "home-scoped clears once the script names another account" 'home-scoped.*reader\.sh' "$out"
  rm -rf "$tmp/proj4"; rm -f "$tmp/sched/schedule/proj4.conf"

  # --- prose-only-rule: a checklist literal no script in bin/ checks for.
  mkdir -p "$tmp/proj5/bin"
  printf 'PROJECT_REPO_PATH="%s/proj5"\n' "$tmp" >"$tmp/sched/schedule/proj5.conf"
  printf -- '- [ ] `SOME_UNENFORCED_RULE` must hold\n' >"$tmp/proj5/CLAUDE.md"
  out="$(SCHED_ROOT="$tmp/sched" bash "${BASH_SOURCE[0]}" 2>&1)"
  t "prose-only-rule fires on a checklist literal no script checks" \
    'prose-only-rule.*SOME_UNENFORCED_RULE' "$out"
  printf '#!/usr/bin/env bash\ngrep -q SOME_UNENFORCED_RULE "$1"\n' >"$tmp/proj5/bin/enforce.sh"
  out="$(SCHED_ROOT="$tmp/sched" bash "${BASH_SOURCE[0]}" 2>&1)"
  tn "prose-only-rule clears once a script in bin/ checks the literal" \
    'prose-only-rule.*SOME_UNENFORCED_RULE' "$out"
  rm -rf "$tmp/proj5"; rm -f "$tmp/sched/schedule/proj5.conf"

  # --- BLIND when repo/bin exists but cannot be read, not clean. Every check
  # that globs/greps "$repo/bin" inherits grep/find's own 2>/dev/null -- a
  # permission-denied bin dir silently returns zero hits, i.e. clean, which
  # is the exact defect these checks exist to find in OTHER scripts, uncaught
  # in themselves. Was fixed 2026-08-04 for stderr-silenced/unwired only;
  # mute-null, dirty-writer, twin and prose-only-rule had the same hole.
  # home-scoped additionally needs >=2 dispatch accounts to reach its own
  # bin/ scan at all, hence the fixtured 2-account crontab here too.
  mkdir -p "$tmp/blind/bin"
  printf 'PROJECT_REPO_PATH="%s/blind"\n' "$tmp" >"$tmp/sched/schedule/blind.conf"
  chmod 000 "$tmp/blind/bin"
  out="$(SCHED_ROOT="$tmp/sched" bash "${BASH_SOURCE[0]}" 2>&1)"
  out2acct="$(SCHED_ROOT="$tmp/sched" CRONTAB_LIST="$tmp/crontab-2acct.tsv" bash "${BASH_SOURCE[0]}" 2>&1)"
  chmod 755 "$tmp/blind/bin"
  rm -f "$tmp/sched/schedule/blind.conf"
  t "stderr-silenced reports BLIND on an unreadable bin dir"  'blind.*stderr-silenced.*blind/bin exists but is not readable'  "$out"
  t "unwired reports BLIND on an unreadable bin dir"          'blind.*unwired.*blind/bin exists but is not readable'          "$out"
  t "mute-null reports BLIND on an unreadable bin dir"        'blind.*mute-null.*blind/bin exists but is not readable'        "$out"
  t "dirty-writer reports BLIND on an unreadable bin dir"     'blind.*dirty-writer.*blind/bin exists but is not readable'     "$out"
  t "twin reports BLIND on an unreadable bin dir"             'blind.*twin.*blind/bin exists but is not readable'             "$out"
  t "prose-only-rule reports BLIND on an unreadable bin dir"  'blind.*prose-only-rule.*blind/bin exists but is not readable'  "$out"
  t "home-scoped reports BLIND on an unreadable bin dir (2+ accounts)" \
    'blind.*home-scoped.*blind/bin exists but is not readable' "$out2acct"

  # --- BLIND: zero mechanisms must exit 3, not 0
  mkdir -p "$tmp/empty/schedule"
  out="$(SCHED_ROOT="$tmp/empty" bash "${BASH_SOURCE[0]}" 2>&1; echo "rc=$?")"
  t "empty domain exits BLIND(3) not clean" 'rc=3' "$out"
  t "empty domain says BLIND"               'BLIND'  "$out"

  echo
  [ "$rc" -eq 0 ] && echo "self-test: PASS" || echo "self-test: FAIL"
  return "$rc"
}

if [ "$SELFTEST" = 1 ]; then self_test; exit $?; fi

# ------------------------------------------------- am I wired to anything?
# The noisy self-trigger. BUILD-DISCIPLINE pattern 2 (build-but-don't-wire)
# is the failure this project regenerates most often, and an auditor that
# sits unwired while reporting on everyone else's wiring is the joke writing
# itself. So this script asks the [unwired] question about ITSELF first, on
# every single run, and refuses to be quiet about the answer.
#
# It cannot be satisfied by a doc mentioning it: the test is whether some
# DISPATCHER names it -- a crontab line, a systemd unit, or hygiene-lint.
self_wiring_banner() {
  local me hits=0
  me="$(basename "${BASH_SOURCE[0]}")"
  read_crontabs | grep -qF "$me" && hits=$((hits+1))
  grep -rqF "$me" /etc/systemd/system ~/.config/systemd 2>/dev/null && hits=$((hits+1))
  [ -n "$REPO" ] && grep -rqF "$me" "$REPO/bin/hygiene-lint.sh" 2>/dev/null && hits=$((hits+1))
  if [ "$hits" -eq 0 ]; then
    echo "########################################################################"
    echo "## NOT WIRED -- this audit is running by hand and by hand only.       ##"
    echo "## No crontab, no systemd unit and no hygiene-lint check names        ##"
    echo "##   $me"
    echo "## Everything below is therefore a ONE-OFF READING, not surveillance. ##"
    echo "## It will not run again unless a human remembers to run it, which is ##"
    echo "## BUILD-DISCIPLINE pattern 2 -- the pattern this script audits for.  ##"
    echo "## Wire it (install-silence-audit.sh) or delete it. Do not leave it   ##"
    echo "## here looking like coverage.                                        ##"
    echo "########################################################################"
    echo
  fi
}

# ---------------------------------------------------------------- run
echo "silence-audit -- $(date -Is)"
echo "domain: schedule/*.conf under $SCHED_ROOT${ONLY:+ (project: $ONLY)}"
echo
self_wiring_banner

check_mute_null
check_self_witness
check_home_scoped
check_stderr_silenced
check_unwired
check_prose_only_rule
check_retirement_open
check_dirty_writer
check_worktree_backed
check_twin
check_subrepo_invisible

echo
if [ "${projects_seen:-0}" -eq 0 ]; then
  echo "BLIND -- parsed ZERO registered projects from $SCHED_ROOT/schedule."
  echo "This is not a clean result. Nothing was audited; the domain was"
  echo "unreadable or empty. Reporting clean here would be the exact defect"
  echo "this script exists to detect."
  exit 3
fi
echo "audited $mechanisms mechanism(s); $flags FLAG(s)"
[ "$STRICT" = 1 ] && [ "$flags" -gt 0 ] && exit 1
exit 0
