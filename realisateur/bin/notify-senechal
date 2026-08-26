#!/usr/bin/env bash
# notify-senechal.sh <text> -- file a machine-config change through senechal's
# own front door, and make sure it actually LANDED where senechal reads it.
#
# KIND: verb
#
# TRAPS (the rest of this header is in the vault):
#   senechal owns the CONTRACT -- everything below the `--- 2.` line: what
#   "landed" means and which surface the consumer actually reads. That is now
#   its issue queue rather than a file in its tree, which is a smaller and
#   more stable contract than the one it replaces: an issue URL cannot be
#   moved by senechal reorganising its own repository.
#
# Usage (TYPED -- this door does not accept prose):

set -uo pipefail

# WHERE PROJECTS LIVE IS A PROPERTY OF THE HOST, NOT OF ZACH'S LAPTOP.
PROJECTS_ROOT="${INSTALLE_PROJECTS:-$HOME/Documents/Projects}"
SCHED_ROOT="${SCHED_ROOT:-$PROJECTS_ROOT/scheduler}"

die() { printf 'notify-senechal: FAIL: %s\n' "$*" >&2; exit 1; }

# THIS DOOR NO LONGER ACCEPTS PROSE (hf7y/senechal#323, #324).
DOORS_REPO="${NOTIFY_DOORS_REPO:-hf7y/senechal}"
DOORS_PATH="${NOTIFY_DOORS_PATH:-registry/front-doors.json}"
DOORS_URL="$DOORS_REPO/$DOORS_PATH"

usage() {
  printf "notify-senechal.sh -- file a machine-config fact through senechal's typed door\n\n"
  printf "usage:\n  notify-senechal.sh <door> <field>=<value> ...\n\n"
  printf "example:\n"
  printf "  notify-senechal.sh footprint id=spawn-here-symlinks kind=path \\\\\n"
  printf "    target=\"\$HOME/.local/bin/spawn-here\" host=mandark owner=senechal \\\\\n"
  printf "    status=live retire='remedies/window-spawn-desktop.sh disable' \\\\\n"
  printf "    notes='installed by the window-spawn-desktop remedy'\n\n"
  printf "This door does NOT accept free text. The doors and their required fields\n"
  printf "are senechal's, published at:\n  %s\n" "$DOORS_URL"
  printf "  notify-senechal.sh --doors    # list them\n\n"
  printf "If no door fits what you need to file, ADD ONE -- a PR to senechal's\n"
  printf "registry/front-doors.json and tools/absorb-notices.py. Do not look for a\n"
  printf "prose fallback; there is deliberately none.\n\n"
  printf "exit codes:\n"
  printf "  0  the filing is confirmed present on senechal's remote\n"
  printf "  1  any failure, with a stated reason (no exit-0 no-op)\n"
  printf "  2  usage error: no door named, or prose passed where fields belong\n\n"
  printf "this tool makes no AI calls and cannot spend: --summon is rejected.\n"
}

command -v python3 >/dev/null 2>&1 || die "python3 is not on PATH -- cannot validate against senechal's door schema, and filing unvalidated is what this replaces"

# --help before the fetch: it must work with no network and no auth.
case "${1:-}" in --help|-h) usage; exit 0 ;; esac

# Fetched once into a file: validation and payload are built from the same bytes.
doors_file="$(mktemp)"
trap 'rm -f "$doors_file"' EXIT
if [ -n "${NOTIFY_DOORS_FILE:-}" ]; then
  cat "$NOTIFY_DOORS_FILE" > "$doors_file" 2>/dev/null \
    || die "NOTIFY_DOORS_FILE=$NOTIFY_DOORS_FILE could not be read"
else
  command -v gh >/dev/null 2>&1 || die "gh is not on PATH -- cannot fetch senechal's door schema from $DOORS_URL"
  gh api "repos/$DOORS_REPO/contents/$DOORS_PATH" -H 'Accept: application/vnd.github.raw' > "$doors_file" 2>/dev/null \
    || die "could not fetch senechal's door schema from $DOORS_URL -- filing unvalidated is not the fallback"
fi
python3 -c 'import json,sys; json.load(open(sys.argv[1]))["doors"]' "$doors_file" \
  || die "senechal's door schema at $DOORS_URL did not parse -- refusing to file against a schema nobody can read"

door="${1:-}"
case "$door" in
  --help|-h) usage; exit 0 ;;
  # exit 2, not 1: naming no door is a usage error, and this script's own
  # --help has always documented 2 for it.
  "") usage >&2; printf 'notify-senechal: no door named\n' >&2; exit 2 ;;
  --doors)
    python3 -c '
