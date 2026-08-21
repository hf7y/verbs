#!/usr/bin/env bash
# closeout-lint.sh -- the deterministic half of the `/cloture` session-closing
# rite. Zero AI, writes
# nothing. A and C are offline; B asks GitHub whether this session left an
# issue or a PR and reports a counted BLIND -- never a FLAG -- when it cannot,
# and `--repo` skips B so the SubagentStop path stays fully offline. Signals,
# not verdicts: see $CLI_EXITS below for what each code means.
#
# KIND: verb
#
# RUNNER: hooks/subagent-closeout.sh bin/tests/closeout-lint.test.sh
# GUARD-TEST: bin/tests/closeout-lint.test.sh
# GATE: strict --repo $TREE
#
# An overnight run that is not saved anywhere didn't happen, and the recorded
# ways that goes wrong are a dirty tree at exit, a commit that never left the
# local clone, and a session that left no record where its readers look.
# Sections A, B and C each carry their own header below; usage is $CLI_USAGE.
#
# --repo audits ONE tree (no positional name reaches a linked worktree): no
# registry, no age gate, B skipped as a session-wide concern. It is what a
# SubagentStop hook needs, since a registry scan would block every subagent.
# BLIND GATES at exit 6: a domain that existed and was NOT read is not a pass.
#
# Env overrides (set by bin/tests/closeout-lint.test.sh, not normally): HOURS,
# SCHED_ROOT, TODAY, GH_BIN (the CLI B asks; the suite stubs it),
# and SESSION_START (epoch or anything `date -d` parses; see below).
set -uo pipefail

CLI_NAME='closeout-lint.sh'
CLI_SUMMARY='the deterministic half of session closeout -- what did today leave behind?'
CLI_USAGE='  closeout-lint.sh              scan every registered project
  closeout-lint.sh <name>...    scan only the named project(s)
  closeout-lint.sh --strict [<name>...]   exit 1 if any FLAG was printed
  closeout-lint.sh --repo <path>          audit ONE working tree (section B
                                          skipped, age gate ignored)
  closeout-lint.sh --allow-blind          BLIND warns instead of gating
    (HOURS=<n> in the environment sets the lookback window)'
CLI_FLAGS='--strict --repo --allow-blind'
CLI_EXITS='  0  scanned; no --strict given, or --strict given and nothing found
  1  --strict was given and at least one FLAG was printed
  6  --strict was given and a domain existed but was NOT read (BLIND), and
     neither --allow-blind nor an interactive override was given. Matches
     `garde` and `ausculte`, which already use 6 for blind'
CLI_POSITIONAL=any
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/cli-guard.sh"
cli_guard "$@"

SCHED_ROOT="${SCHED_ROOT:-${INSTALLE_PROJECTS:-$HOME/Documents/Projects}/scheduler}"
HOURS="${HOURS:-12}"
TODAY="${TODAY:-$(date +%Y-%m-%d)}"
SESSION_START="${SESSION_START:-}"
GH_BIN="${GH_BIN:-gh}"
# Which host OWNS a project: the one with a UNIX account of that name. A seam,
# so the suite can drive both sides without inventing accounts.
ACCOUNT_PROBE="${ACCOUNT_PROBE:-id -u}"
SCHED_OWNER="${SCHED_OWNER:-hf7y}"
SCHED_REPO="${SCHED_REPO:-scheduler}"

# Mode flags are not project names -- strip them before building the
# positional project-filter list (cli_guard validated them but never consumes
# args, per its own contract; each script parses its own).
STRICT=0
ALLOW_BLIND=0
REPO_ARG=""
want=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict)      STRICT=1 ;;
    --allow-blind) ALLOW_BLIND=1 ;;
    --repo)
      shift
      [ "$#" -gt 0 ] || cli_die "--repo needs a path"
      REPO_ARG="$1"
      ;;
    *) want+=("$1") ;;
  esac
  shift
done

