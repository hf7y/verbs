"""A single, testable source of truth for every single-character symbol
`joue` renders (issue #48: "the various I diacritics on the repo level
mean nothing to me" -- and, per the issue's title, the map view's own
`f`/`r`/`d` counts are just as undocumented). Two namespaces, kept
visually separate rather than merged into one table, because they reuse
the same letters for different meanings depending on where you're
looking: `d`/`D` on the grid means "a draft PR's block", `d:` on the map
means "how many open items in this repo are drafts" -- the SAME letter,
two different things, one screen apart.

`test_glossary.py` walks every combination `gh_triage.symbol_for` can
actually produce and asserts it appears in GRID_SYMBOLS below -- so a
future symbol added there without a matching glossary entry fails a
test instead of shipping silently undocumented, exactly what this issue
asked a "mechanical linter" to do.
"""

import textwrap

from .backlog import NOT_COVERED

GRID_SYMBOLS = [
    ("i", "issue, unseen by you or the batch"),
    ("I", "issue, unseen -- last comment is yours"),
    ("í", "issue, seen by you (batch hasn't)"),
    ("Í", "issue, seen by you -- last comment is yours"),
    ("ì", "issue, seen by the batch (you haven't)"),
    ("Ì", "issue, seen by the batch -- last comment is yours"),
    ("î", "issue, seen by both you and the batch"),
    ("Î", "issue, seen by both -- last comment is yours"),
    ("p", "pull request, ready for review"),
    ("P", "pull request, ready -- last comment is yours"),
    ("d", "pull request, still a draft"),
    ("D", "pull request, draft -- last comment is yours"),
]

MAP_SYMBOLS = [
    ("f", "fresh -- open, no reply from you yet"),
    ("r", "replied -- your own comment is the last one"),
    ("d", "draft -- an open PR not yet marked ready"),
]

# Issue #38: column position used to be an arbitrary zigzag (issue #3's
# stagger). Not a fixed-symbol table like GRID_SYMBOLS -- the column is
# a continuous-looking position, not one of a small enumerable set of
# characters -- so like MARKER_SYMBOLS/BACKLOG_SYMBOLS it stays
# hand-documented rather than mechanically linted.
LAYOUT_SYMBOLS = [
    ("column position", "item age -- further from the start column is older, "
     "bucketed into fixed bands (1/3/7/14/30/90+ days) so one very old item "
     "can't blow the grid width out; exact age shows in the detail panel "
     "when you walk up to the item"),
]

# Not a single-character symbol like the two tables above -- a suffix
# appended after a PR's own number overlay (issue #41's second box:
# "constituent PRs of an open integration PR are marked as such in the
# queue view"). test_glossary.py cannot mechanically enumerate this one
# the way it does GRID_SYMBOLS (there is no fixed set of "every value
# NN can be"), so it stays documented by hand here instead.
MARKER_SYMBOLS = [
    (">NN", "this PR's head is already contained in still-open PR #NN -- merge #NN instead, then close this one"),
]

# Issue #75: the backlog-as-sensor numbers on the map header and each
# tile. Not single-character symbols like the tables above, so this
# stays hand-documented the same way MARKER_SYMBOLS does.
BACKLOG_SYMBOLS = [
    ("(+N) / (-N)", "open-issue count change since this map's last local snapshot (build or refresh)"),
    ("(?)", "no prior local snapshot for this repo yet -- not the same as zero change"),
    ("age~Nd", "the single oldest open item in this repo, in days"),
]

SECTIONS = [
    ("grid symbols (walk into a repo, per item)", GRID_SYMBOLS),
    ("grid layout (column position, per item, issue #38)", LAYOUT_SYMBOLS),
    ("map tile counts (zoomed out, per repo)", MAP_SYMBOLS),
    ("queue markers (after a PR's own number)", MARKER_SYMBOLS),
    ("backlog numbers (map header + tile rows, issue #75)", BACKLOG_SYMBOLS),
]


def glossary_lines(width=80):
    """Plain text lines for the glossary screen -- pure so it's testable
    without a stdscr. Clips each line to `width` the same way the rest
    of this codebase's panels do rather than wrapping mid-definition;
    a symbol/definition pair that doesn't fit is a display nuisance, not
    something worth a wrapping engine over."""
    lines = ["glossary -- what the letters on screen mean"]
    for title, entries in SECTIONS:
        lines.append("")
        lines.append(title + ":")
        for symbol, meaning in entries:
            lines.append(f"  {symbol}  {meaning}")
    lines.append("")
    lines.append("what the backlog numbers do NOT cover (issue #75):")
    lines.extend(textwrap.wrap(NOT_COVERED, max(1, width - 2), initial_indent="  ", subsequent_indent="  "))
    return [line[: max(0, width)] for line in lines]
