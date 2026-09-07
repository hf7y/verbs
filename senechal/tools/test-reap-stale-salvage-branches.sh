#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/reap-stale-salvage-branches.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
echo '{}' > "$T/senechal.json"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; echo "       $2"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpected '$3'" ;; *) ok "$1" ;; esac; }

exists_on_remote() { git -C "$T/origin.git" show-ref --verify --quiet "refs/heads/$1"; }

OLD_EPOCH="$(date -d '30 days ago' +%s)"
OLD_STAMP="$(date -d "@$OLD_EPOCH" +%Y%m%d%H%M%S)"
YOUNG_STAMP="$(date -d '2 minutes ago' +%Y%m%d%H%M%S)"

OLD_MERGED="salvage/senechal-nightly-batch-${OLD_STAMP}"
OLD_UNMERGED="salvage/senechal-nightly-batch-$(date -d "@$((OLD_EPOCH + 1))" +%Y%m%d%H%M%S)"  # epoch math: a raw digit-string +1 can roll SS to 60 and fail to parse, ~1 run in 60
YOUNG_MERGED="salvage/senechal-nightly-batch-${YOUNG_STAMP}"
WRONG_SHAPE="salvage/senechal-nightly-batch-${OLD_STAMP}-extra"

newrepo() {
  rm -rf "$T/origin.git" "$T/work"
  git init -q --bare "$T/origin.git"
  git --git-dir="$T/origin.git" symbolic-ref HEAD refs/heads/main

  git init -q "$T/seed"
  git -C "$T/seed" config user.email t@t; git -C "$T/seed" config user.name t
  mkdir -p "$T/seed/tools" "$T/seed/lib"
  cp "$SCRIPT" "$T/seed/tools/reap-stale-salvage-branches.sh"
  cp "$HERE/../lib/common.sh" "$T/seed/lib/common.sh"
  echo base > "$T/seed/f"
  git -C "$T/seed" add -A; git -C "$T/seed" commit -qm base
  git -C "$T/seed" branch -M main
  git -C "$T/seed" push -q "$T/origin.git" main

  git -C "$T/seed" branch "$OLD_MERGED"
  git -C "$T/seed" branch "$YOUNG_MERGED"
  git -C "$T/seed" branch "$WRONG_SHAPE"

  git -C "$T/seed" checkout -q -b "$OLD_UNMERGED"
  echo unmerged > "$T/seed/f"; git -C "$T/seed" commit -qam unmerged
  git -C "$T/seed" checkout -q main

  echo advance > "$T/seed/f"; git -C "$T/seed" commit -qam advance

  git -C "$T/seed" push -q "$T/origin.git" main "$OLD_MERGED" "$YOUNG_MERGED" "$WRONG_SHAPE" "$OLD_UNMERGED"

  git clone -q "$T/origin.git" "$T/work"
  git -C "$T/work" config user.email t@t; git -C "$T/work" config user.name t
  rm -rf "$T/seed"
}

run() { RUN_OUT="$(cd "$T/work" && SENECHAL_CONFIG="$T/senechal.json" bash tools/reap-stale-salvage-branches.sh "$@" 2>&1)"; RUN_RC=$?; }

echo "test-reap-stale-salvage-branches.sh"

echo "-- A. default (no --execute) is dry-run: reports, deletes nothing"
newrepo
run
has   "A1 reports what it would delete"                 "$RUN_OUT" "would  $OLD_MERGED"
exists_on_remote "$OLD_MERGED" \
  && ok "A2 the mergeable branch still exists after a dry run" \
  || bad "A2 the mergeable branch still exists after a dry run" "it was deleted"

echo "-- B. age cutoff: a young branch is kept even though it is merged"
run
has   "B1 names it as kept for age, not deleted"         "$RUN_OUT" "keep   $YOUNG_MERGED  (younger than 24h)"
hasnt "B2 does not offer to delete the young branch"     "$RUN_OUT" "would  $YOUNG_MERGED"

echo "-- C. reachability: an old branch with unmerged commits is kept"
run
has   "C1 names it as kept for carrying unmerged work"   "$RUN_OUT" "keep   $OLD_UNMERGED  (carries commits not on main)"
hasnt "C2 does not offer to delete the unmerged branch"  "$RUN_OUT" "would  $OLD_UNMERGED"

echo "-- D. shape: a name outside the exact generated pattern is never considered"
run
hasnt "D1 the wrong-shape branch is not mentioned at all" "$RUN_OUT" "$WRONG_SHAPE"

echo "-- E. --execute actually deletes only the old, merged branch"
run --execute
has   "E1 deletes the old merged branch"                 "$RUN_OUT" "deleted $OLD_MERGED"
exists_on_remote "$OLD_MERGED" \
  && bad "E2 the branch is actually gone from the remote" "still present" \
  || ok "E2 the branch is actually gone from the remote"
exists_on_remote "$OLD_UNMERGED" \
  && ok "E3 the unmerged branch survives --execute" \
  || bad "E3 the unmerged branch survives --execute" "it was deleted"
exists_on_remote "$YOUNG_MERGED" \
  && ok "E4 the young branch survives --execute" \
  || bad "E4 the young branch survives --execute" "it was deleted"
exists_on_remote "$WRONG_SHAPE" \
  && ok "E5 the wrong-shape branch survives --execute" \
  || bad "E5 the wrong-shape branch survives --execute" "it was deleted"
has   "E6 the summary line counts deleted and kept"      "$RUN_OUT" "1 deleted, 0 already gone, 2 kept, 0 error(s)"
hasnt "E7 the wrong-shape branch is not counted anywhere" "$RUN_OUT" "$WRONG_SHAPE"

echo "-- F. --min-age-hours overrides the default cutoff"
newrepo
run --execute --min-age-hours=0
has   "F1 with a zero cutoff the young branch is now eligible" "$RUN_OUT" "deleted $YOUNG_MERGED"

echo "-- G. a non-numeric --min-age-hours refuses rather than guessing"
newrepo
run --min-age-hours=soon
hasnt "G1 does not report success" "$RUN_OUT" "deleted"
has   "G2 names the bad value"     "$RUN_OUT" "--min-age-hours wants a whole number"

echo "-- H. an unknown flag refuses rather than guessing"
newrepo
run --bogus
hasnt "H1 does not report success" "$RUN_OUT" "deleted"
has   "H2 names the bad argument"  "$RUN_OUT" "unknown argument: --bogus"

echo
echo "test-reap-stale-salvage-branches.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
