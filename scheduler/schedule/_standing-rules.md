STANDING RULES (2026-08-07, Zach-directed). These override everything below.

0. MECHANISM FIRST. Talking is not dev. If you can fix it, fix it in THIS
   run. Describing a problem you could have fixed is a FAILED run, not a
   report. Witness from the 06:00Z tick tonight: a run diagnosed a stale
   origin/HEAD cache in its own clone, fixed it correctly, wrote forty
   lines about it, left the issue open, and reported NOT-DONE. The
   diagnosis was right and the fix was right. Stopping there was the
   failure.

1. CLOSE WHAT YOU RESOLVED, in the same run -- left open, it's work nobody
   can see. Checkable: `$SCHED_ROOT/bin/close-audit.sh <owner/repo>` flags it (#522).

2. IF YOU ARE BLOCKED, name what you TRIED and the EXACT wall -- the
   command you ran, the error it returned, the permission you lack. A note
   saying this needs a decision, with no attempt named, is deferral, not a
   blocker, and it lands on Zach for no reason. Enforced, not just asked
   for: `$SCHED_ROOT/bin/verdict.sh set <job> BLOCKED` refuses a reason with no attempt
   named (#522).

3. LAND YOUR WORK. Commits on a branch nobody merges are not delivered.
   Open a PR against main and merge it when checks pass. Before pushing,
   check git symbolic-ref refs/remotes/origin/HEAD -- a wrong cached value
   stranded work on two clones. Checkable: `$SCHED_ROOT/bin/unlanded-work-check.sh` (#522).

4. NO NEW MARKDOWN FILES. Do not write a handoff, session record, design
   note, sprint summary, or retrospective. Prose is not a deliverable.
   Findings go in the issue they belong to, and then you close it.

5. WORK THAT BELONGS TO ANOTHER REPO GOES THERE AS A DRAFT PR, NOT AS A NOTE
   -- check first: that repo is one you do not watch. Checkable:
   `$SCHED_ROOT/bin/cross-repo-dupe-check.sh <owner/repo> <term>`. Otherwise, clone it,
   open a DRAFT PR there carrying the diff, and open an issue asking its
   self-dev to validate, ready and merge it. Filing an issue that only
   DESCRIBES the fix is rule 0 across a repo boundary.

   Mark it draft and leave it draft. A draft claims nothing, so you are not
   asserting done on behalf of a project you do not own -- and you must not
   merge another project's PR yourself. Their self-dev readies it.

   Filing an issue is a front door and needs no busy check. Writing
   directly into another project's files needs `check-project-busy
   <project>` first; defer on BUSY and say what you deferred.

6. WORK THE MILESTONE FIRST. `gh issue list` returns no milestone column and
   sorts by most recently updated, so an issue filed this morning looks
   identical to the generation every other project is waiting on. What is in
   each open milestone of your repo, computed at dispatch:

@@MILESTONE-QUEUE@@

   Take from a milestone while anything in it is actionable, and name the
   milestone you worked in your report.
