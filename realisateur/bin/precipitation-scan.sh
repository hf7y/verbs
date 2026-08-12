#!/usr/bin/env bash
# precipitation-scan.sh -- offline-first PROMOTION-SIGNAL sense. One of
# realisateur's two surveys since 2026-08-07 -- this and hygiene-lint.sh;
# ecosystem-survey.sh, milestone-audit.sh and steward-survey.sh were retired
# as re-implementations of the same registry enumeration that nothing ran.
# Zero AI cost (plain bash/awk), same discipline as scheduler's
# docs/offline-first-checks.md. Run at the top of every /ideate and
# /nightly-batch pass.
#
# GUARD: which backlog items have re-arrived in the same shape, i.e. are ready to build?
# RUNNER: operator -- read at the top of an /ideate or /nightly-batch pass
# GUARD-TEST: none -- no suite; it ranks signals and asserts nothing, which is why it is a readout and not a gate
# GATE: default
# VERIFIED: 2026-08-07 via bash bin/precipitation-scan.sh
#
# WHY THIS EXISTS
# ---------------
# The retired ecosystem-survey.sh ranked the backlog OLDEST-FIRST -- one
# signal, and by UNIVERSE.md's own account the weakest of the three: "re-arrival in the same
# shape is a stronger 'ready to build' signal than age (oldest-first),
# enthusiasm (newest-first), or any self-report of certainty."
#
# This script senses the other two signals named in
# realisateur/PRECIPITATION.md:
#
#   RE-ARRIVAL  -- the SAME idea returning to the SAME project. Repetition is
#                  only a promotion signal when the shape is STABLE; an idea
#                  that returns in a different shape each time is still
#                  dissolving (the low-weight "bigger dream" case, /ideate
#                  4.6). This script cannot judge shape stability -- it
#                  surfaces the candidate pair/chain and the terms they share
#                  so a session can make that call in one glance.
#
#   CLUSTER     -- DIFFERENT ideas, across DIFFERENT projects, piling onto one
#                  interface. Per UNIVERSE.md's Ashby reading, that is the
#                  signature of an interface whose disturbance variety exceeds
#                  its regulator variety. The correct response to a cluster is
#                  NOT to promote its members -- it is to name the missing
#                  regulator they are all leaking around, as a new entry that
#                  subsumes them. (This is how the multi-writer FOCUS-file
#                  regulator was found by hand: three friction incidents, one
#                  unnamed cause.)
#
# Like every sibling survey: findings are SIGNALS, not verdicts. This script
# writes NOTHING and reorders NOTHING. A silent reorder is indistinguishable
# from forgetting the older item existed (/ideate 4.5) -- so promotion stays a
# stated human/session decision, stamped per PRECIPITATION.md.
#
# THE THREE REPORTS
#   A. Stamp ledger      -- confirmed, durable signals already written into
#                           the files as `(re-arrival: d1, d2)` / `[iface: x]`.
#                           High precision, zero inference. Read this first.
#   B. Re-arrival cands  -- inferred same-project repeats. Noisy by design.
#   C. Cluster cands     -- inferred cross-project interface pressure.
#
# Reports B and C are inference over prose; A is fact. As sessions confirm
# candidates and stamp them, signal migrates from B/C into A -- precision
# accretes on the entries that actually mattered, and nothing is demanded at
# intake time. That is the intended direction of travel.
set -uo pipefail

CLI_NAME='precipitation-scan.sh'
CLI_SUMMARY='find recurring terms clustering across projects'"'"' open FOCUS entries'
CLI_USAGE='  precipitation-scan.sh    all three reports. Configured by ENV, not flags:
    FOCUS_DIR=...     directory of per-project focus files
    MIN_SCORE / MIN_SHARED / UBIQUITY / MIN_TERMLEN   clustering thresholds
    HUBFRAC / MAX_CLUSTERS / INCLUDE_LOGS'
