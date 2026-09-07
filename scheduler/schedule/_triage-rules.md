2. TRIAGE IS NOT FIFO. Zach, 2026-08-06: "first in ideas may be obviated
   before they can be realized." Do NOT just take the oldest. Before picking,
   read the open titles and ask of each: does its premise still hold? An issue
   whose premise expired should be CLOSED, saying which decision or commit
   expired it -- that is real work, it is cheap, and it is the only thing that
   makes the count mean anything. Closing three dead issues beats half-building
   a fourth.

3. CLOSE WHAT YOU RESOLVE. Zach, standing instruction: "agents should close
   issues that are clearly resolved. not leave them to zach. he won't and
   they'll clutter." If your work resolves an issue, close it with a comment
   saying what landed and where (commit sha, PR, or file). Do not leave it for
   him to confirm. If you are NOT sure, say so on the issue and leave it open
   -- that is a different, also-correct outcome.

   Note how Zach answers (corrected 2026-08-14; the previous text here said
   the opposite): he comments and LEAVES THE ISSUE OPEN. He applies no
   `answered` label and does not want to. Issue STATE and LABELS carry NO
   information about whether he answered -- read the COMMENTS. An open
   question issue is not evidence it is unanswered; an issue is ANSWERED if
   it carries a comment from the repo owner that is not agent-stamped.

4. ONE issue per run. A half-finished second one is worse than a queue that
   moves slowly. Work on a BRANCH and open a PR; never push main. Commit
   atomically -- never 'git add -A' -- and leave the tree clean: a dirty tree
   at exit is a failed run, not a handoff.

5. Re-probe before you believe. Any headline QUANTITY in an issue -- a count, a
   size, an 'N of M' -- was true when written and may not be now. Re-derive it
   with a command before acting on it, and if you write it down, stamp it
   '# verified <date> via <command>'. Several confident surveys in this estate
   have been loudly wrong in exactly this way.

6. ADOPTED (hf7y/scheduler#150, 2026-08-14): once you have closed every issue
   whose premise expired (step 2), `bin/next-issue.sh <this repo>` suggests
   what to pick up next -- oldest open issue first, skipping any issue that
   names a still-open "Depends on #N" / "Blocked by #N" in its own body. It
   remains a suggestion, not a claim lock: nothing it prints is binding, and
   picking something else is still your call to make -- that was true before
   adoption and stays true after. "Adopted" means the estate treats it as
   the standard first move instead of an unargued draft, not that it
   overrides judgement. Read the script's own header before trusting it --
   it explains why body length and provenance labels were tried and rejected
   as ranking signals.
