#!/usr/bin/env python3
"""Automation gate lock: does the app actually ask the gate before it collects?

The core tests prove the *decision* (`AutomationGate.decide`), and they stayed
green when the runtime was mutated to ignore it: replacing the call inside
`syncNow` with a constant `CollectionDecision.run` produced 83/83 passing tests
while the app collected regardless of the switch. A suite that certifies the rule
but not the wiring is how "Automatic collection: off" becomes decorative again.

This checker closes that gap mechanically:

    R1  `syncNow` must call AutomationGate.decide
    R2  `exportWindow` must call AutomationGate.decide
    R3  in the app layer, every call that reads HealthKit or drains the outbox must
        live in one of those two functions (no third path to the collector; the
        core's own `collectOnce` is the engine those functions call)
    R4  the *setting* (`AppSettings.automationEnabled`) is read only by the files
        that own it or render it — a new reader is a new decision point

Usage:
    check-automation-gate.py              # check this repository
    check-automation-gate.py --self-test  # mutate a copy, expect failures
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = Path("HealthCollector")
CORE = Path("Sources") / "HealthCollectorCore"

GATE = "AutomationGate.decide("
GATED_FUNCTIONS = {"syncNow", "exportWindow"}
# Calls that reach HealthKit or the outbox. Each must sit inside a gated function.
# Matched as substrings, so the dot-call form counts too: a mutation that writes
# `Collector(...).collectOnce()` bypassed an earlier version of this list simply by
# not spelling the receiver `collector`.
COLLECTION_CALLS = [
    ".collectOnce(",
    "source.fetch(",
    "source.fetchWindow(",
    ".drain(",
]
SETTING_OWNERS = {
    "HealthCollector/Runtime.swift",
    "HealthCollector/AppSettings.swift",
    "HealthCollector/UI/ExportTab.swift",
    "HealthCollector/UI/SettingsTab.swift",
    "Sources/HealthCollectorCore/AutomationGate.swift",
}
FUNC_DECL = re.compile(r"^\s*(?:private\s+|fileprivate\s+|public\s+|static\s+|@\w+\s+)*func\s+(\w+)")


def swift_files(root: Path) -> list[Path]:
    files = []
    for base in (root / APP, root / CORE):
        if base.exists():
            files.extend(sorted(base.rglob("*.swift")))
    return files


def enclosing_function(lines: list[str], index: int) -> str | None:
    """Nearest `func` declaration at or above `index`."""
    for i in range(index, -1, -1):
        match = FUNC_DECL.match(lines[i])
        if match:
            return match.group(1)
    return None


def function_body(text: str, name: str) -> str | None:
    """Text from `func name(` to the next top-level `func` declaration."""
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        match = FUNC_DECL.match(line)
        if match and match.group(1) == name:
            start = i
            break
    if start is None:
        return None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if FUNC_DECL.match(lines[j]):
            end = j
            break
    return "\n".join(lines[start:end])


def check(root: Path) -> list[str]:
    failures: list[str] = []
    runtime = root / APP / "Runtime.swift"
    if not runtime.exists():
        return [f"нет {runtime.relative_to(root)} — проверять нечего, и это не успех"]

    text = runtime.read_text()
    for name in sorted(GATED_FUNCTIONS):
        body = function_body(text, name)
        if body is None:
            failures.append(f"{name} не найдена в Runtime.swift — точка запуска сбора исчезла или переименована")
            continue
        if GATE not in body:
            failures.append(
                f"{name} не спрашивает {GATE.strip()} — сбор пойдёт мимо тумблера "
                f"(именно эта правка осталась зелёной на 83/83)")

    # Only the app layer is scanned here: the core's `collectOnce` is the engine
    # that the gated functions call, and flagging it would mean the checker cannot
    # distinguish "the engine fetches" from "a screen fetches".
    for path in sorted((root / APP).rglob("*.swift")):
        lines = path.read_text().splitlines()
        rel = str(path.relative_to(root))
        for number, line in enumerate(lines, 1):
            for call in COLLECTION_CALLS:
                if call in line:
                    owner = enclosing_function(lines, number - 1)
                    if owner not in GATED_FUNCTIONS:
                        failures.append(
                            f"{rel}:{number}: {call} внутри {owner or '<file scope>'} — "
                            f"третий путь к коллектору в обход гейта")

    for path in swift_files(root):
        rel = str(path.relative_to(root))
        if rel in SETTING_OWNERS:
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if "AppSettings.automationEnabled" in line:
                failures.append(
                    f"{rel}:{number}: читает automationEnabled вне владельца настройки — "
                    f"это новая точка решения помимо AutomationGate")
    return failures


def run(root: Path) -> int:
    failures = check(root)
    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        print(f"ИТОГ: {len(failures)} нарушений — сбор может идти мимо тумблера")
        return 1
    print("ok: syncNow и exportWindow спрашивают гейт; других путей к коллектору нет")
    print("ИТОГ: тумблер связан с поведением (статическая проверка, не прогон)")
    return 0


def self_test() -> int:
    """Mutate a copy; every mutation must be caught, the untouched copy must pass."""
    base = run(ROOT)
    if base != 0:
        print("self-test: чистое дерево уже красное — сначала починить")
        return 1

    mutations = {
        "гейт в syncNow заменён на константу": (
            "HealthCollector/Runtime.swift",
            "switch AutomationGate.decide(trigger: trigger, automationEnabled: state.automationEnabled) {",
            "switch CollectionDecision.run {",
        ),
        "гейт в exportWindow убран": (
            "HealthCollector/Runtime.swift",
            "guard AutomationGate.decide(trigger: .windowExport, automationEnabled: state.automationEnabled).runs else {",
            "guard true else {",
        ),
        "третий путь к коллектору": (
            "HealthCollector/Runtime.swift",
            "    // MARK: - Diagnostics",
            "    func collectBehindEveryonesBack() throws {\n"
            "        _ = try Collector(source: source, outbox: outbox!, anchors: anchors!, types: [], clock: Date.init).collectOnce()\n"
            "    }\n\n    // MARK: - Diagnostics",
        ),
        "новый читатель настройки": (
            "HealthCollector/UI/BrowseTab.swift",
            "import SwiftUI",
            "import SwiftUI\nlet leaks = AppSettings.automationEnabled",
        ),
    }
    caught = 0
    for name, (rel, old, new) in mutations.items():
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "repo"
            shutil.copytree(ROOT, copy, ignore=shutil.ignore_patterns(".git", ".build", "*.ipa"))
            target = copy / rel
            text = target.read_text()
            if old not in text:
                print(f"self-test: якорь не найден для «{name}» — мутация не применилась")
                continue
            target.write_text(text.replace(old, new, 1))
            if run(copy) != 0:
                caught += 1
                print(f"self-test: поймано — {name}")
            else:
                print(f"self-test: ПРОПУЩЕНО — {name}")
    print(f"self-test: {caught} из {len(mutations)} мутаций поймано")
    return 0 if caught == len(mutations) else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    return run(args.root)


if __name__ == "__main__":
    sys.exit(main())
