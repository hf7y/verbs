#!/usr/bin/env bash
# lib/body-grammar.sh -- the grammar of an agent-written issue or PR body.
# Sourced by bin/gh-sign.sh, which refuses a noncompliant body at the write.
# (bin/claim-drift.sh, the other reader, was deleted 2026-08-22.)
# Pure bash: gh-sign runs under cron's PATH, where sed and grep were not found.
#
#   UNDECLARED          line 1 is neither DECISION: nor NO-DECISION:
#   NO-DECIDER          DECISION: named no @handle. NO-DECISION: is exempt (#419)
#   MISPLACED-DECISION  a declaration below line 1
#   UNLEDGERED          no <!-- DEFERRED --> block
#   MULTI-LEDGER        more than one
#   UNCLOSED            opened, never closed
#   EMPTY-LEDGER        no entries; write "- none"
#   NO-DESTINATION      an entry naming no issue and no URL
#   UNSHIPPED           no <!-- DELIVERS --> block
#   MULTI-SHIP          more than one
#   EMPTY-SHIP          no entries; write "- none"
#   UNTYPED-DELIVERY    an entry naming no <kind>:<value>
#
# NO-OWNER: is not a destination -- #327 deferred two things to it and both
# are lost. `defere` files one in a command; cite the number.

GRAMMAR_DECIDER_RE='@[A-Za-z0-9][-A-Za-z0-9_/]*'

grammar_template() {
  cat <<'EOF'
DECISION: @zach -- may a verb build claim /usr/local/bin/gh on monkey?
NO-DECISION: @zach asked for this exact change; tests green, nothing to weigh

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->

...or one line each, every one naming an issue. `defere` files them:

<!-- DEFERRED -->
- hf7y/chezz#12 -- orphaned ecosystem-survey shim on chezz@monkey
- hf7y/realisateur#330 -- gh-sign is linked nowhere; needs a human call
EOF
}

# decision | no-decision | none, from the first non-empty line. The word must
# OPEN the line, or a body quoting the convention exempts itself.
grammar_declaration() {
  local line stripped
  while IFS= read -r line; do
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    stripped="${line#"${line%%[![:space:]#>*_-]*}"}"
    case "$stripped" in
      [Nn][Oo]-[Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn]:*) printf 'no-decision\n'; return ;;
      [Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn]:*)          printf 'decision\n';    return ;;
    esac
    printf 'none\n'; return
  done <<<"$1"
  printf 'none\n'
}

