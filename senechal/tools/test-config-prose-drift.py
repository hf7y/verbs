#!/usr/bin/env python3
"""Suite for tools/config-prose-drift.py. Fixtures only; never the real files."""
import importlib.util
import json
import os
import tempfile
import unittest

_spec = importlib.util.spec_from_file_location(
    "cpd", os.path.join(os.path.dirname(os.path.abspath(__file__)), "config-prose-drift.py"))
cpd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cpd)


class ProseDriftTest(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.tmp = self._td.name

    def tearDown(self):
        self._td.cleanup()

    def run_main(self, live, example):
        """An EMPTY baseline, explicitly. Omitting --baseline picks up the
        repo's real 17-entry file and every fixture below then reports
        against senechal's actual drift -- which it did, failing 7 cases for
        reasons that had nothing to do with what they test."""
        a, b = os.path.join(self.tmp, "live.json"), os.path.join(self.tmp, "ex.json")
        for p, o in ((a, live), (b, example)):
            with open(p, "w") as fh:
                json.dump(o, fh)
        return cpd.main(["--config", a, "--example", b,
                         "--baseline", os.path.join(self.tmp, "none")])

    # --- what counts as drift ------------------------------------------
    def test_identical_prose_passes(self):
        d = {"health": {"why": "because", "disk_warn_pct": 85}}
        self.assertEqual(cpd.RC_PASS, self.run_main(d, json.loads(json.dumps(d))))

    def test_a_diverged_why_is_drift(self):
        self.assertEqual(cpd.RC_FAIL, self.run_main(
            {"h": {"why": "current reason"}}, {"h": {"why": "stale reason"}}))

    def test_a_diverged_underscore_comment_is_drift(self):
        self.assertEqual(cpd.RC_FAIL, self.run_main(
            {"_comment": "new"}, {"_comment": "old"}))

    # --- what is deliberately NOT drift ---------------------------------
    def test_a_differing_VALUE_is_never_drift(self):
        """The whole point of an example config: real host, placeholder host."""
        self.assertEqual(cpd.RC_PASS, self.run_main(
            {"estate": {"host": "mandark.real", "why": "same"}},
            {"estate": {"host": "example.invalid", "why": "same"}}))

    def test_a_field_the_example_omits_is_not_drift(self):
        """An example may carry fewer entries; absence is not disagreement."""
        self.assertEqual(cpd.RC_PASS, self.run_main(
            {"a": {"why": "explained"}, "b": {"why": "only live"}},
            {"a": {"why": "explained"}}))

    def test_reordered_inventory_is_not_drift(self):
        """Items align by id, so reordering an inventory changes nothing."""
        one = {"id": "x", "why": "ex"}
        two = {"id": "y", "why": "wye"}
        self.assertEqual(cpd.RC_PASS, self.run_main(
            {"items": [one, two]}, {"items": [two, one]}))

    def test_drift_inside_a_reordered_inventory_is_still_found(self):
        self.assertEqual(cpd.RC_FAIL, self.run_main(
            {"items": [{"id": "x", "why": "new"}, {"id": "y", "why": "same"}]},
            {"items": [{"id": "y", "why": "same"}, {"id": "x", "why": "old"}]}))

    def test_it_names_the_path_including_the_item_id(self):
        out = cpd.drift({"items": [{"id": "project-checkouts", "retire": "a"}]},
                        {"items": [{"id": "project-checkouts", "retire": "b"}]})
        self.assertEqual(["items[project-checkouts].retire"], out)

    # --- the baseline ratchet -------------------------------------------
    def run_with_baseline(self, live, example, entries):
        a, b = os.path.join(self.tmp, "l.json"), os.path.join(self.tmp, "e.json")
        base = os.path.join(self.tmp, "base")
        for p, o in ((a, live), (b, example)):
            with open(p, "w") as fh:
                json.dump(o, fh)
        with open(base, "w") as fh:
            fh.write("# a comment line is not an entry\n" + "\n".join(entries) + "\n")
        return cpd.main(["--config", a, "--example", b, "--baseline", base])

    def test_known_drift_in_the_baseline_passes(self):
        self.assertEqual(cpd.RC_PASS, self.run_with_baseline(
            {"h": {"why": "a"}}, {"h": {"why": "b"}}, ["h.why"]))

    def test_drift_NOT_in_the_baseline_FAILS(self):
        """New drift is a failure, not a nag: it just happened, so someone
        knows which copy is right."""
        self.assertEqual(cpd.RC_FAIL, self.run_with_baseline(
            {"h": {"why": "a"}, "i": {"why": "c"}},
            {"h": {"why": "b"}, "i": {"why": "d"}}, ["h.why"]))

    def test_a_baseline_entry_that_stopped_diverging_is_a_WARN(self):
        """Reconciled but still listed: the debt can be re-borrowed silently."""
        self.assertEqual(cpd.RC_WARN, self.run_with_baseline(
            {"h": {"why": "same"}}, {"h": {"why": "same"}}, ["h.why"]))

    def test_a_baseline_entry_whose_field_is_absent_from_live_is_not_healed(self):
        """A sparse live config that simply lacks the field is not the same
        as the two copies agreeing -- reporting it as healed would tell a
        reviewer to drop it from the baseline, and the next host with a
        fuller config that still genuinely diverges would then FAIL on
        drift nobody re-reviewed."""
        self.assertEqual(cpd.RC_PASS, self.run_with_baseline(
            {}, {"h": {"why": "explained"}}, ["h.why"]))

    def test_a_baseline_entry_absent_from_the_example_is_not_healed(self):
        self.assertEqual(cpd.RC_PASS, self.run_with_baseline(
            {"h": {"why": "explained"}}, {}, ["h.why"]))

    # --- could-not-look is never a pass ---------------------------------
    def test_a_missing_example_exits_incomplete(self):
        a = os.path.join(self.tmp, "live.json")
        with open(a, "w") as fh:
            json.dump({}, fh)
        self.assertEqual(cpd.RC_INCOMPLETE,
                         cpd.main(["--config", a, "--example", a + ".nope",
                                   "--baseline", os.path.join(self.tmp, "none")]))

    def test_an_unparseable_config_exits_incomplete(self):
        a, b = os.path.join(self.tmp, "l.json"), os.path.join(self.tmp, "e.json")
        with open(a, "w") as fh:
            fh.write("{nope")
        with open(b, "w") as fh:
            json.dump({}, fh)
        self.assertEqual(cpd.RC_INCOMPLETE, cpd.main(
            ["--config", a, "--example", b, "--baseline", os.path.join(self.tmp, "none")]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
