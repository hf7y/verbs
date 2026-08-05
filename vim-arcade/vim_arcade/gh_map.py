"""Tile map for joue's zoom-out view (issue #39: one launcher, two zoom
levels). Pure data/layout functions, no curses -- gh_game.py owns
drawing and the one event loop that dispatches every key, exactly the
same split gh_triage.py (data) / gh_game.py (loop) already uses. Keeping
this curses-free is what makes it directly unit-testable.

Reuses discovery.py's discover_items()/is_pink() for what repos exist and
which owner is pink (#17) -- this module only shapes that into tiles and
lays them out on screen with paging.

Why tiles, not miniature walkable levels (decided 2026-08-04, recorded
so it isn't re-litigated): at 80x24 a single-repo pane was measured at 6
rows (5 usable) while hf7y/ecosim's own level is 23 rows and
dcp-gate-site's is 20 -- a 5-row porthole onto a 20+ item queue. A tile
trades the walkable grid for a name + open count + a compact
fresh/replied/draft symbol summary, and drops item-level actions
entirely (#39: "you cannot safely press x on something you cannot
read") -- zooming into a tile hands off to the exact same single-repo
view/event loop gh_game.py already runs for the no-arg case, so there is
still only ONE place any action key is dispatched.
"""

import math
from dataclasses import dataclass, field
from typing import Dict, List, Optional

from .discovery import is_pink
from .gh_triage import TriageItem

# Chrome reserved outside the tile grid -- fixed COUNT of rows, never a
# fixed absolute row offset (that discipline is what issue #8's crash
# was missing).
HEADER_ROWS = 2  # title, page/count line
STATUS_ROWS = 1  # message line
FOOTER_ROWS = 1  # "Q to quit" row

# A tile's box: name row + counts row, one blank separator row below.
TILE_W = 26  # wide enough for "media-arts-collective/xxxxxxxx" to be legible
TILE_H = 3


@dataclass
class MapTile:
    repo: str
    total: int
    fresh: int
    replied: int
    draft: int
    pink: bool


def build_tiles(by_repo: Dict[str, List[TriageItem]]) -> List[MapTile]:
    """One tile per repo with open items -- reuses discover_items()'s own
    convention (#17: a repo with zero open items has no key in by_repo,
    so there is nothing here to build a tile for). Tile order follows
    by_repo's own (sorted) order, so paging is stable across renders.

    Buckets by KIND first -- a draft PR is always counted 'draft'
    regardless of reply state -- then by reply state for everything
    else. This is the three-way split issue #39 names ("how many fresh
    / replied / draft"), a coarser view than the per-letter symbol table
    gh_triage.symbol_for uses for an individual item row; it is not
    meant to replace that table, only to summarize it at a glance."""
    tiles = []
    for repo, items in by_repo.items():
        fresh = replied = draft = 0
        for item in items:
            if item.kind == "pr" and item.is_draft:
                draft += 1
            elif (
                item.last_comment_by
                and item.viewer_login
                and item.last_comment_by == item.viewer_login
            ):
                replied += 1
            else:
                fresh += 1
        tiles.append(
            MapTile(
                repo=repo, total=len(items), fresh=fresh, replied=replied,
                draft=draft, pink=is_pink(repo),
            )
        )
    return tiles


@dataclass
class MapState:
    """The map's own state: the live discovery snapshot (by_repo) and
    which tile has focus. Deliberately does NOT store a page number --
    the page is always derived from focus // per_page at render/input
    time (see current_page below), so it can never drift out of sync
    with focus the way two independently-tracked numbers could. Not
    touching `focus` anywhere except an explicit move/page/refresh is
    what makes 'returning from a tile lands back on the map with the
    same page and focus' (#39) true by construction: zooming into a
    tile and back out never runs any of those, so focus (and therefore
    the derived page) survives the round trip untouched."""

    by_repo: Dict[str, List[TriageItem]] = field(default_factory=dict)
    focus: int = 0

    @property
    def tiles(self) -> List[MapTile]:
        return build_tiles(self.by_repo)


