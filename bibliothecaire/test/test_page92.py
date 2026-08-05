#!/usr/bin/env python3
"""Offline unit tests: the deterministic pagination rule, and the tracked
product's independence from the untracked cache.

Run: python3 test_page92.py
"""

import contextlib
import io
import json
import pathlib
import shutil
import tempfile

import sys

# page92.py lives in bin/ so that glane(1) and accroche(1) front it from one
# place. This test sits in test/, so bin/ has to be on the path explicitly --
# without it the import fails at collection and the pagination rule, which is
# the one thing here that is a stated promise rather than an implementation
# detail, goes untested while the suite still reports a result.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "bin"))

import page92


def synthetic_book(n_lines, with_boilerplate=True):
    body = "\n".join(f"line {i}" for i in range(1, n_lines + 1))
    if not with_boilerplate:
        return body
    return (
        "junk preamble\n*** START OF THE PROJECT GUTENBERG EBOOK TEST ***\n"
        + body
        + "\n*** END OF THE PROJECT GUTENBERG EBOOK TEST ***\nlicense junk"
    )


@contextlib.contextmanager
def sandbox():
    """Point page92's dirs at a temp tree so extract/gallery can run offline."""
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="page92-test-"))
    saved = (page92.CACHE, page92.PAGES, page92.GALLERY, page92.MANIFEST)
    page92.CACHE, page92.PAGES = tmp / "cache", tmp / "pages"
    page92.GALLERY, page92.MANIFEST = tmp / "gallery", tmp / "pages" / "manifest.json"
    page92.CACHE.mkdir()
    try:
        yield tmp
    finally:
        page92.CACHE, page92.PAGES, page92.GALLERY, page92.MANIFEST = saved
        shutil.rmtree(tmp, ignore_errors=True)


def seed_book(slug, n_lines, title, author, source):
    (page92.CACHE / f"{slug}.txt").write_text(synthetic_book(n_lines))
    (page92.CACHE / f"{slug}.json").write_text(json.dumps(
        {"id": 1, "title": title, "author": author, "source": source}))


def quiet(fn):
    """Run fn with stdout captured -- these commands are chatty by design."""
    with contextlib.redirect_stdout(io.StringIO()) as out:
        fn()
    return out.getvalue()


def test_product_survives_cache_loss():
    """The regression this manifest exists for: cache/ is gitignored, so a
    fresh clone running `gallery` must still render titles and source links."""
    with sandbox():
        seed_book("pg1-long-book", 5000, "A Long Book", "Someone", "https://x/1.txt")
        seed_book("pg2-short-book", 100, "A Short Book", "Nobody", "https://x/2.txt")
        quiet(page92.cmd_extract)

        manifest = json.loads(page92.MANIFEST.read_text())
        assert [e["file"] for e in manifest["pages"]] == ["pg1-long-book-p92.txt"]
        assert [e["title"] for e in manifest["skipped"]] == ["A Short Book"]

        # Simulate the fresh clone: pages/ + manifest tracked, cache/ absent.
        shutil.rmtree(page92.CACHE)
        quiet(page92.cmd_gallery)
        page = (page92.GALLERY / "index.html").read_text()

    assert "A Long Book" in page, "title lost when cache/ is absent"
    assert "https://x/1.txt" in page, "source link lost when cache/ is absent"
    assert "no manifest entry" not in page, "page 92 was not matched to its entry"
    # A fetched book with no page 92 is disclosed, not silently dropped.
    assert "A Short Book" in page and "too short" in page, "skip not disclosed"


def test_manifest_carries_forward_and_prunes():
    """A run against a partial cache keeps metadata for pages still on disk,
    and forgets pages that are gone."""
    with sandbox():
        seed_book("pg1-first", 5000, "First", "A", "https://x/1.txt")
        seed_book("pg2-second", 5000, "Second", "B", "https://x/2.txt")
        quiet(page92.cmd_extract)

        # Next run sees only one book cached, and one page file was removed.
        (page92.CACHE / "pg2-second.txt").unlink()
        (page92.CACHE / "pg2-second.json").unlink()
        seed_book("pg3-third", 5000, "Third", "C", "https://x/3.txt")
        quiet(page92.cmd_extract)

        titles = {e["title"] for e in json.loads(page92.MANIFEST.read_text())["pages"]}
        assert titles == {"First", "Second", "Third"}, titles

        (page92.PAGES / "pg2-second-p92.txt").unlink()
        quiet(page92.cmd_extract)
        titles = {e["title"] for e in json.loads(page92.MANIFEST.read_text())["pages"]}
        assert titles == {"First", "Third"}, titles


def test_partial_page_is_labelled():
    """A book ending mid-page-92 is shown with its true, shorter line range."""
    with sandbox():
        n = (page92.PAGE_NUMBER - 1) * page92.LINES_PER_PAGE + 5
        seed_book("pg1-stub", n, "Stub", "A", "https://x/1.txt")
        quiet(page92.cmd_extract)
        entry = json.loads(page92.MANIFEST.read_text())["pages"][0]
        assert entry["lines"] == 5, entry
        quiet(page92.cmd_gallery)
        page = (page92.GALLERY / "index.html").read_text()
    lo, _ = page92.page_line_range()
    assert f"lines {lo}–{lo + 4} — the book ends mid-page" in page, page[:400]


