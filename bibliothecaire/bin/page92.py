#!/usr/bin/env python3
"""quatre-vingt-douze "page 92" pipeline: fetch / extract / gallery.

Scrapes nothing it doesn't name: downloads a bounded list of individual
public-domain plain-text books (Gutendex API -> gutenberg.org),
sequentially, rate-limited, with an honest User-Agent. Extracts a
deterministic "page 92" from each (see README.md for the stated rule) and
builds a side-by-side gallery for hand-arrangement. The arranging itself
is deliberately NOT automated -- user judgment is the product.

Usage:
    page92.py fetch [--count N]   # default 20, hard cap 40 per run
    page92.py extract
    page92.py gallery
    page92.py rule                # the pagination rule and its line range
    page92.py order               # what order the pages are in, and what it means
    page92.py status              # what is on disk right now

Exit codes: 0 ok, 1 usage/error (fails loud; a fetch/extract that
produces nothing new says so and exits nonzero).
"""

import html
import json
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.request

# This file lives in bin/, so the tree it operates on is bin/'s PARENT --
# resolving to bin/ itself would silently create bin/cache, bin/pages and
# bin/gallery, which is an exit-0 wrong answer rather than a loud one.
# GLANE_ROOT overrides it so a test can run against a scratch tree.
ROOT = pathlib.Path(
    os.environ.get("GLANE_ROOT", pathlib.Path(__file__).resolve().parent.parent)
).resolve()
CACHE = ROOT / "cache"
PAGES = ROOT / "pages"
GALLERY = ROOT / "gallery"

# cache/ is untracked, so per-book metadata (title, author, source URL) has to
# be carried into the tracked product or a fresh clone's gallery degrades to
# bare slugs. extract writes it here; gallery reads only this.
MANIFEST = PAGES / "manifest.json"

USER_AGENT = "quatre-vingt-douze/0.1 (personal art project; contact: dangerpine@gmail.com)"
FETCH_DELAY_S = 2.0
HARD_CAP = 40

LINES_PER_PAGE = 38
PAGE_NUMBER = 92  # the point of the whole project

GUTENDEX = "https://gutendex.com/books/?languages=en&mime_type=text%2Fplain&sort=popular"


def http_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()


def slugify(title):
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return slug[:60] or "untitled"


def cmd_fetch(count):
    count = min(count, HARD_CAP)
    CACHE.mkdir(exist_ok=True)
    got, url = 0, GUTENDEX
    while got < count and url:
        catalog = json.loads(http_get(url))
        url = catalog.get("next")
        for book in catalog.get("results", []):
            if got >= count:
                break
            txt_url = next(
                (u for fmt, u in book.get("formats", {}).items()
                 if fmt.startswith("text/plain") and not u.endswith(".zip")),
                None,
            )
            if not txt_url:
                continue
            title = book.get("title", "untitled")
            author = (book.get("authors") or [{}])[0].get("name", "unknown")
            slug = f"pg{book['id']}-{slugify(title)}"
            dest = CACHE / f"{slug}.txt"
            meta = CACHE / f"{slug}.json"
            if dest.exists():
                got += 1  # already have it; counts toward the target
                continue
            print(f"fetch: {title!r} ({author}) <- {txt_url}")
            try:
                body = http_get(txt_url)
            except (urllib.error.HTTPError, urllib.error.URLError) as e:
                # A stale catalog URL is that book's problem, not the run's.
                print(f"fetch: {title!r}: skipped ({e})")
                time.sleep(FETCH_DELAY_S)
                continue
            dest.write_bytes(body)
            meta.write_text(json.dumps(
                {"id": book["id"], "title": title, "author": author,
                 "source": txt_url}, indent=2))
            got += 1
            time.sleep(FETCH_DELAY_S)
    if got == 0:
        sys.exit("fetch: nothing fetched (API empty or all skipped)")
    print(f"fetch: {got} text(s) in cache/")


def strip_gutenberg_boilerplate(text):
    """Cut PG header/footer between the *** START/END *** markers, if present."""
    start = re.search(r"\*\*\* ?START OF (?:THE|THIS) PROJECT GUTENBERG.*?\*\*\*", text, re.I)
    end = re.search(r"\*\*\* ?END OF (?:THE|THIS) PROJECT GUTENBERG.*?\*\*\*", text, re.I)
    lo = start.end() if start else 0
    hi = end.start() if end else len(text)
    # Strip the newline remnants around the cut markers -- without this the
    # marker's trailing "\n" becomes a phantom first line and shifts every
    # page by one relative to a boilerplate-free text.
    return text[lo:hi].strip("\n")


