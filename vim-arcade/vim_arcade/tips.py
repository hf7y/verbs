"""Meta tips shown outside the grid-motion mechanic itself -- things worth
knowing that don't map onto a level (see .claude/FOCUS.md's "Ideas"
section). Pure data so it stays unit-testable like everything else here;
game.py is the only thing that renders it.
"""

INTRO_TIPS = [
    "Tip: pasting multi-line text (e.g. something Claude printed in a",
    "terminal) straight into vim can mangle it -- each line's leading",
    "whitespace gets re-indented by autoindent as if you'd typed it.",
    "",
    "Before pasting, run `:set paste` (then `:set nopaste` after) to",
    "paste literally. Two more reliable options: `\"+p` pastes straight",
    "from the system clipboard register; `:r <file>` reads a file's",
    "contents in directly, no paste step at all.",
]

# Short, originally-written explanations shown once, right before a level
# that introduces new vocabulary -- same "explain the why before you're
# expected to use it" spirit as vimtutor's own lessons (2026-07-20 idea
# in FOCUS.md), but written fresh rather than copied from vimtutor's
# actual (Vim-licensed) text. Keyed by level index (0-based, matching
# LEVELS' order in levels.py) so game.py can look one up by
# session.level_index without a level having to carry its own tip.
LEVEL_TIPS = {
    0: [
        "h j k l move left/down/up/right, one tile at a time.",
        "",
        "Real vim keeps your hand on the home row for this -- no arrow",
        "keys needed. It feels slow at first; it stops feeling slow once",
        "it's muscle memory.",
    ],
    1: [
        "0 jumps to the first column of the current line; $ jumps to",
        "the last.",
        "",
        "Both ignore walls entirely -- they're absolute jumps to a line",
        "edge, not steps, so they can land past an obstacle a plain h/l",
        "walk into.",
    ],
    2: [
        "gg jumps to the very first line; G jumps to the very last.",
        "",
        "Like 0/$, both ignore walls -- they jump straight to a row,",
        "not through the columns in between.",
    ],
    3: [
        "w jumps forward to the start of the next word; b jumps",
        "backward to the start of the current/previous word.",
        "",
        "Here, a wall run's far edge counts as a 'word' boundary --",
        "w/b jump you across it, not through it.",
    ],
    4: [
        "Prefix almost any motion with a number to repeat it: 3l is",
        "three l's, 2j is two j's.",
        "",
        "This isn't a new motion -- it's how real vim avoids you ever",
        "hammering the same key by hand to cover distance.",
    ],
    5: [
        "d and y are operators, not motions -- they wait for a motion",
        "to tell them what to act on: dw, d3l, d$ all work.",
        "",
        "d deletes (clears an obstacle here); y yanks (copies) without",
        "touching anything. Doubling either one (dd, yy) acts on the",
        "whole current line.",
    ],
    6: [
        "f, t, F, T jump to a specific character in the current line:",
        "f<char> lands ON it, t<char> lands just BEFORE it. Capital",
        "versions search backward instead of forward.",
        "",
        "Faster than counting columns by eye once you know what",
        "you're aiming for.",
    ],
    9: [
        "Macros record a sequence of keystrokes and let you replay it:",
        "qa starts recording into register a, q (again) stops, @a",
        "replays it.",
        "",
        "Real payoff: record the fix once, then @a (or a count + @a)",
        "to repeat it across every remaining occurrence, instead of",
        "retyping the same keys by hand each time.",
    ],
    10: [
        "v starts visual (character) selection -- move to extend it,",
        "then d or y acts on exactly what's highlighted.",
        "",
        "Same result as operator+motion (dw, d6l) -- visual mode is",
        "just a different way to say it, useful when the range you",
        "want is easier to see than to name.",
    ],
    11: [
        "V starts visual LINE selection -- whole lines at a time",
        "instead of characters, the visual-mode counterpart to dj/dG.",
    ],
    12: [
        "Ctrl-v starts visual BLOCK selection -- a rectangle, not a",
        "run of characters or whole lines. Move down and across to",
        "size the rectangle, then d/y acts on just that block.",
    ],
    13: [
        "m<letter> drops an invisible mark at the cursor's exact",
        "position; `<letter> (backtick) jumps straight back to it.",
        "",
        "Unlike gg/G (row only) or 0/$ (column only), a mark remembers",
        "both -- the only way to snap back to one exact spot.",
    ],
    14: [
        "c is change: like d, it clears whatever the motion after it",
        "covers (cw, c3l, cc all work the same as their d equivalents)",
        "-- but then it drops you into INSERT mode instead of leaving",
        "you in place.",
        "",
        "In insert mode, every key you press (except Escape) types a",
        "new wall tile and steps you forward one tile, the same way",
        "real vim would insert replacement text. Escape returns to",
        "normal mode. Typing nothing and pressing Escape right away is",
        "the same as a plain d -- you're never required to type.",
    ],
}