projects=()
paths=()
if [ -n "$REPO_ARG" ]; then
  # --repo: audit exactly this tree. Refuse to also take project names rather
  # than silently honouring one and dropping the other -- two selectors that
  # disagree is a usage error, not something to resolve by precedence.
  [ "${#want[@]}" -eq 0 ] || \
    cli_die "--repo and project names are two different selectors: ${want[*]}"
  [ -d "$REPO_ARG" ] || cli_die "--repo path is not a directory: $REPO_ARG"
  git -C "$REPO_ARG" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    cli_die "--repo path is not inside a git work tree: $REPO_ARG"
  # Resolve to the tree's own root so a subdirectory argument still names the
  # repo, and so the label matches what a reader would call it.
  REPO_ARG="$(git -C "$REPO_ARG" rev-parse --show-toplevel 2>/dev/null || echo "$REPO_ARG")"
  projects+=("$(basename "$REPO_ARG")"); paths+=("$REPO_ARG")
else
  # --- discover registered projects (same loop as hygiene-lint.sh) ----------
  # A CHECKOUT WINS WHEN PRESENT; GitHub is the clone-free fallback (#414).
  # Without it this section is BLIND on any host with no scheduler clone.
  confs=()
  if [ -d "$SCHED_ROOT/schedule" ]; then
    for c in "$SCHED_ROOT"/schedule/*.conf; do [ -f "$c" ] && confs+=("$c"); done
  else
    remote_confs="$("$GH_BIN" api "repos/$SCHED_OWNER/$SCHED_REPO/contents/schedule" \
                      -q '.[].name' 2>/dev/null | grep '\.conf$' || true)"
    if [ -n "$remote_confs" ]; then
      tmp_sched="$(mktemp -d)"; trap 'rm -rf "$tmp_sched"' EXIT
      while read -r rc; do
        [ -n "$rc" ] || continue
        "$GH_BIN" api "repos/$SCHED_OWNER/$SCHED_REPO/contents/schedule/$rc" -q .content 2>/dev/null \
          | base64 -d > "$tmp_sched/$rc" 2>/dev/null && confs+=("$tmp_sched/$rc")
      done <<< "$remote_confs"
    fi
  fi
  for conf in ${confs+"${confs[@]}"}; do
    [ -f "$conf" ] || continue
    name="$(basename "$conf" .conf)"
    case "$name" in _*) continue ;; esac
    p="$(sed -n 's/^PROJECT_REPO_PATH=["'\'']\?\([^"'\'']*\)["'\'']\?[[:space:]]*$/\1/p' "$conf" | head -1)"
    [ -n "$p" ] || continue
    # sed hands back the LITERAL `$HOME`, used as a path directly until
    # from inside one of them. Expanded by SUBSTITUTION, not eval: eval-ing a
    # registry path would make a conf a code-execution surface.
    case "$p" in
      '$HOME'/*)   p="$HOME/${p#\$HOME/}" ;;
      '${HOME}'/*) p="$HOME/${p#\$\{HOME\}/}" ;;
      '~'/*)       p="$HOME/${p#\~/}" ;;
    esac
    if [ "${#want[@]}" -gt 0 ]; then
      skip=1; for w in "${want[@]}"; do [ "$w" = "$name" ] && skip=0; done
      [ "$skip" -eq 1 ] && continue
    fi
    projects+=("$name"); paths+=("$p")
  done
  cli_require_matched want projects
fi

if [ -n "$REPO_ARG" ]; then
  echo "closeout-lint -- $TODAY (single tree: $REPO_ARG)"
else
  echo "closeout-lint -- $TODAY (repos touched in the last ${HOURS}h)"
fi
if [ -n "$REPO_ARG" ]; then
  net="offline (--repo skips section B)"
else
  net="offline but for section B's $GH_BIN query"
fi
if [ "$STRICT" = 1 ]; then
  echo "($net: no claude calls, writes nothing. --strict: FLAG=1, BLIND=6."
else
  echo "($net: no claude calls, writes nothing, exits 0 -- --strict to gate."
fi
echo " FLAGs are SIGNALS a closing session should look at, not verdicts."
echo " Run alongside hygiene-lint.sh; see realisateur/BUILD-DISCIPLINE.md.)"
echo
if [ -n "$REPO_ARG" ]; then
  echo "== A. THIS WORKING TREE =="
else
  echo "== A. RECENTLY TOUCHED REPOS =="
fi

flags=0
blind=0
touched=0
touched_names=()
touched_paths=()
registry_blind=0
now="$(date +%s)"

# REGISTRY ITSELF UNREADABLE (hf7y/realisateur#232). A full sweep that
# discovers ZERO projects is ambiguous: it might mean "the registry is
# empty" or it might mean "the registry could not be read on
if [ -z "$REPO_ARG" ] && [ "${#want[@]}" -eq 0 ] && [ "${#projects[@]}" -eq 0 ]; then
  blind=$((blind+1))
  registry_blind=1
  echo "  BLIND [registry] no registered project was readable under $SCHED_ROOT/schedule/ -- 'could not look', not 'nothing to report'"
fi
cutoff=$(( HOURS * 3600 ))

# --- WHEN DID THIS SESSION START (hf7y/realisateur#137) ----------------------
#
# The dirty-tree rule below assumed "uncommitted changes at close are this
session_start_epoch() { # -> epoch seconds on stdout, or nothing and exit 1
  local raw="$SESSION_START" p="${PPID}" d=0 comm et
  if [ -n "$raw" ]; then
    case "$raw" in *[!0-9]*) date -d "$raw" +%s 2>/dev/null || return 1 ;;
                   *)        printf '%s\n' "$raw" ;; esac
    return 0
  fi
  while [ "${p:-0}" -gt 1 ] 2>/dev/null && [ "$d" -lt 12 ]; do
    comm="$(ps -p "$p" -o comm= 2>/dev/null | tr -d '[:space:]')"
    et="$(ps -p "$p" -o etimes= 2>/dev/null | tr -d '[:space:]')"
    case "$comm" in claude|claude.exe)
      case "$et" in ''|*[!0-9]*) ;; *) printf '%s\n' "$(( now - et ))"; return 0 ;; esac ;;
    esac
    p="$(ps -p "$p" -o ppid= 2>/dev/null | tr -d '[:space:]')"; d=$((d + 1))
  done
  return 1
}

# `find -newermt` IS the test, so its absence must not read as "nothing is
# newer". Probed once; a failed probe leaves the anchor unset, i.e. FLAG.
SESSION_EPOCH=""
if command -v find >/dev/null 2>&1 && find /dev/null -newermt "@0" >/dev/null 2>&1; then
  SESSION_EPOCH="$(session_start_epoch || true)"
fi

# Every dirty path modified at or after <epoch>; one that cannot be resolved
# (a deletion, a rename's old half, a git-quoted name) prints as RECENT --
# unattributable is this run's until proven otherwise. `find`, not `stat`: an
# untracked DIRECTORY's own mtime says nothing about a file three levels in.
dirty_newer_than() { # <repo> <epoch> <porcelain-output>
  local repo="$1" epoch="$2" line p
  printf '%s\n' "$3" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    p="${line:3}"; case "$p" in *' -> '*) p="${p##* -> }" ;; esac
    p="${p%\"}"; p="${p#\"}"
    if [ ! -e "$repo/$p" ] && [ ! -L "$repo/$p" ]; then printf '%s\n' "$p"
    elif [ -n "$(find "$repo/$p" -newermt "@$epoch" -print -quit 2>/dev/null)" ]; then
      printf '%s\n' "$p"
    fi
  done
}

# A branch whose newest commit predates this session is not this run's residue
# (#363): worktrees SHARE the ref store, so every subagent inherited every
# stale branch as a FLAG. Same carve-out and fallback as dirty_newer_than.
tip_predates_session() { # <repo> <rev> -> 0 if its newest commit is older than session start
  local newest
  [ -n "$SESSION_EPOCH" ] || return 1
  newest="$(git -C "$1" log -1 --format=%ct "$2" 2>/dev/null)" || return 1
  [ -n "$newest" ] || return 1
  [ "$newest" -lt "$SESSION_EPOCH" ]
}

i=0
while [ "$i" -lt "${#projects[@]}" ]; do
  name="${projects[$i]}"; repo="${paths[$i]}"; i=$((i+1))
  # A REGISTERED PROJECT WITH NO CHECKOUT HERE IS THE CLONE-FREE STATE, not a
  # finding: dev hosts stopped keeping one clone per project. It is only a
  # finding on the host that OWNS the project -- the one with an account of
  # that name -- where the account's own checkout is where its work lives.
  if [ ! -d "$repo" ]; then
    if $ACCOUNT_PROBE "$name" >/dev/null 2>&1; then
      echo "  FLAG [missing-repo] $name: $repo does not exist on the host that owns $name"
      flags=$((flags+1))
    fi
    continue
  fi
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue

  # Linked worktrees are READ, and BEFORE the age gate; both halves measured
  wt="$(git -C "$repo" worktree list --porcelain 2>/dev/null \
        | awk -v m="$repo" '/^worktree /{p=substr($0,10); if (p != m) print p}')"
  if [ -n "$wt" ]; then
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      # UNREADABLE is the only thing that still earns a BLIND: the directory is
      # gone, or it is not a work tree any more. Nothing can be learned, and
      # reporting that as "clean" is the "found nothing / nothing is wrong"
      # conflation this whole script exists to refuse.
      if [ ! -d "$w" ] || ! git -C "$w" rev-parse --git-dir >/dev/null 2>&1; then
        blind=$((blind+1))
        echo "  BLIND [worktree] $name: $w could not be read (directory gone or not a work tree)"
        continue
      fi
      wbr="$(git -C "$w" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
      echo "  read [worktree] $name: $w [$wbr]"

      # AN UNPUSHED COMMIT IS THE UNAMBIGUOUS FINDING. Measured against the
      # branch's own remote ref, never `@{u}`: an explicit-refspec push
      # configures no upstream and is still safely on origin.
      if git -C "$w" rev-parse --verify -q "origin/$wbr" >/dev/null 2>&1; then
        wahead="$(git -C "$w" rev-list --count "origin/$wbr..HEAD" 2>/dev/null)"
        if [ "${wahead:-0}" -gt 0 ] && tip_predates_session "$w" HEAD; then
          echo "    note [pre-existing-unpushed] $name: $wahead commit(s) on '$wbr' in $w predate this session -- not this run's to push"
        elif [ "${wahead:-0}" -gt 0 ]; then
          echo "    FLAG [worktree-unpushed] $name: $wahead commit(s) on '$wbr' in $w not on origin/$wbr"
          git -C "$w" log --oneline "origin/$wbr..HEAD" 2>/dev/null | head -5 | sed 's/^/      /'
          flags=$((flags+1))
        fi
      fi

      # A DIRTY TREE, mtime-split the same way #137 split the main checkout
      # (dirty_newer_than, above): dirt modified DURING this session could
      # belong to a still-running concurrent agent in this same worktree, so
      wdirty_all="$(git -C "$w" status --porcelain 2>/dev/null)"
      if [ -n "$wdirty_all" ]; then
        wdcount="$(printf '%s\n' "$wdirty_all" | grep -c .)"
        wrecent=""
        [ -n "$SESSION_EPOCH" ] && wrecent="$(dirty_newer_than "$w" "$SESSION_EPOCH" "$wdirty_all")"
        if [ -n "$SESSION_EPOCH" ] && [ -z "$wrecent" ]; then
          echo "    FLAG [worktree-dirty-abandoned] $name: $wdcount uncommitted path(s) in $w, every one last modified BEFORE this session started ($(date -d "@$SESSION_EPOCH" '+%F %T' 2>/dev/null || printf '@%s' "$SESSION_EPOCH"))"
          printf '%s\n' "$wdirty_all" | head -8 | sed 's/^/      /'
          echo "      (the agent that used this worktree already exited before this"
          echo "       session began -- nothing is left to adopt or clean this up)"
          flags=$((flags+1))
        else
          echo "    note [worktree-dirty] $name: $wdcount uncommitted path(s) in $w"
          if [ -n "$SESSION_EPOCH" ]; then
            echo "      ($(printf '%s\n' "$wrecent" | grep -c .) of $wdcount modified since this session started)"
          fi
          echo "      (not a FLAG: a live concurrent agent's tree is dirty by"
          echo "       construction, and it is that run's to resolve, not this one's)"
        fi
      fi
    done <<EOF
$wt
EOF
  fi

  ct="$(git -C "$repo" log -1 --format=%ct 2>/dev/null)"
  [ -n "$ct" ] || continue
  age=$(( now - ct ))
  # The age gate answers "did THIS SESSION touch it": right for a registry
  # sweep, wrong for --repo, where skipping the named tree as "too old" would
  # audit nothing and report clean -- the exact shape of a false all-clear.
  if [ -z "$REPO_ARG" ] && [ "$age" -gt "$cutoff" ]; then continue; fi
  touched=$((touched+1))
  touched_names+=("$name"); touched_paths+=("$repo")
  printf '  %-18s HEAD %sh ago\n' "$name" "$(( age / 3600 ))"

  # dirty tree: an uncommitted change to a live script is indistinguishable
  # from an abandoned one (CLAUDE.md subagent rule) -- unless it predates the
  # session, when it is indistinguishable from a CONCURRENT one and adopting
  # it is the same incident with the names swapped.
  dirty_all="$(git -C "$repo" status --porcelain 2>/dev/null)"
  if [ -n "$dirty_all" ]; then
    dcount="$(printf '%s\n' "$dirty_all" | grep -c .)"
    recent=""
    [ -n "$SESSION_EPOCH" ] && recent="$(dirty_newer_than "$repo" "$SESSION_EPOCH" "$dirty_all")"
    if [ -n "$SESSION_EPOCH" ] && [ -z "$recent" ]; then
      echo "    note [pre-existing-dirty] $name: $dcount uncommitted path(s), every one last modified BEFORE this session started ($(date -d "@$SESSION_EPOCH" '+%F %T' 2>/dev/null || printf '@%s' "$SESSION_EPOCH"))"
      printf '%s\n' "$dirty_all" | head -8 | sed 's/^/      /'
      echo "      (not a FLAG, same carve-out as [worktree-dirty] above: committing"
      echo "       adopts another run's work under your name, reverting destroys it)"
    else
      echo "    FLAG [dirty-tree] $name: uncommitted changes at session close"
      printf '%s\n' "$dirty_all" | head -8 | sed 's/^/      /'
      if [ -n "$SESSION_EPOCH" ]; then
        echo "      ($(printf '%s\n' "$recent" | grep -c .) of $dcount modified since this session started -- those are this run's:)"
        printf '%s\n' "$recent" | head -8 | sed 's/^/        /'
      else  # unknown is not clean: the FLAG stands, as it did before #137
        echo "      (session start is unknown here -- no SESSION_START and no claude"
        echo "       ancestor -- so pre-existing dirt cannot be told from this run's)"
      fi
      flags=$((flags+1))
    fi
  fi

  # unpushed: "verified where the consumer reads it" -- the nightly clones the
  # REF, not this tree. EVERY BRANCH, not just the checked-out one.
  wt_owner="$(git -C "$repo" worktree list --porcelain 2>/dev/null \
        | awk -v m="$repo" '
            /^worktree /{p=substr($0,10)}
            /^branch /{b=substr($0,8); sub("^refs/heads/","",b); if (p != m) printf "%s\t%s\n", b, p}')"
  wt_branches="$(printf '%s' "$wt_owner" | cut -f1)"
  on_a_remote() { # <branch> -> 0 if its tip is reachable from any remote ref
    local sha
    sha="$(git -C "$repo" rev-parse -q --verify "$1" 2>/dev/null)" || return 1
    [ -n "$sha" ] || return 1
    [ -n "$(git -C "$repo" branch -r --contains "$sha" 2>/dev/null | head -1)" ]
  }

  #
  # THE NUMBERS. This section reported 12 [host-only-branch] FLAGs against the
  default_remote="$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -z "$default_remote" ]; then
    for c in origin/main origin/master; do
      git -C "$repo" rev-parse -q --verify "$c" >/dev/null 2>&1 && { default_remote="$c"; break; }
    done
  fi
  landed() { # <branch> -> 0 if its content is already on the default branch
    local br="$1" base tree basetree probe
    [ -n "$default_remote" ] || return 1
    base="$(git -C "$repo" merge-base "$default_remote" "$br" 2>/dev/null)" || return 1
    [ -n "$base" ] || return 1
    tree="$(git -C "$repo" rev-parse -q --verify "$br^{tree}" 2>/dev/null)" || return 1
    basetree="$(git -C "$repo" rev-parse -q --verify "$base^{tree}" 2>/dev/null)"
    # A branch whose tree already equals the merge base's adds nothing at all.
    # `git cherry` on an empty patch is not defined to say so, and a branch
    # with nothing in it has nothing to lose either way.
    [ "$tree" = "$basetree" ] && return 0
    probe="$(GIT_AUTHOR_NAME=closeout-lint GIT_AUTHOR_EMAIL=closeout-lint@invalid \
             GIT_COMMITTER_NAME=closeout-lint GIT_COMMITTER_EMAIL=closeout-lint@invalid \
             git -C "$repo" commit-tree "$tree" -p "$base" -m squash-probe 2>/dev/null)" || return 1
    [ -n "$probe" ] || return 1
    case "$(git -C "$repo" cherry "$default_remote" "$probe" 2>/dev/null)" in
      -*) return 0 ;;
    esac
    return 1
  }
  owned_elsewhere=""
  owned_n=0
  while IFS= read -r br; do
    [ -n "$br" ] || continue
    if [ -n "$wt_branches" ] && printf '%s\n' "$wt_branches" | grep -qxF "$br"; then
      owned_n=$((owned_n+1))
      owned_elsewhere="${owned_elsewhere:+$owned_elsewhere, }$br"
      continue
    fi
    if ! git -C "$repo" rev-parse --verify -q "origin/$br" >/dev/null 2>&1 && on_a_remote "$br"; then
      echo "    note [stale-pointer] $name: '$br' has no origin/$br, but its tip is already reachable from a remote ref -- nothing unpushed"
      continue
    fi
    # ...and the same for a branch that was SQUASH-merged, whose tip is on no
    # remote by construction but whose content is on the default branch.
    if ! git -C "$repo" rev-parse --verify -q "origin/$br" >/dev/null 2>&1 && landed "$br"; then
      echo "    note [landed] $name: '$br' has no origin/$br, but its content is already on $default_remote (squash-merged) -- nothing unpushed"
      continue
    fi
    if git -C "$repo" rev-parse --verify -q "origin/$br" >/dev/null 2>&1; then
      ahead="$(git -C "$repo" rev-list --count "origin/$br..$br" 2>/dev/null)"
      if [ "${ahead:-0}" -gt 0 ] && tip_predates_session "$repo" "$br"; then
        echo "    note [pre-existing-unpushed] $name: $ahead commit(s) on $br predate this session -- not this run's to push"
      elif [ "${ahead:-0}" -gt 0 ]; then
        echo "    FLAG [unpushed] $name: $ahead commit(s) on $br not on origin/$br"
        git -C "$repo" log --oneline "origin/$br..$br" 2>/dev/null | head -5 | sed 's/^/      /'
        flags=$((flags+1))
      fi
    elif tip_predates_session "$repo" "$br"; then
      echo "    note [pre-existing-branch] $name: '$br' has no origin/$br, but its tip predates this session -- another run's residue, not this one's"
    else
      echo "    FLAG [host-only-branch] $name: branch '$br' has no origin/$br -- it exists only on this host"
      flags=$((flags+1))
    fi
  done <<EOF
$(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)
EOF
  if [ "$owned_n" -gt 0 ]; then
    owner_n="$(printf '%s' "$wt_owner" | cut -f2 | sort -u | grep -c .)"
    echo "    skip [other-worktree] $name: $owned_n branch(es) are checked out in $owner_n linked worktree(s) and belong to those runs, not this one (each read above):"
    printf '%s\n' "$owned_elsewhere" | fold -s -w 74 | sed 's/^/      /'
  fi
  i=$i
done
[ -n "$REPO_ARG" ] || [ "$touched" -ne 0 ] || [ "${#projects[@]}" -eq 0 ] || \
  echo "  (no registered repo has a commit younger than ${HOURS}h)"

# B and C ask about the SESSION, not a directory, so --repo skips them -- which
# is also what keeps the SubagentStop path offline now that B asks a remote.
# Wrapped in a function purely so the body stays unindented; bash functions
# share scope, so `flags` still accumulates.
session_wide_sections() {
echo
echo "== B. TODAY'S SESSION RECORD (issues/PRs created $TODAY) =="
# B ASKS THE REMOTE, not a file in the tree: did this session leave an issue or
# a PR over the repos A found touched. A mandatory row nobody can satisfy is
# how a checklist stops being read (#139).
#
# REST, NOT SEARCH -- search is one call instead of one per repo, but its index
# is eventually consistent and a PR opened ninety seconds ago is exactly what a
# closing session asks about.
#
# IT CAN NEVER FLAG FOR BEING OFFLINE -- no gh, no auth, a timeout, a rate
# limit, a non-GitHub origin: each leaves the question unanswered, which is a
# counted BLIND. A FLAG needs GitHub reached and actually saying no, and if
# even one touched repo went unreached the record might be in that one.
# $GH_BIN under a timeout when there is one: a hung DNS lookup at session close
# must not wedge the rite that runs this.
GH_RUN=("$GH_BIN")
command -v timeout >/dev/null 2>&1 && GH_RUN=(timeout "${GH_TIMEOUT:-20}" "$GH_BIN")
gh_slug() { # <repo-path> -> owner/name for a GitHub origin, or nothing
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  case "$url" in *github.com*) ;; *) return 1 ;; esac
  url="${url##*github.com}"; url="${url#:}"; url="${url#/}"; url="${url%/}"
  case "${url%.git}" in */*) printf '%s\n' "${url%.git}" ;; *) return 1 ;; esac
}
if ! command -v "$GH_BIN" >/dev/null 2>&1; then
  blind=$((blind+1))
  echo "  BLIND [session-record] '$GH_BIN' is not on PATH, so nothing here can ask"
  echo "    the remote where /cloture §3 now says the record goes."
