#!/usr/bin/env python3
"""Assert that a screenshot really shows the tab it is named after.

Why this exists
---------------
The first version of the capture job ran green while all three files held the same
Export screen: `simctl openurl` delivered nothing, and the only assertion was "the
files differ". That assertion is the wrong statement — three captures taken across a
minute boundary differ by their clock while showing one screen. What has to be proven
is that the selected tab *changed*, so this reads the tab bar and asks where the accent
colour sits, comparing the position with the tab the file is named after.

Two things are checked besides the tab itself, because both have already gone wrong:

- a dark-pass capture is first proven to be *dark*: "no accent found" and "the app was
  never in dark mode" look identical in pixels, and reporting the second as the first
  hides a capture defect behind a rendering excuse;
- the "different files show different tabs" rule applies inside a pass, not across
  them: `export.png` and `dark-export.png` legitimately show the same tab.

No third-party modules: PNG is decoded here (8-bit, non-interlaced — what `simctl io
screenshot` writes), so the same code runs on the macOS runner and on a Linux box.

Exit codes: 0 all tabs correct, 1 a screenshot does not match its tab, 2 cannot check.
"""
from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path


def is_accent(r: int, g: int, b: int) -> bool:
    """iOS accent blue, as rendered by the system tab bar.

    Wide enough for the label glyphs, tight enough to reject the unselected grey
    (#8E8E93, whose blue channel is 147).
    """
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
        rows.append([(line[i], line[i + 1], line[i + 2]) for i in range(0, stride, channels)])
        previous = line
    return width, height, rows


# The glyph row of the tab bar only. Measured on real captures (1206x2622): accent
# pixels live 221..98 px above the bottom edge, i.e. 8.4%..3.7% of the height. A wider
# band also covered the home indicator and the content above the bar — and in dark mode
# the content really does show through the translucent bar.
BAND_TOP = 0.096
BAND_BOTTOM = 0.034


def band_rows(height: int) -> tuple[int, int]:
    return int(height * (1 - BAND_TOP)), int(height * (1 - BAND_BOTTOM))


# The tab bar is a compact centred cluster, not a uniform W/6, W/2, 5W/6 grid: on a
# 1206-px capture the item centres sit at 346 / 603 / 861, i.e. 0.287 / 0.500 / 0.714 of
# the width, with a 257-px step. A third-based rule worked only because those centres
# happen to fall inside their thirds with 56 px to spare — the narrowest margin in the
# scheme, and the first thing a different width or a wider panel breaks.
EXPECTED_CENTRE = {"export": 0.2869, "browse": 0.5, "settings": 0.7140}
CENTRE_TOLERANCE = 0.107

# Measured cluster widths are 93..121 px of 1206 (0.077..0.100); the ceiling leaves room
# for a wider label without accepting a block that spans the bar.
MAX_CLUSTER_WIDTH = 0.12
GAP_MERGE_PX = 12

EXPECTED_TAB = {
    "export": "export",
    "browse": "browse",
    "settings": "settings",
    # A pushed screen keeps the tab bar visible, so a nested capture is checked against
    # the tab that owns it.
    "server": "export",
    "advanced": "settings",
    # Workouts and Sleep are pushed from Browse.
    "workouts": "browse",
    "sleep": "browse",
    # Every Settings sub-screen keeps the tab bar; each is a push under Settings.
    "settings-permissions": "settings",
    "settings-export": "settings",
    "settings-units": "settings",
    "settings-notifications": "settings",
    "settings-about": "settings",
}

DARK_LUMINANCE = 0.45


def expected_tab(stem: str) -> str | None:
    """`dark-export.png` is the same screen captured in the other appearance."""
    return EXPECTED_TAB.get(stem.removeprefix("dark-"))


def group_of(stem: str) -> str:
    """Which pass a capture belongs to. Duplicate-tab checks apply inside a pass."""
    base = stem.removeprefix("dark-")
    if base in ("server", "advanced", "workouts", "sleep") or base.startswith("settings-"):
        return "nested"
    return "dark" if stem.startswith("dark-") else "light"


def mean_luminance(rows: list[list[tuple[int, int, int]]], width: int, height: int) -> float:
    """Luminance of the content area, away from the tab bar and the status bar."""
    top, bottom = int(height * 0.12), int(height * 0.45)
    total = 0.0
    samples = 0
    for y in range(top, bottom, 4):
        row = rows[y]
        for x in range(0, width, 8):
            r, g, b = row[x]
            total += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
            samples += 1
    return total / samples if samples else 0.0


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
    """Accent pixels outside the glyph row — a signal, not a verdict.

    A legitimate screen has accent buttons and icons in its content, so this number
    cannot gate a pass; it is printed so a changing number is visible.
    """
    top, _ = band_rows(height)
    total = 0
    for y in range(0, top):
        for (r, g, b) in rows[y]:
            if is_accent(r, g, b):
                total += 1
    return total


