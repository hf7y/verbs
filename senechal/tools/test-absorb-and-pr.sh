#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/absorb-and-pr.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; echo "       $2"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want '$2', got '$3'"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpected '$3'" ;; *) ok "$1" ;; esac; }

FOOTPRINT_DOOR='{
  "comment": "test", "target": "estate.footprint", "key": "id",
  "required": ["id","kind","target","host","owner","status","retire","notes"],
  "enums": {"kind": ["path"], "status": ["live","retiring","retired"]}
}'

FILING_ID=spawn-here-symlinks
issue_json() {
  cat <<EOF
[{"number": 900, "title": "t", "body": "\`\`\`senechal-door\n{\"door\": \"footprint\", \"fields\": {\"id\": \"$FILING_ID\", \"kind\": \"path\", \"target\": \"/x\", \"host\": \"mandark\", \"owner\": \"senechal\", \"status\": \"live\", \"retire\": \"rm /x\", \"notes\": \"n\"}}\n\`\`\`", "comments": []}]
EOF
}

newrepo() {
  rm -rf "$T/origin.git" "$T/work" "$T/seed" "$T/bin"
  git init -q --bare "$T/origin.git"
  git --git-dir="$T/origin.git" symbolic-ref HEAD refs/heads/main

  git init -q "$T/seed"
  git -C "$T/seed" config user.email t@t; git -C "$T/seed" config user.name t
  mkdir -p "$T/seed/tools" "$T/seed/registry"
  cp "$HERE/absorb-notices.py" "$T/seed/tools/absorb-notices.py"
  cp "$HERE/boundary.py" "$T/seed/tools/boundary.py"
  cp "$SCRIPT" "$T/seed/tools/absorb-and-pr.sh"
  printf '{"doors": {"footprint": %s}}\n' "$FOOTPRINT_DOOR" > "$T/seed/registry/front-doors.json"
  echo '{"estate": {"footprint": []}}' > "$T/seed/registry/senechal-registry.json"
  echo '{"entries": {}, "config_keys": {"estate.footprint": {"class": "fleet", "why": "test"}}}' > "$T/seed/registry/boundary.json"
  git -C "$T/seed" add -A; git -C "$T/seed" commit -qm seed
  git -C "$T/seed" branch -M main
  git -C "$T/seed" push -q "$T/origin.git" main

  git clone -q "$T/origin.git" "$T/work"
  git -C "$T/work" config user.email t@t; git -C "$T/work" config user.name t

  mkdir -p "$T/bin"
  : > "$T/gh.log"
  cat > "$T/bin/gh" <<FAKE
#!/usr/bin/env bash
echo "\$*" >> "$T/gh.log"
case "\$1 \$2" in
  "issue list") cat "$T/gh-issues.json" ;;
  "issue close") exit 0 ;;
  "pr create") echo "https://github.com/hf7y/senechal/pull/999" ;;
  *) echo "fake gh: unhandled: \$*" >&2; exit 1 ;;
esac
FAKE
  chmod +x "$T/bin/gh"
}

run() {
  ( cd "$T/work" && PATH="$T/bin:$PATH" SENECHAL_ROOT="$T/work" bash "$T/work/tools/absorb-and-pr.sh" ) >"$T/out" 2>&1
  RC=$?
  OUT="$(cat "$T/out")"
}

echo "-- A. nothing pending -- no branch, no commit, no PR"
newrepo
echo '[]' > "$T/gh-issues.json"
run
is   "A1 exits 0"                              0 "$RC"
has  "A1 says there is nothing to PR"          "$OUT" "nothing to PR"
hasnt "A1 never calls gh pr create"            "$(cat "$T/gh.log")" "pr create"
is   "A2 the work tree is back on main"        "main" "$(git -C "$T/work" rev-parse --abbrev-ref HEAD)"
is   "A3 origin gained no branch"              "" "$(git --git-dir="$T/origin.git" branch --list 'absorb-notices-*')"

