#!/usr/bin/env bash
# cli-guard.sh -- the argument contract, in one place.
#
# TRAPS (the rest of this header is in the vault):
#   1. THE SILENT FULL RUN. `ecosystem-survey.sh --not-a-real-flag` ignored the
#      flag and printed a complete, authoritative-looking survey. The reader
#      has no way to tell that the flag they thought they passed did nothing.
#   2. THE SILENT WRITE. `weight-audit.sh` takes no flags at all and REWRITES
#      AND PUSHES schedule/_paced.conf. So `weight-audit.sh --dry-run` -- a
#      flag a careful operator would plausibly reach for, and which does not
#      exist -- was silently a live apply-and-push. That is the exit-0 no-op
#      inverted into an exit-0 no-op that changes the ecosystem's weights.
# USAGE. Set the four CLI_* variables, source this, call `cli_guard "$@"`
# BEFORE doing any work. The guard validates and returns; it never consumes
# arguments, so each script keeps parsing its own exactly as before.
#
# exit 0)". realisateur's own sensors scored 0 of 8 against it: eleven of the
# EXIT CODES, uniform across every script that sources this:

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
  # A script whose findings DO gate (reach-lint --strict, closeout-lint) must
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
