#!/usr/bin/env bash
# roster-set.sh -- WHICH REPOSITORIES THIS ESTATE SWEEPS. One list, one file.
#
# Was typed into three sweeps: three chances to add a repo to two of them.
# STILL TYPED -- hf7y owns roughly twice what this estate sweeps, and uid
# 3000-3099 misses the ecosystem repos that carry decisions and never dispatch.

[ -n "${SWEEP_SET_LIB:-}" ] && return 0  # exported as SWEEP*, not ROSTER*: distinct from scheduler's schedule/ROSTER, the sole arming authority (#905)
SWEEP_SET_LIB=1

. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/estate-set.sh"
SWEEP_OWNER="${SWEEP_OWNER:-$GH_ESTATE_OWNER}"

# SWEPT, NOT ARMED. Membership says which repos to READ; liveness is
# lib/arming.sh's authority, read at run time. Names here are REPO names, not
# ROSTER keys -- $OWNER/$p is a GitHub path (#905). SWEEP_ROSTER_ALIAS maps.
SWEEP_PROJECTS=(
  abletim american-cycle apms-2173 baudin bibliothecaire chezz crt
  dcp-gate-site dog ecosim gardien groc-mangr nine-speakers realisateur
  scheduler secretaire senechal sequestria vim-arcade wtul
)

SWEEP_ROSTER_ALIAS='apms=apms-2173'   # ROSTER key -> repo name, where they differ

sweep_repo() {
  local kv
  for kv in $SWEEP_ROSTER_ALIAS; do
    [ "${kv%%=*}" = "$1" ] && { printf '%s' "${kv#*=}"; return 0; }
  done
  printf '%s' "$1"
}

# sweep_unswept <roster-text> -- live ROSTER rows SWEEP omits, as repo names.
# Reads the roster, so an ARRIVAL reports itself; H1's pinned list cannot.
sweep_unswept() {
  local key state repo
  while IFS=$'\t' read -r key state; do
    [ "$state" = live ] || continue
    repo="$(sweep_repo "$key")"
    case " ${SWEEP[*]} " in *" $repo "*) ;; *) printf '%s\n' "$repo" ;; esac
  done <<< "$1"
}

# ECOSYSTEM: carries decisions, never dispatches. WIRED, NOT ARMED -- swept by
# decision-rot, given no account, no crontab row and no quota.
#
# ARMING IS A SEPARATE ACT and deliberately not done here: being swept costs
# one API read per run, being armed costs quota every night.
SWEEP_ECOSYSTEM=(  # dcp-gate-site moved to SWEEP_PROJECTS 2026-09-02 (#905): onboarded live with an account 2026-08-28, so it now dispatches
  verbs front-door basheur
  musc-2300 scriba-senatus french-textbook
  etalon vitae space-canon maitre
)

SWEEP=("${SWEEP_PROJECTS[@]}" "${SWEEP_ECOSYSTEM[@]}")
