"""The level progression -- each level introduces one new set of motions
on top of everything unlocked so far, arcade/platformer-style.
"""

from .grid import Level

LEVELS = [
    Level(
        name="1: hjkl",
        introduces=["h", "j", "k", "l"],
        ascii_map=[
            "..........",
            "..........",
            "....S.....",
            "..........",
            ".........@",
        ],
    ),
    Level(
        name="2: 0 and $",
        introduces=["0", "$"],
        ascii_map=[
            "##########",
            "#S.......#",
            "#.########",
            "#........#",
            "########.@",
        ],
    ),
    Level(
        name="3: gg and G",
        introduces=["gg", "G"],
        ascii_map=[
            "S.........",
            "#########.",
            "..........",
            ".#########",
            "..........",
            "#########.",
            "..........",
            ".........@",
        ],
    ),
    Level(
        # Trailing floor after the goal matters: without it, a bare "$"
        # (already unlocked since Level 2, ignores walls entirely) jumps
        # straight to the last column and lands exactly on the goal in
        # one keystroke, without ever touching w/b. See levels.py's
        # module-level note below for the general shape of this bug.
        name="4: w and b",
        introduces=["w", "b"],
        ascii_map=[
            "S..#..#..#..#....@..",
        ],
    ),
    Level(
        name="5: counts (e.g. 3l, 2j)",
        introduces=["counts"],
        ascii_map=[
            "S.........",
            "..........",
            "..........",
            "..........",
            "..........",
            "..........",
            ".........@",
        ],
    ),
    Level(
        # A single row, one wall run standing between S and the goal --
        # there's no way around it, only through it. dw (or d$/d6l) clears
        # the obstacle instead of just jumping past it like w would.
        # Floor tiles both before the goal (after the wall run) and after
        # it are load-bearing, not decoration: without them, a bare "w"
        # (jumps straight to the first floor tile past a wall run) or a
        # bare "$" (already unlocked since Level 2, ignores walls
        # entirely) would land exactly on the goal in one keystroke,
        # solving the level without ever touching d/y.
        name="6: operators (dd, dw, d3l, d$)",
        introduces=["d", "y"],
        ascii_map=[
            "S..######...@..",
        ],
    ),
    Level(
        # 'X' is a marker tile (see grid.py's char legend) -- "fX" jumps
        # straight to it in one keystroke instead of counting steps by hand.
        # Trailing floor after the goal is load-bearing: this row has no
        # walls at all, so without it a bare "$" (unlocked since Level 2)
        # or a bare "w" (with no wall run to bound it, jumps to the last
        # column exactly like "$" does) would land on the goal directly,
        # one keystroke, without ever needing f/t/F/T.
        name="7: f t F T (find-in-line)",
        introduces=["f", "t", "F", "T"],
        ascii_map=[
            "S.......X.......@..",
        ],
    ),
    Level(
        # Two full wall rows block straight-down movement -- "dj" (clear
        # current row + the row below) or "dG" (clear everything from here
        # to the bottom) opens a path a bare j/k never could, since j/k
        # can't step onto/through a wall tile at all.
        name="8: operators + j/k/gg/G (dj, dk, dgg, dG)",
        introduces=[],
        ascii_map=[
            "S.........",
            "##########",
            "..........",
            "##########",
            ".........@",
        ],
    ),
    Level(
        # No new motions -- combines what's already unlocked. "dfX" clears
        # from the cursor through the marker in one command, instead of
        # needing a separate motion to reach it first. Trailing floor
        # after the goal is load-bearing: without it, a bare "$" (already
        # unlocked since Level 2, ignores walls entirely) would land on
        # the goal in one keystroke, without ever touching dfX.
        name="9: operators + find-in-line (dfX, dtX, dFX, dTX)",
        introduces=[],
        ascii_map=[
            "S..######X......@..",
        ],
    ),
    Level(
        # Five identical wall-then-floor units in a row. Crossing one is
        # "dll" (dl clears the wall ahead, then two l's step through it and
        # across the following floor tile to sit right before the next
        # wall) -- record it once ("qadllq"), then "@a" replays the exact
        # same three keystrokes at every remaining wall, no retyping.
        # Nothing here *requires* the macro (typing "dll" five times by
        # hand works too) -- same "efficiency, not new capability" spirit
        # as counts (level 5): the payoff is fewer, more reliable
        # keystrokes on a repeated pattern, exactly like real vim macros.
        # Trailing floor after the goal is load-bearing: without it, a
        # bare "$" (already unlocked since Level 2, ignores walls
        # entirely) would land on the goal in one keystroke, without ever
        # touching the macro mechanic this level teaches.
        name="10: macros (qa...q to record, @a to replay)",
        introduces=["q", "@"],
        ascii_map=[
            "S#.#.#.#.#.@..",
        ],
    ),
    Level(
        # A wall run, then open floor, then the goal -- unlike Level 6's
        # map, the goal isn't the tile immediately reachable by jumping
        # the wall run, so a bare "w"/"$" can't accidentally solve the
        # whole level in one keystroke the way it could on Level 6's
        # shape. "v" enters visual (character-wise) selection, any motion
        # extends it toward the cursor, then "d" (or "y") acts on the
        # selected range and exits visual mode -- an alternative
        # selection syntax to operator+motion ("dw"/"d6l"), not a new
        # capability. Nothing here *requires* v (dw still clears the same
        # wall run) -- same "vocabulary, not new capability" spirit as
        # counts (level 5) and macros (level 10).
        name="11: visual mode (v + motion, then d or y)",
        introduces=["v"],
        ascii_map=[
            "S..######...@..",
        ],
    ),
    Level(
        # Two full wall rows, same shape as Level 8, but j/k can't reach
        # them to build a visual selection (they're blocked stepping onto
        # a wall tile, exactly like Level 8's bare j/k). "G" ignores
        # walls the same way it already does for plain motions and for
        # "dG" -- "VGd" (visual-line to the bottom, then delete) clears
        # every row in between in one alternate-vocabulary command, the
        # linewise-visual counterpart to "dG". Nothing here *requires*
        # V -- "dG"/"d2j" (already unlocked since level 8) still clear
        # the same rows -- same "alternate vocabulary, not new
        # capability" spirit as v (level 11), macros (level 10), and
        # counts (level 5).
        name="12: visual line mode (V)",
        introduces=["V"],
        ascii_map=[
            "S.........",
            "##########",
            "##########",
            ".........@",
        ],
    ),
    Level(
        # A wall block that doesn't span the full row width (cols 2-6
        # only, cols 0-1 stay open floor) -- unlike Level 12's full-width
        # rows, a linewise "V" selection here would clear more than the
        # block actually needs. Ctrl-v selects the exact rectangle
        # instead: move onto the block's first column (plain "l", floor
        # only), enter block mode, extend down with "G" and right with
        # "$" (both ignore walls, same as every other motion that already
        # jumps over/through them), then "d" clears just that rectangle.
        # Alternate vocabulary again, not a new capability -- the same
        # rectangle is also reachable one row at a time with "dl"/"d$".
        #
        # Row 3's cols 0-1 wall is load-bearing, not decoration: without
        # it, cols 0-1 are open floor top-to-bottom, and a bare "j j j
        # l l l l l l" (h/j/k/l, unlocked since Level 1) walks straight
        # down the untouched margin and across row 3 to the goal without
        # ever touching an operator or entering visual mode at all --
        # not just a one-keystroke solve like the bugs fixed in
        # b414366/one-keystroke-solve, but a total bypass of the level's
        # entire point. Blocking that column at row 3 forces clearing the
        # cols 2-6 block (by whatever means) before reaching the goal.
        # Trailing floor after the goal, both a row and a column's worth,
        # is load-bearing for the usual reason: without it, a bare "G"
        # then "$" (both unlocked well before this level, and both used
        # deliberately as *part of* the intended Ctrl-v solve, not
        # against it) would land exactly on the goal in two keystrokes,
        # the same "$"/"G" motions this level actually wants you to use
        # for extending the block selection -- not a same-keystroke
        # solve of the level, just this level's tools pointed at empty
        # air instead of the block.
        name="13: visual block mode (Ctrl-v)",
        introduces=["\x16"],
        ascii_map=[
            "S.......",
            "..#####.",
            "..#####.",
            "##......",
            "......@.",
            "........",
        ],
    ),
    Level(
        # A single open row, no walls -- like Level 5 (counts), the point
        # is purely the new vocabulary, not an obstacle only it can clear.
        # 'C' is a checkpoint marker tile partway down the row (see
        # grid.py's marker-char legend, same mechanism as Level 7's 'X').
        # "maC" style play: touch the checkpoint, mark it ("ma"), wander on
        # to the far marker 'X', then "`a" snaps straight back to the
        # checkpoint's exact (row, col) in one keystroke -- something no
        # *single* existing motion can do (gg/G restore a row but not the
        # column, 0/$ restore a column but not the row, w/b only land on
        # word/wall boundaries). Trailing floor after the goal is
        # load-bearing for the usual reason: without it, a bare "$"
        # (unlocked since Level 2) would land on the goal in one
        # keystroke without ever touching a mark.
        name="14: marks (ma to set, `a to jump back)",
        introduces=["m", "`"],
        ascii_map=[
            "S....C.........X..@..",
        ],
    ),
    Level(
        # A single wall run, same shape as Level 6's -- "cw" clears it
        # exactly like "dw" would, but then drops the session into insert
        # mode (real vim: "change" deletes, then lets you type the
        # replacement). Pressing Escape immediately, typing nothing,
        # finishes the change with no different outcome than a plain
        # "dw" -- exactly like real vim, where "cw<Esc>" with no typing
        # in between is just a delete. Typing before Escape places new
        # wall tiles at the cursor instead (session.py's insert-mode
        # handling, via Level.set_wall) -- not required to clear this
        # level, just there to actually exercise the "type a
        # replacement" half of the mechanic if the player wants to.
        # Trailing floor after the goal is load-bearing for the usual
        # reason: without it, a bare "$" (unlocked since Level 2) would
        # land on the goal in one keystroke, without ever touching c.
        name="15: c (change operator)",
        introduces=["c"],
        ascii_map=[
            "S...#####...@..",
        ],
    ),
]
