#!/usr/bin/env bash
# lib/body-grammar.sh -- the grammar of an agent-written issue or PR body.
# Sourced by bin/gh-sign.sh, which refuses a noncompliant body at the write.
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
#   BAD-DEFAULT         a DEFAULT-AFTER line that is not `<n>d: <action>`
#   BAD-ANSWERED-BY     an ANSWERED-BY line that is not `<owner>/<repo>#<n>`
#   NO-DEFAULT          a DECISION: body carrying no DEFAULT-AFTER at all
#   NEGATED-CLOSE       a closing keyword + reference in a sentence DENYING it
#
# DEFAULT-AFTER -- MANDATORY ON A DECISION SINCE #680 (Zach, 2026-08-28),
# because 21 of 45 open `needs-human` blocked by omission. Past the window the
# owning account applies it, says so, and leaves the issue open to be
# reversed; `0d: block` keeps blocking forever legal once DECLARED. Only
# gh-sign's SIGNING path reaches this, so it binds agents, not Zach.
#
# NO-OWNER: is not a destination -- #327 lost two that way. `defere` files one.
#
# NEGATED-CLOSE -- the parser reads the KEYWORD, not the sentence. Under a
# heading titled "What this is not", hf7y/scheduler#180 said it did NOT close
# scheduler#79; GitHub shut the ROSTER consolidation anyway. A BARE reference
# shuts nothing, so the remedy is to drop the verb -- which is why this is NOT
# a ban (Zach 2026-08-04: batch agents shut shipped issues automatically).

GRAMMAR_DECIDER_RE='@[A-Za-z0-9][-A-Za-z0-9_/]*'
GRAMMAR_CLOSING_WORDS=' close closes closed closing fix fixes fixed fixing resolve resolves resolved resolving '

grammar_negated_close() {  # <line> <heading-negates> -- print "<keyword> <ref>", 1 if clean
  local text="$1" heading_negates="$2" out='' words=() i w ref prefix=''
  local IFS=$' \t\n'

  while [ -n "$text" ]; do   # a code span is a quotation, not a close
    case "$text" in *'`'*) ;; *) out="$out$text"; break ;; esac
    out="$out${text%%'`'*}"; text="${text#*'`'}"
    case "$text" in
      *'`'*) text="${text#*'`'}" ;;
      *)     out="$out$text"; break ;;   # unterminated: it is literal text
    esac
  done

  read -ra words <<<"$out"
  for ((i = 0; i < ${#words[@]} - 1; i++)); do
    w="${words[i],,}"; w="${w%:}"; w="${w%,}"
    case "$GRAMMAR_CLOSING_WORDS" in *" $w "*) ;; *) prefix="$prefix$w "; continue ;; esac
    ref="${words[i + 1]}"
    case "$ref" in
      '#'[0-9]*) ;;                                    # bare #79 -- with a verb
      *[a-zA-Z0-9]/[a-zA-Z0-9]*'#'[0-9]*) ;;           # hf7y/scheduler#79
      *://*/issues/[0-9]*|*://*/pull/[0-9]*) ;;        # the full URL
      *) prefix="$prefix$w "; continue ;;
    esac
    if [ "$heading_negates" -eq 1 ]; then :
    else case "$prefix" in   # `not ` covers "does not", "do not", "cannot"
        *'not '*|*"doesn't "*|*"don't "*|*"won't "*|*'never '*|*'without '*|\
        *'rather than '*|*'instead of '*|*'no longer '*) ;;
        *) prefix="$prefix$w "; continue ;;
      esac
    fi
    printf '%s %s\n' "$w" "$ref"
    return 0
  done
  return 1
}

