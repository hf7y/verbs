#!/usr/bin/env bash
pass=0; fail=0  # the six lines 51/54 suites re-declared, drifted in 18 formats; source, call harness_tmp/section/ok/bad/eq/rc/has/hasnt, end with summary

section() { printf '\n%s\n' "$*"; }
ok()      { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()     { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }

eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }  # (label, GOT, WANT)
rc()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want exit $2, got $3"; fi; }  # (label, WANT, GOT) -- disagrees with eq; existing convention, not changed mid-port
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing: $3" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "present but should not be: $3" ;; *) ok "$1" ;; esac; }
no()    { bad "$@"; }   # #440: alias for suites carried under their own pre-harness spelling
check() { eq "$@"; }    # #440: same (label, GOT, WANT) order as eq, just the other name

summary() {
  printf '\n%s: %d passed, %d failed\n' "${0##*/}" "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

harness_tmp() {  # sets $T; must be called bare -- `T="$(harness_tmp)"` runs it in a subshell where the EXIT trap fires immediately
  T="$(mktemp -d)" || { echo "harness: cannot mktemp -- refusing to run blind" >&2; exit 2; }
  trap "rm -rf '$T'" EXIT  # shellcheck disable=SC2064 -- expanded now, removes the dir this call made
}
