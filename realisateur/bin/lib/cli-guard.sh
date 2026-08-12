#!/usr/bin/env bash
# cli-guard.sh -- the argument contract, in one place.
#
# WHY THIS EXISTS. The bashify pass (2026-07-30) held all 19 projects to a
# contract whose first assertion is "rejects an unknown flag loudly (not
# exit 0)". realisateur's own sensors scored 0 of 8 against it: eleven of the
# twenty scripts in bin/ took `--not-a-real-flag` and ran the full job anyway.
# Filed by /cloture into scheduler's BLOCKERS.md the same morning. This is the
# fix, and it is a LIBRARY rather than eleven pasted preambles because
# BUILD-DISCIPLINE.md's "config read from one source, not retyped per file"
# applies to the argument contract as much as to a hostname.
#
# The two failure shapes it closes, both measured on 2026-07-30, not imagined:
#
#   1. THE SILENT FULL RUN. `ecosystem-survey.sh --not-a-real-flag` ignored the
#      flag and printed a complete, authoritative-looking survey. The reader
#      has no way to tell that the flag they thought they passed did nothing.
#   2. THE SILENT WRITE. `weight-audit.sh` takes no flags at all and REWRITES
#      AND PUSHES schedule/_paced.conf. So `weight-audit.sh --dry-run` -- a
#      flag a careful operator would plausibly reach for, and which does not
#      exist -- was silently a live apply-and-push. That is the exit-0 no-op
#      inverted into an exit-0 no-op that changes the ecosystem's weights.
#
# USAGE. Set the four CLI_* variables, source this, call `cli_guard "$@"`
# BEFORE doing any work. The guard validates and returns; it never consumes
# arguments, so each script keeps parsing its own exactly as before.
#
#   CLI_NAME='thing.sh'
#   CLI_SUMMARY='one line, what it does'
#   CLI_USAGE='  thing.sh [--flag]   what that form does'   # multi-line ok
#   CLI_FLAGS='--flag --other'    # every flag the script actually accepts;
#                                 # empty means it accepts none
#   CLI_POSITIONAL=none|any       # `none` rejects any non-flag argument
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
#   cli_guard "$@"
#
# EXIT CODES, uniform across every script that sources this:
#   0  --help was asked for and printed
#   2  usage error -- unknown flag, unexpected argument, or a cost-flag
#      near-miss. Always on stderr, always naming what was rejected.
#
# WHAT IT DELIBERATELY DOES NOT DO. It does not touch a script's FINDINGS exit
# status. hygiene-lint.sh's header states "exit status is always 0 -- findings
# are signals, not build failures", and that stays true: a usage error is not
# a finding. Confusing the two is what would make this fix a regression.

# cli_die <message...> -- usage error, stderr, exit 2.
cli_die() {
  printf '%s: %s\n' "${CLI_NAME:-$(basename "${BASH_SOURCE[1]:-script}")}" "$*" >&2
  printf 'try `%s --help`\n' "${CLI_NAME:-script}" >&2
  exit 2
}

cli_help() {
  printf '%s -- %s\n\n' "${CLI_NAME:-script}" "${CLI_SUMMARY:-(no summary)}"
  printf 'usage:\n%s\n' "${CLI_USAGE:-  (none recorded)}"
  if [ -n "${CLI_FLAGS:-}" ]; then
    printf '\nflags: %s\n' "$CLI_FLAGS"
  else
    printf '\nflags: none accepted\n'
  fi
  printf '\nexit codes:\n'
  # A script whose findings DO gate (reach-lint --strict, focus-commit) must
  # say so itself, or this block would state a falsehood in the one place a
  # caller is most likely to trust it.
  if [ -n "${CLI_EXITS:-}" ]; then
    printf '%s\n' "$CLI_EXITS"
  else
    printf '  0  ran to completion (findings, if any, are printed -- not encoded here)\n'
  fi
  printf '  2  usage error: unknown flag, unexpected argument, or cost-flag near-miss\n'
  printf '\nthis tool makes no AI calls and cannot spend: --summon is rejected.\n'
  exit 0
}

