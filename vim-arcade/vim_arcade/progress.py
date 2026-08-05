"""Save/load which level the player last reached -- deliberately tiny and
curses-free like every other module here, so it stays unit-testable.

Only the *level index* is persisted, not the full `Session` -- everything
else (`unlocked`, marks, macros, key buffer) is either derivable from the
level index (`cumulative_unlocked`) or deliberately per-run/per-level
state that shouldn't survive a restart anyway.
"""

import json
import os

DEFAULT_PATH = os.path.expanduser("~/.vim_arcade_progress.json")


def cumulative_unlocked(level_index, levels):
    """Every motion introduced by `levels[0..level_index]` inclusive --
    what a fresh `Session` would have unlocked by playing straight
    through to `level_index`, without needing to replay every level."""
    unlocked = set()
    for level in levels[: level_index + 1]:
        for motion in level.introduces:
            if motion != "counts":  # "counts" isn't a motion key itself
                unlocked.add(motion)
    return unlocked


def load_progress(levels, path=DEFAULT_PATH):
    """Returns the level index to resume at -- 0 if there's no save file,
    it's corrupt, or it names a level index that no longer exists (e.g.
    the save predates a level being removed)."""
    try:
        with open(path) as f:
            data = json.load(f)
        level_index = int(data["level_index"])
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        return 0
    if not (0 <= level_index < len(levels)):
        return 0
    return level_index


def save_progress(level_index, path=DEFAULT_PATH):
    with open(path, "w") as f:
        json.dump({"level_index": level_index}, f)


def clear_progress(path=DEFAULT_PATH):
    """Called on finishing the whole game -- next play starts fresh."""
    try:
        os.remove(path)
    except FileNotFoundError:
        pass
