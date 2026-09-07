#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/bashified-ships-main.sh"
fails=0
t() { local want=$1 desc=$2; shift 2
  local out rc; out=$("$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then echo "ok   $desc"
  else echo "FAIL $desc (rc=$rc want $want)"; echo "$out" | sed 's/^/     /'; fails=$((fails+1)); fi
}
has() { grep -qF -- "$1" <<<"$out"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
git -C "$T" init -q
git -C "$T" config user.email t@t; git -C "$T" config user.name t
echo one > "$T/f"; git -C "$T" add f; git -C "$T" commit -qm one
git -C "$T" branch -f fake-main
git -C "$T" branch -f fake-ship
echo '{"watch": []}' > "$T/senechal.json"

run() {  # git via GIT_DIR/GIT_WORK_TREE, since the script cd's to its own dir
  GIT_DIR="$T/.git" GIT_WORK_TREE="$T" SENECHAL_CONFIG="$T/senechal.json" \
    SENECHAL_MAIN_REF=refs/heads/fake-main SENECHAL_SHIP_REF=refs/heads/fake-ship \
    bash "$CHECK" "$@"
}

t 0 "equal refs -> pass" run -q

git -C "$T" checkout -q fake-ship
git -C "$T" commit -q --allow-empty -m "merge pr: reintegrate main"
t 0 "ship ahead by a tree-identical (PR-merge-route) commit -> pass" run -q
out=$(run); has "everything on main ships" || { echo "FAIL missing ok line"; echo "$out"; fails=$((fails+1)); }

echo two > "$T/g"; git -C "$T" add g; git -C "$T" commit -qm "direct edit on ship"
t 3 "ship ahead with real file drift -> warn" run -q
out=$(run); has "edited directly somewhere" || { echo "FAIL missing warn text"; echo "$out"; fails=$((fails+1)); }

git -C "$T" checkout -q fake-main
echo three > "$T/h"; git -C "$T" add h; git -C "$T" commit -qm "main moved on"
t 5 "ship behind main -> fail" run -q

git -C "$T" checkout -q --detach
git -C "$T" branch -D fake-ship
t 5 "ship ref missing -> fail" run -q

git -C "$T" branch -f fake-ship fake-main
git -C "$T" branch -D fake-main
t 2 "main ref missing -> incomplete, not a pass" run -q

[ "$fails" = 0 ] && echo "PASS" || echo "$fails FAILED"
exit $((fails > 0))