elif [ "$registry_blind" = 1 ]; then
  blind=$((blind+1))
  echo "  BLIND [session-record] registry was unreadable (see A above) -- cannot"
  echo "    enumerate which repos this session touched, so whether any has a"
  echo "    record is unknown -- this is not a claim that there was none."
elif [ "${#touched_paths[@]}" -eq 0 ]; then
  echo "  NOTE no repo touched in the last ${HOURS}h -- no work to have recorded."
else
  b_found=""; b_probed=0; b_unreached=0; bi=0
  while [ "$bi" -lt "${#touched_paths[@]}" ]; do
    bname="${touched_names[$bi]}"; bpath="${touched_paths[$bi]}"; bi=$((bi+1))
    if ! slug="$(gh_slug "$bpath")"; then
      b_unreached=$((b_unreached+1))
      echo "  NOTE $bname: origin is not a GitHub remote -- cannot ask it for today's record"
    elif out="$("${GH_RUN[@]}" api -X GET "repos/$slug/issues" \
                  -f state=all -f "since=${TODAY}T00:00:00Z" -f per_page=100 \
                  --jq ".[] | select(.created_at | startswith(\"$TODAY\")) | \"$slug#\(.number) \(.title)\"" \
                  2>/dev/null)"; then
      b_probed=$((b_probed+1)); [ -n "$out" ] && b_found="${b_found}${out}"$'\n'
    else
      b_unreached=$((b_unreached+1))
    fi
  done
  if [ -n "$b_found" ]; then
    echo "  ok -- $(printf '%s' "$b_found" | grep -c .) issue(s)/PR(s) created $TODAY, across $b_probed repo(s):"
    printf '%s' "$b_found" | head -6 | sed 's/^/    /'
  elif [ "$b_unreached" -gt 0 ]; then
    blind=$((blind+1))
    echo "  BLIND [session-record] $b_unreached of $((b_probed + b_unreached)) touched repo(s)"
    echo "    could not be asked (offline, unauthenticated, rate-limited, or not on"
    echo "    GitHub) and today's record could be in one. Never a FLAG: this check"
    echo "    does not report a missing record it merely could not see."
  else
    echo "  FLAG [no-record] no issue or PR created $TODAY on any of the $b_probed"
    echo "    recently-touched repo(s) -- no durable record where /cloture §3 puts it."
    flags=$((flags+1))
  fi
fi

}
[ -n "$REPO_ARG" ] || session_wide_sections

