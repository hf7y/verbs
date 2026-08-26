"""Tests for tools/issue-janitor.py.

Everything here is offline: `classify` is pure, and the two tests that
exercise `main` stub out the GitHub calls entirely. No test can reach
the network, and no test can close an issue.

The fixtures are verbatim copies of real issue bodies from hf7y/senechal
(#44 and #78 for the receipts, #75 for the machine-filed thing that is
NOT a receipt), because the whole safety argument rests on those exact
sentences.

  python3 -m unittest tools.test-issue-janitor  # (dashes: use the runner
  python3 tools/test-issue-janitor.py           #  below instead)
"""

import importlib.util
import io
import json
import sys
import unittest
import unittest.mock
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("issue_janitor", HERE / "issue-janitor.py")
issue_janitor = importlib.util.module_from_spec(spec)
sys.modules["issue_janitor"] = issue_janitor
spec.loader.exec_module(issue_janitor)

NOW = datetime(2026, 8, 6, 12, 0, 0, tzinfo=timezone.utc)
OLD = "2026-08-05T19:14:08Z"  # ~17h before NOW

FOOTER = (
    "\n\n---\nfiled 2026-08-05 14:14 via `scheduler -i senechal` on mandark\n\n"
    "Triage this on senechal's next run: act on it if it is work,\n"
    "answer and close it if it is a note. Closing IS the acknowledgement --\n"
    "there is no separate label to add.\n"
)

# hf7y/senechal#44, verbatim.
ADD_SENTENCE = (
    "installe: garde is now on PATH at /home/zach/.local/bin/garde -> "
    "/home/zach/.local/share/verb-builds/current/gardien/bin/garde "
    "(owned by senechal's installe; remove with: installe retire garde)"
)
# hf7y/senechal#78, verbatim.
REMOVE_SENTENCE = (
    "installe: entraine is no longer on PATH "
    "(removed /home/zach/.local/bin/entraine; its target was not deleted)"
)


def issue(number=44, title=None, body=None, labels=("idea",), created=OLD, **over):
    sentence = ADD_SENTENCE if body is None else body
    out = {
        "number": number,
        # scheduler -i truncates titles mid-word; reproduce that.
        "title": sentence[:148] if title is None else title,
        "body": sentence + FOOTER,
        "labels": [{"name": n} for n in labels],
        "createdAt": created,
        "comments": [],
        "assignees": [],
        "milestone": None,
        "reactionGroups": [],
        "url": "https://github.com/hf7y/senechal/issues/%d" % number,
    }
    out.update(over)
    return out


def verdict(iss, min_age=issue_janitor.MIN_AGE_HOURS):
    return issue_janitor.classify(iss, NOW, min_age)[0]


class ClassifyReceiptsTest(unittest.TestCase):
    def test_never_closes_a_typed_door_filing(self):
        # It carries a payload absorb-notices.py must WRITE before anyone may
        # close it. Asserted with a body that otherwise matches a receipt
        # perfectly, and with ALLOWED_LABELS widened to include `door`, so the
        # guard is the explicit check and not gate 5 happening to refuse it.
        iss = issue(labels=("idea", "door"))
        self.assertEqual("keep", verdict(iss))
        widened = frozenset(issue_janitor.ALLOWED_LABELS | {"door"})
        with unittest.mock.patch.object(issue_janitor, "ALLOWED_LABELS", widened):
            self.assertEqual("keep", verdict(iss))

    def test_closes_real_installe_path_add_receipt(self):
        v, name, _ = issue_janitor.classify(issue(), NOW)
        self.assertEqual(("close", "installe-path-add"), (v, name))

    def test_closes_real_installe_path_remove_receipt(self):
        v, name, _ = issue_janitor.classify(
            issue(number=78, body=REMOVE_SENTENCE), NOW
        )
        self.assertEqual(("close", "installe-path-remove"), (v, name))

    def test_truncated_title_does_not_block_close(self):
        # Real titles arrive cut mid-word; only the body is trustworthy.
        iss = issue(title=ADD_SENTENCE[:60])
        self.assertEqual("close", verdict(iss))


