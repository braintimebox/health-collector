#!/usr/bin/env python3
"""Weaken the screenshot guard on purpose and require the self-test to notice.

Why this exists
---------------
A green self-test proves the guard's *behaviour*; it says nothing about its *settings*.
Two rounds were spent discovering that by hand: the cluster-width ceiling, the band
height and the "exactly one cluster" rule could all be loosened while every case still
passed. This harness turns that criterion into a command: each mutation below is applied
to a copy of the guard, and the self-test must fail against the copy.

Exit codes: 0 every mutation caught, 1 a mutation slipped through, 2 cannot run.
"""
from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
GUARD = HERE / "check-screenshots.py"
SELF_TEST = HERE / "test-check-screenshots.py"

MUTATIONS: list[tuple[str, str, str]] = [
    (
        "все вердикты ok (ранний return)",
        "def main(argv: list[str]) -> int:\n    if len(argv) < 2:",
        "def main(argv: list[str]) -> int:\n    return 0\n    if len(argv) < 2:",
    ),
    (
        "потолок ширины кластера 0.12 → 0.9",
        "MAX_CLUSTER_WIDTH = 0.12",
        "MAX_CLUSTER_WIDTH = 0.9",
    ),
    (
        "верхняя граница полосы 0.096 → 0.500",
        "BAND_TOP = 0.096",
        "BAND_TOP = 0.500",
    ),
    (
        "несколько кластеров: взять любой вместо отказа",
        "    if len(runs) > 1:",
        "    if False:",
    ),
    (
        "допуск центра 0.107 → 5.0",
        "CENTRE_TOLERANCE = 0.107",
        "CENTRE_TOLERANCE = 5.0",
    ),
    (
        "проверка тёмной темы отключена",
        '    if group == "dark" and not dark:',
        "    if False:",
    ),
]


def run_self_test(guard: Path) -> int:
    result = subprocess.run(
        [sys.executable, str(SELF_TEST), str(guard)],
        capture_output=True,
        text=True,
    )
    return result.returncode


def main() -> int:
    for path in (GUARD, SELF_TEST):
        if not path.is_file():
            print(f"нет файла: {path}", file=sys.stderr)
            return 2

    uncaught = 0
    for name, old, new in MUTATIONS:
        source = GUARD.read_text()
        if old not in source:
            print(f"FAIL: якорь мутации не найден — {name}", file=sys.stderr)
            return 2
        with tempfile.TemporaryDirectory() as tmp:
            mutant = Path(tmp) / GUARD.name
            mutant.write_text(source.replace(old, new, 1))
            # The self-test must resolve the checker it was given, not its neighbour.
            code = run_self_test(mutant)
        caught = code != 0
        print(f"{'ok  ' if caught else 'FAIL'} {'ловит' if caught else 'НЕ ловит'}: {name}")
        if not caught:
            uncaught += 1

    if uncaught:
        print(f"ИТОГ: {uncaught} ослаблений стража не пойманы")
        return 1
    print(f"ИТОГ: все {len(MUTATIONS)} ослаблений пойманы")
    return 0


if __name__ == "__main__":
    sys.exit(main())