echo
# BLIND LEADS: as a trailing clause after the FLAG count it gets skipped.
if [ "$blind" -gt 0 ]; then
  echo "!! BLIND: $blind domain(s) existed and were NOT read. This is NOT a clean"
  echo "!! result -- an unread domain can hold anything, including the stranded"
  echo "!! work this check exists to find."
  echo
fi
if [ -n "$REPO_ARG" ]; then
  echo "== $flags FLAG(s) in $REPO_ARG; $blind BLIND =="
else
  echo "== $flags FLAG(s) across $touched recently-touched repo(s); $blind BLIND =="
fi
echo "FLAGs are candidates for the closing session to resolve before it ends;"
echo "this script never edits, commits, or pushes anything."

# --- the gate --------------------------------------------------------------
# Order matters: a FLAG is something we DID see and is the stronger claim, so
# it wins over BLIND when both are present.
[ "$STRICT" = 1 ] && [ "$flags" -gt 0 ] && exit 1

if [ "$STRICT" = 1 ] && [ "$blind" -gt 0 ] && [ "$ALLOW_BLIND" != 1 ]; then
  # Interactive override. Both stdin AND stdout must be a TTY: a hook gets
  # neither, cron gets neither, and a lint that blocks forever waiting for an
  # answer nobody is there to give is worse than one that never gated.
  if [ -t 0 ] && [ -t 1 ]; then
    printf '\n%s BLIND domain(s) were not read. Proceed anyway? [y/N] ' "$blind" >&2
    read -r _reply </dev/tty 2>/dev/null || _reply=""
    case "$_reply" in
      [yY]|[yY][eE][sS])
        echo "closeout-lint: proceeding past $blind BLIND on an interactive override." >&2
        exit 0
        ;;
    esac
  fi
  echo "closeout-lint: refusing -- $blind BLIND domain(s) unread." >&2
  echo "  Audit them: closeout-lint.sh --strict --repo <path>   (one per worktree)" >&2
  echo "  Or accept:  re-run with --allow-blind (states, in the command, that" >&2
  echo "              you chose to proceed without reading them)." >&2
  exit 6
fi
exit 0