def compute_map_layout(n_tiles: int, height: int, width: int) -> dict:
    """Pure function of (how many tiles exist, terminal size) -- same
    no-fixed-absolute-offsets discipline as gh_game.compute_layout and
    the old gh_multipane.compute_pane_grid (#8)."""
    quit_row = max(0, height - 1)
    top_fixed = HEADER_ROWS + STATUS_ROWS
    # Tiles occupy rows [top_fixed, quit_row) -- FOOTER_ROWS is already
    # accounted for by quit_row itself being the last row.
    available = max(0, quit_row - top_fixed)
    cols = max(1, width // TILE_W)
    rows = max(1, available // TILE_H)
    per_page = max(1, cols * rows)
    page_count = max(1, math.ceil(n_tiles / per_page)) if n_tiles else 1
    return {
        "quit_row": quit_row,
        "status_row": HEADER_ROWS,
        "grid_top": top_fixed,
        "available_h": available,
        "cols": cols,
        "rows": rows,
        "per_page": per_page,
        "page_count": page_count,
        "tile_w": TILE_W,
        "tile_h": TILE_H,
    }


def tile_rect(slot_index: int, layout: dict):
    """Screen rect (top, left, width, height) for the slot_index-th tile
    box on the current page (row-major: left to right, then next row)."""
    r, c = divmod(slot_index, layout["cols"])
    top = layout["grid_top"] + r * layout["tile_h"]
    left = c * layout["tile_w"]
    return top, left, layout["tile_w"], layout["tile_h"]


def current_page(focus: int, layout: dict) -> int:
    per_page = layout["per_page"]
    return (focus // per_page) if per_page else 0


def move_focus(state: MapState, direction: str, layout: dict) -> None:
    """Move focus to the tile in `direction` ("h"/"j"/"k"/"l") among the
    tiles visible on the CURRENT page. Moving toward a slot with no tile
    (edge of the grid, or past the end of the tile list) is a no-op --
    same convention the old pane world used for 'target doesn't exist
    yet.' Never crosses a page boundary as a side effect (see
    next_page/prev_page for that)."""
    tiles = state.tiles
    per_page = layout["per_page"]
    cols = layout["cols"]
    page = current_page(state.focus, layout)
    page_start = page * per_page
    page_tiles = len(tiles) - page_start
    if page_tiles <= 0:
        return
    page_tiles = min(page_tiles, per_page)

    slot = (state.focus - page_start) % per_page if per_page else 0
    r, c = divmod(slot, cols)
    if direction == "h":
        c -= 1
    elif direction == "l":
        c += 1
    elif direction == "k":
        r -= 1
    elif direction == "j":
        r += 1
    if r < 0 or c < 0 or c >= cols:
        return
    target_slot = r * cols + c
    if target_slot >= page_tiles:
        return
    state.focus = page_start + target_slot


def next_page(state: MapState, layout: dict) -> None:
    per_page = layout["per_page"]
    page = current_page(state.focus, layout)
    if page + 1 < layout["page_count"]:
        state.focus = (page + 1) * per_page


def prev_page(state: MapState, layout: dict) -> None:
    per_page = layout["per_page"]
    page = current_page(state.focus, layout)
    if page > 0:
        state.focus = (page - 1) * per_page


def focused_tile(state: MapState) -> Optional[MapTile]:
    tiles = state.tiles
    if 0 <= state.focus < len(tiles):
        return tiles[state.focus]
    return None


def focus_on_repo(state: MapState, repo: Optional[str]) -> None:
    """Point focus at `repo`'s tile if it has one; otherwise park at 0.
    Used on the map's first build (so the repo joue was launched in
    starts highlighted) and after an explicit refresh (so a manual `r`
    tries to keep looking at the same repo -- same convention the old
    pane world's own `r` handler used)."""
    if repo:
        for i, t in enumerate(state.tiles):
            if t.repo == repo:
                state.focus = i
                return
    state.focus = 0
