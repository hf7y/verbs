"""The one shared refusal shape -- issue #46, applying #31's rule where
#42 warned it would drift.

#31 established the standard `merge_safety.py` was built to: "a refusal
must name the specific reason AND the next action. 'Cannot merge' teaches
nothing." `staleness.py`'s dirty-tree refusal did neither for months --
just `"the tree is dirty -- refusing to update automatically."`, no file
list, no command -- until a real session (#46) got refused over a single
`?? .directory` KDE litter file, then ran the exact same fast-forward by
hand, with that file still present, and it succeeded cleanly.

Rather than hand-patch `staleness.py`'s wording to match `merge_safety.py`
this once, this module gives both a single shape to build refusals from,
so a future fix to one cannot silently leave the other behind -- the
"two copies of a truth" pattern #42 already named.
"""

from dataclasses import dataclass, field
from typing import List


@dataclass
class Refusal:
    """reason: what's actually wrong, in plain language.
    evidence: the SPECIFIC file(s)/check(s)/commit(s) that make it true --
        never just "the tree is dirty", always the file it means.
    next_action: the exact command (or instruction) that resolves it.
        Empty only when there genuinely is none (there always should be
        one; #31's whole point)."""

    reason: str
    next_action: str
    evidence: List[str] = field(default_factory=list)

    def describe(self, evidence_limit: int = 3) -> str:
        """One-line rendering used by every refusal screen (startup
        staleness prompt, merge-key log line) -- 'reason -- evidence --
        run: next_action', evidence truncated with a '+N more' the same
        way merge_safety.py already truncates failing-check lists."""
        parts = [self.reason]
        if self.evidence:
            shown = ", ".join(self.evidence[:evidence_limit])
            more = "" if len(self.evidence) <= evidence_limit else f" (+{len(self.evidence) - evidence_limit} more)"
            parts.append(f"{shown}{more}")
        text = " -- ".join(parts)
        if self.next_action:
            text = f"{text} -- run: {self.next_action}"
        return text