echo "-- B. a real, absorbable filing -- branch pushed, PR opened, main untouched"
newrepo
issue_json > "$T/gh-issues.json"
run
is   "B1 exits 0"                              0 "$RC"
has  "B1 reports the PR"                       "$OUT" "opened a PR"
has  "B2 gh was asked to create a PR"          "$(cat "$T/gh.log")" "pr create"
is   "B3 the work tree ends back on main"      "main" "$(git -C "$T/work" rev-parse --abbrev-ref HEAD)"
BR="$(git --git-dir="$T/origin.git" branch --list 'absorb-notices-*' | tr -d ' *')"
[ -n "$BR" ] && ok  "B4 origin gained the absorb branch" \
             || bad "B4 origin gained the absorb branch" "no absorb-notices-* ref on origin"
git --git-dir="$T/origin.git" cat-file -e "main:registry/senechal-registry.json" 2>/dev/null
if git --git-dir="$T/origin.git" show "main:registry/senechal-registry.json" | grep -q "$FILING_ID"; then
  bad "B5 main is NOT modified directly" "the filing landed on main without a PR"
else
  ok  "B5 main is NOT modified directly"
fi
[ -n "$BR" ] && git --git-dir="$T/origin.git" show "$BR:registry/senechal-registry.json" | grep -q "$FILING_ID" \
  && ok  "B6 the branch DOES carry the absorbed filing" \
  || bad "B6 the branch DOES carry the absorbed filing" "not found on $BR"

echo "-- C. re-running against an already-absorbed, unmerged PR is a no-op"
echo '[]' > "$T/gh-issues.json"   # #484's own promise: --close already closed #900
run
is   "C1 exits 0"                              0 "$RC"
has  "C1 finds nothing left to absorb"         "$OUT" "nothing to PR"
BR2="$(git --git-dir="$T/origin.git" branch --list 'absorb-notices-*' | wc -l | tr -d ' ')"
is   "C2 no second branch was created"         "1" "$BR2"

echo "-- E. one good filing, one rejected -- the good one still gets a PR (#620/#622 shape)"
newrepo
cat > "$T/gh-issues.json" <<EOF
[{"number": 900, "title": "t", "body": "\`\`\`senechal-door\n{\"door\": \"footprint\", \"fields\": {\"id\": \"$FILING_ID\", \"kind\": \"path\", \"target\": \"/x\", \"host\": \"mandark\", \"owner\": \"senechal\", \"status\": \"live\", \"retire\": \"rm /x\", \"notes\": \"n\"}}\n\`\`\`", "comments": []},
 {"number": 901, "title": "t", "body": "no fence here", "comments": []}]
EOF
run
is   "E1 exits 1 (the reject's own code, not silently 0)" 1 "$RC"
has  "E2 reports the PR"                       "$OUT" "opened a PR"
has  "E3 gh was asked to create a PR"          "$(cat "$T/gh.log")" "pr create"
BR3="$(git --git-dir="$T/origin.git" branch --list 'absorb-notices-*' | tr -d ' *')"
[ -n "$BR3" ] && git --git-dir="$T/origin.git" show "$BR3:registry/senechal-registry.json" | grep -q "$FILING_ID" \
  && ok  "E4 the branch carries the good filing despite the reject" \
  || bad "E4 the branch carries the good filing despite the reject" "not found on $BR3"

echo "-- D. a rejected filing -- no PR, no branch, the reason surfaces"
newrepo
cat > "$T/gh-issues.json" <<'EOF'
[{"number": 901, "title": "t", "body": "no fence here", "comments": []}]
EOF
run
is   "D1 exits 1 (absorb-notices.py's own REJECT code)" 1 "$RC"
has  "D1 the reason is visible"                "$OUT" "no \`\`\`senechal-door"
hasnt "D1 never calls gh pr create"            "$(cat "$T/gh.log")" "pr create"
is   "D2 origin gained no branch"              "" "$(git --git-dir="$T/origin.git" branch --list 'absorb-notices-*')"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
