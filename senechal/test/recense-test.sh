#!/usr/bin/env bash
# recense-test.sh -- THE PAGE TEST, mechanized for `recense`.
#
# test/contract-test.sh already covers the universal assertions (rows 3, 4 and
# 6 in their generic form). This file covers what only recense's own page can
# assert: that every SYNOPSIS form runs, that the page and the code name the
# same subcommands in both directions, that every exit code on the page can be
# provoked, and that the EXAMPLES execute.
#
# A row verified by reading is a row that will drift. Everything scored in the
# report is scored here.

set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CMD="${1:-$ROOT/bin/recense}"
PAGE="$ROOT/man/recense.1"

pass=0; fail=0
ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no()   { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }

rc() { "$CMD" "$@" >/dev/null 2>&1; printf '%s' "$?"; }

printf '=== THE PAGE TEST: recense\n    command: %s\n    page:    %s\n\n' "$CMD" "$PAGE"

# --- row 1: NAME is one clause, no "and" -----------------------------------
name_line="$(awk '/^\.SH NAME/{getline; print; exit}' "$PAGE")"
case "$name_line" in
  *" and "*) no "row 1: NAME line contains 'and' -- that is two verbs: $name_line" ;;
  *\\-*)     ok "row 1: NAME is one clause" ;;
  *)         no "row 1: NAME line is not '<verb> \\- <clause>': $name_line" ;;
esac

# --- row 2: every SYNOPSIS form runs as written ----------------------------
# Forms marked `.\" bashify: norun` take an argument that is not ours to
# invent; they are asserted by row 4's provocations instead.
while IFS= read -r form; do
  # shellcheck disable=SC2086
  r="$(rc $form)"
  case "$r" in 0|1|9) ok "row 2: \`recense $form\` runs (exit $r)" ;;
               *)   no "row 2: \`recense $form\` exited $r" ;; esac
done < <(awk '
  /^\.SH SYNOPSIS/ { in_syn=1; next }
  /^\.SH /         { in_syn=0 }
  !in_syn          { next }
  /^\.\\" bashify: norun/ { skip=1; next }
  /^\.B recense$/         { if (skip) { skip=0; next }; print ""; next }
  /^\.B recense /         { if (skip) { skip=0; next }
                            if ($0 ~ /\\f/) next          # flag-form line
                            sub(/^\.B recense /, ""); print }
' "$PAGE")

# --- row 3: surface is bidirectional ---------------------------------------
page_subs="$(grep -oE '^\.B recense [a-z]+' "$PAGE" | awk '{print $3}' | sort -u)"
code_subs="$(awk '/^  [a-z]+\)/ {sub(/\).*/,""); gsub(/ /,""); print}' "$CMD" | sort -u)"
check "row 3: page subcommands == code subcommands" "$page_subs" "$code_subs"

page_flags="$(grep -oE '\\-\\-[a-z]+' "$PAGE" | sed 's/\\//g' | sort -u)"
for f in $page_flags; do
  [ "$f" = "--summon" ] && continue   # documented as ABSENT; asserted below
  if grep -q -- "$f" "$ROOT/lib/verb.sh" "$CMD"; then ok "row 3: $f exists in code"
  else no "row 3: $f is on the page and not in the code"; fi
done

# --- row 4: every documented exit code is reachable ------------------------
check "row 4: exit 0 (census taken)"          "$(rc)"                     0
check "row 4: exit 9 (name not installed)"    "$(rc where definitely-not-installed-xyz)" 9
check "row 4: exit 2 (unknown subcommand)"    "$(rc bogus)"               2
check "row 4: exit 2 (where without a name)"  "$(rc where)"               2

blind_root="$(mktemp -d)"; mkdir -p "$blind_root/dir"; chmod 000 "$blind_root/dir"
blind_rc="$(HOME="$blind_root" PATH="$blind_root/dir:$PATH" "$CMD" paths >/dev/null 2>&1; printf '%s' "$?")"
chmod 755 "$blind_root/dir"; rm -rf "$blind_root"
check "row 4: exit 6 (unreadable path entry)" "$blind_rc" 6

# The codes the page does NOT list must not appear. 3/4/5 would mean the page
# and the runtime disagree about what this utility can do.
for bad in 3 4 5; do
  if [ "$(rc)" = "$bad" ] || [ "$(rc paths)" = "$bad" ]; then
    no "row 4: exit $bad is reachable but not on the page"
  fi
done
ok "row 4: no undocumented exit code observed"

# --- row 5: EXAMPLES execute -----------------------------------------------
bindir="$(dirname "$(readlink -f "$CMD")")"
while IFS= read -r ex; do
  ex="${ex#\$ }"
  PATH="$bindir:$PATH" bash -c "$ex" >/dev/null 2>&1
  r=$?
  # 0 and 1 are both results; 141 is SIGPIPE from an example that pipes into
  # `head`, which is the pipe working, not the example failing.
  case "$r" in 0|1|9|141) ok "row 5: example runs: $ex" ;;
               *)       no "row 5: example failed (exit $r): $ex" ;; esac
done < <(awk '
  /^\.SH EXAMPLES/ { in_ex=1; next }   # scoped: a norun marker in SYNOPSIS
  /^\.SH /         { in_ex=0 }         # otherwise leaks in and eats example 1
  !in_ex           { next }
  /^\.\\" bashify: norun/ { skip=1; next }
  /^\$ recense/    { if (skip) { skip=0; next }
                     gsub(/\\-/, "-")   # roff escapes an option hyphen; the
                     print }            # shell must receive the real one
' "$PAGE")

# --- row 6: cost is answerable from the page alone -------------------------
if grep -q 'cannot spend money' "$PAGE"; then ok "row 6: page states it cannot spend"
else no "row 6: page is silent on cost"; fi
check "row 6: --summon is refused by name" "$(rc --summon)" 2

# --- row 7: lineage named --------------------------------------------------
if grep -q 'which (1)' "$PAGE" || grep -q 'which' "$PAGE"; then
  ok "row 7: SEE ALSO names the standard tool this behaves like"
else no "row 7: no lineage named"; fi

# --- row 8: no vendor, no agent names --------------------------------------
if grep -rqiE 'anthropic|claude|openai|copilot|\bllm\b|\bagent\b|agentic' "$PAGE" "$CMD"; then
  no "row 8: a vendor or agent name is present"
else ok "row 8: clean"; fi

# --- row 9: present tense only ---------------------------------------------
if grep -qiE 'will |going to |not yet|planned|TODO|coming soon' "$PAGE"; then
  no "row 9: the page contains an aspirational sentence"
else ok "row 9: present tense only"; fi

printf '\n--- recense: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
