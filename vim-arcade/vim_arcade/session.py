"""Core game-session logic -- no curses/terminal dependency, so this is
the part covered by unit tests. game.py wraps this with real terminal I/O.
"""

from dataclasses import dataclass, field
from typing import List, Optional

from . import motions
from .levels import LEVELS


@dataclass
class Session:
    level_index: int = 0
    player_pos: tuple = None
    key_buffer: str = ""
    unlocked: set = field(default_factory=set)
    won_all: bool = False
    recording: Optional[str] = None
    macros: dict = field(default_factory=dict)
    _register_wait: Optional[str] = None  # "record" or "replay", waiting on a register letter
    marks: dict = field(default_factory=dict)
    _mark_wait: Optional[str] = None  # "set" or "jump", waiting on a mark letter
    visual_active: bool = False
    visual_anchor: Optional[tuple] = None
    visual_kind: Optional[str] = None  # "char", "line", or "block" -- which visual sub-mode
    levels: Optional[List] = None  # override LEVELS with a caller-supplied progression

    def __post_init__(self):
        self._levels = self.levels if self.levels is not None else LEVELS
        self._load_level(self.level_index)

    @property
    def level(self):
        return self._levels[self.level_index]

    def _load_level(self, index):
        level = self._levels[index]
        self.player_pos = level.start_pos
        self.key_buffer = ""
        self.recording = None
        self._register_wait = None
        self.marks = {}  # marks are positions in *this* level's grid -- don't carry over
        self._mark_wait = None
        self.visual_active = False
        self.visual_anchor = None
        self.visual_kind = None
        for motion in level.introduces:
            if motion != "counts":
                self.unlocked.add(motion)

    def feed_key(self, key: str) -> Optional[str]:
        """Feed one keypress. Returns an event string ("moved", "won",
        "level_complete", "game_complete", "deleted", "yanked",
        "recording_started", "recording_stopped", "visual_on",
        "visual_off", "mark_set", "no_mark") or None if the buffer is
        still incomplete (e.g. mid-count, waiting on the second 'g' of
        'gg', an operator waiting on its motion, or 'q'/'@'/'m'/'`'
        waiting on a register/mark letter).
        """
        if key == "\x1b":  # escape clears the buffer, like real vim
            self.key_buffer = ""
            self._register_wait = None
            self._mark_wait = None
            self.visual_active = False
            self.visual_anchor = None
            self.visual_kind = None
            return None

        # 'q'/'@' are session-level register commands, not motions parsed
        # by motions.py -- handled entirely here, like real vim macros.
        if self._register_wait == "record":
            self._register_wait = None
            self.recording = key
            self.macros[key] = []
            return "recording_started"

        if self._register_wait == "replay":
            self._register_wait = None
            sequence = self.macros.get(key, [])
            last_event = None
            for recorded_key in list(sequence):
                last_event = self.feed_key(recorded_key)
            return last_event

        if key == "q" and self.key_buffer == "":
            if self.recording is not None:
                self.recording = None
                return "recording_stopped"
            if "q" not in self.unlocked:
                return "locked"
            self._register_wait = "record"
            return None

        if key == "@" and self.key_buffer == "":
            if "@" not in self.unlocked:
                return "locked"
            self._register_wait = "replay"
            return None

        if self.recording is not None:
            self.macros[self.recording].append(key)

        # 'm'/'`' are session-level register commands too, handled here
        # rather than by motions.py, but (unlike 'q'/'@') both keystrokes
        # are meant to be macro-recordable/replayable, like any other
        # editing command -- so they're consumed *after* the append above,
        # not before it the way 'q'/'@' are.
        if self._mark_wait == "set":
            self._mark_wait = None
            self.marks[key] = self.player_pos
            return "mark_set"

        if self._mark_wait == "jump":
            self._mark_wait = None
            target = self.marks.get(key)
            if target is None:
                return "no_mark"  # real vim: E20, unset mark -- no-op here too
            self.player_pos = target
            return self._check_goal("moved")

        if key == "m" and self.key_buffer == "":
            if "m" not in self.unlocked:
                return "locked"
            self._mark_wait = "set"
            return None

        if key == "`" and self.key_buffer == "":
            if "`" not in self.unlocked:
                return "locked"
            self._mark_wait = "jump"
            return None

        # 'v'/'V'/Ctrl-v are session-level mode toggles, not motions parsed
        # by motions.py -- handled entirely here, like 'q'/'@'. Real vim:
        # pressing the visual key you're already in exits visual mode;
        # pressing a *different* visual key switches sub-mode in place
        # (the anchor and selection so far are kept).
        if key in ("v", "V", "\x16") and self.key_buffer == "":
            kind = {"v": "char", "V": "line", "\x16": "block"}[key]
            if self.visual_active and self.visual_kind == kind:
                self.visual_active = False
                self.visual_anchor = None
                self.visual_kind = None
                return "visual_off"
            if key not in self.unlocked:
                return "locked"
            if self.visual_active:
                self.visual_kind = kind
                return "visual_on"
            self.visual_active = True
            self.visual_anchor = self.player_pos
            self.visual_kind = kind
            return "visual_on"

        # In visual mode, a bare 'd'/'y' acts immediately on the selected
        # range instead of waiting for a motion argument (unlike normal
        # mode, where 'd'/'y' are operators-pending-a-motion).
        if self.visual_active and key in ("d", "y") and self.key_buffer == "":
            if key not in self.unlocked:
                self.visual_active = False
                self.visual_anchor = None
                self.visual_kind = None
                return "locked"
            self.player_pos = self._apply_visual_operator(key)
            self.visual_active = False
            self.visual_anchor = None
            self.visual_kind = None
            default_event = "deleted" if key == "d" else "yanked"
            return self._check_goal(default_event)

        candidate = self.key_buffer + key
        parsed = motions.parse(candidate)

        if parsed is None:
            # Still incomplete (or the whole thing was junk) -- keep
            # buffering only if it's a plausible prefix of some command.
            if motions.is_partial(candidate):
                self.key_buffer = candidate
            else:
                self.key_buffer = ""
            return None

        self.key_buffer = ""

        if parsed.operator:
            if parsed.operator not in self.unlocked:
                return "locked"
            if parsed.motion != parsed.operator and parsed.motion not in self.unlocked:
                return "locked"
            new_pos = motions.apply_operator(
                self.player_pos,
                parsed.operator,
                parsed.motion,
                parsed.count,
                self.level,
                find_char=parsed.find_char,
            )
            self.player_pos = new_pos
            default_event = "deleted" if parsed.operator == "d" else "yanked"
            return self._check_goal(default_event)

        motion_key = parsed.motion
        if motion_key not in self.unlocked:
            return "locked"

        new_pos = motions.apply_motion(
            self.player_pos, parsed.motion, parsed.count, self.level, find_char=parsed.find_char
        )
        moved = new_pos != self.player_pos
        self.player_pos = new_pos

        return self._check_goal("moved" if moved else "blocked")

    def _apply_visual_operator(self, operator: str) -> tuple:
        """Apply 'd'/'y' to the current visual selection, matching real
        vim's three visual sub-modes:
        - "char": a same-row range between visual_anchor and the cursor
          (inclusive). A selection spanning rows is a no-op rather than
          guessing at a linewise-style range.
        - "line": every column of every row between the anchor's row and
          the cursor's row (inclusive) -- the linewise equivalent of
          Level 8's "dj"/"dk"/"dgg"/"dG", just via a visual selection
          instead of an operator+motion.
        - "block": the rectangular region spanned by the anchor and
          cursor corners (inclusive on both axes)."""
        anchor_row, anchor_col = self.visual_anchor
        row, col = self.player_pos
        if self.visual_kind == "line":
            start_row, end_row = sorted((anchor_row, row))
            if operator == "d":
                for r in range(start_row, end_row + 1):
                    for c in range(self.level.width):
                        self.level.clear_wall(r, c)
            return (start_row, 0)
        if self.visual_kind == "block":
            start_row, end_row = sorted((anchor_row, row))
            start_col, end_col = sorted((anchor_col, col))
            if operator == "d":
                for r in range(start_row, end_row + 1):
                    for c in range(start_col, end_col + 1):
                        self.level.clear_wall(r, c)
            return (start_row, start_col)
        # "char"
        if row != anchor_row:
            return self.player_pos
        start_col, end_col = sorted((anchor_col, col))
        if operator == "d":
            for c in range(start_col, end_col + 1):
                self.level.clear_wall(row, c)
        return (row, start_col)

    def _check_goal(self, default_event: str) -> str:
        """Shared by both motion and operator paths -- either can land the
        cursor on the goal tile (e.g. `db` moves the cursor backward)."""
        if self.player_pos != self.level.goal_pos:
            return default_event
        if self.level_index + 1 < len(self._levels):
            self.level_index += 1
            self._load_level(self.level_index)
            return "level_complete"
        self.won_all = True
        return "game_complete"