def page_lines(text, page_number=PAGE_NUMBER, lines_per_page=LINES_PER_PAGE):
    """The stated deterministic rule. Returns list of lines, or None if the
    text is too short to have that page."""
    lines = strip_gutenberg_boilerplate(text).splitlines()
    lo = (page_number - 1) * lines_per_page
    hi = lo + lines_per_page
    if lo >= len(lines):
        return None
    return lines[lo:hi]


def page_line_range():
    """1-indexed first/last line of page 92 in the stripped text."""
    lo = (PAGE_NUMBER - 1) * LINES_PER_PAGE + 1
    return lo, lo + LINES_PER_PAGE - 1


def cached_meta(slug):
    """Per-book metadata fetch wrote alongside the text, or {} if absent."""
    meta_path = CACHE / f"{slug}.json"
    if not meta_path.exists():
        return {}
    return json.loads(meta_path.read_text())


def display_author(author):
    """Gutendex hands back library catalogue order ("Shakespeare, William").
    That form exists for sorting a card index, not for reading, and on a wall
    of found pages it reads as filing, not authorship. Flip it for display
    only -- the manifest keeps the archive's own string verbatim, so nothing
    the archive told us is lost.

    Left alone when the shape isn't a personal name: no comma at all
    ("unknown", corporate names), or an already-natural string.
    """
    if not author or "," not in author:
        return author
    surname, _, rest = author.partition(",")
    # Trailing catalogue cruft: life dates ("Twain, Mark, 1835-1910") and any
    # further comma-separated qualifiers are filing apparatus, not the name.
    given = rest.split(",")[0].strip()
    # "Forster, E. M. (Edward Morgan)" -- the parenthetical expands initials
    # for disambiguation in a catalogue; the byline wants the initials.
    given = re.sub(r"\s*\([^)]*\)", "", given).strip()
    surname = surname.strip()
    if not given or not surname:
        return author
    return f"{given} {surname}"


def load_manifest():
    if not MANIFEST.exists():
        return {"pages": [], "skipped": []}
    return json.loads(MANIFEST.read_text())


def cmd_extract():
    if not CACHE.is_dir() or not any(CACHE.glob("*.txt")):
        sys.exit("extract: cache/ is empty -- run fetch first")
    PAGES.mkdir(exist_ok=True)

    # Carry forward entries from previous runs: cache/ is transient, so a run
    # against a partial cache must not erase metadata for pages still on disk.
    old = load_manifest()
    pages_by_file = {e["file"]: e for e in old.get("pages", [])}
    skipped_by_slug = {e["slug"]: e for e in old.get("skipped", [])}

    made = skipped = 0
    for src in sorted(CACHE.glob("*.txt")):
        slug = src.stem
        meta = cached_meta(slug)
        entry = {"slug": slug, "id": meta.get("id"), "title": meta.get("title"),
                 "author": meta.get("author"), "source": meta.get("source")}
        lines = page_lines(src.read_text(errors="replace"))
        if lines is None:
            print(f"extract: {slug}: too short for page {PAGE_NUMBER}, skipped")
            entry["reason"] = f"too short for page {PAGE_NUMBER}"
            skipped_by_slug[slug] = entry
            pages_by_file.pop(f"{slug}-p{PAGE_NUMBER}.txt", None)
            skipped += 1
            continue
        name = f"{slug}-p{PAGE_NUMBER}.txt"
        (PAGES / name).write_text("\n".join(lines) + "\n")
        entry["file"] = name
        entry["lines"] = len(lines)  # < LINES_PER_PAGE for a partial last page
        pages_by_file[name] = entry
        skipped_by_slug.pop(slug, None)
        made += 1

    # Drop entries whose page file is gone; keep the manifest honest about disk.
    pages = [e for name, e in sorted(pages_by_file.items()) if (PAGES / name).exists()]
    lo, hi = page_line_range()
    MANIFEST.write_text(json.dumps({
        "rule": {"page_number": PAGE_NUMBER, "lines_per_page": LINES_PER_PAGE,
                 "first_line": lo, "last_line": hi,
                 "of": "the Project Gutenberg boilerplate-stripped text"},
        "pages": pages,
        "skipped": [e for _, e in sorted(skipped_by_slug.items())],
    }, indent=2, ensure_ascii=False) + "\n")

    print(f"extract: {made} page(s) written, {skipped} too short; "
          f"manifest lists {len(pages)}")
    if made == 0:
        sys.exit("extract: produced nothing")


