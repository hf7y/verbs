import importlib.util
import io
import sys
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("claim_issue", HERE / "claim-issue.py")
claim_issue = importlib.util.module_from_spec(spec)
sys.modules["claim_issue"] = claim_issue
spec.loader.exec_module(claim_issue)

NOW = datetime(2026, 9, 2, 12, 0, 0, tzinfo=timezone.utc)


def claim_body(marker, when, ttl=21600):
    return claim_issue.claim_comment(marker, when, ttl)


def issue(state="OPEN", comments=None):
    return {"state": state, "comments": comments or []}


class DecideTest(unittest.TestCase):
    def test_no_comments_is_free_to_claim(self):
        verdict, detail = claim_issue.decide(issue(), NOW, "a@host", 21600)
        self.assertEqual("claim", verdict)

    def test_no_claim_marker_among_comments_is_free_to_claim(self):
        i = issue(comments=[{"body": "just a regular reply, no marker here"}])
        verdict, _ = claim_issue.decide(i, NOW, "a@host", 21600)
        self.assertEqual("claim", verdict)

    def test_live_claim_by_someone_else_blocks(self):
        i = issue(comments=[{"body": claim_body("other@host", NOW - timedelta(minutes=5))}])
        verdict, detail = claim_issue.decide(i, NOW, "me@host", 21600)
        self.assertEqual("blocked", verdict)
        self.assertIn("other@host", detail)

    def test_expired_claim_by_someone_else_may_be_claimed_over(self):
        stale = NOW - timedelta(hours=7)  # older than the 6h default ttl
        i = issue(comments=[{"body": claim_body("other@host", stale)}])
        verdict, detail = claim_issue.decide(i, NOW, "me@host", 21600)
        self.assertEqual("claim", verdict)
        self.assertIn("abandoned", detail)

    def test_claim_exactly_at_ttl_boundary_is_treated_as_expired(self):
        i = issue(comments=[{"body": claim_body("other@host", NOW - timedelta(seconds=21600))}])
        verdict, _ = claim_issue.decide(i, NOW, "me@host", 21600)
        self.assertEqual("claim", verdict, "age >= ttl must expire, not just age > ttl")

    def test_own_marker_reclaims_even_if_recent(self):
        i = issue(comments=[{"body": claim_body("me@host", NOW - timedelta(minutes=1))}])
        verdict, detail = claim_issue.decide(i, NOW, "me@host", 21600)
        self.assertEqual("claim", verdict)
        self.assertIn("already claimed by this marker", detail)

    def test_only_the_most_recent_claim_among_several_matters(self):
        i = issue(
            comments=[
                {"body": claim_body("first@host", NOW - timedelta(hours=5))},
                {"body": "unrelated reply in between"},
                {"body": claim_body("second@host", NOW - timedelta(minutes=1))},
            ]
        )
        verdict, detail = claim_issue.decide(i, NOW, "me@host", 21600)
        self.assertEqual("blocked", verdict)
        self.assertIn("second@host", detail)
        self.assertNotIn("first@host", detail)

    def test_closed_issue_is_not_claimable(self):
        verdict, detail = claim_issue.decide(issue(state="CLOSED"), NOW, "me@host", 21600)
        self.assertEqual("closed", verdict)
        self.assertIn("CLOSED", detail)

    def test_merged_pr_state_is_also_not_claimable(self):
        verdict, _ = claim_issue.decide(issue(state="MERGED"), NOW, "me@host", 21600)
        self.assertEqual("closed", verdict)


class MainTest(unittest.TestCase):
    def run_main(self, argv, fetched=None, fetch_raises=None, post_raises=None):
        posted = []

        def fake_fetch(repo, number):
            if fetch_raises:
                raise fetch_raises
            return fetched

        def fake_post(repo, number, comment):
            if post_raises:
                raise post_raises
            posted.append((repo, number, comment))

        buf = io.StringIO()
        with mock.patch.object(claim_issue, "fetch_issue", fake_fetch), \
                mock.patch.object(claim_issue, "post_claim", fake_post), \
                mock.patch.object(claim_issue, "datetime") as mock_dt, \
                redirect_stdout(buf):
            mock_dt.now.return_value = NOW
            mock_dt.strptime = datetime.strptime
            rc = claim_issue.main(["485", "--marker", "me@host"] + argv)
        return rc, buf.getvalue(), posted

    def test_unclaimed_issue_is_claimed_and_posted(self):
        rc, out, posted = self.run_main([], fetched=issue())
        self.assertEqual(claim_issue.RC_PASS, rc)
        self.assertEqual(1, len(posted))
        self.assertIn("claim-issue: marker=me@host", posted[0][2])
        self.assertIn("claimed by me@host", out)

    def test_dry_run_decides_but_posts_nothing(self):
        rc, out, posted = self.run_main(["--dry-run"], fetched=issue())
        self.assertEqual(claim_issue.RC_PASS, rc)
        self.assertEqual([], posted)
        self.assertIn("WOULD CLAIM", out)

    def test_blocked_by_live_claim_exits_fail_and_posts_nothing(self):
        held = issue(comments=[{"body": claim_body("other@host", NOW - timedelta(minutes=1))}])
        rc, out, posted = self.run_main([], fetched=held)
        self.assertEqual(claim_issue.RC_FAIL, rc)
        self.assertEqual([], posted)

    def test_closed_issue_exits_incomplete_and_posts_nothing(self):
        rc, out, posted = self.run_main([], fetched=issue(state="CLOSED"))
        self.assertEqual(claim_issue.RC_INCOMPLETE, rc)
        self.assertEqual([], posted)

    def test_fetch_failure_exits_incomplete(self):
        rc, _, posted = self.run_main([], fetch_raises=claim_issue.CannotLook("gh not found on PATH"))
        self.assertEqual(claim_issue.RC_INCOMPLETE, rc)
        self.assertEqual([], posted)

    def test_post_failure_exits_incomplete_not_pass(self):
        rc, _, _ = self.run_main([], fetched=issue(), post_raises=claim_issue.CannotLook("network"))
        self.assertEqual(claim_issue.RC_INCOMPLETE, rc)

    def test_marker_defaults_when_not_supplied(self):
        posted = []

        def fake_fetch(repo, number):
            return issue()

        def fake_post(repo, number, comment):
            posted.append(comment)

        with mock.patch.object(claim_issue, "fetch_issue", fake_fetch), \
                mock.patch.object(claim_issue, "post_claim", fake_post), \
                mock.patch.dict("os.environ", {"CLAIM_ISSUE_MARKER": "env@marker"}):
            rc = claim_issue.main(["485"])
        self.assertEqual(claim_issue.RC_PASS, rc)
        self.assertIn("marker=env@marker", posted[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
