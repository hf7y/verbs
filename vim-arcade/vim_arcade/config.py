"""Issue #88: a global config file and per-repo config files, both
plain editable text. Pure path/permissions logic only -- no curses, no
`gh` -- so it's unit-testable without a terminal or network, same split
as gh_triage.py's data layer vs gh_game.py's curses front-end.

Location follows the convention github_app_auth.py already documented
but never implemented a read path for: outside the repo, under the
account's own home, never machine-wide -- ~/.config/vim-arcade/. That
needs no escalation (the account already owns its own home), so the
"if blocked on escalation, write a script for Zach" branch issue #88
asks for doesn't apply here; there's nothing to escalate past.
"""

import configparser
import os
import stat
from pathlib import Path

CONFIG_HOME_ENV_VAR = "VIM_ARCADE_CONFIG_HOME"

GLOBAL_TEMPLATE = """\
# vim-arcade global config (~/.config/vim-arcade/config.ini)
# Applies across every repo unless a repo's own config overrides it.

[defaults]
# live = true
"""

REPO_TEMPLATE = """\
# vim-arcade per-repo config for {slug}
# Overrides the global config's [defaults] section for this repo only.

[repo]
# live = true
"""


def config_home() -> Path:
    """~/.config/vim-arcade by default; overridable via
    VIM_ARCADE_CONFIG_HOME so tests never touch the real machine file
    (same pattern as gh_triage.VIM_ARCADE_STATE_HOME)."""
    base = os.environ.get(CONFIG_HOME_ENV_VAR)
    return Path(base) if base else Path.home() / ".config" / "vim-arcade"


def global_config_path() -> Path:
    return config_home() / "config.ini"


def repo_config_path(slug: str) -> Path:
    """slug is 'owner/name'; '/' isn't filename-safe so it becomes '__'."""
    return config_home() / "repos" / f"{slug.replace('/', '__')}.ini"


def _secure_mkdir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path, 0o700)


def ensure_config_file(path: Path, template: str) -> Path:
    """Creates path's parent dir and the file itself (seeded with
    template) if either is missing -- never overwrites existing
    content. Always (re-)applies 0700/0600 afterward, so a config file
    created before this ran with a looser umask still ends up
    locked-down, not just newly-created ones."""
    _secure_mkdir(path.parent)
    if not path.exists():
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        try:
            os.write(fd, template.encode())
        finally:
            os.close(fd)
    os.chmod(path, 0o600)
    return path


def ensure_global_config() -> Path:
    return ensure_config_file(global_config_path(), GLOBAL_TEMPLATE)


def ensure_repo_config(slug: str) -> Path:
    return ensure_config_file(repo_config_path(slug), REPO_TEMPLATE.format(slug=slug))


def permission_problems(path: Path) -> list:
    """Non-empty iff path is readable/writable by anyone but its owner
    -- group or world read/write/execute bits set. Used by tests to
    prove ensure_config_file's chmod actually took, and available to
    callers who want to warn rather than trust silently."""
    mode = stat.S_IMODE(path.stat().st_mode)
    problems = []
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        problems.append(f"{path} is accessible by group/other (mode {oct(mode)})")
    return problems


def read_config(path: Path) -> configparser.ConfigParser:
    parser = configparser.ConfigParser()
    parser.read(path)
    return parser
