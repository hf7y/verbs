#!/usr/bin/env bash
# Concern: the "Claude Quota" plasmoid (mode=online) reports "idle" far too
# often. Root cause, probed before writing this -- a direct call to the same
# endpoint the widget uses succeeded (HTTP 200, real numbers) seconds after
# Zach reported the problem, so it isn't a dead credential. It's the failure
#   [rest: vault:senechal/header-archaeology-20260818.md]
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
. ../lib/common.sh

PLASMOID_DIR="${SENECHAL_CLAUDEQUOTA_DIR:-$HOME/.local/share/plasma/plasmoids/com.docusketch.claudequota}"
SCRIPT="$PLASMOID_DIR/contents/scripts/claude-quota-json"
QML="$PLASMOID_DIR/contents/ui/main.qml"
MARKER="senechal-online-cache-fallback-2026-08-11"

_patch_script() { # $1 = path to claude-quota-json
  python3 - "$1" "$MARKER" <<'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()

if marker in src:
    print("already patched")
    raise SystemExit(0)

# 1) cache location, right after REQ_FILE/CRED_FILE.
anchor1 = 'CRED_FILE="${CLAUDE_QUOTA_CRED_FILE:-$HOME/.claude/.credentials.json}"\n'
if anchor1 not in src:
    print("ANCHOR1-NOT-FOUND", file=sys.stderr); raise SystemExit(1)
src = src.replace(anchor1, anchor1 + (
    '\n# %s\n'
    'CACHE_FILE="${CLAUDE_QUOTA_ONLINE_CACHE:-$HOME/.cache/claude-quota/online-last.json}"\n'
    'CACHE_TTL_MIN="${CLAUDE_QUOTA_ONLINE_CACHE_TTL_MIN:-30}"\n'
) % marker, 1)

# 2) replace the transform tail of fetch_online() with a reusable function,
#    plus retry/cache wrappers. Anchor on the exact old tail (auth-gathering
#    block above it is untouched).
old_tail = '''  [ -n "$resp" ] || return 1
  printf '%s' "$resp" | node -e '
    let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
      let j; try { j = JSON.parse(s); } catch (e) { process.exit(1); }
      if (!j || !j.five_hour) process.exit(1);   // Cloudflare HTML / login => bail
      const now = Date.now(), DAY = 86400000;
      const reset = iso => {
        if (!iso) return { resetHuman: null, remainingMinutes: null, remainingDays: null };
        const d = new Date(iso);
        const hh = String(d.getHours()).padStart(2, "0");
        const mm = String(d.getMinutes()).padStart(2, "0");
        const mins = Math.max(0, Math.round((d - now) / 60000));
        return {
          resetHuman: d.toLocaleDateString(undefined, { month: "short", day: "numeric" }) + " " + hh + ":" + mm,
          remainingMinutes: mins,
          remainingDays: Math.max(0, Math.ceil((d - now) / DAY))
        };
      };
      const pct = o => o && typeof o.utilization === "number" ? Math.round(o.utilization) : 0;

      const fh = j.five_hour || {}, sd = j.seven_day || {};
      const fhR = reset(fh.resets_at), sdR = reset(sd.resets_at);
      // 5h window: time-only is clearer than a date.
      const fhTime = fh.resets_at ? (() => { const d = new Date(fh.resets_at); return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0"); })() : null;

      const names = {
        seven_day_opus: "Opus", seven_day_sonnet: "Sonnet",
        seven_day_omelette: "Claude Design", seven_day_cowork: "Cowork",
        seven_day_oauth_apps: "OAuth apps"
      };
      const models = [];
      for (const k in names) if (j[k] && typeof j[k].utilization === "number")
        models.push({ name: names[k], pct: Math.round(j[k].utilization) });

      const eu = j.extra_usage || {};
      const extra = eu.is_enabled ? {
        enabled: true,
        used: eu.used_credits || 0,
        limit: eu.monthly_limit || 0,
        currency: eu.currency || "",
        pct: eu.monthly_limit ? Math.round((eu.used_credits || 0) / eu.monthly_limit * 100) : 0
      } : { enabled: false };

      console.log(JSON.stringify({
        source: "online",
        window: { active: true, pct: pct(fh), resetHuman: fhTime, remainingMinutes: fhR.remainingMinutes },
        week:   { active: true, pct: pct(sd), resetHuman: sdR.resetHuman, remainingMinutes: sdR.remainingMinutes, remainingDays: sdR.remainingDays },
        models, extra
      }));
    });
  ' && return 0
  return 1
}'''
if old_tail not in src:
    print("ANCHOR2-NOT-FOUND", file=sys.stderr); raise SystemExit(1)

new_tail_tpl = '''  [ -n "$resp" ] || return 1
  local out
  out="$(printf '%s' "$resp" | _parse_usage_json "")" || return 1
  mkdir -p "$(dirname "$CACHE_FILE")" 2>/dev/null
  printf '%s' "$resp" > "$CACHE_FILE.tmp" 2>/dev/null && mv "$CACHE_FILE.tmp" "$CACHE_FILE" 2>/dev/null
  printf '%s\\n' "$out"
  return 0
}

# __MARKER__
# Shared transform: raw claude.ai usage JSON -> the widget's compact shape.
# stdin = raw JSON. $1 = cache age in minutes ("" for a live fetch) -- when
# set, tags the output "online-cached" instead of "online" and recomputes
# every time-derived field (resetHuman/remainingMinutes/remainingDays)
# against *now*, so only the % readings are stale, not the countdown.
_parse_usage_json() {
  node -e '
    let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
      let j; try { j = JSON.parse(s); } catch (e) { process.exit(1); }
      if (!j || !j.five_hour) process.exit(1);   // Cloudflare HTML / login => bail
      const now = Date.now(), DAY = 86400000;
      const cachedAgeMin = process.argv[1] ? parseInt(process.argv[1], 10) : null;
      const reset = iso => {
        if (!iso) return { resetHuman: null, remainingMinutes: null, remainingDays: null };
        const d = new Date(iso);
        const hh = String(d.getHours()).padStart(2, "0");
        const mm = String(d.getMinutes()).padStart(2, "0");
        const mins = Math.max(0, Math.round((d - now) / 60000));
        return {
          resetHuman: d.toLocaleDateString(undefined, { month: "short", day: "numeric" }) + " " + hh + ":" + mm,
          remainingMinutes: mins,
          remainingDays: Math.max(0, Math.ceil((d - now) / DAY))
        };
      };
      const pct = o => o && typeof o.utilization === "number" ? Math.round(o.utilization) : 0;

      const fh = j.five_hour || {}, sd = j.seven_day || {};
      const fhR = reset(fh.resets_at), sdR = reset(sd.resets_at);
      // 5h window: time-only is clearer than a date.
      const fhTime = fh.resets_at ? (() => { const d = new Date(fh.resets_at); return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0"); })() : null;

      const names = {
        seven_day_opus: "Opus", seven_day_sonnet: "Sonnet",
        seven_day_omelette: "Claude Design", seven_day_cowork: "Cowork",
        seven_day_oauth_apps: "OAuth apps"
      };
      const models = [];
      for (const k in names) if (j[k] && typeof j[k].utilization === "number")
        models.push({ name: names[k], pct: Math.round(j[k].utilization) });

      const eu = j.extra_usage || {};
      const extra = eu.is_enabled ? {
        enabled: true,
        used: eu.used_credits || 0,
        limit: eu.monthly_limit || 0,
        currency: eu.currency || "",
        pct: eu.monthly_limit ? Math.round((eu.used_credits || 0) / eu.monthly_limit * 100) : 0
      } : { enabled: false };

      console.log(JSON.stringify({
        source: cachedAgeMin !== null ? "online-cached" : "online",
        cachedAgeMin,
        window: { active: true, pct: pct(fh), resetHuman: fhTime, remainingMinutes: fhR.remainingMinutes },
        week:   { active: true, pct: pct(sd), resetHuman: sdR.resetHuman, remainingMinutes: sdR.remainingMinutes, remainingDays: sdR.remainingDays },
        models, extra
      }));
    });
  ' "$1"
}

# __MARKER__: one retry on a transient failure (network blip, a credentials-file
# refresh race) before giving up on a live fetch.
fetch_online_retry() {
  fetch_online && return 0
  sleep 1
  fetch_online
}

# __MARKER__: serve the last successful raw response, re-run through the same
# transform so countdowns stay accurate, only if it's not older than
# CACHE_TTL_MIN. Never fabricates data -- returns 1 (falls through to the
# hard error, or to emit_local in auto mode) once the cache goes stale.
fetch_online_cached() {
  [ -f "$CACHE_FILE" ] || return 1
  local age_min raw
  age_min=$(( ( $(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ) / 60 ))
  [ "$age_min" -le "$CACHE_TTL_MIN" ] || return 1
  raw="$(cat "$CACHE_FILE" 2>/dev/null)"
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | _parse_usage_json "$age_min"
}'''
new_tail = new_tail_tpl.replace("__MARKER__", marker)
src = src.replace(old_tail, new_tail, 1)

# 3) case statement: retry + cache fallback before giving up.
old_case = '''case "$MODE" in
  online) fetch_online || echo '{"error":"online fetch failed (token/cookie invalid or endpoint changed)"}' ;;
  auto)   fetch_online || emit_local ;;
  *)      emit_local ;;
esac'''
if old_case not in src:
    print("ANCHOR3-NOT-FOUND", file=sys.stderr); raise SystemExit(1)
new_case = '''case "$MODE" in
  online) fetch_online_retry || fetch_online_cached || echo '{"error":"online fetch failed (token/cookie invalid or endpoint changed)"}' ;;
  auto)   fetch_online_retry || fetch_online_cached || emit_local ;;
  *)      emit_local ;;
esac'''
src = src.replace(old_case, new_case, 1)

open(path, "w", encoding="utf-8").write(src)
print("patched")
PY
}

