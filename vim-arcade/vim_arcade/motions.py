"""Parsing and applying real vim motions -- no curses dependency, so this
is fully unit-testable without a terminal.

Supported so far (level-gated -- see levels.py's `introduces` field):
  h j k l    single-step directional
  0 $        start / end of current row
  gg G       top / bottom row
  w b        jump to next/previous "word" -- in this grid world, a word
             boundary is any wall tile, so w/b jump across gaps between
             obstacles the way word-motion jumps across whitespace in
             real vim.
  d y c      operators -- wait for a motion (or a doubled operator, "dd"/
             "yy"/"cc", for the whole current row) the same way "g" waits
             for a second "g". `d` + motion clears the wall tiles the
             motion passes over (the grid-world stand-in for "deleting"
             text and clearing an obstacle); `y` (yank) computes the same
             range and moves the cursor the same way, but never clears a
             wall. `c` (change) clears exactly like `d`, then -- like real
             vim dropping you into Insert mode to type the replacement --
             puts the session in insert mode: every following keypress
             (besides Escape) places a new wall tile at the cursor and
             steps the cursor forward one column, the same "typing"
             stand-in `set_wall` is for. Escape leaves insert mode and
             returns to normal mode; see session.py's Session.feed_key
             for the state machine (insert mode swallows every key, not
             just motions, exactly like real vim).
  f t F T    find-in-line -- each takes a target character argument (the
             next key after f/t/F/T), and jumps to the count-th
             occurrence of that character in the current row. f/F land
             ON the target; t/T land just before it (one tile short, in
             the direction of travel). f/t search forward, F/T backward.
  A leading count (e.g. "3l", "2w") repeats the motion that many times,
  exactly like real vim. Counts before and between an operator and its
  motion multiply, exactly like real vim ("2d3l" clears 6 tiles).

  Operators also combine with j/k/gg/G (linewise-by-motion, e.g. "dj"
  clears the current row and the row(s) below/above/to the top/to the
  bottom) and with f/t/F/T (e.g. "dfX" clears from the cursor through/up
  to the found target, "dFX"/"dTX" clear backward the same way).

  q <register> ... q   record a macro (any of the above keystrokes) into
                        a named register; a second "q" stops recording.
  @ <register>          replay a recorded macro's keystrokes in sequence.
  q/@ are session-level register commands, not motions -- see
  session.py's Session.feed_key, not this module, for their handling.

  v V Ctrl-v            visual mode -- "v" toggles a character-wise
                        selection anchored at the cursor, "V" a linewise
                        (whole-row) selection, Ctrl-v ("\x16") a
                        rectangular block selection; any motion above
                        extends it, then "d"/"y" acts on the selected
                        range and exits visual mode. Pressing a
                        *different* visual key while already in visual
                        mode switches sub-mode in place instead of
                        exiting, matching real vim. Like q/@, these are
                        session-level mode toggles handled in session.py,
                        not motions parsed by this module.
  m <letter>             set a mark: remembers the current (row, col)
                        under a register letter.
  ` <letter>             jump back to a mark's exact (row, col) in one
                        keystroke -- unlike gg/G (row only) or 0/$
                        (column only), a mark restores both at once.
                        Jumping to a mark that was never set is a no-op,
                        matching real vim's error-without-crashing
                        behavior. Like q/@/v/V/Ctrl-v, m/` are
                        session-level register commands handled in
                        session.py, not motions parsed by this module.
"""

from dataclasses import dataclass
from typing import Optional, Tuple

_MOTIONS = {"h", "j", "k", "l", "0", "$", "gg", "G", "w", "b"}
_OPERATORS = ("d", "y", "c")
_FIND_CHARS = "ftFT"

# A buffer that's a *complete* command takes one of five shapes:
#   count? + motion                      -- a bare motion, e.g. "3l", "gg"
#   count? + op + count? + motion         -- operator + motion, e.g. "d3l"
#   count? + op + op                      -- doubled operator (linewise), "dd"
#   count? + [ftFT] + <any char>          -- find-in-line, e.g. "fX", "2tY"
#   count? + op + count? + [ftFT] + <any char> -- operator + find, "dfX"
#
# Counts follow real vim's own grammar, not "any digit string": a count's
# first digit must be 1-9, and only then can further 0-9 digits follow.
# "0" on its own is never a count digit -- it's the "0" motion (start of
# row) instead, exactly like real vim (a bare leading "0" moves the
# cursor rather than starting a count). Splitting on that grammar (rather
# than a naive `\d*`) matters for correctness, not just style: a naive
# `\d*` greedily eats "10" as a whole, then has to backtrack to satisfy
# the trailing motion-char requirement, which lands on "1" + "0"-as-motion
# instead of "10" as one count -- so typing "10l" would silently move one
# column via a phantom "0" motion, then a separate one-column "l", rather
# than ten columns in one command.