def cmd_gallery():
    pages = sorted(PAGES.glob(f"*-p{PAGE_NUMBER}.txt"))
    if not pages:
        sys.exit("gallery: pages/ is empty -- run extract first")
    manifest = load_manifest()
    by_file = {e["file"]: e for e in manifest.get("pages", [])}
    GALLERY.mkdir(exist_ok=True)
    lo, hi = page_line_range()

    cards, unlisted = [], []
    for p in pages:
        meta = by_file.get(p.name) or {}
        listed = p.name in by_file
        if not listed:
            # No metadata rather than wrong metadata -- say so here and below.
            unlisted.append(p.name)
        title_part = html.escape(meta['title']) if meta.get("title") else p.stem
        author_part = (
            f"<span class=\"author\">"
            f"{html.escape(display_author(meta['author']))}</span>"
            if meta.get("author") else "")
        title = f"{title_part}{(' — ' + author_part) if author_part else ''}"
        n_lines = meta.get("lines", LINES_PER_PAGE)
        byline = (f"lines {lo}–{hi} (of the boilerplate-stripped text)"
                  if n_lines == LINES_PER_PAGE
                  else f"lines {lo}–{lo + n_lines - 1} — the book ends mid-page")
        bits = [byline]
        if meta.get("source"):
            bits.append(f'<a href="{html.escape(meta["source"])}">source</a>')
        if not listed:
            bits.append("no manifest entry — re-run <code>extract</code>")
        cards.append(
            f"<figure><figcaption>{title}"
            f'<span class="meta">{" &middot; ".join(bits)}</span></figcaption>'
            f"<pre>{html.escape(p.read_text())}</pre></figure>"
        )

    # Books that were fetched but have no page 92 are part of the record, not
    # a silent hole in it -- the corpus is bigger than the wall.
    skipped = manifest.get("skipped", [])
    skipped_html = ""
    if skipped:
        items = "".join(
            f"<li>{html.escape(e.get('title') or e['slug'])}"
            + (f" — {html.escape(display_author(e['author']))}"
               if e.get("author") else "")
            + f" <span class=\"why\">({html.escape(e.get('reason', 'skipped'))})</span></li>"
            for e in skipped
        )
        skipped_html = (
            f'<section class="skipped"><h2>{len(skipped)} fetched, no page '
            f"{PAGE_NUMBER}</h2><ul>{items}</ul></section>"
        )

    (GALLERY / "index.html").write_text(f"""<!doctype html>
<meta charset="utf-8">
<title>page {PAGE_NUMBER} — quatre-vingt-douze</title>
<style>
  body {{ font-family: Georgia, "Iowan Old Style", serif; margin: 2rem;
          background: #faf8f4; color: #222; }}
  main {{ display: flex; flex-wrap: wrap; gap: 1.5rem; align-items: flex-start; }}
  figure {{ margin: 0; max-width: 34rem; background: #fff;
            border: 1px solid #ddd; border-radius: 3px;
            box-shadow: 0 1px 3px rgba(0,0,0,.08); padding: 1rem 1.25rem; }}
  figcaption {{ font-weight: bold; margin-bottom: .6rem; }}
  figcaption .author {{ font-weight: normal; font-size: 0.85rem; color: #666; }}
  figcaption .meta {{ display: block; font-weight: normal; font-size: 0.75rem;
                      color: #888; margin-top: .15rem; }}
  figcaption .meta a {{ color: #888; }}
  pre {{ white-space: pre-wrap; font: 0.72rem/1.4 "Courier New", monospace; }}
  /* The real radios are the state; the labels are the visible control. */
  input[name="density"] {{ position: absolute; opacity: 0; pointer-events: none; }}
  .sheets {{ font-size: .8rem; color: #777; margin: -.5rem 0 1.2rem; }}
  .sheets label {{ margin-left: .5rem; padding: .1rem .5rem; cursor: pointer;
                   border: 1px solid #ddd; border-radius: 3px; background: #fff; }}
  #d1:checked ~ .sheets label[for="d1"],
  #d2:checked ~ .sheets label[for="d2"],
  #d4:checked ~ .sheets label[for="d4"] {{ border-color: #888; color: #333; }}
  .order {{ font-size: .8rem; color: #999; margin-top: -.6rem; }}
  .skipped {{ margin-top: 2.5rem; font-size: .8rem; color: #777; }}
  .skipped h2 {{ font-size: .8rem; font-weight: bold; margin-bottom: .3rem; }}
  .skipped ul {{ margin: 0; padding-left: 1.2rem; }}
  .skipped .why {{ color: #aaa; }}
  /* Arranging is done by hand -- on paper too, if Zach wants. No screen
     chrome in print, nothing that costs ink. How many page 92s land on a
     sheet is a genuine open question (QUESTIONS.md), so it is a switch he
     can try rather than a guess baked in: fewer per sheet reads better and
     shuffles better, more per sheet shows a whole spread at once. CSS only
     -- the radios sit next to <main> so :checked can reach the figures. */
  @media print {{
    body {{ background: #fff; margin: 0; }}
    h1, p, .skipped, .sheets {{ display: none; }}
    /* Block/float, never flex: a print flex container fragments one item per
       sheet in Chrome, which silently defeats every multi-up density. */
    main {{ display: block; }}
    main::after {{ content: ""; display: block; clear: both; }}
    figure {{ margin: 0; max-width: none; border: 0; box-shadow: none;
              border-radius: 0; padding: 0 .4rem; box-sizing: border-box;
              page-break-inside: avoid; break-inside: avoid; }}
    figcaption .meta a {{ text-decoration: none; }}
    #d1:checked ~ main figure {{ page-break-after: always; break-after: page; }}
    #d1:checked ~ main pre {{ font-size: 0.9rem; }}
    #d2:checked ~ main pre {{ font-size: 0.46rem; line-height: 1.25; }}
    #d2:checked ~ main figure:nth-of-type(2n) {{
        page-break-after: always; break-after: page; }}
    #d4:checked ~ main figure {{ float: left; width: 50%; }}
    #d4:checked ~ main pre {{ font-size: 0.42rem; line-height: 1.25; }}
    #d4:checked ~ main figure:nth-of-type(4n) {{
        page-break-after: always; break-after: page; }}
    /* ...but never after the last one, or every print ends on a blank sheet.
       Needs the :checked prefix too, or the id selectors above outrank it. */
    #d1:checked ~ main figure:last-of-type,
    #d2:checked ~ main figure:last-of-type,
    #d4:checked ~ main figure:last-of-type {{
        page-break-after: auto; break-after: auto; }}
  }}
</style>
<h1>page {PAGE_NUMBER} × {len(cards)}</h1>
<p>Raw material for hand-arrangement. The tooling stops here on purpose.</p>
<input type="radio" name="density" id="d1" checked><input type="radio" name="density" id="d2"><input type="radio" name="density" id="d4">
<p class="sheets">On paper — print preview to compare:
  <label for="d1">1 per sheet</label><label for="d2">2 per sheet</label><label for="d4">4 per sheet</label>
</p>
<p class="order">Shown in {html.escape(ORDER_STATEMENT.replace(chr(10), " "))}</p>
<main>{"".join(cards)}</main>
{skipped_html}
""")
    print(f"gallery: gallery/index.html with {len(cards)} page(s)"
          + (f", {len(skipped)} skipped book(s) noted" if skipped else ""))
    if unlisted:
        print(f"gallery: warning: {len(unlisted)} page(s) missing from "
              f"{MANIFEST.name} (shown without title/source): "
              + ", ".join(unlisted[:3]) + ("..." if len(unlisted) > 3 else ""),
              file=sys.stderr)