# cli_guard "$@" -- validate, then return so the caller parses as it always did.
cli_guard() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --help|-h)
        cli_help
        ;;
      --summon)
        # The cost boundary. These are zero-AI-cost sensors, so the honest
        # answer is a refusal rather than silence -- the contract accepts
        # either, and rejects only saying nothing.
        cli_die "--summon rejected: this tool makes no AI calls and cannot spend."
        ;;
      -s|-S)
        # No-bundling rule: a near-miss on the only flag that spends real
        # money must fail, never be quietly ignored as an unknown.
        cli_die "'$arg' rejected as a near-miss on --summon (the cost flag is long-form only)."
        ;;
      --)
        # Not accepted by any of these scripts; treating it as a silent
        # separator would be exactly the quiet misparse this guards against.
        cli_die "'--' is not accepted."
        ;;
      -)
        # A BARE `-` IS A VALUE, NOT A FLAG, and this branch is here because
        # treating it as one silenced the release channel on the first real
        # gated cut (2026-08-07).
        #
        # cli_guard walks EVERY element of argv, values included -- it has to,
        # because it does not know which flags take a value. So a value that
        # begins with `-` reaches the `-*)` arm below. Almost always that is
        # correct and desirable: `--reason --apply` is a misparse worth dying
        # on. A bare `-` is the one exception, because in this estate it is
        # not a near-miss on anything -- it is the DOCUMENTED sentinel that
        # publish-release-verdict.sh and release-ledger.sh both use for "no
        # build id", and it is their own default value for that field.
        #
        # WHAT IT COST. build-verbs.yml invokes the publisher with
        # `--build-id "${CUT_BUILD:--}"`. CUT_BUILD is empty on every night
        # that does NOT cut -- which is every BLOCKED, ERROR and NO_CHANGE
        # night, i.e. exactly the nights the verdict channel was built for. So
        # the publisher died `unknown flag: -`, exit 2, and published nothing.
        # The endpoint went on serving the previous CUT verdict, and the
        # consumer graded a broken gate as "release channel healthy".
        #
        # It is NOT waved through: with CLI_POSITIONAL=none it still dies, and
        # it dies naming itself rather than as an "unknown flag", so a script
        # that genuinely takes no arguments is no laxer than it was.
        [ "${CLI_POSITIONAL:-none}" = none ] && \
          cli_die "unexpected argument: '-' (this tool takes no positional arguments)"
        ;;
      -*)
        case " ${CLI_FLAGS:-} " in
          *" $arg "*) ;;
          *) cli_die "unknown flag: $arg" ;;
        esac
        ;;
      *)
        [ "${CLI_POSITIONAL:-none}" = none ] && \
          cli_die "unexpected argument: $arg (this tool takes no positional arguments)"
        ;;
    esac
  done
  return 0
}

# cli_require_matched <wanted-array-name> <matched-array-name>
#
# The SECOND silent failure in the project-filter scripts, and the subtler one.
# hygiene-lint/closeout-lint/milestone-audit take project names as positional
# arguments and filter their scan to them. A name matching nothing -- a typo, a
# renamed project, a project that was never registered -- produced an empty
# scan, a clean header, and exit 0. Indistinguishable from "I checked it and it
# is fine", which is the worst thing a lint can say about something it never
# looked at.
cli_require_matched() {
  local -n _cli_want="$1" _cli_got="$2"
  [ "${#_cli_want[@]}" -gt 0 ] || return 0
  local w g found missing=()
  for w in "${_cli_want[@]}"; do
    found=0
    for g in "${_cli_got[@]}"; do [ "$g" = "$w" ] && { found=1; break; }; done
    [ "$found" -eq 0 ] && missing+=("$w")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0
  cli_die "not a registered project (nothing would be scanned): ${missing[*]}"
}