@dataclass
class ParsedCommand:
    count: int
    motion: str
    operator: Optional[str] = None
    find_char: Optional[str] = None


def _split_count(s: str):
    """Split a leading vim-style count (`[1-9][0-9]*`) off `s`. Returns
    (count_str, rest) -- count_str is "" if `s` doesn't start with a
    nonzero digit (including if `s` starts with "0": that's the "0"
    motion, not a count)."""
    if not s or s[0] not in "123456789":
        return "", s
    i = 1
    while i < len(s) and s[i].isdigit():
        i += 1
    return s[:i], s[i:]


def is_partial(buffer: str) -> bool:
    """True if `buffer` isn't a complete command yet but could become one
    with more keypresses (e.g. a bare count, a lone operator, "g" waiting
    for its pair, or "f" waiting for its target character)."""
    _, rest = _split_count(buffer)

    if rest == "":
        return True  # bare count so far, e.g. "3", "12"

    if rest[0] in _OPERATORS:
        op, remainder = rest[0], rest[1:]
        if remainder == "":
            return True  # e.g. "d", "3d"
        _, remainder2 = _split_count(remainder)
        if remainder2 == "":
            return True  # e.g. "d3", "2d15" -- still buffering the inner count
        if remainder2 == "g":
            return True  # waiting on the second "g" of "dgg"
        if len(remainder2) == 1 and remainder2[0] in _FIND_CHARS:
            return True  # e.g. "df", "d3f" -- waiting on the find target
        return False

    if rest == "g":
        return True  # waiting on the second "g" of "gg"

    if len(rest) == 1 and rest[0] in _FIND_CHARS:
        return True  # e.g. "f", "2f" -- waiting on the find target

    return False


def parse(buffer: str) -> Optional[ParsedCommand]:
    """Parse a key buffer into a count+motion(+operator/find_char), or
    None if the buffer is incomplete (still a valid partial -- caller
    should keep buffering) or outright invalid (caller should discard
    it)."""
    outer_str, rest = _split_count(buffer)
    outer = int(outer_str) if outer_str else 1

    if len(rest) == 2 and rest[0] == rest[1] and rest[0] in _OPERATORS:
        return ParsedCommand(count=outer, motion=rest[0], operator=rest[0])

    if rest and rest[0] in _OPERATORS:
        op = rest[0]
        inner_str, remainder = _split_count(rest[1:])
        inner = int(inner_str) if inner_str else 1
        count = outer * inner
        if len(remainder) == 2 and remainder[0] in _FIND_CHARS:
            return ParsedCommand(count=count, motion=remainder[0], operator=op, find_char=remainder[1])
        if remainder in _MOTIONS:
            return ParsedCommand(count=count, motion=remainder, operator=op)
        return None

    if len(rest) == 2 and rest[0] in _FIND_CHARS:
        return ParsedCommand(count=outer, motion=rest[0], find_char=rest[1])

    if rest in _MOTIONS:
        return ParsedCommand(count=outer, motion=rest)

    return None


def apply_motion(pos: Tuple[int, int], motion: str, count: int, grid, find_char: Optional[str] = None) -> Tuple[int, int]:
    """pos = (row, col). grid must provide .width, .height, .is_wall(row, col)
    (and .find_in_row(row, col, char, direction, count) for f/t/F/T)."""
    row, col = pos

    if motion in ("f", "t", "F", "T"):
        direction = 1 if motion in ("f", "t") else -1
        target = grid.find_in_row(row, col, find_char, direction, count)
        if target is None:
            return pos  # not found -- real vim leaves the cursor put, too
        if motion == "t":
            return (row, target - 1)
        if motion == "T":
            return (row, target + 1)
        return (row, target)

    def step(dr, dc, n):
        r, c = row, col
        for _ in range(n):
            nr, nc = r + dr, c + dc
            if not (0 <= nr < grid.height and 0 <= nc < grid.width):
                break
            if grid.is_wall(nr, nc):
                break
            r, c = nr, nc
        return r, c

    if motion == "h":
        return step(0, -1, count)
    if motion == "l":
        return step(0, 1, count)
    if motion == "j":
        return step(1, 0, count)
    if motion == "k":
        return step(-1, 0, count)
    if motion == "0":
        return (row, 0)
    if motion == "$":
        return (row, grid.width - 1)
    if motion == "gg":
        return (0, col)
    if motion == "G":
        return (grid.height - 1, col)
    if motion == "w":
        return _jump_to_boundary(row, col, +1, grid, count)
    if motion == "b":
        return _jump_to_boundary(row, col, -1, grid, count)

    return pos