# The ordering statement lives HERE, next to the code that does no ordering,
# and the gallery header and `order` both read it. Two copies of a sentence
# this load-bearing would drift, and the drifted one would be the reassuring
# one.
ORDER_STATEMENT = (
    "archive catalogue order. An accident of the archive, not a reading order.\n"
    "It carries no judgment, and nothing here will reorder it: arranging is yours."
)


def cmd_rule():
    lo, hi = page_line_range()
    print(f"page {PAGE_NUMBER} = lines {lo}-{hi}, at {LINES_PER_PAGE} lines "
          f"per page, after boilerplate is stripped")


def cmd_order():
    print(ORDER_STATEMENT)


def cmd_status():
    cached = len(list(CACHE.glob("*.txt"))) if CACHE.is_dir() else 0
    harvested = len(list(PAGES.glob("*-p92.txt"))) if PAGES.is_dir() else 0
    manifest = load_manifest()
    skipped = len(manifest.get("skipped", []))
    hung = GALLERY / "index.html"
    print(f"cached      {cached} text(s)")
    print(f"harvested   {harvested} page(s)")
    print(f"skipped     {skipped} text(s) too short to have page {PAGE_NUMBER}")
    if not hung.exists():
        print("hung        no surface built yet")
    elif harvested and hung.stat().st_mtime < max(
            p.stat().st_mtime for p in PAGES.glob("*-p92.txt")):
        # Loud, because a surface older than its harvest shows the old harvest
        # while reporting nothing wrong -- exactly the silent-wrong-answer case.
        print("hung        STALE -- older than the harvest it shows")
    else:
        print("hung        current")


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    if not args:
        sys.exit(__doc__.strip())
    cmd = args[0]
    if cmd == "fetch":
        count = 20
        for a in argv[1:]:
            if a.startswith("--count"):
                count = int(a.split("=", 1)[1] if "=" in a else argv[argv.index(a) + 1])
        cmd_fetch(count)
    elif cmd == "extract":
        cmd_extract()
    elif cmd == "gallery":
        cmd_gallery()
    elif cmd == "rule":
        cmd_rule()
    elif cmd == "order":
        cmd_order()
    elif cmd == "status":
        cmd_status()
    else:
        sys.exit(f"unknown command {cmd!r}\n\n" + __doc__.strip())


if __name__ == "__main__":
    main(sys.argv)