CLI_FLAGS=''
CLI_POSITIONAL=none
. "$(dirname "${BASH_SOURCE[0]}")/lib/cli-guard.sh"
cli_guard "$@"

SCHED_ROOT="${SCHED_ROOT:-${INSTALLE_PROJECTS:-$HOME/Documents/Projects}/scheduler}"
FOCUS_DIR="${FOCUS_DIR:-$SCHED_ROOT/focus}"   # overridable for fixture tests
# BLIND, not FATAL -- reworded 2026-08-07. The exit code was already right;
# the WORD was not, and the word is what a reader acts on. "FATAL" reads as
# "this tool is broken"; the true statement is "I could not look, so I am
# telling you nothing rather than telling you nothing is wrong". Found by
# bin/tests/guard-estate.test.sh check D, which requires a non-zero exit with
# no findings to say which of the three world-states it is in.
[ -d "$FOCUS_DIR" ] || { echo "precipitation-scan: BLIND: scheduler focus/ not found at $FOCUS_DIR" >&2; echo "precipitation-scan: this is 'I cannot see', NOT 'nothing to report'." >&2; exit 2; }

# Tunables -- printed below so any run is reproducible from its own output.
# Jaccard over informative terms: shared / (|A| + |B| - shared). Deliberately
# NOT shared/min(|A|,|B|) -- that scores a 5-term stub 0.8 against any long
# entry containing it, and the backlog is full of short stubs.
MIN_SCORE="${MIN_SCORE:-0.12}"
MIN_SHARED="${MIN_SHARED:-6}"    # absolute floor: kills small-vocabulary coincidences
UBIQUITY="${UBIQUITY:-0.25}"     # a term in >25% of entries carries no signal
MIN_TERMLEN="${MIN_TERMLEN:-5}"
# Only HUMAN-ORIGIN entries are promotion candidates by default: an inbox
# arrival (`via \`scheduler -i\``) or a human-directed session. The machine's
# own pass journal ("inbox empty, nothing to build", fable-review, queued-job
# stubs) repeats by construction -- scoring it drowns report B in the
# system logging its own heartbeat. Set INCLUDE_LOGS=1 to score everything.
INCLUDE_LOGS="${INCLUDE_LOGS:-0}"
# An omnibus session entry (a long, multi-topic /ideate record) is adjacent to
# a large fraction of the corpus because it touches everything -- it is a HUB,
# not a cluster member, and left in it joins every cluster to every other.
# Same information-theoretic move as the ubiquity cutoff, one level up.
# 0.10 tuned against the 2026-07-26 corpus (212 entries): generic
# infra-vocabulary clusters ("daily setup install reachable") drop out, the
# real multi-writer FOCUS-file cluster survives. 0.08 is the sharpest/
# strictest setting; 0.20 lets the omnibus session records back in.
HUBFRAC="${HUBFRAC:-0.10}"
MAX_CLUSTERS="${MAX_CLUSTERS:-6}"

echo "precipitation-scan -- $(date '+%Y-%m-%d %H:%M')"
echo "(offline-first: no claude calls -- findings are SIGNALS, not verdicts."
echo " Doctrine: realisateur/PRECIPITATION.md. Promotion is always STATED.)"
echo "(tunables: MIN_SCORE=$MIN_SCORE MIN_SHARED=$MIN_SHARED UBIQUITY=$UBIQUITY MIN_TERMLEN=$MIN_TERMLEN)"

# ---------------------------------------------------------------- report A
echo
echo "############################################################"
echo "== A. STAMP LEDGER (confirmed signals, no inference) =="
echo "(written by prior sessions per PRECIPITATION.md; these are FACTS about"
echo " what was already judged, not guesses. Promote from here first.)"
echo

# Counted up front, NOT inside the loop below: that loop is piped into
# `sort`, so it runs in a subshell and any counter it increments is lost.
stamps="$(grep -ho '(re-arrival:[^)]*)' "$FOCUS_DIR"/*.md | wc -l)"

