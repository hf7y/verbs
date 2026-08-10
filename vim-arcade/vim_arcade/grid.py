"""ASCII-map-backed level grid.

Map legend:
  '#'  wall
  '.'  open floor
  '@'  goal
  'S'  player start (removed from the grid at load time, becomes start_pos)
  any other character  a walkable floor tile that keeps its literal
                       character -- used as a target for f/t/F/T
                       find-in-line motions (e.g. an 'X' to jump to).
"""

from dataclasses import dataclass
from typing import List, Tuple


@dataclass
class Level:
    name: str
    ascii_map: List[str]
    introduces: List[str]  # motions newly available starting this level
    start_pos: Tuple[int, int] = None
    goal_pos: Tuple[int, int] = None
    width: int = 0
    height: int = 0
    _walls: set = None
    _markers: dict = None

    def __post_init__(self):
        self.height = len(self.ascii_map)
        self.width = max(len(row) for row in self.ascii_map)
        walls = set()
        markers = {}
        start = None
        goal = None
        for r, row in enumerate(self.ascii_map):
            for c, ch in enumerate(row):
                if ch == "#":
                    walls.add((r, c))
                elif ch == "@":
                    goal = (r, c)
                elif ch == "S":
                    start = (r, c)
                elif ch != ".":
                    markers[(r, c)] = ch
        if start is None:
            raise ValueError(f"level {self.name!r} has no 'S' start tile")
        # A missing goal is allowed here (not for a real playable level,
        # but tests exercising motions in isolation don't need one) --
        # Session._load_level relies on every LEVELS entry having a real
        # goal, so that's where it'd actually bite.
        self._walls = walls
        self._markers = markers
        self.start_pos = start
        self.goal_pos = goal

    def is_wall(self, row: int, col: int) -> bool:
        return (row, col) in self._walls

    def clear_wall(self, row: int, col: int) -> None:
        """Remove a wall tile, turning it to floor -- the grid-world stand-in
        for an operator (`d`) consuming/deleting text."""
        self._walls.discard((row, col))

    def set_wall(self, row: int, col: int) -> None:
        """Add a wall tile -- the grid-world stand-in for typing replacement
        content during a `c` (change) operator's insert-mode stage."""
        self._walls.add((row, col))

    def char_at(self, row: int, col: int) -> str:
        if (row, col) == self.goal_pos:
            return "@"
        if self.is_wall(row, col):
            return "#"
        return self._markers.get((row, col), ".")

    def find_in_row(self, row: int, col: int, char: str, direction: int, count: int = 1):
        """Scan row `row` from `col` in `direction` (+1/-1) for the
        `count`-th occurrence of `char` (a marker tile's literal
        character). Returns the column, or None if there aren't that
        many occurrences before the edge of the grid -- the grid-world
        stand-in for real vim's f/t/F/T find-in-line motions."""
        found = 0
        c = col + direction
        while 0 <= c < self.width:
            if self.char_at(row, c) == char:
                found += 1
                if found == count:
                    return c
            c += direction
        return None