# grammar_landing_ref <text> -- print the first thing <text> names that a check
# could go and look at, 1 when it names none. gh-sign's `issue close` guard
# asks it of a close comment: closing having landed nothing is this estate's
# largest measured class (#752), and prose cannot be followed -- the same
# argument UNTYPED-DELIVERY makes about DELIVERS. Four shapes, all already
# written here daily: `#N`/`owner/repo#N`/an issue-pull-commit URL, a 7-40
# char hex commit, a typed <kind>:<value>, a `code span` naming a path. The
# span looks arbitrary and is not -- over 1,348 real closes, dropping it takes
# the guard from 49 refusals to 91, and all 42 it acquits are honest (#778).
grammar_landing_ref() {
  local text="$1" words=() w seg rest
  local IFS=$' \t\n'

  # `-d ''` IS LOAD-BEARING: bare `read -ra` stops at the first newline, which
  # is correct above only because grammar_check hands it one line at a time.
  read -rd '' -a words <<<"$text" || :
  for w in "${words[@]}"; do
    w="${w//\`/}"; w="${w%[.,;:)]}"
    case "$w" in
      '#'[0-9]*|*[a-zA-Z0-9]/[a-zA-Z0-9]*'#'[0-9]*) printf '%s\n' "$w"; return 0 ;;
      *://*/pull/[0-9]*|*://*/issues/[0-9]*|*://*/commit/*) printf '%s\n' "$w"; return 0 ;;
      *host:*|*path:*|*clock:*|*tag:*|*secret:*|*unit:*|*port:*|*repo:*) printf '%s\n' "$w"; return 0 ;;
    esac
    case "$w" in                      # a commit: hex only, and never all digits
      *[!0-9a-f]*) ;;
      *[a-f]*) [ "${#w}" -ge 7 ] && [ "${#w}" -le 40 ] && { printf '%s\n' "$w"; return 0; } ;;
    esac
  done

  rest="$text"                        # same walk as grammar_negated_close
  while :; do
    case "$rest" in *'`'*) ;; *) return 1 ;; esac
    rest="${rest#*\`}"
    case "$rest" in
      *'`'*) seg="${rest%%\`*}"; rest="${rest#*\`}" ;;
      *) return 1 ;;
    esac
    case "$seg" in
      *[A-Za-z0-9_-][/.][A-Za-z0-9_-]*) printf '%s\n' "$seg"; return 0 ;;
    esac
  done
}

# grammar_default_after <body> -- print "<days><TAB><action>" and return 0 when
# the body carries a well-formed DEFAULT-AFTER; return 1 when it carries none.
# Pure bash: this runs wherever gh-sign runs, and sed/grep were not on that PATH.
grammar_default_after() {
  local body="$1" line stripped rest days action
  while IFS= read -r line; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in
      [Dd][Ee][Ff][Aa][Uu][Ll][Tt]-[Aa][Ff][Tt][Ee][Rr]\ *) ;;
      *) continue ;;
    esac
    rest="${stripped#* }"                 # "14d: do the thing"
    days="${rest%%d:*}"
    case "$days" in ''|*[!0-9]*) continue ;; esac
    action="${rest#*d:}"
    action="${action#"${action%%[![:space:]]*}"}"
    [ -n "$action" ] || continue
    printf '%s\t%s\n' "$days" "$action"
    return 0
  done <<<"$body"
  return 1
}