def test_print_density_control():
    """The sheet-density switch exists, defaults to 1-per-sheet, is CSS-only
    (no script), and is screen chrome that never prints."""
    with sandbox():
        seed_book("pg1-long-book", 5000, "A Long Book", "Someone", "https://x/1.txt")
        quiet(page92.cmd_extract)
        quiet(page92.cmd_gallery)
        page = (page92.GALLERY / "index.html").read_text()

    for d in ("d1", "d2", "d4"):
        assert f'id="{d}"' in page, f"no {d} density radio"
        assert f"#{d}:checked ~ main figure" in page, f"{d} radio drives nothing"
    assert 'id="d1" checked' in page, "default is not one page 92 per sheet"
    # Both regressions found by actually printing to PDF and counting sheets:
    # a flex main fragments one figure per sheet (2-up silently became 1-up),
    # and an unqualified last-of-type rule loses to the id selectors above it,
    # leaving a blank final sheet. Sheet counts verified 18/9/5 for 18 pages.
    print_css = page[page.index("@media print"):]
    assert "display: flex" not in print_css, "print main went back to flex"
    for d in ("d1", "d2", "d4"):
        assert f"#{d}:checked ~ main figure:last-of-type" in print_css, \
            f"{d} would print a trailing blank sheet"
    # Arranging is never automated: the switch changes ink, never order.
    assert "<script" not in page and "onclick" not in page, "gallery grew script"
    assert "h1, p, .skipped, .sheets { display: none; }" in page, \
        "density control would print as chrome"


def test_author_reads_as_a_byline():
    """Catalogue order is filing apparatus; the wall shows a readable byline.
    The manifest still carries the archive's own string verbatim."""
    cases = {
        "Shakespeare, William": "William Shakespeare",
        "Forster, E. M. (Edward Morgan)": "E. M. Forster",
        "Mérimée, Prosper": "Prosper Mérimée",
        "Alcott, Louisa May": "Louisa May Alcott",
        "Twain, Mark, 1835-1910": "Mark Twain",
        # Not personal-name shaped -- left exactly as the archive said it.
        "unknown": "unknown",
        "Homer": "Homer",
        "United States. War Department": "United States. War Department",
        "": "",
        None: None,
    }
    for raw, want in cases.items():
        got = page92.display_author(raw)
        assert got == want, f"{raw!r} -> {got!r}, wanted {want!r}"

    with sandbox():
        seed_book("pg1-b", 5000, "A Book", "Shakespeare, William", "https://x/1.txt")
        # A too-short book lands in the skipped list, which has its own byline.
        seed_book("pg2-s", 100, "A Short Book", "Mérimée, Prosper", "https://x/2.txt")
        quiet(page92.cmd_extract)
        quiet(page92.cmd_gallery)
        page = (page92.GALLERY / "index.html").read_text()
        manifest = json.loads(page92.MANIFEST.read_text())

    assert "William Shakespeare" in page, "card byline still in catalogue order"
    assert "Shakespeare, William" not in page, "card byline shows raw catalogue form"
    assert "Prosper Mérimée" in page, "skipped-book byline still in catalogue order"
    assert manifest["pages"][0]["author"] == "Shakespeare, William", \
        "manifest lost the archive's verbatim author string"


def main():
    lp, pn = page92.LINES_PER_PAGE, page92.PAGE_NUMBER

    # Page 92 starts at line (92-1)*38 + 1 = 3459 (1-indexed), 38 lines long.
    text = synthetic_book(5000)
    lines = page92.page_lines(text)
    assert lines[0] == f"line {(pn - 1) * lp + 1}", lines[0]
    assert len(lines) == lp, len(lines)

    # Deterministic: same input, same page.
    assert page92.page_lines(text) == lines

    # Boilerplate stripping changes nothing about the rule's origin line.
    assert page92.page_lines(synthetic_book(5000, with_boilerplate=False))[0] == lines[0]

    # Too short -> None, not a crash and not a partial lie.
    assert page92.page_lines(synthetic_book(100)) is None

    # A book ending mid-page-92 yields the partial page.
    partial = page92.page_lines(synthetic_book((pn - 1) * lp + 5))
    assert partial is not None and len(partial) == 5, partial

    print("ok: pagination rule")

    test_product_survives_cache_loss()
    print("ok: product survives cache loss (title + source from manifest)")
    test_manifest_carries_forward_and_prunes()
    print("ok: manifest carries forward across partial caches, prunes gone pages")
    test_partial_page_is_labelled()
    print("ok: partial page labelled with its true line range")
    test_print_density_control()
    print("ok: print density switch is CSS-only, 1-per-sheet default, never printed")
    test_author_reads_as_a_byline()
    print("ok: bylines read naturally; manifest keeps the archive's own string")


if __name__ == "__main__":
    main()
