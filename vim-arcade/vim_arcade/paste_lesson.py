"""Real-vim paste-safety lesson -- the stability milestone's actual bar
(`.claude/FOCUS.md`'s `## Stability milestone`): teach pasting multi-line
text into vim without autoindent mangling it into a staircase, and
copying a selection back out. Unlike the ASCII-grid levels in levels.py,
this domain needs a REAL vim buffer to be honest about it -- autoindent's
actual behavior can't be faked on a static grid without lying about what
vim does, the same reason the git-etiquette arc (`.claude/FOCUS.md`,
2026-07-27 pivot note) moved off the grid metaphor. So this launches real
`vim` via subprocess instead, the way `joue`/`gh_game.py` launches real
`gh`.

Only the orchestration (`run_lesson`, the two `_run_*_stage` helpers, and
`main`) needs a real terminal and a real `vim` binary, and isn't covered
by tests -- exactly the boundary game.py draws around curses. Everything
else here is a pure function over strings/paths, tested in
tests/test_paste_lesson.py.
"""

import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

# A fenced-code-block-shaped snippet plus a Markdown blockquote reply --
# literally "the shape Zach actually moves between Claude and these
# FOCUS.md files" (the milestone's own wording). The nested indent inside
# the loop is what makes a naive paste stairstep badly.
SOURCE_SNIPPET = (
    'for f in *.log; do\n'
    '    gzip "$f"\n'
    'done\n'
    '\n'
    '> resolved -- ran the loop above, all logs compressed\n'
)

# QUESTIONS.md's own answer-block shape (see that file's header example),
# used for the copy-OUT half so both stages use realistic material.
COPY_OUT_SNIPPET = (
    "- **2026-08-04 (nightly-batch): ship the paste lesson as its own\n"
    "  entry point, or fold it into game.py's level list?**\n"
    "  > own entry point -- the domain doesn't fit the grid, same call as\n"
    "  > the git arc\n"
)


@dataclass
class LessonResult:
    passed: bool
    message: str


def simulate_autoindent_mangling(source: str) -> str:
    """Deterministic model of vim's `autoindent` behavior on a naive
    terminal paste (no `:set paste`, no bracketed-paste): pressing Enter
    in insert mode copies the CURRENT line's actual indentation to the
    new line, and the incoming text's own leading whitespace is then
    inserted on top of that -- verbatim, vim doesn't know it's "already
    indented" text. Applied line by line, indentation compounds, which
    is exactly the staircase this lesson is about. Used to preview the
    failure before asking the player to avoid it, and to build the
    diagnostic below -- not a stand-in for actually running vim.
    """
    result = []
    inherited = ""
    for line in source.splitlines():
        own_indent = line[: len(line) - len(line.lstrip(" \t"))]
        content = line[len(own_indent) :]
        new_indent = inherited + own_indent
        # A line with no real content gets its auto-inserted indent
        # stripped back to truly empty by vim -- but the NEXT line still
        # inherits the level as if it had been written, so `inherited`
        # updates either way.
        result.append(new_indent + content if content else "")
        inherited = new_indent
    return "\n".join(result)


def diagnose_paste(source: str, got: str) -> LessonResult:
    """Compare what actually ended up in the destination file against the
    source snippet, naming which failure (if any) it looks like -- the
    staircase specifically, a changed line count, changed content, or
    some other whitespace drift -- rather than just pass/fail."""
    source_lines = source.splitlines()
    got_lines = got.splitlines()

    if got_lines == source_lines:
        return LessonResult(True, "Matches the source exactly -- pasted safely.")

    mangled_lines = simulate_autoindent_mangling(source).splitlines()
    if got_lines == mangled_lines:
        return LessonResult(
            False,
            "That's the autoindent staircase: each line inherited the "
            "previous line's actual indentation on top of its own. Try "
            "`:set paste` before pasting (`:set nopaste` after), or `:r "
            "<file>` to skip the paste step entirely.",
        )

    if len(source_lines) != len(got_lines):
        return LessonResult(
            False,
            f"Line count differs: source has {len(source_lines)}, yours has "
            f"{len(got_lines)} -- that's not indentation drift, something "
            "else changed (a dropped or duplicated line).",
        )

    for i, (s, g) in enumerate(zip(source_lines, got_lines), start=1):
        if s.strip() != g.strip():
            return LessonResult(
                False,
                f"Line {i}'s text itself differs, not just its indentation "
                "-- double check what actually ended up there.",
            )

    return LessonResult(
        False,
        "Indentation differs from the source but doesn't match the "
        "autoindent-staircase shape either -- worth a closer look at what "
        "actually happened.",
    )


