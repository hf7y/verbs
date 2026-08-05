"""Shared agent-authorship stamp for GitHub issues/comments (issue #34).

`nightly-batch` and any other automation that posts to GitHub as `hf7y`
needs a way to tell its own output apart from Zach's -- otherwise it can
read its own comment back as his answer and act on it (proven live on
#6: four comments, all `hf7y`, two Zach's and two an agent's).

The design, from #34: the agent stamps its own output; absence of a
stamp means human. Zach never has to tag anything -- any scheme that
requires him to would fail the same silent way #16 did, three times in
one day.

Existing provenance was ad hoc and inconsistent -- `q-94e71f` on #6,
`q-mr1` on #11, `q-up1` on #12, nothing at all on #31/#32. This module
is the ONE place the stamp is emitted and detected; no caller retypes
the format.

Format: a last-line HTML comment, invisible when GitHub renders the
markdown, trivially greppable via the API:

    <!-- agent: <project>/<job> <ISO8601 UTC, second precision> -->

e.g. `<!-- agent: vim-arcade/nightly-batch 2026-08-04T22:23:00Z -->`.
"""

import re
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

# project: no "/" (it's the left side of project/job, so a stray "/"
# would make the pair ambiguous to parse back out). job: no whitespace.
# The timestamp is captured as-written and not validated strictly here --
# format_stamp is the only thing that's ever supposed to produce it, and
# a detector that's pickier than the emitter just invites drift between
# the two.
_STAMP_LINE_RE = re.compile(
    r"^<!--\s*agent:\s*(?P<project>[^/\s]+)/(?P<job>\S+)\s+(?P<when>\S+)\s*-->$"
)


class ProvenanceError(ValueError):
    """Raised when format_stamp is asked to emit a malformed stamp --
    fails loud rather than emitting something the detector can't parse
    back out."""


def format_stamp(project: str, job: str, when: Optional[datetime] = None) -> str:
    """The stamp line itself, with no surrounding body text. `project`
    must not contain '/' (it's the delimiter between project and job);
    `job` must be non-empty and whitespace-free."""
    if not project or "/" in project:
        raise ProvenanceError(f"project must be non-empty and contain no '/': {project!r}")
    if not job or any(ch.isspace() for ch in job):
        raise ProvenanceError(f"job must be non-empty and contain no whitespace: {job!r}")
    moment = when if when is not None else datetime.now(timezone.utc)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    moment = moment.astimezone(timezone.utc)
    ts = moment.strftime("%Y-%m-%dT%H:%M:%SZ")
    return f"<!-- agent: {project}/{job} {ts} -->"


def stamp_body(body: str, project: str, job: str, when: Optional[datetime] = None) -> str:
    """`body` with the stamp appended as its own trailing line, blank-line
    separated from whatever text came before (so it reads as a distinct
    marker, not a run-on with the last sentence). Safe to call on an
    empty body (a stamp-only comment is valid)."""
    stamp = format_stamp(project, job, when)
    text = (body or "").rstrip("\n")
    return f"{text}\n\n{stamp}\n" if text else f"{stamp}\n"


@dataclass(frozen=True)
class Stamp:
    project: str
    job: str
    when: str  # ISO8601 string exactly as written; parse it yourself if you need a datetime


def extract_stamp(text: str) -> Optional[Stamp]:
    """The stamp, if and only if `text`'s LAST non-blank line is one.

    Load-bearing: a stamp that shows up mid-body (quoted from another
    comment, pasted in, part of an example) must NOT count -- only the
    marker line the helper itself appends, which is always last."""
    lines = [line.strip() for line in (text or "").splitlines() if line.strip()]
    if not lines:
        return None
    m = _STAMP_LINE_RE.match(lines[-1])
    if not m:
        return None
    return Stamp(project=m.group("project"), job=m.group("job"), when=m.group("when"))


def is_stamped(text: str) -> bool:
    """True iff `text` carries an agent stamp as its last line. This is
    the detector half of the pair `format_stamp`/`stamp_body` produce --
    the only function anything should call to answer "did an agent write
    this," rather than re-deriving the pattern."""
    return extract_stamp(text) is not None