grammar_answered_by() {  # <body> -- print the ref (#568), 1 if none; shape of grammar_default_after
  local body="$1" line stripped rest ref
  while IFS= read -r line; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in
      [Aa][Nn][Ss][Ww][Ee][Rr][Ee][Dd]-[Bb][Yy]\ *) ;;
      *) continue ;;
    esac
    rest="${stripped#* }"
    ref="${rest%% *}"
    case "$ref" in
      */*'#'[0-9]*) ;;
      *) continue ;;
    esac
    case "${ref#*'#'}" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$ref"
    return 0
  done <<<"$body"
  return 1
}

# PLACEHOLDERS: a truncated fence must not read as another repo's ledger (#627).
grammar_template() {
  cat <<'EOF'
DECISION: @hf7y -- may a verb build claim /usr/local/bin/gh on monkey?
NO-DECISION: @hf7y asked for this exact change; tests green, nothing to weigh

...and on a DECISION, say what happens if nobody answers. REQUIRED, because an
unanswered question brakes the repo that asked. To block forever, declare it:
`DEFAULT-AFTER 0d: block -- irreversible, no default`.

DEFAULT-AFTER 14d: ship it unsigned and open a follow-up; reverse by saying so

<!-- DEFERRED -->
- none
<!-- /DEFERRED -->

<!-- DELIVERS -->
- none
<!-- /DELIVERS -->

...or one line each, every one naming an issue. `defere` files them:

<!-- DEFERRED -->
- hf7y/<repo>#<n> -- <what was left behind, in a few words>
- hf7y/<repo>#<n> -- <and the next one>
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
  local has_default=0 head_neg=0 nc=''

  _find() { printf '%s  %s\n' "$1" "$2"; n=$((n + 1)); }

  # A bullet plus its continuations, judged when the next bullet or / arrives.
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

  # A claim names WHERE the change takes effect, so a check can go and look.
  # Untyped prose cannot be, which is how "merged" became the finish line for
  # changes that never landed anywhere.
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

    # A heading scopes the denial over every line under it, until the next one.
    case "$stripped" in
      '# '*|'## '*|'### '*|'#### '*|'##### '*|'###### '*)
        case "${stripped,,}" in
          *'is not'*|*'does not'*|*'not in scope'*|*'out of scope'*|*non-goal*|*'not doing'*)
            head_neg=1 ;;
          *) head_neg=0 ;;
        esac ;;
    esac
    if nc="$(grammar_negated_close "$stripped" "$head_neg")"; then
      _find NEGATED-CLOSE "line $lineno: \`$nc\` in a sentence that denies it -- GitHub closes the issue from the keyword alone. Use a bare \`#N\` to reference without closing, or move the closing keyword to its own line: ${stripped:0:70}"
    fi

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
      [Dd][Ee][Ff][Aa][Uu][Ll][Tt]-[Aa][Ff][Tt][Ee][Rr]*)
        # A malformed default is worse than none: it reads as a timer to a
        # human and is invisible to grammar_default_after, so the issue looks
        # self-resolving and blocks forever.
        _da_rest="${decl#*[Rr] }"
        _da_days="${_da_rest%%d:*}"
        _da_act="${_da_rest#*d:}"
        _da_act="${_da_act#"${_da_act%%[![:space:]]*}"}"
        case "$_da_days" in
          ''|*[!0-9]*) _find BAD-DEFAULT \
            "line $lineno: DEFAULT-AFTER needs a day count -- \`DEFAULT-AFTER 14d: <reversible action>\`." ;;
          *) if [ -n "$_da_act" ]; then has_default=1; else _find BAD-DEFAULT \
               "line $lineno: DEFAULT-AFTER names a window but no action. Say what happens when nobody answers."; fi ;;
        esac
        [ "$first_seen" -eq 0 ] && [ "$open" -eq 0 ] && [ "$sopen" -eq 0 ] && _find UNDECLARED \
          'line 1 is neither `DECISION:` nor `NO-DECISION:`. Every body declares one.' ;;
      [Aa][Nn][Ss][Ww][Ee][Rr][Ee][Dd]-[Bb][Yy]*)
        _ab_ref="${decl#* }"  # malformed reads as settled to a human, unresolved to grammar_answered_by
        _ab_ref="${_ab_ref%% *}"
        case "$_ab_ref" in
          */*'#'[0-9]*) case "${_ab_ref#*'#'}" in
              ''|*[!0-9]*) _find BAD-ANSWERED-BY \
                "line $lineno: ANSWERED-BY needs \`<owner>/<repo>#<n>\` -- got: ${decl:0:60}" ;;
            esac ;;
          *) _find BAD-ANSWERED-BY \
               "line $lineno: ANSWERED-BY needs \`<owner>/<repo>#<n>\` -- got: ${decl:0:60}" ;;
        esac
        [ "$first_seen" -eq 0 ] && [ "$open" -eq 0 ] && [ "$sopen" -eq 0 ] && _find UNDECLARED \
          'line 1 is neither `DECISION:` nor `NO-DECISION:`. Every body declares one.' ;;
      *) [ "$first_seen" -eq 0 ] && [ "$open" -eq 0 ] && [ "$sopen" -eq 0 ] && _find UNDECLARED \
           'line 1 is neither `DECISION:` nor `NO-DECISION:`. Every body declares one.' ;;
    esac
    first_seen=1
  done <<<"$body"

  # A body that is entirely a ledger never reached the check above.
  [ "$first_seen" -eq 0 ] && _find UNDECLARED 'no first line to declare on.'

  [ "$has_default" -eq 0 ] && [ "$(grammar_declaration "$body")" = decision ] && _find NO-DEFAULT \
    'a DECISION needs `DEFAULT-AFTER <n>d: <action>`. To block forever, declare it: `DEFAULT-AFTER 0d: block -- irreversible, no default`.'

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