_patch_qml() { # $1 = path to main.qml
  python3 - "$1" "$MARKER" <<'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()

if marker in src:
    print("already patched")
    raise SystemExit(0)

# 1) new property to hold the cache age reported by the data source.
anchor1 = '    property string source: "local"\n'
if anchor1 not in src:
    print("ANCHOR1-NOT-FOUND", file=sys.stderr); raise SystemExit(1)
src = src.replace(anchor1, anchor1 + '    property int cachedAgeMin: -1  // %s\n' % marker, 1)

# 2) parse cachedAgeMin alongside source in onNewData.
anchor2 = '                    root.source = j.source || "local"\n'
if anchor2 not in src:
    print("ANCHOR2-NOT-FOUND", file=sys.stderr); raise SystemExit(1)
src = src.replace(anchor2, anchor2 +
    '                    root.cachedAgeMin = (j.cachedAgeMin === null || j.cachedAgeMin === undefined) ? -1 : j.cachedAgeMin  // %s\n' % marker,
    1)

# 3) header badge: live / cached (amber) / local.
old_badge = '''                PlasmaComponents.Label {
                    text: root.source === "online" ? "● live" : "○ local"
                    color: root.source === "online" ? "#27ae60" : Kirigami.Theme.textColor
                    opacity: root.source === "online" ? 1.0 : 0.6
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }'''
if old_badge not in src:
    print("ANCHOR3-NOT-FOUND", file=sys.stderr); raise SystemExit(1)
new_badge = '''                PlasmaComponents.Label {
                    // %s: cached reading gets its own amber state, distinct
                    // from both a real-time live fetch and the local proxy.
                    text: root.source === "online" ? "● live"
                          : root.source === "online-cached" ? "◐ cached " + root.cachedAgeMin + "m"
                          : "○ local"
                    color: root.source === "online" ? "#27ae60"
                           : root.source === "online-cached" ? "#f67400"
                           : Kirigami.Theme.textColor
                    opacity: root.source === "online" ? 1.0 : (root.source === "online-cached" ? 0.9 : 0.6)
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }'''
src = src.replace(old_badge, new_badge, 1)

# 4) footer detail line: mention the cache age instead of the generic
#    "refreshes every Ns" line while serving a cached reading.
old_footer = '''                text: root.source === "online"
                      ? "Real claude.ai utilization · refreshes every " + plasmoid.configuration.refreshSeconds + "s"
                      : "Local proxy · scale " + (root.winLimit > 0 ? root.fmtTokens(root.winLimit) : "auto") + " / wk " + (root.weekLimit > 0 ? root.fmtTokens(root.weekLimit) : "auto")'''
if old_footer not in src:
    print("ANCHOR4-NOT-FOUND", file=sys.stderr); raise SystemExit(1)
new_footer = '''                text: root.source === "online"
                      ? "Real claude.ai utilization · refreshes every " + plasmoid.configuration.refreshSeconds + "s"
                      : root.source === "online-cached"
                      ? "Cached claude.ai utilization (" + root.cachedAgeMin + "m old) · retrying live"  // %s
                      : "Local proxy · scale " + (root.winLimit > 0 ? root.fmtTokens(root.winLimit) : "auto") + " / wk " + (root.weekLimit > 0 ? root.fmtTokens(root.weekLimit) : "auto")''' % marker
src = src.replace(old_footer, new_footer, 1)

open(path, "w", encoding="utf-8").write(src)
print("patched")
PY
}