def diagnose_copy_out(expected: str, got: str) -> LessonResult:
    """Same idea as diagnose_paste, for the copy-OUT direction: did the
    selection that left vim match what was meant to be selected."""
    expected_lines = expected.splitlines()
    got_lines = got.splitlines()
    if got_lines == expected_lines:
        return LessonResult(True, "Copied out exactly the right selection.")
    if not got_lines:
        return LessonResult(
            False,
            "Nothing came out -- did the write/paste actually land? "
            "(`:'<,'>w! <file>` needs a visual selection active first; "
            '`"+p` needs the yank to have gone to the `+` register.)',
        )
    return LessonResult(
        False,
        f"Expected {len(expected_lines)} line(s) matching the selection; "
        f"got {len(got_lines)} that don't match -- re-select just the "
        "intended lines.",
    )


def has_clipboard_support(version_output: str) -> bool:
    """Parses `vim --version` output. Stock vim on a minimal/headless
    machine is often built without `+clipboard`/`+xterm_clipboard` --
    when that's true the lesson falls back to a range-write, which is
    the "more reliable" option the intro tip (tips.py) already names."""
    return "+clipboard" in version_output or "+xterm_clipboard" in version_output


def verify_paste_in(dest_path: Path, source: str = SOURCE_SNIPPET) -> LessonResult:
    got = dest_path.read_text() if dest_path.exists() else ""
    return diagnose_paste(source, got)


def verify_copy_out(dest_path: Path, expected: str = COPY_OUT_SNIPPET) -> LessonResult:
    got = dest_path.read_text() if dest_path.exists() else ""
    return diagnose_copy_out(expected, got)


def _detect_clipboard() -> bool:
    try:
        proc = subprocess.run(
            ["vim", "--version"], capture_output=True, text=True, timeout=5
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return has_clipboard_support(proc.stdout)


def _run_paste_in_stage(tmp_path: Path) -> None:
    source_file = tmp_path / "source.txt"
    source_file.write_text(SOURCE_SNIPPET)
    dest_file = tmp_path / "dest.txt"
    dest_file.write_text("")

    print("STAGE 1 -- paste this in without mangling it.")
    print(f"The text to paste lives at: {source_file}")
    print("A naive terminal paste with autoindent on would turn it into:")
    print("-" * 40)
    print(simulate_autoindent_mangling(SOURCE_SNIPPET))
    print("-" * 40)
    print("Opening real vim on an empty file with autoindent ON (forced, so")
    print("this works the same on a machine with no ~/.vimrc). Two ways to")
    print("avoid the staircase above:")
    print("  - `:set paste`, paste, `:set nopaste` -- the simplest, works")
    print("    from any cursor position.")
    print(f"  - `:0r {source_file.name}` (0, not blank -- reads it in BEFORE")
    print("    the buffer's existing empty line, not after it), then `G` `dd`")
    print("    to remove that now-trailing empty line vim always leaves you")
    print("    with. `:r` on its own leaves it behind -- worth knowing before")
    print("    it costs you a diff.")
    print(":wq when done.")
    input("Press Enter to launch vim...")

    while True:
        subprocess.run(["vim", "-c", "set autoindent", str(dest_file)])
        result = verify_paste_in(dest_file)
        print(result.message)
        if result.passed or input("Try again? [Y/n] ").strip().lower() == "n":
            break


def _run_copy_out_stage(tmp_path: Path, clipboard: bool) -> None:
    source_file = tmp_path / "reply-source.txt"
    source_file.write_text(COPY_OUT_SNIPPET)
    out_file = tmp_path / "copied-out.txt"
    out_file.write_text("")

    print()
    print("STAGE 2 -- copy a selection OUT of vim so it can go back to Claude.")
    if clipboard:
        print("This vim has clipboard support. In the first window: select")
        print('the reply with V, yank to the system clipboard with "+y, then')
        print(f'quit. In the second window (on {out_file.name}): "+p to paste')
        print("it back in, then :wq.")
    else:
        print("This vim has no system clipboard support (+clipboard not")
        print("compiled in) -- the always-works fallback is a range write:")
        print(f"select the reply with V, then `:'<,'>w! {out_file}` to write")
        print("it straight to a file -- no clipboard needed. :q after.")
    input("Press Enter to open the source...")
    subprocess.run(["vim", str(source_file)])

    if clipboard:
        input("Press Enter to open the destination...")
        subprocess.run(["vim", str(out_file)])

    result = verify_copy_out(out_file)
    print(result.message)


def run_lesson() -> None:
    if shutil.which("vim") is None:
        print("This lesson needs real `vim` on PATH -- not found.")
        return
    with tempfile.TemporaryDirectory(prefix="vim-arcade-paste-") as tmp:
        tmp_path = Path(tmp)
        _run_paste_in_stage(tmp_path)
        _run_copy_out_stage(tmp_path, _detect_clipboard())


def main() -> None:
    run_lesson()


if __name__ == "__main__":
    main()
