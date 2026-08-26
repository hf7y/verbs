# NAMING — keeper of names and places

The confirmed-conventions registry is `tools/naming.py` now, not this
file — a table you had to read became a check you can run:

```sh
tools/naming.py <name>       # 0 confirmed match / 1 confirmed violation / 2 unconfirmed
tools/naming.py --list       # every confirmed convention
```

The open research question ("is there a Roman/Latin-named convention for
a vaporwave project family?") is tracked as `gh issue view 166`, not
here.

This file still lives at the repo root rather than under `.claude/`
because that directory is permission-gated for direct agent edits in
this environment (confirmed 2026-07-24).
