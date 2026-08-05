"""A tmux-flavored pane-splitting mechanic -- grid-world metaphor, not a
real tmux subprocess (keeps this curses-free/unit-testable like every
other level in the game, at the cost of teaching keybinding muscle
memory only, not real tmux multiplexing/scrollback/detach). Standalone
from Session/LEVELS on purpose: this is a proposed new mechanic, not
slotted into the existing vim-motion progression, so it can't regress
anything already shipped there.

Real tmux: `Ctrl-b %` splits the current pane vertically (side by side),
`Ctrl-b "` splits horizontally (stacked); `Ctrl-b <arrow>` moves focus to
the pane in that direction. Arrow keys aren't available as plain
characters in this project's string-keyed input model (see game.py's
curses layer for the only place raw key codes are handled), so pane
navigation reuses the vim motion letters the player already knows: `h`/
`l` after a vertical split (side by side, like real vim's own window
navigation), `j`/`k` after a horizontal split (stacked). This also means
navigation is directionally *correct* only for a two-pane layout -- a
third pane is out of scope for this first pass.

A level is "solved" only once the player has actually split (revealing
the second pane) and both panes' cursors sit on their own goal tile --
finishing the first pane alone never completes a two-pane level, the
same way a real tmux workflow that never splits never gets said pane's
work done.
"""

from dataclasses import dataclass, field
from typing import List, Optional

from . import motions
from .grid import Level

LEADER = "\x02"  # Ctrl-b


@dataclass
class PaneSession:
    """Two-pane tmux-splitting drill. `panes[0]` is always active; `panes[1]`
    only becomes active (and visible) after a split."""

    panes: List[Level]
    positions: List[tuple] = field(default_factory=list)
    active: List[bool] = None
    focus: int = 0
    split_kind: Optional[str] = None  # None, "vertical" (%), or "horizontal" (")
    key_buffer: str = ""
    _leader_wait: bool = False

    def __post_init__(self):
        if len(self.panes) != 2:
            raise ValueError("PaneSession currently supports exactly 2 panes")
        self.positions = [p.start_pos for p in self.panes]
        self.active = [True, False]
        self.focus = 0
        self.split_kind = None
        self.key_buffer = ""
        self._leader_wait = False

    @property
    def solved(self) -> bool:
        if not all(self.active):
            return False
        return all(pos == pane.goal_pos for pos, pane in zip(self.positions, self.panes))

    def feed_key(self, key: str) -> Optional[str]:
        """Returns an event string ("split", "focus_changed", "moved",
        "blocked", "deleted", "yanked", "pane_solved", "solved") or None if
        still buffering."""
        if key == "\x1b":
            self.key_buffer = ""
            self._leader_wait = False
            return None

        if self._leader_wait:
            self._leader_wait = False
            return self._handle_leader_command(key)

        if key == LEADER and self.key_buffer == "":
            self._leader_wait = True
            return None

        return self._feed_motion_key(key)

    def _handle_leader_command(self, key: str) -> Optional[str]:
        if key in ("%", '"'):
            if self.active[1]:
                return None  # already split -- no-op, matches tmux ignoring a redundant split
            self.active[1] = True
            self.split_kind = "vertical" if key == "%" else "horizontal"
            self.focus = 1  # real tmux moves focus to the newly created pane
            return "split"

        nav_keys = {"h", "l"} if self.split_kind == "vertical" else {"j", "k"}
        if self.split_kind is not None and key in nav_keys:
            target = 1 - self.focus
            if self.active[target]:
                self.focus = target
                return "focus_changed"
            return None
        return None  # unrecognized leader command -- no-op, matches real tmux ignoring it

    def _feed_motion_key(self, key: str) -> Optional[str]:
        level = self.panes[self.focus]
        pos = self.positions[self.focus]

        candidate = self.key_buffer + key
        parsed = motions.parse(candidate)

        if parsed is None:
            if motions.is_partial(candidate):
                self.key_buffer = candidate
            else:
                self.key_buffer = ""
            return None

        self.key_buffer = ""

        if parsed.operator:
            new_pos = motions.apply_operator(
                pos, parsed.operator, parsed.motion, parsed.count, level,
                find_char=parsed.find_char,
            )
            self.positions[self.focus] = new_pos
            return self._check_pane_goal("deleted" if parsed.operator == "d" else "yanked")

        new_pos = motions.apply_motion(pos, parsed.motion, parsed.count, level, find_char=parsed.find_char)
        moved = new_pos != pos
        self.positions[self.focus] = new_pos
        return self._check_pane_goal("moved" if moved else "blocked")

    def _check_pane_goal(self, default_event: str) -> str:
        pos = self.positions[self.focus]
        level = self.panes[self.focus]
        if pos != level.goal_pos:
            return default_event
        if self.solved:
            return "solved"
        return "pane_solved"