import json, sys
doors = json.load(open(sys.argv[1]))["doors"]
for name, d in sorted(doors.items()):
    print("%s -- %s" % (name, d.get("comment", "")))
    for f in d["required"]:
        print("    %-8s %s" % (f, d.get("help", {}).get(f, "")))
' "$doors_file"
    exit 0 ;;
  # exit 2, not 1: a flag that is not a door is a usage error, and this
  # script's own --help has always documented 2 for exactly that.
  -*) usage >&2; printf "notify-senechal: '%s' is not a door. Name a door first.\n" "$door" >&2; exit 2 ;;
  *\ *)
    # A door name is one word. Whitespace means a sentence was passed where a
    # door belongs -- the old prose call, verbatim. Exit 2 (usage), not 1: the
    # caller has not made a bad filing, it is still making the old KIND of call.
    printf "notify-senechal: refusing to file prose: %s\n" "$door" >&2
    printf "  This door takes: notify-senechal.sh <door> <field>=<value> ...\n" >&2
    printf "  Run --doors to see the doors senechal publishes. If none fits what you\n" >&2
    printf "  need to file, ADD one to senechal's registry/front-doors.json -- there is\n" >&2
    printf "  deliberately no free-text fallback.\n" >&2
    exit 2 ;;
esac
shift

# PROSE IS REFUSED AT THE ARGUMENT, not silently coerced. This also keeps the
# A misparse fixed for free: `--not-a-real-flag` was once filed as a
# note's entire body, because free text has no wrong shape. Now it does.
fields_args=()
for arg in "$@"; do
  case "$arg" in
    *=*) fields_args+=("$arg") ;;
    *)
      printf "notify-senechal: refusing to file prose: %s\n" "$arg" >&2
      printf "  This door takes <field>=<value> pairs only. Run --doors for the fields\n" >&2
      printf "  door '%s' requires. If no door fits, add one to senechal's\n" "$door" >&2
      printf "  registry/front-doors.json -- there is no free-text fallback.\n" >&2
      exit 2 ;;
  esac
done
if [ "${#fields_args[@]}" -eq 0 ]; then
  usage >&2
  printf "notify-senechal: FAIL: door '%s' named with no <field>=<value> pairs\n" "$door" >&2
  exit 2
fi

# Validate HERE: a payload senechal's absorber would reject must never become
# an issue somebody closes by hand -- the prose backlog in a JSON hat.
payload="$(python3 - "$doors_file" "$door" "${fields_args[@]}" <<'PY'
import json, sys

doors_file, door_name, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
doors = json.load(open(doors_file))["doors"]
door = doors.get(door_name)
if door is None:
    sys.exit("no such door: %r -- known doors: %s\n"
             "If none of these fit, ADD a door to senechal's registry/front-doors.json."
             % (door_name, ", ".join(sorted(doors))))

fields = {}
for p in pairs:
    k, _, v = p.partition("=")
    if k in fields:
        sys.exit("field %r given twice" % k)
    fields[k] = v

missing = [f for f in door["required"] if not fields.get(f, "").strip()]
if missing:
    helps = door.get("help", {})
    sys.exit("door %s is missing required field(s):\n%s" % (door_name, "\n".join(
        "  %-8s %s" % (f, helps.get(f, "")) for f in missing)))
extra = [f for f in fields if f not in door["required"]]
if extra:
    sys.exit("door %s takes no field(s): %s" % (door_name, ", ".join(sorted(extra))))
for field, allowed in door.get("enums", {}).items():
    if fields[field] not in allowed:
        sys.exit("door %s: %s=%r is not one of: %s"
                 % (door_name, field, fields[field], ", ".join(allowed)))

print(json.dumps({"door": door_name, "fields": fields}, indent=2, sort_keys=True))
PY
)" || die "the filing does not satisfy senechal's schema for door '$door' (see above) -- nothing was filed"

# The human-readable line is DERIVED from the fields, not typed alongside them,
# so it cannot disagree with the payload the absorber reads.
text="$(printf '%s' "$payload" | python3 -c '
import json, sys
p = json.load(sys.stdin)
f = p["fields"]
key = f.get("id") or f.get("name")
print("%s: %s (%s)" % (p["door"], key, ", ".join(
    "%s=%s" % (k, v) for k, v in sorted(f.items()) if k not in ("id", "name", "notes"))))
')"

command -v gh >/dev/null 2>&1 || die "gh is not on PATH -- cannot file, and could not confirm a filing either"
# NOTE: no senechal clone is required any more -- the note goes to GitHub.
# The check that used to be here (`[ -d "$SENECHAL/.git" ]`) is removed
# deliberately: keeping it would have made this script keep DEMANDING the very
# checkout the change exists to make unnecessary, on every host, forever.

