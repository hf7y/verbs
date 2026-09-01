#!/usr/bin/env bash
# dose-common.sh -- the half `dose <project>` and `dose host` must agree on.
#
# WHY IT EXISTS. Both forms read the SAME roster from the SAME place and write
# crontabs through the SAME rules. Written twice they drift, and the drift is
# silent: hf7y/scheduler#119 is that exact failure caught one commit early --
# `dose <project>` kept converging five staggered per-account crontabs for six
# hours after hf7y/scheduler#55 decided there should be one host tick, and it
# exited 0 the whole time.
#
# Sourced, never executed. Callers set nothing; every knob below already reads
# from the environment so a witness can point it at fixtures.
#
# RUNNER: tests/dose-project-witness.sh, tests/dose-host-witness.sh
set -uo pipefail

REPO_SLUG="${DOSE_REPO_SLUG:-hf7y/scheduler}"
ROSTER_REF="${DOSE_ROSTER_REF:-main}"
GH_BIN="${DOSE_GH_BIN:-gh}"
CRONTAB_BIN="${DOSE_CRONTAB_BIN:-crontab}"
HOST="${DOSE_HOST_OVERRIDE:-$(hostname -s 2>/dev/null || echo unknown)}"
LOCAL_ACCOUNT="$(id -un)"

# --- stagger: IDENTICAL formula to cron_spec_for() in realisateur's
# bin/wire-release-channel.sh (cksum % 60 of the name). Not sourced -- that
# script is a CLI entry point that consumes $@ on load, not a library -- but
# the transform is copied verbatim so dose and the release-channel tick can
# never disagree about which minute a given name lands on.
stagger_minute() {
  printf '%d' "$(( $(cksum <<<"$1" | cut -d' ' -f1) % 60 ))"
}

# Roster rate ("6h" / "1h" / "30m", per hf7y/scheduler#81) -> 5-field cron,
# minute(s) staggered by project name. Echoes the fields; returns 1 on a rate
# this dose does not understand (a broken roster row, not a usage error).
cron_fields_for_rate() {
  local rate="$1" name="$2" m n v i count vals
  m="$(stagger_minute "$name")"
  if [[ "$rate" =~ ^([0-9]+)h$ ]]; then
    n="${BASH_REMATCH[1]}"
    if [ "$n" -eq 1 ]; then printf '%s * * * *' "$m"; else printf '%s */%s * * *' "$m" "$n"; fi
    return 0
  fi
  if [[ "$rate" =~ ^([0-9]+)m$ ]]; then
    n="${BASH_REMATCH[1]}"
    { [ "$n" -ge 1 ] && [ "$n" -lt 60 ] && [ $((60 % n)) -eq 0 ]; } || return 1
    count=$((60 / n)); v=$m; vals="$m"
    for ((i = 1; i < count; i++)); do v=$(( (v + n) % 60 )); vals="$vals,$v"; done
    vals="$(printf '%s\n' "${vals//,/$'\n'}" | sort -n | paste -sd, -)"
    printf '%s * * * *' "$vals"
    return 0
  fi
  return 1
}

validate_cron() { [ "$(awk '{print NF}' <<<"$1")" -eq 5 ]; }

# --- crontab access, one account's at a time. Foreign-account read mirrors
# bin/sync-crontab.sh's read_crontab_for(): "no crontab for" is a successful
# read of nothing (crontab -l's own exit 1 for that case), anything else
# nonzero is a real failure and must not be swallowed into "empty".
crontab_read() {
  local acct="$1" out rc
  if [ "$acct" = "$LOCAL_ACCOUNT" ]; then
    "$CRONTAB_BIN" -l 2>/dev/null || true
    return 0
  fi
  out="$(sudo -n -u "$acct" "$CRONTAB_BIN" -l 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"no crontab for"*) printf ''; return 0 ;;
      *) printf '%s' "$out" >&2; return 1 ;;
    esac
  fi
  printf '%s' "$out"
}
crontab_write() {
  local acct="$1" content="$2"
  if [ "$acct" = "$LOCAL_ACCOUNT" ]; then
    printf '%s\n' "$content" | "$CRONTAB_BIN" -
  else
    printf '%s\n' "$content" | sudo -n -u "$acct" "$CRONTAB_BIN" -
  fi
}

# --- 1. bootstrap: read schedule/ROSTER from GitHub, not a local clone -----
# WHOSE CREDENTIAL READS THE ROSTER. root has no `gh` auth on monkey (measured
# 2026-08-11 and again 2026-08-30), so a human-invoked converger borrows
# $SUDO_USER's rather than install a standing secret for a transient read.
# BUT THE DISPATCH TICK READS THE ROSTER NOW (#412), retiring the "only the
# converger reads it" premise this block carried: a cron tick has no human to
# borrow from, so host mode reads as root and gets BLIND -- closed, never
# working. `usage-paced-runner.sh --check` measures it; the credential is #364.
gh_as() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    sudo -n -u "$SUDO_USER" "$GH_BIN" "$@"
  else
    "$GH_BIN" "$@"
  fi
}

