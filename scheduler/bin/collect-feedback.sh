#!/usr/bin/env bash
# collect-feedback.sh <file> [--section "## Heading"] [--consume]
#                     <file> --list-consumed
#
# Collect `%TAG` reply lines out of <file>. Exit 0 with output on stdout if
# any were found; exit 1 with NO output if the file has none, does not exist,
# or (with --section) has none under that heading -- a caller should read
# non-zero as "nothing to say", not as an error.
#
#   --section TEXT    only tags anchored under a heading matching TEXT
#   --consume         MARK the matched entries in this account's ledger
#   --list-consumed   print this account's ledger rows for <file>
#
# TRAP: --consume MARKS, it does not DELETE (changed 2026-07-28). It used to
#   rewrite <file> in place, which dirtied the working tree -- and
#   usage-paced-runner.sh gates its pull-before-dispatch on `git status
#   --porcelain --untracked-files=no`, so the job blocked its own dispatcher.
#   Marking in a ledger is what makes it idempotent.
# TRAP: stripping the `> ` marker as a side effect made an entry invisible to
#   every future --consume -- nothing left to collect. Do not reintroduce it.
# TRAP: a tag in a DIFFERENT section (filtered out by --section) must stay
#   collectable by the pass that owns that section.
#
# The full account is in vault:scheduler/three-headers-20260826.md.
set -uo pipefail

FILE=""
SECTION=""
CONSUME=0
LIST_CONSUMED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --section) SECTION="${2:-}"; shift 2 ;;
    --consume) CONSUME=1; shift ;;
    --list-consumed) LIST_CONSUMED=1; shift ;;
    *) FILE="$1"; shift ;;
  esac
done

[ -n "$FILE" ] || { echo "usage: collect-feedback.sh <file> [--section TEXT] [--consume] | <file> --list-consumed" >&2; exit 2; }

# ONE definition of where this account's consumption state lives -- the
# per-call receipt log and the per-entry ledger share a directory and a single
# override, so there is no second place to retype the path.
RECEIPT_DIR="${SCHEDULER_RECEIPT_DIR:-$HOME/.local/share/scheduler-glance}"
LEDGER="$RECEIPT_DIR/consumed-entries.tsv"

# The ledger is keyed on an ABSOLUTE path: callers reach the same file by
# several spellings (lib/../BLOCKERS.md from the engine, ./BLOCKERS.md by
# hand), and an unnormalised key would record them as different entries and
# hand the same feedback over twice.
FILE_ABS="$(readlink -f "$FILE" 2>/dev/null || true)"
[ -n "$FILE_ABS" ] || FILE_ABS="$FILE"

if [ "$LIST_CONSUMED" = "1" ]; then
  [ -f "$LEDGER" ] || exit 1
  OUT="$(awk -F'\t' -v f="$FILE_ABS" '
    $2 == f { printf "%s  [%s under %s] %s\n", $1, $5, ($3 == "" ? "(no section)" : $3), $6 }
  ' "$LEDGER")"
  [ -n "$OUT" ] || exit 1
  printf '%s\n' "$OUT"
  exit 0
fi

[ -f "$FILE" ] || exit 1

norm() { printf '%s' "$1" | sed -E 's/^[ \t]*#+[ \t]*//; s/[ \t]+$//' | tr '[:upper:]' '[:lower:]'; }

SECTION_NORM=""
[ -n "$SECTION" ] && SECTION_NORM="$(norm "$SECTION")"

# Keys of entries consumed by THIS call, collected by awk and appended to the
# ledger below. Written by awk rather than parsed back out of $OUT: the printed
# block is for a human/agent to read and its shape is free to change, while the
# key must stay byte-stable or an entry silently un-consumes itself.
KEYS_FILE=""
if [ "$CONSUME" = "1" ]; then
  KEYS_FILE="$(mktemp)"
fi

