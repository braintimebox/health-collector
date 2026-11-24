#!/usr/bin/env python3
"""Prove `check-screenshots.py` still fails when a screenshot is wrong.

Why this exists
---------------
The guard's controls lived in chat: hand-built sets in a scratch directory, made from
real captures. That proves the guard for an afternoon — the next edit can turn every
verdict into "ok" and nothing in the repository would notice.

These fixtures are synthetic and generated here, so the suite runs without network, CI
artifacts or a simulator. Each case is one deliberate lie, and three of them are aimed at
the guard's *settings* (band height, cluster width, "exactly one cluster") rather than
its behaviour: weakening those settings has to fail here too, otherwise a green suite
keeps meaning "the code ran" instead of "the check holds".

Usage: test-check-screenshots.py [path/to/check-screenshots.py]

Exit codes: 0 all cases behave, 1 a case produced the wrong verdict, 2 cannot run.
"""
from __future__ import annotations

import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_CHECKER = HERE / "check-screenshots.py"

WIDTH, HEIGHT = 402, 874  # 1x points, same proportions as the 3x captures
LIGHT_BG = (242, 242, 247)
DARK_BG = (28, 28, 30)
DIM = (142, 142, 147)
ACCENT_LIGHT = (0, 122, 255)
ACCENT_DARK = (10, 132, 255)
# Measured on real captures: 0.287 / 0.500 / 0.714 of the width.
CENTRES = {"export": 0.287, "browse": 0.5, "settings": 0.714}
BAND_TOP = 0.096
BAND_BOTTOM = 0.034


def write_png(path: Path, rows: list[bytearray]) -> None:
    raw = b"".join(b"\x00" + bytes(row) for row in rows)

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 6))
        + chunk(b"IEND", b"")
    )


def paint(rows: list[bytearray], x0: int, y0: int, x1: int, y1: int, colour: tuple[int, int, int]) -> None:
    for y in range(max(0, y0), min(HEIGHT, y1)):
        for x in range(max(0, x0), min(WIDTH, x1)):
            rows[y][x * 3 : x * 3 + 3] = bytes(colour)


def frame(
    selected: str | None,
    layout: dict[str, float] | None = None,
    content_accent: bool = False,
    draw_bar: bool = True,
    dark: bool = False,
    second_cluster: bool = False,
    wide_block: bool = False,
    accent_above_band: bool = False,
) -> list[bytearray]:
    background = DARK_BG if dark else LIGHT_BG
    accent = ACCENT_DARK if dark else ACCENT_LIGHT
    rows = [bytearray(background * WIDTH) for _ in range(HEIGHT)]
    if content_accent:
        paint(rows, 20, 200, 180, 260, accent)

    top = int(HEIGHT * (1 - BAND_TOP))
    bottom = int(HEIGHT * (1 - BAND_BOTTOM))

    if accent_above_band:
        # Content showing above / through the translucent bar: just outside the band.
        paint(rows, int(WIDTH * 0.10), top - 8, int(WIDTH * 0.20), top - 2, accent)

    if wide_block:
        # One continuous block over ~40% of the width inside the glyph row.
        paint(rows, int(WIDTH * 0.30), top + 8, int(WIDTH * 0.70), bottom - 8, accent)

    if second_cluster:
        # A second accent cluster inside the glyph row, on a tab that is not selected.
        paint(rows, int(WIDTH * 0.13), top + 8, int(WIDTH * 0.17), bottom - 8, accent)

    if not draw_bar:
        return rows

    centres = layout or CENTRES
    for tab, fraction in centres.items():
        colour = accent if tab == selected else DIM
        centre = int(WIDTH * fraction)
        paint(rows, centre - 15, top + 8, centre + 15, bottom - 8, colour)
    return rows


def run(checker: Path, directory: Path) -> tuple[int, str]:
    result = subprocess.run(
        [sys.executable, str(checker), str(directory)],
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout + result.stderr


def case(
    checker: Path,
    name: str,
    shots: dict[str, list[bytearray]],
    expected_code: int,
    expected_text: str = "",
) -> bool:
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        for filename, rows in shots.items():
            write_png(directory / f"{filename}.png", rows)
        code, output = run(checker, directory)
    ok = code == expected_code and expected_text in output
    detail = "" if ok else f" (ожидался код {expected_code}, получен {code})"
    print(f"{'ok  ' if ok else 'FAIL'} {name}{detail}")
    if not ok and output:
        for line in output.strip().splitlines()[-4:]:
            print(f"       {line}")
    return ok


def triple(**kwargs) -> dict[str, list[bytearray]]:
    """Three captures of consecutive tabs, all carrying the same extra decoration."""
    return {name: frame(name, **kwargs) for name in ("export", "browse", "settings")}


def main(argv: list[str]) -> int:
    checker = Path(argv[1]) if len(argv) > 1 else DEFAULT_CHECKER
    if not checker.is_file():
        print(f"нет стража: {checker}", file=sys.stderr)
        return 2

    results = [
        case(checker, "правильные имена", triple(), 0, "ИТОГ: OK"),
        case(
            checker,
            "перепутанные имена (browse и settings)",
            {"export": frame("export"), "browse": frame("settings"), "settings": frame("browse")},
            1,
        ),
        case(
            checker,
            "один экран под тремя именами",
            {name: frame("export") for name in ("export", "browse", "settings")},
            1,
            "одну и ту же вкладку",
        ),
        case(checker, "акцент в контенте, панель на месте", triple(content_accent=True), 0, "ИТОГ: OK"),
        case(
            checker,
            "панель разложена по W/6",
            triple(layout={"export": 1 / 6, "browse": 0.5, "settings": 5 / 6}),
            1,
        ),
        case(checker, "панели нет вовсе", {n: frame(None, draw_bar=False) for n in ("export", "browse", "settings")}, 1),
        # Three cases aimed at the guard's settings rather than its behaviour.
        case(
            checker,
            "второй акцентный кластер внутри строки глифов",
            {"export": frame("export", second_cluster=True), "browse": frame("browse"), "settings": frame("settings")},
            1,
            "кластеров",
        ),
        case(
            checker,
            "сплошной блок шириной 40 % вместо пункта",
            # No bar icons here: the point is a single block wider than a tab glyph, and a
            # block overlapping an icon would be caught by the cluster-count rule instead.
            {"export": frame(None, draw_bar=False, wide_block=True), "browse": frame("browse"), "settings": frame("settings")},
            1,
            "не пункт панели",
        ),
        case(checker, "акцент над полосой (просвечивание контента)", triple(accent_above_band=True), 0, "ИТОГ: OK"),
        # Dark pass, and a name that lies about the appearance it was captured in.
        case(checker, "тёмный проход целиком", triple(dark=True), 0, "ИТОГ: OK"),
        case(
            checker,
            "тёмное имя, светлый кадр",
            {
                "export": frame("export"),
                "browse": frame("browse"),
                "settings": frame("settings"),
                "dark-export": frame("export"),
                "dark-browse": frame("browse"),
                "dark-settings": frame("settings"),
            },
            1,
            "тема не применилась",
        ),
    ]

    failures = results.count(False)
    if failures:
        print(f"ИТОГ: {failures} случаев повели себя неверно")
        return 1
    print(f"ИТОГ: все {len(results)} случаев ведут себя как заявлено")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
