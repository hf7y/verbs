"""Small, named decay-rate vocabulary for issue triage (#77).

Zach, 2026-08-06: FIFO over the backlog is incoherent because it mixes
two populations with different decay rates -- ideas that can go stale
before they're ever built ("first in ideas may be obviated before they
can be realized"), and bugs/broken guards that only get more expensive
the longer they sit. Sorting by decay rate needs to know which is which
first; this module is the "named, small type vocabulary... not a
growing label zoo" #77 asks for as that precondition.

Deliberately two labels, not a taxonomy: `decayable` (an idea/build that
may already be obviated) and `durable` (a bug, broken guard, or missing
credential that stays exactly as broken until fixed). Mutually
exclusive -- an issue carries at most one.
"""

TYPE_LABELS = ("decayable", "durable")


class IssueTypeError(ValueError):
    """Raised on a type name outside TYPE_LABELS -- fails loud rather
    than silently applying a label the vocabulary doesn't recognize."""


def current_type(labels):
    """Which of TYPE_LABELS `labels` already carries, or None if
    neither is present."""
    for name in TYPE_LABELS:
        if name in labels:
            return name
    return None


def next_type(labels):
    """Cycle order for a single keystroke: unset -> decayable ->
    durable -> unset. A two-way (well, three-state) choice doesn't need
    a picker -- one key does the whole thing, same as [x]/[m]/[R]."""
    current = current_type(labels)
    if current is None:
        return TYPE_LABELS[0]
    idx = TYPE_LABELS.index(current)
    return TYPE_LABELS[idx + 1] if idx + 1 < len(TYPE_LABELS) else None


def type_label_command(item, new_type):
    """`gh issue edit` argv that sets `item`'s type label to `new_type`
    (or clears it entirely if `new_type` is None), removing whichever
    OTHER vocabulary label might already be on it so at most one is
    ever set at a time.

    Only issues take this judgment -- PRs are gone once merged/closed,
    so "does leaving this open get more expensive over time" doesn't
    apply the same way; callers should not offer this on a PR row."""
    if new_type is not None and new_type not in TYPE_LABELS:
        raise IssueTypeError(f"unknown issue type: {new_type!r}")
    cmd = ["gh", "issue", "edit", str(item.number)]
    if new_type is not None:
        cmd += ["--add-label", new_type]
    for other in TYPE_LABELS:
        if other != new_type:
            cmd += ["--remove-label", other]
    if item.repo:
        cmd += ["--repo", item.repo]
    return cmd
