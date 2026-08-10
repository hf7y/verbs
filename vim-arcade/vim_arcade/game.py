"""curses front-end around session.Session -- the only part of this
project that needs a real terminal, kept as thin as possible so the game
logic itself (session.py, motions.py, grid.py) stays unit-testable.
"""

import curses

from .levels import LEVELS
from .progress import clear_progress, cumulative_unlocked, load_progress, save_progress
from .session import Session
from .tips import INTRO_TIPS, LEVEL_TIPS

PLAYER_CHAR = "@"
GOAL_CHAR = "$"


def _key_to_char(key) -> str:
    if key in (curses.KEY_ENTER, 10, 13):
        return "\n"
    if 0 <= key < 256:
        return chr(key)
    return ""


def _show_tip(stdscr, lines):
    stdscr.erase()
    for i, line in enumerate(lines):
        stdscr.addstr(i, 0, line)
    stdscr.addstr(len(lines) + 1, 0, "Press any key to start.")
    stdscr.refresh()
    stdscr.getch()


def run(stdscr):
    curses.curs_set(0)
    stdscr.nodelay(False)
    start_level = load_progress(LEVELS)
    session = Session(level_index=start_level, unlocked=cumulative_unlocked(start_level, LEVELS))

    if INTRO_TIPS and start_level == 0:
        _show_tip(stdscr, INTRO_TIPS)
    if start_level in LEVEL_TIPS:
        _show_tip(stdscr, LEVEL_TIPS[start_level])
    last_tipped_level = start_level

    message = ""
    while True:
        if session.level_index != last_tipped_level and session.level_index in LEVEL_TIPS:
            _show_tip(stdscr, LEVEL_TIPS[session.level_index])
        last_tipped_level = session.level_index

        stdscr.erase()
        level = session.level
        stdscr.addstr(0, 0, f"vim-arcade -- {level.name}")
        stdscr.addstr(1, 0, f"unlocked: {' '.join(sorted(session.unlocked))}")

        for r in range(level.height):
            for c in range(level.width):
                ch = level.char_at(r, c)
                if ch == "@":
                    ch = GOAL_CHAR
                try:
                    stdscr.addch(3 + r, c, ch)
                except curses.error:
                    pass  # terminal too small for this level -- best effort
        pr, pc = session.player_pos
        try:
            stdscr.addch(3 + pr, pc, PLAYER_CHAR, curses.A_BOLD)
        except curses.error:
            pass

        recording_note = f" [recording @{session.recording}]" if session.recording else ""
        visual_labels = {"char": "VISUAL", "line": "VISUAL LINE", "block": "VISUAL BLOCK"}
        visual_note = (
            f" -- {visual_labels[session.visual_kind]} --" if session.visual_active else ""
        )
        insert_note = " -- INSERT --" if session.insert_active else ""
        stdscr.addstr(
            3 + level.height + 1,
            0,
            f"buffer: {session.key_buffer}{recording_note}{visual_note}{insert_note}",
        )
        stdscr.addstr(3 + level.height + 2, 0, message)
        stdscr.addstr(3 + level.height + 4, 0, "Q to quit")
        stdscr.refresh()

        key = stdscr.getch()
        if key == ord("Q"):
            break

        char = _key_to_char(key)
        if not char:
            continue

        event = session.feed_key(char)
        if event == "locked":
            message = f"'{char}' isn't unlocked yet on this level."
        elif event == "deleted":
            message = "cleared."
        elif event == "yanked":
            message = "yanked (no effect on the grid)."
        elif event == "changed":
            message = "cleared -- INSERT mode (type to place, Esc to leave)."
        elif event == "inserted":
            message = "-- INSERT --"
        elif event == "insert_exited":
            message = "back to normal mode."
        elif event == "recording_started":
            message = f"recording macro into register '{session.recording}'..."
        elif event == "recording_stopped":
            message = "macro recorded."
        elif event == "visual_on":
            message = "visual mode (motion to extend, d/y to act, same key/Esc to cancel)"
        elif event == "visual_off":
            message = "visual mode cancelled."
        elif event == "mark_set":
            message = "mark set."
        elif event == "no_mark":
            message = "that mark isn't set yet."
        elif event == "level_complete":
            save_progress(session.level_index)
            message = f"Level complete! Welcome to {session.level.name}."
        elif event == "game_complete":
            clear_progress()
            stdscr.erase()
            stdscr.addstr(0, 0, "You cleared every level. Press any key to exit.")
            stdscr.refresh()
            stdscr.getch()
            break
        else:
            message = ""


def main():
    curses.wrapper(run)


if __name__ == "__main__":
    main()