cmd_enable() {
  [ -f "$SCRIPT" ] || die "not found: $SCRIPT -- is the claudequota plasmoid installed under a different path? Override with SENECHAL_CLAUDEQUOTA_DIR."
  [ -f "$QML" ] || die "not found: $QML"
  if grep -q "$MARKER" "$SCRIPT" 2>/dev/null && grep -q "$MARKER" "$QML" 2>/dev/null; then
    say "already applied ($MARKER present in both files) -- nothing to do"
    exit 0
  fi
  local bak1 bak2
  bak1="$(backup_file "$SCRIPT")"; say "backed up: $bak1"
  bak2="$(backup_file "$QML")"; say "backed up: $bak2"
  _patch_script "$SCRIPT" || die "script patch failed -- claude-quota-json's shape has changed since this remedy was written; restored nothing (patch is all-or-nothing on a fresh read). Diff it against the anchors in _patch_script()."
  _patch_qml "$QML" || die "QML patch failed -- main.qml's shape has changed since this remedy was written; restored nothing. Diff it against the anchors in _patch_qml()."
  bash -n "$SCRIPT" || die "patched $SCRIPT fails bash -n -- syntax error introduced, restore from $bak1"
  command -v qmllint >/dev/null 2>&1 && { qmllint "$QML" && say "qmllint: clean" || warn "qmllint reported issues -- review $QML before trusting the widget"; }
  say "applied. Restart plasmashell to see it: systemctl --user restart plasma-plasmashell.service"
}

cmd_verify() {
  parse_common_args "$@"
  head_ "Claude Quota plasmoid: online-fetch retry + last-known-good cache fallback"
  if [ ! -f "$SCRIPT" ] || [ ! -f "$QML" ]; then
    skip "plasmoid not found under $PLASMOID_DIR"
    finish_verify
  fi
  if grep -q "fetch_online_retry || fetch_online_cached" "$SCRIPT" && grep -q "_parse_usage_json" "$SCRIPT"; then
    ok "claude-quota-json retries once and falls back to a cached reading before erroring"
  else
    fail "claude-quota-json missing retry/cache fallback -- run: $0 enable"
  fi
  if grep -q 'online-cached' "$QML" && grep -q "cachedAgeMin" "$QML"; then
    ok "main.qml renders the cached-reading state"
  else
    fail "main.qml missing cached-reading rendering -- run: $0 enable"
  fi
  finish_verify "OK -- online mode degrades to a labelled cached reading instead of idle."
}

case "${1:-}" in
  enable) cmd_enable ;;
  verify) shift; cmd_verify "$@" ;;
  *) die "usage: $0 enable|verify [-q]" ;;
esac