# fetch_repo_file <relpath> -- print a file from the repo, over gh, no clone.
#
# GENERALISED FROM fetch_roster, not copied beside it. schedule/FREEZE needs
# exactly the same treatment as schedule/ROSTER (hf7y/scheduler#124) and a
# second fetcher would be a second answer to "is this repo reachable" -- the
# one-fact-two-readers shape this estate keeps paying for. The BLIND/GAP
# distinction below is the whole value and must not be re-derived per caller.
fetch_repo_file() {
  local rel="${1:?fetch_repo_file needs a repo-relative path}"
  if ! command -v "$GH_BIN" >/dev/null 2>&1; then
    echo "BLIND: '$GH_BIN' not on PATH -- cannot read $rel" >&2
    return 6
  fi
  local out rc
  out="$(gh_as api "repos/$REPO_SLUG/contents/$rel?ref=$ROSTER_REF" --jq '.content' 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    # "THE FILE IS NOT THERE" AND "I COULD NOT LOOK" ARE DIFFERENT ANSWERS, and
    # collapsing them is this estate's signature failure -- selfdev-release-tick
    # makes the same distinction in the other direction ("Deliberately NOT 3.
    # BLIND means we could not look at the channel; this means we looked at
    # ourselves and the bootstrap is not here").
    #
    # They ARE distinguishable, contrary to a first draft of this function: a
    # 404 from the contents endpoint, when `repos/<slug>` itself reads fine, is
    # a POSITIVE statement that the ref carries no such file. Only if the repo
    # probe fails too is dose actually blind. Without this, a mistyped path
    # would report "cannot see truth" forever instead of "that file is absent",
    # and the operator would go looking at credentials.
    if printf '%s' "$out" | grep -q 'HTTP 404' \
       && gh_as api "repos/$REPO_SLUG" --jq '.name' >/dev/null 2>&1; then
      echo "GAP: $REPO_SLUG is reachable and $ROSTER_REF carries no $rel." >&2
      echo "     It has not landed on that ref yet, or the path is wrong." >&2
      echo "     This is not a credential problem: repos/$REPO_SLUG read fine on the same token." >&2
      return 4
    fi
    echo "BLIND: gh could not read $rel from $REPO_SLUG@$ROSTER_REF -- unauthenticated or unreachable. Nothing was verified: $out" >&2
    return 6
  fi
  printf '%s' "$out" | tr -d '\n' | base64 -d 2>/dev/null
}

# The roster is just the file this was written for first. Kept as a named
# function because every caller reads better saying what it wants than saying
# a path, and because the path itself then lives in exactly one place.
fetch_roster() { fetch_repo_file schedule/ROSTER; }

branch_head_sha() {  # <ref> -> the sha it currently points at
  local ref="${1:?branch_head_sha needs a ref}"
  gh_as api "repos/$REPO_SLUG/git/ref/heads/$ref" --jq '.object.sha' 2>/dev/null
}

create_repo_branch() {  # <new-branch> <base-ref>, off base's CURRENT tip
  local branch="${1:?create_repo_branch needs a branch name}" base="${2:?needs a base ref}" sha
  sha="$(branch_head_sha "$base")" || return 6
  [ -n "$sha" ] || return 6
  gh_as api "repos/$REPO_SLUG/git/refs" -f ref="refs/heads/$branch" -f sha="$sha" >/dev/null
}

write_repo_file() {  # <path> <content> <branch> <commit-msg> -- re-fetches sha first, the API's optimistic lock
  local rel="${1:?write_repo_file needs a path}" content="$2" branch="${3:?needs a branch}" msg="${4:?needs a commit message}"
  local sha
  sha="$(gh_as api "repos/$REPO_SLUG/contents/$rel?ref=$branch" --jq '.sha' 2>/dev/null)"
  [ -n "$sha" ] || return 6
  gh_as api "repos/$REPO_SLUG/contents/$rel" -X PUT \
    -f message="$msg" -f content="$(printf '%s' "$content" | base64 -w0)" \
    -f sha="$sha" -f branch="$branch" >/dev/null
}

open_repo_pr() {  # <branch> <base> <title> <body> -> "<number> <url>"
  local branch="${1:?}" base="${2:?}" title="${3:?}" body="${4:-}"
  gh_as api "repos/$REPO_SLUG/pulls" \
    -f title="$title" -f head="$branch" -f base="$base" -f body="$body" \
    --jq '"\(.number) \(.html_url)"'
}

enable_pr_auto_merge() {  # <pr-number> -- GraphQL only; best-effort, PR still exists if this fails
  local num="${1:?enable_pr_auto_merge needs a PR number}" node_id
  node_id="$(gh_as api "repos/$REPO_SLUG/pulls/$num" --jq '.node_id' 2>/dev/null)"
  [ -n "$node_id" ] || return 1
  gh_as api graphql -f query='
    mutation($id: ID!) {
      enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: SQUASH}) {
        pullRequest { number }
      }
    }' -f id="$node_id" >/dev/null 2>&1
}

# NOTHING BELOW THIS LINE MAY RUN AT SOURCE TIME. This file ended with
#   ROSTER_CONTENT="$(fetch_roster)" || exit $?
# from its extraction in hf7y/scheduler#120 until 2026-08-11, which made
# `. lib/dose-common.sh` do a NETWORK FETCH and, on failure, `exit` the
# CALLING process with dose's exit code. Caught when freeze-check.sh sourced it
# for fetch_repo_file and died with 6 (dose's BLIND) instead of its own
# contract's 2 (FROZEN) -- a library reaching past its caller's error handling.
# The fetch belongs to whoever wants the roster; see bin/dose-project.sh.
