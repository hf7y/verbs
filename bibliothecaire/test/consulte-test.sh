#!/usr/bin/env bash
# consulte-test.sh -- the man page, executed.
#
# Every row here names the page sentence it checks, so "the contract was kept"
# is a MEASUREMENT rather than a claim -- the shape trie-test.sh established.
#
# WHY THERE IS A FAKE gh AND NOT A LIVE ONE. The thing under test is a door
# onto somebody else's repository. A test that filed real issues would either
# spam the queue this verb exists to keep clean, or be skipped on any host
# without a credential -- and a skipped test reads exactly like a passing one
# in a log. The stub lets every branch run everywhere, including the three that
# matter most and that a live run can barely reach on purpose: the duplicate
# refusal, a `gh issue create` that FAILS, and a `gh` that is not installed.
#
#   ./test/consulte-test.sh [path-to-consulte]

set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
VERB="${1:-$ROOT/bin/consulte}"
PAGE="$ROOT/man/consulte.1"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "output lacked [$3]"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "output contained [$3]"; else ok "$1"; fi; }

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin" "$D/lib" "$D/fake"
cp "$VERB" "$D/bin/consulte"; chmod +x "$D/bin/consulte"
cp "$ROOT/lib/verb.sh" "$D/lib/verb.sh"

# The stub. QUEUE is what `gh issue list` returns; CREATE_RC is whether
# `gh issue create` succeeds; every call is logged so "nothing was filed" is
# something the test can SEE rather than infer from an exit code.
cat > "$D/fake/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "auth status") exit 0 ;;
  "label create") exit 1 ;;   # already exists: the normal case
  "issue list")   [ "${LIST_RC:-0}" = 0 ] || { echo "HTTP 403" >&2; exit 1; }
                  cat "$QUEUE"; exit 0 ;;
  "issue view")   printf '{"number":20,"title":"t","state":"OPEN","labels":[],"url":"u","body":"b","comments":[]}\n'; exit 0 ;;
  "issue create") [ "${CREATE_RC:-0}" = 0 ] || { echo "GraphQL: Title is too long" >&2; exit 1; }
                  echo "https://github.com/hf7y/bibliothecaire/issues/20"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$D/fake/gh"

C="$D/bin/consulte"
export GH_LOG="$D/gh.log" QUEUE="$D/queue.json"
echo '[]' > "$QUEUE"
run() { : > "$GH_LOG"; PATH="$D/fake:$PATH" "$C" "$@" 2>&1; }

CLAIM="Local self-repair should beat the best central-sensing arm."
FALS="FALSIFIED if H_local does not reduce undetected_ticks by 10%."

printf 'consulte -- contract test\n\n'

# --- ROW 2: every SYNOPSIS form the page shows runs as written ---------------
printf 'SYNOPSIS forms run as written\n'
out="$(run --help)";    check "consulte --help"    "$?" "0"
out="$(run --version)"; check "consulte --version" "$?" "0"
has "--version prints the utility name" "$out" "consulte (bashified)"
out="$(run --claim "$CLAIM" --falsifier "$FALS" --from ecosim)"
check "file: --claim/--falsifier/--from" "$?" "0"
out="$(run list)";      check "consulte list"      "$?" "0"
out="$(run show 20)";   check "consulte show N"    "$?" "0"

# --- the page: "Both are required" -------------------------------------------
printf '\nrequired fields are required (DESCRIPTION)\n'
out="$(run --falsifier "$FALS" --from ecosim)"; check "no --claim exits 2" "$?" "2"
has "and says which" "$out" "--claim is required"
out="$(run --claim "$CLAIM" --from ecosim)";    check "no --falsifier exits 2" "$?" "2"
has "and says why, not just what" "$out" "asks for agreement"
out="$(run --claim "$CLAIM" --falsifier "$FALS")"; check "no --from exits 2" "$?" "2"
out="$(run --claim "$CLAIM" --falsifier "$FALS" --from ecosim --context-file /nope)"
check "unreadable --context-file exits 2" "$?" "2"
out="$(run stray --claim "$CLAIM" --falsifier "$FALS" --from ecosim)"
check "a stray argument exits 2" "$?" "2"
hasnt "and nothing was filed" "$(cat "$GH_LOG")" "issue create"

# --- THE COST BOUNDARY: "carries no --summon flag at all" --------------------
printf '\nthe cost boundary (THE COST BOUNDARY)\n'
out="$(run --summon --claim "$CLAIM" --falsifier "$FALS" --from ecosim)"
check "--summon exits 2" "$?" "2"
has "refused by name, not ignored" "$out" "the flag does not exist here"
out="$(run --help)"
has "--help answers the cost question on its own" "$out" "cannot spend money"

# --- what actually gets filed ------------------------------------------------
printf '\nwhat gets filed (DESCRIPTION, "labelled request")\n'
out="$(run --claim "$CLAIM" --falsifier "$FALS" --prediction "H_local beats C_blind_symbol." --from ecosim)"
check "a full request files" "$?" "0"
has "reports the issue it filed"    "$out" "filed as hf7y/bibliothecaire#20"
has "names the queue label"         "$out" "label: request"
log="$(cat "$GH_LOG")"
has "files under --label request"   "$log" "--label request"
has "carries the claim in the body" "$log" "$CLAIM"
has "carries the falsifier"         "$log" "$FALS"
has "carries the prediction"        "$log" "H_local beats C_blind_symbol."
has "names the caller"              "$log" "from **ecosim**"
has "says answering is metered"     "$log" "METERED"