class ClassifyRefusalsTest(unittest.TestCase):
    """Every one of these must survive the sweep."""

    def test_keeps_hand_written_issue_with_no_footer(self):
        iss = issue(body=ADD_SENTENCE)
        iss["body"] = ADD_SENTENCE  # no machine footer at all
        self.assertEqual("keep", verdict(iss))

    def test_keeps_machine_filed_work_item_hf7y_senechal_75(self):
        # #75: `idea`-labelled, filed by `scheduler -i senechal`, and a
        # real unfinished build. Label + channel are not evidence.
        iss = issue(
            number=75,
            title="Finish the notification-noise work on branch "
            "alert-on-change-not-on-level (commit e19219d)",
            body="Finish the notification-noise work on branch "
            "alert-on-change-not-on-level (commit e19219d)\n\n"
            "The build is committed but UNVERIFIED -- the session was stopped "
            "before the test suite ran even once.",
        )
        self.assertEqual("keep", verdict(iss))

    def test_keeps_receipt_with_extra_prose_appended(self):
        iss = issue(body=ADD_SENTENCE + "\n\nKnown gap: the wrapper is unwired.")
        self.assertEqual("keep", verdict(iss))

    def test_keeps_receipt_that_a_human_commented_on(self):
        iss = issue(comments=[{"body": "wait, why?"}])
        self.assertEqual("keep", verdict(iss))

    def test_keeps_receipt_that_a_human_reacted_to(self):
        iss = issue(
            reactionGroups=[{"content": "THUMBS_UP", "users": {"totalCount": 1}}]
        )
        self.assertEqual("keep", verdict(iss))

    def test_zero_count_reaction_group_is_not_a_reaction(self):
        iss = issue(reactionGroups=[{"content": "EYES", "users": {"totalCount": 0}}])
        self.assertEqual("close", verdict(iss))

    def test_keeps_receipt_that_a_human_relabelled(self):
        self.assertEqual("keep", verdict(issue(labels=("idea", "bug"))))

    def test_closes_receipt_carrying_machine_applied_from_label(self):
        # `scheduler -i` stamps `from:<project>` itself; it is not a
        # human triage decision and must not block the close.
        v, name, _ = issue_janitor.classify(
            issue(labels=("idea", "from:realisateur")), NOW
        )
        self.assertEqual(("close", "installe-path-add"), (v, name))

    def test_keeps_receipt_with_from_label_a_human_still_added_manually(self):
        # A malformed/unexpected from:-shaped label a human typed by hand
        # is indistinguishable from the machine-applied one here, and
        # that ambiguity is exactly why real human labels must still
        # gate closure -- covered by relabelled test above using "bug".
        # This test instead pins the regex to `from:` only, not any
        # colon-bearing label.
        v, name, _ = issue_janitor.classify(
            issue(labels=("idea", "source:realisateur")), NOW
        )
        self.assertEqual("keep", v)

    def test_keeps_receipt_that_is_assigned(self):
        self.assertEqual("keep", verdict(issue(assignees=[{"login": "hf7y"}])))

    def test_keeps_receipt_in_a_milestone(self):
        self.assertEqual("keep", verdict(issue(milestone={"title": "v1"})))

    def test_keeps_body_that_is_long_even_if_it_starts_like_a_receipt(self):
        iss = issue(body=ADD_SENTENCE + " " + "x" * issue_janitor.MAX_RECEIPT_BODY_CHARS)
        self.assertEqual("keep", verdict(iss))

    def test_keeps_body_whose_verb_backreference_disagrees(self):
        # Hand-edited or mis-emitted: "retire garde" for verb "fauche".
        iss = issue(body=ADD_SENTENCE.replace("installe retire garde", "installe retire fauche"))
        self.assertEqual("keep", verdict(iss))

    def test_keeps_prose_host_state_note_that_is_machine_filed(self):
        # e.g. #72 -- a receipt to a reader, prose to this tool.
        iss = issue(
            number=72,
            body="mandark: REMOVED the gardien dev clone "
            "(~/Documents/Projects/gardien, 5.6M). Recover with: "
            "git clone https://github.com/hf7y/gardien.git.",
        )
        self.assertEqual("keep", verdict(iss))

    def test_keeps_empty_bodied_human_issue(self):
        iss = issue(number=83, title="too many issues", body="")
        iss["body"] = ""
        self.assertEqual("keep", verdict(iss))


