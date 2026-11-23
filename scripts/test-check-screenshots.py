#!/usr/bin/env python3
"""Prove `check-screenshots.py` still fails when the screenshot is wrong.

Why this exists
---------------
The guard's controls lived in chat: five hand-built sets in a scratch directory, made by
hand from real captures. That proves the guard for an afternoon — the next edit to it can
be the one that turns every verdict into "ok", and nothing in the repository would notice.

These fixtures are synthetic and generated here, so the suite runs anywhere without
network, CI artifacts or a simulator: a frame with a tab bar drawn at the measured
positions, and one deliberate lie per case.

Cases: correct names, swapped names, duplicates, content accent above the bar, a panel
laid out at W/6, and a frame with no tab bar at all.

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
CHECKER = HERE / "check-screenshots.py"

WIDTH, HEIGHT = 402, 874  # 1x points, same proportions as the 3x captures
BACKGROUND = (242, 242, 247)
DIM = (142, 142, 147)
ACCENT = (0, 122, 255)
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


def frame(
    selected: str | None,
    layout: dict[str, float] | None = None,
    content_accent: bool = False,
    draw_bar: bool = True,
) -> list[bytearray]:
    rows = [bytearray(BACKGROUND * WIDTH) for _ in range(HEIGHT)]
    if content_accent:
        for y in range(200, 260):
            for x in range(20, 180):
                rows[y][x * 3 : x * 3 + 3] = bytes(ACCENT)
    if not draw_bar:
        return rows

    top = int(HEIGHT * (1 - BAND_TOP))
    bottom = int(HEIGHT * (1 - BAND_BOTTOM))
    centres = layout or CENTRES
    for tab, fraction in centres.items():
        colour = ACCENT if tab == selected else DIM
        centre = int(WIDTH * fraction)
        for y in range(top + 8, bottom - 8):
            for x in range(centre - 15, centre + 15):
                if 0 <= x < WIDTH:
                    rows[y][x * 3 : x * 3 + 3] = bytes(colour)
    return rows


def run(directory: Path) -> tuple[int, str]:
    result = subprocess.run(
        [sys.executable, str(CHECKER), str(directory)],
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout + result.stderr


def case(
    name: str,
    shots: dict[str, list[bytearray]],
    expected_code: int,
    expected_text: str = "",
) -> bool:
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        for filename, rows in shots.items():
            write_png(directory / f"{filename}.png", rows)
        code, output = run(directory)
    ok = code == expected_code and expected_text in output
    detail = "" if ok else f" (ожидался код {expected_code}, получен {code})"
    print(f"{'ok  ' if ok else 'FAIL'} {name}{detail}")
    if not ok and output:
        for line in output.strip().splitlines()[-4:]:
            print(f"       {line}")
    return ok


def main() -> int:
    if not CHECKER.is_file():
        print(f"нет стража: {CHECKER}", file=sys.stderr)
        return 2

    results = [
        case(
            "правильные имена",
            {
                "export": frame("export"),
                "browse": frame("browse"),
                "settings": frame("settings"),
            },
            0,
            "ИТОГ: OK",
        ),
        case(
            "перепутанные имена (browse и settings)",
            {
                "export": frame("export"),
                "browse": frame("settings"),
                "settings": frame("browse"),
            },
            1,
        ),
        case(
            "один экран под тремя именами",
            {name: frame("export") for name in ("export", "browse", "settings")},
            1,
            "одну и ту же вкладку",
        ),
        case(
            "акцент в контенте, панель на месте",
            {
                "export": frame("export", content_accent=True),
                "browse": frame("browse"),
                "settings": frame("settings"),
            },
            0,
            "ИТОГ: OK",
        ),
        case(
            "панель разложена по W/6",
            {
                "export": frame("export", layout={"export": 1 / 6, "browse": 0.5, "settings": 5 / 6}),
                "browse": frame("browse", layout={"export": 1 / 6, "browse": 0.5, "settings": 5 / 6}),
                "settings": frame("settings", layout={"export": 1 / 6, "browse": 0.5, "settings": 5 / 6}),
            },
            1,
        ),
        case(
            "панели нет вовсе",
            {
                "export": frame(None, draw_bar=False),
                "browse": frame(None, draw_bar=False),
                "settings": frame(None, draw_bar=False),
            },
            1,
        ),
    ]

    failures = results.count(False)
    if failures:
        print(f"ИТОГ: {failures} случаев повели себя неверно")
        return 1
    print(f"ИТОГ: все {len(results)} случаев ведут себя как заявлено")
    return 0


if __name__ == "__main__":
    sys.exit(main())