# The page: "the title is an index entry and never the record."
printf '\nthe title is an index entry, never the record (--claim)\n'
LONG="$(printf 'word%.0s ' $(seq 1 200))"
out="$(run --claim "$LONG" --falsifier "$FALS" --from ecosim)"
check "a 1000-character claim still files" "$?" "0"
title="$(grep -o -- '--title [^-]*' "$GH_LOG" | head -1)"
if [ "${#title}" -lt 256 ]; then ok "title stays under GitHub's 256 cap"
else bad "title stays under GitHub's 256 cap" "got ${#title}"; fi
has "truncation is marked" "$(cat "$GH_LOG")" "[truncated]"

# --- DUPLICATES --------------------------------------------------------------
printf '\nduplicates (DUPLICATES)\n'
printf '[{"number":19,"body":"Filed by consulte\\n%s\\nrest"}]\n' "$CLAIM" > "$QUEUE"
out="$(run --claim "$CLAIM" --falsifier "$FALS" --from ecosim)"
check "an open duplicate exits 9" "$?" "9"
has "names the issue that already has it" "$out" "already open as hf7y/bibliothecaire#19"
hasnt "and files nothing" "$(cat "$GH_LOG")" "issue create"
out="$(run --force --claim "$CLAIM" --falsifier "$FALS" --from ecosim)"
check "--force files anyway" "$?" "0"
has "and it really filed" "$(cat "$GH_LOG")" "issue create"
echo '[]' > "$QUEUE"

# --- --dry-run: "file nothing" -----------------------------------------------
printf '\n--dry-run composes and files nothing (OPTIONS)\n'
out="$(run --dry-run --claim "$CLAIM" --falsifier "$FALS" --from ecosim)"
check "--dry-run exits 0" "$?" "0"
has "and shows the request"  "$out" "$CLAIM"
hasnt "and files nothing"    "$(cat "$GH_LOG")" "issue create"
has "but still checks credentials" "$(cat "$GH_LOG")" "auth status"

# --- EXIT 5: it tried to file and could not ----------------------------------
printf '\nexit 5 BROKEN: it tried to file and could not (EXIT STATUS)\n'
out="$(CREATE_RC=1 run --claim "$CLAIM" --falsifier "$FALS" --from ecosim)"
check "a failing gh issue create exits 5" "$?" "5"
has "and says the request was NOT filed" "$out" "was NOT filed"
hasnt "and never claims a filing"        "$out" "filed as"
# gh absent entirely. A bare PATH is not enough -- the verb needs readlink and
# friends to start at all, and an empty PATH tests exit 127 from the shell
# rather than this verb's own guard. So: a minimal PATH carrying exactly what
# the verb uses, and no gh.
mkdir -p "$D/min"
for t in bash readlink dirname date hostname head cat mkdir jq sed grep; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$D/min/$t"
done
out="$(: > "$GH_LOG"; PATH="$D/min" "$C" --claim "$CLAIM" --falsifier "$FALS" --from ecosim 2>&1)"
check "a missing gh exits 5" "$?" "5"
has "and names the fix"  "$out" "https://cli.github.com"
has "and calls it a stop" "$out" "not something to route around"

# --- EXIT 6: BLIND is not an empty queue -------------------------------------
printf '\nexit 6 BLIND is never "nothing to report" (EXIT STATUS)\n'
out="$(LIST_RC=1 run list)"
check "an unreadable queue exits 6" "$?" "6"
has "and says so in those words" "$out" "NOT \"nothing to report\""
hasnt "and never prints an empty queue" "$out" "no requests on"
out="$(LIST_RC=1 run --claim "$CLAIM" --falsifier "$FALS" --from ecosim)"
check "an unreadable queue blocks filing too" "$?" "6"

# --- ROW 3: the surface is bidirectional (page <-> program) ------------------
printf '\nsurface is bidirectional (page <-> program)\n'
# troff escapes every hyphen as \-, so the page is de-escaped before matching.
page="$(sed 's/\\-/-/g' "$PAGE")"
for f in --claim --falsifier --from --prediction --context --context-file \
         --dry-run --force --json --quiet --help --version; do
  if printf '%s' "$page" | grep -q -- "$f"; then ok "page documents $f"
  else bad "page documents $f"; fi
done
for w in list show; do
  if printf '%s' "$page" | grep -q "^\.B consulte $w"; then ok "page documents subcommand $w"
  else bad "page documents subcommand $w"; fi
done
# Every exit code the program declares must appear on the page, and no other.
for e in 0 2 5 6 9; do
  if printf '%s' "$page" | grep -q "^\.B $e$"; then ok "page documents exit $e"
  else bad "page documents exit $e"; fi
done
for e in 3 4 7; do
  if printf '%s' "$page" | grep -q "^\.B $e$"; then bad "page must NOT promise exit $e"
  else ok "page does not promise exit $e (this verb cannot reach it)"; fi
done
if man --warnings -l "$PAGE" >/dev/null 2>"$D/manwarn" && [ ! -s "$D/manwarn" ]; then
  ok "page renders with no troff warnings"
else bad "page renders with no troff warnings" "$(head -2 "$D/manwarn")"; fi

# --- the label is the one scheduler's prompt reads ---------------------------
printf '\nthe label is not retyped per file (FILES)\n'
CONF="${SCHEDULER_CONF:-$HOME/Documents/Projects/scheduler/schedule/bibliothecaire.conf}"
if [ -r "$CONF" ]; then
  if grep -q -- "--label request" "$CONF"; then
    ok "scheduler's BATCH_PROMPT works the same label this verb files under"
  else
    bad "scheduler's BATCH_PROMPT works the same label this verb files under" \
        "no '--label request' in $CONF -- one of the two moved"
  fi
else
  printf '  note  scheduler conf not readable here (%s); the label agreement is UNCHECKED on this host, not confirmed\n' "$CONF"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