# --- 1. file it through the front door, and capture the issue it created ----
#
# THE FRONT DOOR IS GITHUB (scheduler#22). `scheduler -i`
DEST_REPO="${NOTIFY_SENECHAL_REPO:-hf7y/senechal}"
FROM_PROJECT="${NOTIFY_FROM_PROJECT:-realisateur}"

# The title is the first line, bounded; the body carries the whole note. A
# title that is the entire paragraph is unreadable in a list, and the list is
# where a human meets this.
title="$(printf '%s' "$text" | head -1 | cut -c1-72)"
[ -n "$title" ] || die "the note has no first line to title it with"

# THE FOOTER IS A GATE, NOT DECORATION (senechal#221 ->
# realisateur#220). `scheduler -i` stamped every issue it filed with
#
# TRAP: line 1, the DEFERRED block AND the DELIVERS block satisfy
#   bin/gh-sign.sh, which refuses a body declaring no DECISION:/NO-DECISION:,
#   carrying no ledger, or shipping nowhere. Delete any of them as
#   boilerplate and every call dies wherever the shim is live (#356, #554).
#
# DELIVERS is DERIVED, not typed alongside the fields: the door already names
# WHERE the change takes effect (footprint's target, crontab's tag, device's
# name), so re-typing it invites the two from disagreeing. Falls back to
# "- none" only for a door this mapping does not yet know.
delivers="$(printf '%s' "$payload" | python3 -c '
import json, sys
p = json.load(sys.stdin)
f = p["fields"]
door = p["door"]
if door == "footprint":
    kind = f.get("kind", "")
    prefix = {"systemd-user-unit": "unit", "systemd-system-unit": "unit",
              "listening-port": "port"}.get(kind, "path")
    print("- %s: %s" % (prefix, f.get("target", "")))
elif door == "crontab":
    print("- tag: %s" % f.get("tag", ""))
elif door == "device":
    print("- host: %s" % f.get("name", ""))
else:
    print("- none")
')"
body="$(printf 'NO-DECISION: @hf7y -- a typed door note; it records a fact and asks nothing.\n\n%s\n\n```senechal-door\n%s\n```\n\n---\nfiled %s via `notify-senechal` on %s\n\nsenechal absorbs this with `tools/absorb-notices.py --write`; closing IS the\nacknowledgement. If it was REJECTED, the payload above is wrong or the entry\nalready exists -- fix it at the caller, not by hand here.\n\n<!-- DEFERRED -->\n- none\n<!-- /DEFERRED -->\n\n<!-- DELIVERS -->\n%s\n<!-- /DELIVERS -->\n' \
  "$text" "$payload" "$(date '+%Y-%m-%d %H:%M')" "$(hostname -s 2>/dev/null || hostname)" "$delivers")"

echo "notify-senechal: filing to $DEST_REPO as from:$FROM_PROJECT ..."
# `door` is what the absorber queries on; `idea` stays for continuity with
# senechal's tools/issue-janitor.py, which already keys on it.
out="$(gh issue create --repo "$DEST_REPO" \
        --title "$title" \
        --body "$body" \
        --label idea --label door --label "from:$FROM_PROJECT" 2>&1)" || {
  printf '%s\n' "$out" >&2
  die "gh issue create rejected the note on $DEST_REPO"
}
printf '%s\n' "$out"

# The URL is the receipt. Parsed rather than assumed: a create that prints
# success without a URL recorded nothing anybody can find, and exit 0 is not
# evidence that an issue exists. Same reason the body below reads it back.
issue_url="$(printf '%s\n' "$out" | grep -oE 'https://github\.com/[^[:space:]]+/issues/[0-9]+' | head -1)"
[ -n "$issue_url" ] \
  || die "gh reported success but printed no issue URL -- nothing verifiable was recorded"

# --- 2. prove the issue exists on the remote --------------------------------
#
# Re-read it from GitHub rather than trusting the URL we were handed. The
# discipline rule is "verified where the consumer reads it", and the consumer
# here is whoever opens senechal's issue list.
command -v gh >/dev/null 2>&1 \
  || die "gh is not on PATH -- the note may have been filed, but nothing here can confirm it"

if ! state="$(gh issue view "$issue_url" --json state,title -q '.state' 2>&1)"; then
  printf '%s\n' "$state" >&2
  die "filed $issue_url but could not read it back -- treat as UNVERIFIED"
fi
case "$state" in
  OPEN|CLOSED) ;;
  *) die "filed $issue_url but its state reads as '$state' -- treat as UNVERIFIED" ;;
esac

echo "notify-senechal: OK -- filed and verified on senechal's issue queue ($state)"
echo "  $issue_url"
exit 0