# Prints `CODE  message` per violation; returns the count. Never exits.
grammar_check() {
  local body="$1" line stripped n=0 lineno=0 first_seen=0
  local open=0 in_block=0 entries=0 entry='' fenced=0
  local sopen=0 in_ship=0 ships=0 ship='' indent=''

  _find() { printf '%s  %s\n' "$1" "$2"; n=$((n + 1)); }

  # An entry is a bullet plus its continuation lines; judged when the next
  # bullet or the closing marker arrives.
  _judge_entry() {
    [ -n "$entry" ] || return 0
    entries=$((entries + 1))
    case "$entry" in
      *[a-zA-Z0-9_.-]/[a-zA-Z0-9_.-]*'#'[0-9]*) entry=''; return 0 ;;
      *http*://*)                               entry=''; return 0 ;;
      '- none'|'- none.'|'-none')               entry=''; return 0 ;;
    esac
    case "$entry" in
      *NO-OWNER:*|*'NO OWNER:'*)
        _find NO-DESTINATION "\`NO-OWNER:\` is not a destination -- \`defere\` it, cite the number: ${entry:0:60}" ;;
      *)
        _find NO-DESTINATION "names no issue and no URL: ${entry:0:70}" ;;
    esac
    entry=''
  }

  # A delivery claim names WHERE the change takes effect, so `delivery-audit`
  # can go and look. Untyped prose cannot be checked, which is how "merged"
  # became the finish line for changes that never landed anywhere.
  _judge_ship() {
    [ -n "$ship" ] || return 0
    ships=$((ships + 1))
    case "$ship" in
      '- none'|'- none.'|'-none')                       ship=''; return 0 ;;
      *host:*|*path:*|*clock:*|*tag:*|*secret:*|*unit:*|*port:*|*repo:*) ship=''; return 0 ;;
    esac
    _find UNTYPED-DELIVERY "names no <kind>:<value> a check could look for: ${ship:0:60}"
    ship=''
  }

  while IFS= read -r line; do
    lineno=$((lineno + 1))
    case "$line" in '```'*) fenced=$((1 - fenced)); continue ;; esac
    [ "$fenced" -eq 1 ] && continue

    stripped="${line#"${line%%[![:space:]]*}"}"
    # Indented four spaces, a marker is an EXAMPLE, not a second block.
    indent="${line%%[![:space:]]*}"
    if [ "${#indent}" -ge 4 ]; then
      case "$stripped" in *'<!--'*'DEFERRED'*'-->'*|*'<!--'*'DELIVERS'*'-->'*) continue ;; esac
    fi
    case "$stripped" in
      '<!-- DEFERRED -->'|'<!--DEFERRED-->')   open=$((open + 1)); in_block=1; continue ;;
      '<!-- /DEFERRED -->'|'<!--/DEFERRED-->') _judge_entry; in_block=0; continue ;;
      '<!-- DELIVERS -->'|'<!--DELIVERS-->')   sopen=$((sopen + 1)); in_ship=1; continue ;;
      '<!-- /DELIVERS -->'|'<!--/DELIVERS-->') _judge_ship; in_ship=0; continue ;;
    esac

    if [ "$in_ship" -eq 1 ]; then
      case "$stripped" in
        '- '*|'* '*|[0-9]*'. '*) _judge_ship; ship="$stripped" ;;
        '')                      _judge_ship ;;
        *) [ -n "$ship" ] && ship="$ship $stripped" ;;
      esac
      continue
    fi

    if [ "$in_block" -eq 1 ]; then
      case "$stripped" in
        '- '*|'* '*|[0-9]*'. '*) _judge_entry; entry="$stripped" ;;
        '')                      _judge_entry ;;
        *) [ -n "$entry" ] && entry="$entry $stripped" ;;
      esac
      continue
    fi

    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    [ "$sopen" -gt 0 ] && [ "$first_seen" -eq 0 ] && first_seen=0
    local decl="${stripped#"${stripped%%[![:space:]#>*_-]*}"}"
    case "$decl" in
      [Nn][Oo]-[Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn]:*)
        [ "$first_seen" -eq 1 ] && _find MISPLACED-DECISION \
          "line $lineno declares, but line 1 did not. The convention reads line 1 only." ;;
      [Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn]:*)
        if [ "$first_seen" -eq 1 ]; then
          _find MISPLACED-DECISION "line $lineno declares, but line 1 did not. The convention reads line 1 only."
        else
          [[ $decl =~ $GRAMMAR_DECIDER_RE ]] || _find NO-DECIDER \
            'the declaration names no decider. Line 1: "DECISION: @who -- <the call>".'
        fi ;;
      *) [ "$first_seen" -eq 0 ] && [ "$open" -eq 0 ] && [ "$sopen" -eq 0 ] && _find UNDECLARED \
           'line 1 is neither `DECISION:` nor `NO-DECISION:`. Every body declares one.' ;;
    esac
    first_seen=1
  done <<<"$body"

  # A body that is entirely a ledger never reached the check above.
  [ "$first_seen" -eq 0 ] && _find UNDECLARED 'no first line to declare on.'

  [ "$in_block" -eq 1 ] && { _judge_entry; _find UNCLOSED 'the DEFERRED block is never closed.'; }
  [ "$open" -eq 0 ] && _find UNLEDGERED 'no <!-- DEFERRED --> block. Say what was left behind, or "- none".'
  [ "$open" -gt 1 ] && _find MULTI-LEDGER "$open DEFERRED blocks -- a reader cannot tell which is current."
  [ "$open" -ge 1 ] && [ "$entries" -eq 0 ] && _find EMPTY-LEDGER 'the DEFERRED block is empty. Write "- none".'

  [ "$in_ship" -eq 1 ] && { _judge_ship; _find UNCLOSED 'the DELIVERS block is never closed.'; }
  [ "$sopen" -eq 0 ] && _find UNSHIPPED 'no <!-- DELIVERS --> block. Say where this takes effect outside the repo, or "- none".'
  [ "$sopen" -gt 1 ] && _find MULTI-SHIP "$sopen DELIVERS blocks -- a reader cannot tell which is current."
  [ "$sopen" -ge 1 ] && [ "$ships" -eq 0 ] && _find EMPTY-SHIP 'the DELIVERS block is empty. Write "- none".'

  [ "$n" -gt 125 ] && n=125
  return "$n"
}
