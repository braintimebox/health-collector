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


def accent_thirds(rows: list[list[tuple[int, int, int]]], width: int, height: int) -> list[int]:
    """Count accent pixels per horizontal third of the tab bar's glyph row."""
    top, bottom = band_rows(height)
    thirds = [0, 0, 0]
    for y in range(top, bottom):
        for x, (r, g, b) in enumerate(rows[y]):
            if is_accent(r, g, b):
                thirds[min(2, x * 3 // width)] += 1
    return thirds


def accent_anywhere(rows: list[list[tuple[int, int, int]]], width: int, height: int) -> int:
    """Accent pixels in the whole frame — used to tell "wrong screen" from "wrong band"."""
    top, _ = band_rows(height)
    total = 0
    for y in range(0, top):
        for (r, g, b) in rows[y]:
            if is_accent(r, g, b):
                total += 1
    return total


# The tab bar stays visible under a pushed screen, so a nested capture is checked
# against the tab that owns it: Server lives under Export, Advanced under Settings.
EXPECTED = {
    "export": 0, "browse": 1, "settings": 2,
    "server": 0, "advanced": 2,
}


def expected_third(stem: str) -> int | None:
    """`dark-export.png` is the same screen, captured in the other appearance."""
    return EXPECTED.get(stem.removeprefix("dark-"))


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
    seen: dict[str, list[int]] = {}
    for path in files:
        expected = expected_third(path.stem)
        if expected is None:
            print(f"WARN: {path.name} не из известных вкладок — проверять нечего")
            continue
        try:
            width, height, rows = read_png(path)
        except Exception as exc:  # noqa: BLE001 - unreadable is not clean
            print(f"UNKNOWN: {path.name}: {exc}", file=sys.stderr)
            return 2
        thirds = accent_thirds(rows, width, height)
        seen[path.stem] = thirds
        total = sum(thirds)
        if total == 0:
            # Three states, not two: a band with nothing in it means the checker is
            # looking in the wrong place (or the capture is not this app at all), and
            # reporting that as a pass is how a guard starts lying.
            outside = accent_anywhere(rows, width, height)
            if outside:
                print(
                    f"UNKNOWN: {path.name}: в полосе глифов акцента нет, а вне её {outside} px — "
                    "полоса не совпадает с вёрсткой панели",
                    file=sys.stderr,
                )
                return 2
            print(f"FAIL: {path.name}: панели вкладок не найдено — снят другой экран?", file=sys.stderr)
            failures += 1
            continue
        winner = thirds.index(max(thirds))
        share = (max(thirds) / total) if total else 0.0
        ok = winner == expected and share >= 0.5
        verdict = "ok  " if ok else "FAIL"
        names = ["export", "browse", "settings"]
        print(
            f"{verdict} {path.stem:14s} акцент по третям: {thirds} — ожидалась треть "
            f"{expected} ({names[expected]}), доля {share:.0%}"
        )
        if not ok:
            failures += 1

    # The three captures must land on three different tabs, otherwise one of them is
    # a duplicate that happened to pass its own check.
    winners = [thirds.index(max(thirds)) for thirds in seen.values() if sum(thirds)]
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