OUT="$(awk -v section_filter="$SECTION_NORM" -v consume="$CONSUME" \
           -v ledger="$LEDGER" -v keys_file="${KEYS_FILE:-}" -v file_key="$FILE_ABS" '
  function norm(s,   t) {
    t = s
    sub(/^[ \t]*#+[ \t]*/, "", t)
    gsub(/[ \t]+$/, "", t)
    return tolower(t)
  }
  # The ledger key. Section AND anchor are both in it on purpose: a short
  # reply ("> yes") can legitimately appear twice under one heading, and a key
  # that could not tell those apart would silently swallow the second one.
  # Feedback lost is a worse failure than feedback offered twice, so the key
  # errs narrow -- editing the line above a consumed reply re-collects it,
  # which is visible and harmless.
  function mkkey(h, a, kind, text,   th, ta, tt) {
    th = h; ta = a; tt = text
    gsub(/\t/, " ", th); gsub(/\t/, " ", ta); gsub(/\t/, " ", tt)
    return file_key "\t" th "\t" ta "\t" kind "\t" tt
  }
  # Should this entry be collected now? Only if no run has been handed it
  # before. Marked as consumed only when --consume: a plain read must not
  # change what the next read sees.
  function claim(k) {
    if (k in seen) return 0
    if (consume) { seen[k] = 1; print k > keys_file }
    return 1
  }
  # Migration: record a legacy in-file `>>` marker in the ledger, so the
  # record survives the tracked file being restored/reverted/re-cloned.
  function seed(k) {
    if (!consume) return
    if (k in seen) return
    seen[k] = 1
    print k > keys_file
  }
  function flush_reply(   k) {
    if (in_reply) {
      if (reply_matched) {
        k = mkkey(reply_heading_norm, reply_anchor, "REPLY", reply_text)
        if (claim(k)) {
          print "### REPLY"
          if (reply_heading != "") print "Section: " reply_heading
          if (reply_anchor != "") print "Re: \"" reply_anchor "\""
          print reply_text
          print ""
        }
      }
      in_reply = 0
      reply_text = ""
    }
  }
  function flush_consumed(   k) {
    if (in_consumed) {
      if (consumed_text != "") {
        k = mkkey(consumed_heading_norm, consumed_anchor, "REPLY", consumed_text)
        seed(k)
      }
      in_consumed = 0
      consumed_text = ""
    }
  }
  BEGIN {
    heading = ""; heading_norm = ""; anchor = ""
    in_reply = 0; reply_text = ""
    in_consumed = 0; consumed_text = ""
    if (ledger != "") {
      while ((getline lline < ledger) > 0) {
        lp = index(lline, "\t")
        if (lp > 0) seen[substr(lline, lp + 1)] = 1
      }
      close(ledger)
    }
  }
  /^#+[ \t]/ {
    flush_reply(); flush_consumed()
    heading = $0
    heading_norm = norm($0)
    anchor = ""
    next
  }
  /^%%(ACTION|BLOCKER|QUESTION|NOTE|APPROVE|REJECT)([ \t]|$)/ {
    flush_reply(); flush_consumed()
    matched = (section_filter == "" || heading_norm == section_filter)
    if (matched) {
      tagline = $0
      sub(/^%%/, "", tagline)
      split(tagline, parts, /[ \t]+/)
      kw = parts[1]
      text = tagline
      sub("^" kw "[ \t]*", "", text)
      if (claim(mkkey(heading_norm, anchor, kw, text))) {
        print "### " kw
        if (heading != "") print "Section: " heading
        if (anchor != "") print "Re: \"" anchor "\""
        if (text != "") print text
        print ""
      }
    }
    next
  }
  /^[ \t]*>>/ {
    # An ALREADY-CONSUMED reply, in the pre-2026-08-11 in-file format. Never
    # re-collected, never re-marked, kept verbatim -- this is half of what
    # makes --consume idempotent. The other half is the ledger, and this block
    # feeds it: see seed() above and the MIGRATION note in the header.
    flush_reply()
    cc = $0
    sub(/^[ \t]*>>[ \t]?/, "", cc)
    if (!in_consumed) {
      in_consumed = 1
      consumed_anchor = anchor
      consumed_heading_norm = heading_norm
      consumed_text = ""
    }
    # The two header lines the old in-place marker wrote are not part of the
    # human reply and must not enter the key, or the seeded key would not
    # match the one the same reply produces when it is a plain `> ` line.
    if (cc ~ /^_\[consumed / || cc ~ /^still OPEN until something deletes it\]_$/) next
    if (consumed_text == "") consumed_text = cc; else consumed_text = consumed_text " " cc
    next
  }
  /^[ \t]*>[ \t]?/ {
    flush_consumed()
    content = $0
    sub(/^[ \t]*>[ \t]?/, "", content)
    if (content == "(answer inline here)" || content ~ /^\(answer inline here\)/) {
      flush_reply()
      next
    }
    if (content ~ /^[ \t]*$/ && !in_reply) {
      # A bare ">" not continuing a reply is an un-answered slot, same as
      # the "(answer inline here)" placeholder: keep it, collect nothing.
      next
    }
    if (!in_reply) {
      in_reply = 1
      reply_anchor = anchor
      reply_heading = heading
      reply_heading_norm = heading_norm
      reply_text = content
      reply_matched = (section_filter == "" || heading_norm == section_filter)
    } else {
      reply_text = reply_text " " content
    }
    next
  }
  {
    flush_reply(); flush_consumed()
    if ($0 !~ /^[ \t]*$/) anchor = $0
  }
  END { flush_reply(); flush_consumed() }
' "$FILE")"

if [ "$CONSUME" = "1" ] && [ -n "$KEYS_FILE" ]; then
  if [ -s "$KEYS_FILE" ]; then
    # LOUD on failure. An unrecordable consumption is not a no-op: the entry
    # will be handed to the next run as if it were fresh, which is the exact
    # re-prepend loop the ledger exists to end.
    if ! { mkdir -p "$RECEIPT_DIR" 2>/dev/null \
           && awk -v ts="$(date -Is)" '{ print ts "\t" $0 }' "$KEYS_FILE" >> "$LEDGER"; }; then
      echo "collect-feedback.sh: WARNING could not record consumption in $LEDGER -- these entries WILL be collected again next run" >&2
    fi
  fi
  rm -f "$KEYS_FILE"

  if [ -n "$OUT" ]; then
    RECEIPT_COUNT="$(printf '%s\n' "$OUT" | grep -c '^### ')"
    mkdir -p "$RECEIPT_DIR" 2>/dev/null || true
    printf '%s\tfile=%s\tsection=%s\tconsumed=%s\n' \
      "$(date -Is)" "$FILE" "${SECTION:--}" "$RECEIPT_COUNT" \
      >> "$RECEIPT_DIR/consumed-receipts.log" 2>/dev/null || true
  fi
fi

if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT"
  exit 0
fi
exit 1
