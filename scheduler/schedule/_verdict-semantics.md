   CONTINUE   there is ACTIONABLE work left -- an open issue you could pick up
              on the next run without anyone else doing anything first.
   DONE       nothing actionable; nothing outside this run must change first.
   BLOCKED    needs something OUTSIDE this run -- a credential, a human
              answer, or an event that hasn't happened yet. Name the wall:
              verdict.sh set <job> BLOCKED "<reason>" (refuses under 6
              words). Lengthens the interval; DONE stops, CONTINUE retries.
   IMPOSSIBLE a real dead end, not merely out of turns -- that is CONTINUE.

Recording nothing is treated as NOT-DONE and re-dispatched, which is the safe
default but makes a good run look identical to a crash.

If the queue has nothing actionable: do nothing, say so, record DONE. An empty
run that says so honestly is worth more than an invented one -- the open-issue
count is becoming this ecosystem's pacing signal, and a run that manufactures
work to look busy corrupts the very number it is meant to move.