class GraceWindowTest(unittest.TestCase):
    def test_holds_a_receipt_inside_the_grace_window(self):
        fresh = (NOW - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        v, name, _ = issue_janitor.classify(issue(created=fresh), NOW)
        self.assertEqual(("hold", "installe-path-add"), (v, name))

    def test_closes_once_the_grace_window_passes(self):
        aged = (NOW - timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertEqual("close", verdict(issue(created=aged)))

    def test_grace_window_is_overridable(self):
        aged = (NOW - timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertEqual("hold", verdict(issue(created=aged), min_age=24))

    def test_missing_created_at_cannot_look(self):
        iss = issue()
        del iss["createdAt"]
        with self.assertRaises(issue_janitor.CannotLook):
            issue_janitor.classify(iss, NOW)


class ClosingCommentTest(unittest.TestCase):
    def test_comment_names_the_pattern_and_how_to_reopen(self):
        text = issue_janitor.closing_comment("installe-path-add", "hf7y/senechal")
        self.assertIn("installe-path-add", text)
        self.assertIn("reopen", text.lower())
        self.assertIn("issue-janitor.py", text)


class MainExitContractTest(unittest.TestCase):
    """The 0 / 1 / 2 contract, with GitHub stubbed out."""

    def run_main(self, argv, issues=None, fetch_raises=None, close_raises=False):
        def fake_fetch(repo, limit=500):
            if fetch_raises:
                raise fetch_raises
            return issues or []

        closed = []

        def fake_close(repo, number, comment):
            if close_raises:
                raise issue_janitor.CannotLook("boom")
            closed.append(number)

        buf = io.StringIO()
        with mock.patch.object(issue_janitor, "fetch_open_issues", fake_fetch), \
                mock.patch.object(issue_janitor, "close_issue", fake_close), \
                redirect_stdout(buf):
            rc = issue_janitor.main(argv)
        return rc, buf.getvalue(), closed

    def test_clean_inbox_exits_pass(self):
        rc, _, _ = self.run_main([], issues=[issue(number=83, body="", title="x")])
        self.assertEqual(issue_janitor.RC_PASS, rc)

    def test_buried_inbox_of_unrecognised_issues_is_not_a_pass(self):
        """The regression this tool shipped with: 57 open, 0 recognised, exit 0.

        Every issue here is unrecognisable (empty body, no footer), so
        `close` is empty and the old exit logic returned RC_PASS -- the
        broom reporting a clean inbox while standing in the burial it
        exists to prevent. Past BACKLOG_CEILING that is could-not-look.
        """
        many = [
            issue(number=n, body="", title="realisateur: monkey change %d" % n)
            for n in range(100, 100 + issue_janitor.BACKLOG_CEILING)
        ]
        rc, out, closed = self.run_main([], issues=many)
        self.assertEqual(issue_janitor.RC_INCOMPLETE, rc)
        self.assertEqual([], closed, "must still close nothing it cannot read")
        self.assertIn("UNSWEPT", out)

    def test_backlog_below_the_ceiling_still_passes(self):
        """The ceiling is a ceiling, not a ban on having any open issues."""
        few = [
            issue(number=n, body="", title="x")
            for n in range(200, 200 + issue_janitor.BACKLOG_CEILING - 1)
        ]
        rc, out, _ = self.run_main([], issues=few)
        self.assertEqual(issue_janitor.RC_PASS, rc)
        self.assertNotIn("UNSWEPT", out)

    def test_dirty_dry_run_exits_fail_and_closes_nothing(self):
        rc, out, closed = self.run_main([], issues=[issue()])
        self.assertEqual(issue_janitor.RC_FAIL, rc)
        self.assertEqual([], closed)
        self.assertIn("WOULD CLOSE: 1", out)

    def test_apply_closes_and_exits_pass(self):
        rc, out, closed = self.run_main(["--apply"], issues=[issue(), issue(number=45)])
        self.assertEqual(issue_janitor.RC_PASS, rc)
        self.assertEqual([44, 45], closed)
        self.assertIn("CLOSED: 2", out)

    def test_apply_is_idempotent_second_run_sees_nothing(self):
        # Second run: the closed issues are no longer in the open list,
        # and the one that remains carries the janitor's own comment.
        remaining = issue(number=44, comments=[{"body": "Auto-closed by ..."}])
        rc, out, closed = self.run_main(["--apply"], issues=[remaining])
        self.assertEqual(issue_janitor.RC_PASS, rc)
        self.assertEqual([], closed)

    def test_gh_unavailable_exits_incomplete(self):
        rc, _, _ = self.run_main(
            [], fetch_raises=issue_janitor.CannotLook("gh not found on PATH")
        )
        self.assertEqual(issue_janitor.RC_INCOMPLETE, rc)

    def test_failed_close_exits_fail(self):
        rc, _, _ = self.run_main(["--apply"], issues=[issue()], close_raises=True)
        self.assertEqual(issue_janitor.RC_FAIL, rc)

    def test_json_report_is_parseable_and_names_the_pattern(self):
        rc, out, _ = self.run_main(["--json"], issues=[issue()])
        data = json.loads(out)
        self.assertEqual(issue_janitor.RC_FAIL, rc)
        self.assertEqual({"installe-path-add": 1}, data["by_pattern"])
        self.assertEqual([44], [row["number"] for row in data["close"]])


if __name__ == "__main__":
    unittest.main(verbosity=2)
