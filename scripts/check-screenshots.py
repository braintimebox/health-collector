#!/usr/bin/env python3
"""Assert that a screenshot really shows the tab it is named after.

Why this exists
---------------
The first version of the capture job ran green while all three files held the same
Export screen: `simctl openurl` delivered nothing, and the only assertion was "the
files differ". That assertion is the wrong statement — three captures taken across a
minute boundary differ by their clock while showing one screen. What has to be proven
is that the selected tab *changed*, so this reads the tab bar and asks which third of
it carries the accent colour.

No third-party modules: PNG is decoded here (8-bit, non-interlaced — what `simctl io
screenshot` writes), so the same code runs on the macOS runner and on a Linux box.
`sips`/Pillow would have made the guard unverifiable where it was written.

Exit codes: 0 all tabs correct, 1 a screenshot does not match its tab, 2 cannot check.
"""
from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path

# iOS accent blue, as rendered by the system tab bar: distinctly blue, not too dark,
# not cyan. The tolerance is wide because the screenshot carries the label glyphs too.
def is_accent(r: int, g: int, b: int) -> bool:
    return b > 170 and r < 130 and 70 < g < 200 and (b - r) > 80


def read_png(path: Path) -> tuple[int, int, list[list[tuple[int, int, int]]]]:
    """Decode an 8-bit PNG into rows of RGB tuples."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path.name}: не PNG")
    pos = 8
    width = height = depth = colour_type = None
    idat = bytearray()
    while pos < len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        kind = data[pos + 4 : pos + 8]
        payload = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, colour_type, _comp, _filt, interlace = struct.unpack(">IIBBBBB", payload)
            if depth != 8 or interlace != 0 or colour_type not in (2, 6):
                raise ValueError(
                    f"{path.name}: поддерживается только 8-бит RGB/RGBA без интерлейса "
                    f"(depth={depth}, type={colour_type}, interlace={interlace})"
                )
        elif kind == b"IDAT":
            idat += payload
        elif kind == b"IEND":
            break
    if width is None or height is None:
        raise ValueError(f"{path.name}: нет IHDR")

    channels = 4 if colour_type == 6 else 3
    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    rows: list[list[tuple[int, int, int]]] = []
    previous = bytearray(stride)
    offset = 0
    for _ in range(height):
        filter_type = raw[offset]
        offset += 1
        line = bytearray(raw[offset : offset + stride])
        offset += stride
        if filter_type == 1:  # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filter_type == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filter_type == 3:  # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filter_type == 4:  # Paeth
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = previous[i]
                c = previous[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        elif filter_type != 0:
            raise ValueError(f"{path.name}: неизвестный фильтр {filter_type}")
        rows.append(
            [(line[i], line[i + 1], line[i + 2]) for i in range(0, stride, channels)]
        )
        previous = line
    return width, height, rows


# The glyph row of the tab bar only. Measured on real captures (1206x2622): accent
# pixels live 221..98 px above the bottom edge, i.e. 8.4%..3.7% of the height. The
# previous band was the bottom 187 px, which also covered the home-indicator area and
# reached above the bar — so an accent-coloured block in the content (and in dark mode
# the content really does show through) could be counted as the selected tab.
BAND_TOP = 0.096
BAND_BOTTOM = 0.034


def band_rows(height: int) -> tuple[int, int]:
    return int(height * (1 - BAND_TOP)), int(height * (1 - BAND_BOTTOM))


# The tab bar is a compact centred cluster, not a uniform W/6, W/2, 5W/6 grid: on a
# 1206-px capture the item centres sit at 346 / 603 / 861, i.e. 0.287 / 0.500 / 0.714
# of the width, with a step of 257 px between neighbours. A third-based rule worked
# only because those centres happen to fall inside their thirds, with 56 px to spare —
# the narrowest margin in the whole scheme, and the first thing a different screen
# width or a wider panel would break. Positions are therefore taken from the measured
# layout, and the tolerance is half a step, which is the largest value that still
# cannot confuse two neighbouring tabs.
EXPECTED_CENTRE = {"export": 0.2869, "browse": 0.5, "settings": 0.7140}
CENTRE_TOLERANCE = 0.107
# Measured cluster widths are 93..121 px of 1206 (0.077..0.100); the ceiling leaves
# room for a wider label without accepting a block that spans the bar.
MAX_CLUSTER_WIDTH = 0.12
GAP_MERGE_PX = 12

def accent_columns(rows: list[list[tuple[int, int, int]]], width: int, height: int) -> list[int]:
    """How many accent pixels each column has inside the glyph row."""
    top, bottom = band_rows(height)
    columns = [0] * width
    for y in range(top, bottom):
        for x, (r, g, b) in enumerate(rows[y]):
            if is_accent(r, g, b):
                columns[x] += 1
    return columns


def accent_clusters(columns: list[int], gap: int = GAP_MERGE_PX) -> list[tuple[int, int]]:
    """Contiguous runs of columns carrying accent, merged across glyph gaps."""
    runs: list[tuple[int, int]] = []
    start: int | None = None
    last = -gap
    for x, count in enumerate(columns):
        if count == 0:
            continue
        if start is None:
            start = x
        elif x - last > gap:
            runs.append((start, last))
            start = x
        last = x
    if start is not None:
        runs.append((start, last))
    return runs


def accent_outside_band(rows: list[list[tuple[int, int, int]]], height: int) -> int:
    """Accent pixels outside the glyph row — a signal, not a verdict."""
    top, _ = band_rows(height)
    total = 0
    for y in range(0, top):
        for (r, g, b) in rows[y]:
            if is_accent(r, g, b):
                total += 1
    return total


EXPECTED_TAB = {
    "export": "export",
    "browse": "browse",
    "settings": "settings",
    # A pushed screen keeps the tab bar visible, so a nested capture is checked against
    # the tab that owns it.
    "server": "export",
    "advanced": "settings",
}


def expected_tab(stem: str) -> str | None:
    """`dark-export.png` is the same screen captured in the other appearance."""
    return EXPECTED_TAB.get(stem.removeprefix("dark-"))


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: check-screenshots.py <dir>", file=sys.stderr)
        return 2
    directory = Path(argv[1])
    files = sorted(directory.glob("*.png"))
    if not files:
        print(f"нет снимков в {directory}", file=sys.stderr)
        return 2

    failures = 0
    seen: dict[str, str] = {}
    for path in files:
        expected = expected_tab(path.stem)
        if expected is None:
            print(f"WARN: {path.name} не из известных вкладок — проверять нечего")
            continue
        try:
            width, height, rows = read_png(path)
        except Exception as exc:  # noqa: BLE001 - unreadable is not clean
            print(f"UNKNOWN: {path.name}: {exc}", file=sys.stderr)
            return 2

        runs = accent_clusters(accent_columns(rows, width, height))
        if not runs:
            outside = accent_outside_band(rows, height)
            if outside:
                print(
                    f"UNKNOWN: {path.name}: в строке глифов акцента нет, а вне её {outside} px — "
                    "полоса не совпадает с вёрсткой панели",
                    file=sys.stderr,
                )
                return 2
            print(f"FAIL: {path.name}: панели вкладок не найдено — снят другой экран?", file=sys.stderr)
            failures += 1
            continue

        if len(runs) > 1:
            print(f"FAIL: {path.name}: в строке глифов {len(runs)} акцентных кластеров {runs}")
            failures += 1
            continue

        left, right = runs[0]
        span = right - left + 1
        if span / width > MAX_CLUSTER_WIDTH:
            print(
                f"FAIL: {path.name}: кластер шириной {span} px ({span / width:.0%} ширины) — "
                "это не пункт панели"
            )
            failures += 1
            continue

        centre = (left + right) / 2 / width
        nearest = min(EXPECTED_CENTRE, key=lambda tab: abs(EXPECTED_CENTRE[tab] - centre))
        delta = abs(EXPECTED_CENTRE[nearest] - centre)
        seen[path.stem] = nearest
        outside = accent_outside_band(rows, height)
        ok = nearest == expected and delta <= CENTRE_TOLERANCE
        print(
            f"{'ok  ' if ok else 'FAIL'} {path.stem:14s} кластер x={left}..{right} "
            f"({span} px), центр {centre:.3f} → ближайшая {nearest} (Δ{delta:.3f})"
            + (f", акцент вне полосы {outside} px" if outside else "")
        )
        if not ok:
            failures += 1

    winners = list(seen.values())
    if len(winners) == len(seen) and len(set(winners)) != len(seen):
        print(f"FAIL: разные файлы показывают одну и ту же вкладку: {winners}")
        failures += 1

    if failures:
        print(f"ИТОГ: FAIL ({failures})")
        return 1
    print(f"ИТОГ: OK — {len(seen)} снимков, каждый на своей вкладке")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