def _jump_to_boundary(row, col, direction, grid, count):
    """Jump past `count` wall-bounded gaps, landing on the first floor
    tile just after each wall run -- the grid-world stand-in for real
    vim's whitespace-delimited word motion.
    """
    c = col
    for _ in range(count):
        # Walk to the edge of the current floor run.
        probe = c + direction
        while 0 <= probe < grid.width and not grid.is_wall(row, probe):
            probe += direction
        if not (0 <= probe < grid.width):
            c = max(0, min(grid.width - 1, probe - direction))
            break
        # probe now sits on the first wall tile of the run -- walk through
        # it to the first floor tile beyond.
        while 0 <= probe < grid.width and grid.is_wall(row, probe):
            probe += direction
        if not (0 <= probe < grid.width):
            c = max(0, min(grid.width - 1, probe - direction))
            break
        c = probe
    return (row, c)


def apply_operator(
    pos: Tuple[int, int],
    operator: str,
    motion: str,
    count: int,
    grid,
    find_char: Optional[str] = None,
) -> Tuple[int, int]:
    """Apply an operator (`d` delete / `y` yank / `c` change) over the
    range a motion would cover, clearing any wall tiles in that range if
    `operator` is "d" or "c" (yank never mutates). Returns the new cursor
    position -- computed the same way for all three operators (real vim
    moves the cursor to the start of the range for a backward/linewise
    motion regardless of which operator it is; only the actual mutation
    is operator-specific). `c`'s insert-mode follow-up (typing a
    replacement) is session.py's job, not this function's -- this only
    does the "delete" half `c` shares with `d`.
    """
    row, col = pos

    if motion == operator:  # doubled operator ("dd"/"yy") -- whole row(s)
        rows = range(row, min(row + count, grid.height))
        if operator in ("d", "c"):
            for r in rows:
                for c in range(grid.width):
                    grid.clear_wall(r, c)
        return pos

    if motion in ("j", "k", "gg", "G"):  # linewise-by-motion -- whole row(s)
        if motion == "j":
            start_row, end_row = row, min(row + count, grid.height - 1)
        elif motion == "k":
            start_row, end_row = max(row - count, 0), row
        elif motion == "gg":
            start_row, end_row = 0, row
        else:  # "G"
            start_row, end_row = row, grid.height - 1
        if operator in ("d", "c"):
            for r in range(start_row, end_row + 1):
                for c in range(grid.width):
                    grid.clear_wall(r, c)
        return (start_row, col)

    if motion in ("f", "t", "F", "T"):
        direction = 1 if motion in ("f", "t") else -1
        target = grid.find_in_row(row, col, find_char, direction, count)
        if target is None:
            return pos  # not found -- nothing to operate on
        if motion == "f":
            cells = range(col, target + 1)
            new_col = col
        elif motion == "t":
            cells = range(col, target)
            new_col = col
        elif motion == "F":
            cells = range(target, col + 1)
            new_col = target
        else:  # "T"
            cells = range(target + 1, col + 1)
            new_col = target + 1
        if operator in ("d", "c"):
            for c in cells:
                grid.clear_wall(row, c)
        return (row, new_col)

    if motion == "h":
        start = max(0, col - count)
        cells = range(start, col)
        new_col = start
    elif motion == "l":
        end = min(grid.width, col + count)
        cells = range(col, end)
        new_col = col
    elif motion == "w":
        _, target = apply_motion(pos, "w", count, grid)
        cells = range(col, target)
        new_col = col
    elif motion == "b":
        _, target = apply_motion(pos, "b", count, grid)
        cells = range(target, col)
        new_col = target
    elif motion == "0":
        cells = range(0, col)
        new_col = 0
    elif motion == "$":
        cells = range(col, grid.width)
        new_col = col
    else:
        return pos

    if operator in ("d", "c"):
        for c in cells:
            grid.clear_wall(row, c)

    return (row, new_col)
