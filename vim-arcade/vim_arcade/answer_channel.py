"""The "answer channel" rule nightly-batch.md follows, expressed as code
so it's directly testable instead of only inferable from prose (#34,
tightening #33).

#33 made the rule "a comment from the repo owner is the answer." #34
found the hole: agents comment as the repo owner too (same token), so an
agent's own comment could be read back as Zach's answer -- proven live
on #6. The fix: a comment only counts as Zach's answer if it is NOT
carrying this project's agent stamp (see provenance.py). Absence of a
stamp means human, per #34's inversion.
"""

from dataclasses import dataclass
from typing import List, Optional, Sequence

from .provenance import is_stamped


@dataclass(frozen=True)
class Comment:
    author: str
    body: str


def select_owner_answer(comments: Sequence[Comment], owner: str) -> Optional[Comment]:
    """The most recent `owner`-authored comment that is NOT agent-stamped
    -- nightly-batch's answer channel. `comments` is assumed chronological
    (as `gh issue list --json comments` returns them); the most recent
    qualifying one wins, same as #33's original rule, just narrowed to
    exclude an agent's own reply posted under the owner's token.

    Returns None if the owner never commented, or every owner-authored
    comment is agent-stamped (i.e. the issue is still genuinely waiting
    on a human answer)."""
    candidates = [c for c in comments if c.author == owner and not is_stamped(c.body)]
    return candidates[-1] if candidates else None


def is_awaiting_owner_reply(comments: Sequence[Comment], owner: str) -> bool:
    """True iff this conversation currently needs `owner`'s (Zach's)
    input -- the most recent comment is NOT an unstamped `owner`
    comment. This is #77's second axis ("issues awaiting a Zach reply"
    vs "issues Zach issued"), read off the exact same signal
    `select_owner_answer` already uses (author + provenance stamp), so
    it needs no Zach-applied label -- #77: "the awaiting-Zach predicate
    is derivable without a Zach-applied label," feeding #47's wanted
    fraction (outstanding-for-Zach over not-addressed).

    An issue with no comments at all is NOT awaiting a reply -- nobody
    has asked Zach anything on it yet."""
    if not comments:
        return False
    last = comments[-1]
    return not (last.author == owner and not is_stamped(last.body))