for f in "$FOCUS_DIR"/*.md; do
  proj="$(basename "$f" .md)"
  # `(re-arrival: 2026-07-20, 2026-07-25, ...)` -- count the dates.
  while IFS= read -r line; do
    n="$(printf '%s' "$line" | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' | wc -l)"
    printf 're-arrival x%-2s  %-18s %s\n' "$n" "$proj" "$(printf '%s' "$line" | cut -c1-90)"
  done < <(grep -o '(re-arrival:[^)]*)' "$f" || true)
done | sort -t x -k2 -rn

for f in "$FOCUS_DIR"/*.md; do
  proj="$(basename "$f" .md)"
  grep -o '\[iface:[^]]*\]' "$f" | sed "s|^|$proj |" || true
done | sort | uniq -c | sort -rn | awk '
  NR == 1 { print ""; print "-- interface tags (cluster membership, accreted) --" }
  { printf "  %2s  %s\n", $1, substr($0, index($0, $2)) }'

[ "$stamps" -eq 0 ] && echo "(no re-arrival stamps yet -- expected until sessions start stamping;"
[ "$stamps" -eq 0 ] && echo " until then report B is the only re-arrival signal, and it is inference.)"

# ------------------------------------------------------------- reports B/C
# One awk pass: parse dated entries (header + body), tokenize, drop ubiquitous
# terms via document frequency, score every pair, union-find the survivors
# into components, print same-project components as B and cross-project as C.
awk -v min_score="$MIN_SCORE" -v min_shared="$MIN_SHARED" \
    -v ubiquity="$UBIQUITY" -v min_termlen="$MIN_TERMLEN" \
    -v include_logs="$INCLUDE_LOGS" -v hubfrac="$HUBFRAC" -v max_clusters="$MAX_CLUSTERS" '
  function flush(   t, i, w, seen) {
    if (!pending) return
    n++
    eproj[n] = cur_proj; edate[n] = cur_date; ehead[n] = cur_head
    # normalized headline -- identical across projects means a BROADCAST
    # cross-write (one decision copied to every focus file), not a cluster.
    t = tolower(cur_head); gsub(/[^a-z0-9 ]/, " ", t); gsub(/  +/, " ", t)
    ebcast[n] = substr(t, 1, 60)
    # origin: what KIND of writer produced this entry
    if (t ~ /via scheduler i/)                       eorig[n] = "INBOX"
    else if (t ~ /human direction|human directed|zach directed|interactive/) eorig[n] = "HUMAN"
    else                                             eorig[n] = "LOG"
    t = tolower(cur_text)
    gsub(/[^a-z]/, " ", t)
    split(t, w, " ")
    delete seen
    for (i in w) {
      if (length(w[i]) < min_termlen) continue
      if (w[i] in seen) continue
      seen[w[i]] = 1
      terms[n, w[i]] = 1
      tlist[n] = tlist[n] " " w[i]
      df[w[i]]++
    }
    pending = 0; started = 0; cur_text = ""
  }
  FNR == 1 { flush(); nf++; fproj = FILENAME; sub(/.*\//, "", fproj); sub(/\.md$/, "", fproj) }
  /^[ \t]*[-*]?[ \t]*\*\*[0-9]{4}-[0-9]{2}-[0-9]{2}/ {
    flush()
    pending = 1; started = 1; cur_proj = fproj
    match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2}/)
    cur_date = substr($0, RSTART, RLENGTH)
    cur_head = $0
    sub(/^[ \t]*[-*]?[ \t]*/, "", cur_head)
    gsub(/\*\*/, "", cur_head)
    if (length(cur_head) > 96) cur_head = substr(cur_head, 1, 96) "..."
    cur_text = $0
    next
  }
  # An entry body ends at the next dated header OR at trailing non-entry
  # content -- an injected HTML-comment footer (inject-suggestions.sh appends
  # one to every focus file) or a new `## ` section. Without this the LAST
  # entry in each file absorbs that footer, and every file`s last entry then
  # shares its vocabulary: on 2026-07-26 that manufactured a 5-project
  # "cluster" whose members were a tmux title tweak and a ROADMAP migration.
  # stop ACCUMULATING here, but keep `pending` set so the entry itself is
  # still recorded -- clearing `pending` too would silently DROP every
  # footer-terminated entry (30 of 212 on first attempt).
  /^[ \t]*<!--/ || /^## / { started = 0 }
  started { cur_text = cur_text " " $0 }
  END {
    flush()
    if (n < 2) { print "\n(fewer than 2 dated entries found -- nothing to score)"; exit }

    # Informative terms only: a term in more than `ubiquity` of all entries
    # (scheduler, project, milestone, focus, ...) is ecosystem background.
    # Derived from the corpus, never hand-listed, so it self-tunes as the
    # ecosystems vocabulary drifts.
    cutoff = ubiquity * n

    for (i = 1; i <= n; i++) {
      split(tlist[i], w, " ")
      cnt = 0
      for (k in w) if (w[k] != "" && df[w[k]] <= cutoff && !(w[k] in kept_seen_i)) {
        kept[i, w[k]] = 1; klist[i] = klist[i] " " w[k]; cnt++
      }
      ksize[i] = cnt
      delete kept_seen_i
      parent[i] = i
    }

    for (i = 1; i <= n; i++) {
      if (!include_logs && eorig[i] == "LOG") continue
      for (j = i + 1; j <= n; j++) {
        if (!include_logs && eorig[j] == "LOG") continue
        if (ksize[i] == 0 || ksize[j] == 0) continue
        if (ebcast[i] == ebcast[j] && eproj[i] != eproj[j]) { bcast++; continue }
        shared = 0; sterms = ""
        split(klist[i], w, " ")
        for (k in w) if (w[k] != "" && ((j SUBSEP w[k]) in kept)) {
          shared++; sterms = sterms " " w[k]
        }
        if (shared < min_shared) continue
        score = shared / (ksize[i] + ksize[j] - shared)     # Jaccard
        if (score < min_score) continue
        # Adjacency only -- NO transitive closure. A~B and B~C does not make
        # A~C; chaining these edges collapsed 205 of 211 entries into one
        # "cluster" on the first run. Components are built as stars around a
        # seed below, where every member is adjacent to the seed itself.
        pn++; pa[pn] = i; pb[pn] = j; ps[pn] = score
        deg[i]++; deg[j]++
        adj[i] = adj[i] " " j; adj[j] = adj[j] " " i
      }
    }
    report()
  }

  function report(   i, j, k, m, w, o, best, bs, seen, stars, sn) {
    printf "\n############################################################\n"
    printf "== B. RE-ARRIVAL CANDIDATES (same project, same shape?) ==\n"
    printf "(INFERRED. The same idea returning to the same organ. Repetition\n"
    printf " alone is NOT the signal -- shape stability is. Read each pair and\n"
    printf " judge: same shape -> promotion trigger, stronger than age.\n"
    printf " Drifting shape -> still dissolving, LOWER the weight instead.)\n"
    emitted = 0
    # same-project pairs, strongest first
    for (o = 1; o <= pn; o++) rank[o] = o
    for (o = 1; o <= pn; o++) for (k = o + 1; k <= pn; k++)
      if (ps[rank[k]] > ps[rank[o]]) { t = rank[o]; rank[o] = rank[k]; rank[k] = t }
    for (o = 1; o <= pn; o++) {
      i = pa[rank[o]]; j = pb[rank[o]]
      if (eproj[i] != eproj[j]) continue
      if (edate[i] == edate[j]) continue      # same-day split entries are one arrival
      emitted++
      if (emitted > 12) { extra++; continue }
      printf "\n  [%.2f] %s\n", ps[rank[o]], eproj[i]
      printf "    %-5s %s  %s\n", eorig[i], edate[i], ehead[i]
      printf "    %-5s %s  %s\n", eorig[j], edate[j], ehead[j]
      printf "    shared: %s\n", shared_terms(" " i " " j)
      printf "    -> if same shape: stamp `(re-arrival: %s, %s)` and promote, stating what it passed over.\n", edate[i], edate[j]
    }
    if (extra) printf "\n  (... %d more pair(s) below the top 12; raise MIN_SCORE to narrow)\n", extra
    if (!emitted) printf "\n  (none above threshold)\n"

    printf "\n############################################################\n"
    printf "== C. INTERFACE-CLUSTER CANDIDATES (different ideas, one interface) ==\n"
    printf "(INFERRED. Distinct asks across DIFFERENT projects converging on one\n"
    printf " place. Per UNIVERSE.md/Ashby: a cluster marks an interface whose\n"
    printf " disturbance variety exceeds its regulator variety. Do NOT promote\n"
    printf " the members -- NAME THE MISSING REGULATOR they are leaking around,\n"
    printf " file it as one entry, and tag the members `[iface: <name>]` so the\n"
    printf " cluster becomes a fact in report A instead of a re-inference.)\n"
    emitted = 0
    # Stars: seed + every neighbour ADJACENT TO THE SEED (no chaining). A star
    # counts as an interface cluster only if its members span >= 3 projects --
    # two projects is a coincidence or a cross-write, three is pressure.
    ns = 0
    for (i = 1; i <= n; i++) if (include_logs || eorig[i] != "LOG") ns++
    hubmax = hubfrac * ns
    nhub = 0
    for (i = 1; i <= n; i++) if (deg[i] > hubmax) { ishub[i] = 1; nhub++ }

    for (i = 1; i <= n; i++) {
      if (deg[i] < 2 || ishub[i]) continue
      grp = " " i; delete pseen; pseen[eproj[i]] = 1; np = 1
      split(adj[i], w, " ")
      for (k in w) if (w[k] != "" && !ishub[w[k]] && eproj[w[k]] != eproj[i]) {
        grp = grp " " w[k]
        if (!(eproj[w[k]] in pseen)) { pseen[eproj[w[k]]] = 1; np++ }
      }
      if (np < 3) continue
      key = canon(grp)
      if (key in starseen) continue
      starseen[key] = 1
      sn++; stargrp[sn] = grp; starnp[sn] = np; starsz[sn] = nmemb(grp); starkey[sn] = key
    }
    # biggest first, then drop any star whose members are a subset of one
    # already emitted -- overlapping seeds otherwise print the same cluster
    # once per member.
    for (o = 1; o <= sn; o++) for (k = o + 1; k <= sn; k++)
      if (starsz[k] > starsz[o]) {
        t = stargrp[o]; stargrp[o] = stargrp[k]; stargrp[k] = t
        t = starnp[o]; starnp[o] = starnp[k]; starnp[k] = t
        t = starsz[o]; starsz[o] = starsz[k]; starsz[k] = t
        t = starkey[o]; starkey[o] = starkey[k]; starkey[k] = t
      }
    for (o = 1; o <= sn; o++) {
      if (emitted >= max_clusters) { csupp++; continue }
      if (subsumed(starkey[o], o)) { csupp++; continue }
      kept_star[++nkept] = starkey[o]
      printf "\n  [%d entries across %d projects] %s\n", starsz[o], starnp[o], projs_of(stargrp[o])
      split(stargrp[o], m, " ")
      for (i in m) if (m[i] != "") printf "    %-5s %-16s %s  %s\n", eorig[m[i]], eproj[m[i]], edate[m[i]], ehead[m[i]]
      printf "    shared: %s\n", shared_terms(stargrp[o])
      printf "    -> what regulator is missing at this interface? (not: who slipped)\n"
      emitted++
    }
    if (!emitted) printf "\n  (none above threshold)\n"
    if (csupp) printf "\n  (%d further star(s) suppressed as subsets of the above, or past MAX_CLUSTERS=%d)\n", csupp, max_clusters
    if (nhub) {
      printf "\n  -- %d omnibus entr(ies) excluded as HUBS (adjacent to >%.0f%% of the\n", nhub, hubfrac * 100
      printf "     corpus; multi-topic session records that would join every cluster\n"
      printf "     to every other). Raise HUBFRAC to let them back in: --\n"
      for (i = 1; i <= n; i++) if (ishub[i]) printf "     %-16s %s  %s\n", eproj[i], edate[i], substr(ehead[i], 1, 74)
    }
    if (bcast) printf "\n(%d pair(s) suppressed as broadcast cross-writes -- identical headline\n replicated across projects is one decision copied, not a cluster.)\n", bcast
    printf "\nscanned %d dated entries across %d project files.\n", n, nfiles()
  }

  # terms held by at least half a components members, rarest first, top 8.
  function shared_terms(members,   m, i, w, k, c, out, o, best, bt, used) {
    split(members, m, " ")
    tot = 0
    for (i in m) if (m[i] != "") { tot++; split(klist[m[i]], w, " ")
      for (k in w) if (w[k] != "") { if (!((m[i] SUBSEP w[k]) in counted)) { counted[m[i], w[k]] = 1; c[w[k]]++ } } }
    for (o = 0; o < 8; o++) {
      best = ""; bt = 999999
      for (k in c) if (c[k] >= (tot + 1) / 2 && !(k in used) && df[k] < bt) { best = k; bt = df[k] }
      if (best == "") break
      used[best] = 1; out = out " " best
    }
    delete c; delete used; delete counted
    return (out == "" ? "(none in common to half the members)" : out)
  }
  # true if every member of `key` already appears in some kept star
  function subsumed(key, upto,   m, i, k, q, hit) {
    split(key, m, ",")
    for (q = 1; q <= nkept; q++) {
      hit = 1
      for (i in m) if (m[i] != "" && index(kept_star[q], "," m[i] ",") == 0) { hit = 0; break }
      if (hit) return 1
    }
    return 0
  }
  function canon(members,   m, i, a, c, o, out) {   # sorted member key, for dedupe
    c = split(members, m, " "); o = 0
    for (i = 1; i <= c; i++) if (m[i] != "") a[++o] = m[i] + 0
    for (i = 1; i <= o; i++) for (j = i + 1; j <= o; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
    for (i = 1; i <= o; i++) out = out "," a[i]
    return out ","          # trailing delimiter: every member matches ",N,"
  }
  function nmemb(members,   m, i, c, o) {
    c = split(members, m, " "); o = 0
    for (i = 1; i <= c; i++) if (m[i] != "") o++
    return o
  }
  function dates_of(members,   m, i, out) {
    split(members, m, " "); for (i in m) if (m[i] != "") out = out (out == "" ? "" : ", ") edate[m[i]]
    return out
  }
  function projs_of(members,   m, i, out, seen) {
    split(members, m, " ")
    for (i in m) if (m[i] != "" && !(eproj[m[i]] in seen)) { seen[eproj[m[i]]] = 1; out = out (out == "" ? "" : ", ") eproj[m[i]] }
    return out
  }
  function nfiles() { return nf }
' "$FOCUS_DIR"/*.md

echo
echo "(All of B and C is INFERENCE over prose -- treat as candidates to read,"
echo " never as a verdict. Confirming one means WRITING it down: a"
echo " \`(re-arrival: <dates>)\` stamp or an \`[iface: <name>]\` tag, plus the"
echo " stated promotion (what got passed over, and why) in the project's own"
echo " FOCUS.md. Unstamped, the same candidate is re-inferred from scratch"
echo " next run and the judgment is lost -- see PRECIPITATION.md.)"