def check_one(path: Path, expected: str) -> tuple[str, str | None, int]:
    """Return (verdict, tab-or-None, exit-hint). verdict ∈ ok|FAIL|UNKNOWN."""
    width, height, rows = read_png(path)
    group = group_of(path.stem)
    dark = mean_luminance(rows, width, height) < DARK_LUMINANCE

    if group == "dark" and not dark:
        return (
            f"FAIL: {path.name}: снимок светлый (яркость {mean_luminance(rows, width, height):.2f}), "
            "хотя назван тёмным — тема не применилась при запуске",
            None,
            1,
        )
    if group == "light" and dark:
        print(f"WARN: {path.name}: снимок тёмный, хотя проход светлый — проверь simctl ui appearance")
    if group == "dark":
        print(f"     {path.name}: тёмная тема подтверждена (яркость {mean_luminance(rows, width, height):.2f})")

    runs = accent_clusters(accent_columns(rows, width, height))
    if not runs:
        outside = accent_outside_band(rows, height)
        if group == "dark":
            # In dark mode the bar is translucent: a missing accent here is either a
            # changed band or a rendering we have never measured. Saying "wrong screen"
            # would hide that difference behind a confident verdict.
            return (
                f"UNKNOWN: {path.name}: тёмный кадр, но в строке глифов акцента нет "
                f"(вне полосы {outside} px) — полоса или рендер тёмной панели не подтверждены",
                None,
                2,
            )
        if outside:
            return (
                f"UNKNOWN: {path.name}: в строке глифов акцента нет, а вне её {outside} px — "
                "полоса не совпадает с вёрсткой панели",
                None,
                2,
            )
        return (f"FAIL: {path.name}: панели вкладок не найдено — снят другой экран?", None, 1)

    if len(runs) > 1:
        return (f"FAIL: {path.name}: в строке глифов {len(runs)} акцентных кластеров {runs}", None, 1)

    left, right = runs[0]
    span = right - left + 1
    if span / width > MAX_CLUSTER_WIDTH:
        return (
            f"FAIL: {path.name}: кластер шириной {span} px ({span / width:.0%} ширины) — "
            "это не пункт панели",
            None,
            1,
        )

    centre = (left + right) / 2 / width
    nearest = min(EXPECTED_CENTRE, key=lambda tab: abs(EXPECTED_CENTRE[tab] - centre))
    delta = abs(EXPECTED_CENTRE[nearest] - centre)
    outside = accent_outside_band(rows, height)
    detail = (
        f"кластер x={left}..{right} ({span} px), центр {centre:.3f} → ближайшая {nearest} "
        f"(Δ{delta:.3f})" + (f", акцент вне полосы {outside} px" if outside else "")
    )
    if nearest != expected or delta > CENTRE_TOLERANCE:
        return (f"FAIL: {path.name}: {detail}; ожидалась {expected}", nearest, 1)
    return (f"ok: {path.name}: {detail}", nearest, 0)


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
    unknown = 0
    seen: dict[str, list[str]] = {}
    for path in files:
        expected = expected_tab(path.stem)
        if expected is None:
            print(f"WARN: {path.name} не из известных вкладок — проверять нечего")
            continue
        try:
            message, tab, hint = check_one(path, expected)
        except Exception as exc:  # noqa: BLE001 - unreadable is not clean
            print(f"UNKNOWN: {path.name}: {exc}", file=sys.stderr)
            return 2
        print(message)
        if hint == 2:
            unknown += 1
        elif hint == 1:
            failures += 1
        if tab:
            seen.setdefault(group_of(path.stem), []).append(tab)

    for group, tabs in sorted(seen.items()):
        # Only the tab-root captures make the claim "three files, three tabs". A nested
        # screen is a push on top of some tab, and two of them legitimately share one:
        # Workouts and Sleep are both under Browse. Applying the rule here produced a
        # false failure on the first run that had more than one nested screen per tab.
        if group == "nested":
            continue
        if len(tabs) > 1 and len(set(tabs)) != len(tabs):
            print(f"FAIL: проход {group}: разные файлы показывают одну и ту же вкладку: {tabs}")
            failures += 1

    if unknown:
        print(f"ИТОГ: UNKNOWN ({unknown}) — проверка не выполнена до конца")
        return 2
    if failures:
        print(f"ИТОГ: FAIL ({failures})")
        return 1
    total = sum(len(t) for t in seen.values())
    print(f"ИТОГ: OK — {total} снимков, каждый на своей вкладке")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
