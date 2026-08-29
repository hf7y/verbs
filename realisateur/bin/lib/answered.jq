# answered.jq -- has a human answered this issue? THE one text (#568).
#
# Prepended to a caller's filter:
#   jq --arg owner hf7y --arg era 2026-08-14 "$(cat answered.jq)"'.[] | verdict'
#
# INPUT, per issue: what `gh issue list/view --json ...,labels,comments`
# produce. Two callers, two feeding styles, one text -- it lived THREE times
# and the copies disagreed on the era cutoff, the `answered` label, what
# `stamped` means, and whether the author mattered.
#
# THREE VERDICTS, AND THE THIRD IS THE POINT:
#   answered     a human did, or the `answered` label says one did elsewhere
#   uncounted    a comment COULD be a human's and cannot be counted
#   unanswered   there is nothing here
# `uncounted` used to report as `unanswered`, with no line and no count. That
# is how Zach was asked chezz#4 twice, and how wtul#37 blocked nine days after
# being settled on wtul#34. An unknowable is not an answer -- but it is not a
# silence either.

# stamped: TRUE iff the body's LAST NON-BLANK LINE opens with `<!-- agent:`.
# The stricter of the two rules that merged here: `test("<!--\\s*agent:")`
# anywhere in the body also matched a body QUOTING the convention.
def stamped:
  (. // "") | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))
  | if length == 0 then false else (.[-1] | test("^<!--\\s*agent:")) end;

# relayed: `<!-- decision-by: zach ... -->`. Zach answers OUT LOUD; without a
# relay marker every spoken call reads as never given.
def relayed: (. // "") | test("<!--\\s*decision-by:");

# The LATEST $owner comment that is unstamped or relaying. An older answer that
# WAS taken up does not excuse a newer one that was not.
#
# ONLY $owner. A comment from anyone else is a human's, but a human commenting
# is not the decider answering -- "any word on this?" from a third party is the
# case this filter exists for. A genuine outside answer (Chris's `APPROVED` on
# hf7y/front-door#4) is settled with the `answered` label below: typed and
# auditable, rather than inferred from the fact that somebody spoke.
def candidates:
  [ .comments[]?
    | select((.author.login // "") == $owner)
    | select(((.body | stamped) | not) or (.body | relayed)) ];

def latest: sort_by(.createdAt) | last;

# The `answered` label is an OVERRIDE, never the trigger. It is the one act
# that settles an answer living somewhere this predicate cannot see -- another
# issue, a conversation, a room. It needs a clock, so it borrows the latest
# comment's date.
def labelled: ((.labels // []) | any(.name == "answered"));

# `unsettled` is the mirror OVERRIDE (#705): the owner replied and the reply
# did not settle the question -- a contradiction, a non-answer, an answer to a
# different question. `candidates`/`latest` can only see THAT a comment
# exists, never whether it settled anything, so a typed label says what the
# predicate cannot. Checked before the comment branch, same precedence
# `answered` already has, so it wins over "there is a reply" rather than
# losing to it.
def unsettled_labelled: ((.labels // []) | any(.name == "unsettled"));

# ANSWERED-BY <owner>/<repo>#<n> (#568), extraction only -- see body-grammar.sh.
def answered_by:
  (.body // "") as $b
  | ($b | [scan("(?im)^\\s*ANSWERED-BY\\s+(\\S+/\\S+#[0-9]+)")]) as $m
  | if ($m | length) > 0 then $m[-1][0] else null end;

def verdict:
  . as $i
  | ($i | candidates | latest) as $a
  | if ($i | unsettled_labelled) then
      { verdict: "unanswered", at: null,
        why: "the `unsettled` label -- the owner replied and it did not settle the question" }
    elif $a != null and ($a.createdAt[0:10] >= $era) then
      { verdict: "answered",   at: $a.createdAt,
        why: "an unstamped or relayed comment" }
    elif ($i | labelled) then
      { verdict: "answered",   at: ([$i.comments[]?] | latest | .createdAt),
        why: "the `answered` label -- a human answered somewhere this cannot see" }
    elif $a != null then
      { verdict: "uncounted",  at: $a.createdAt,
        why: "a comment from \($a.createdAt[0:10]) predates the stamp era (\($era)), so it cannot be told from an agent's" }
    else
      { verdict: "unanswered", at: null,
        why: "no comment that could be a human's" }
    end
  | . + { number: $i.number, answered_by: ($i | answered_by) };
