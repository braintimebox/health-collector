#!/usr/bin/env python3
"""Text checks for the app skeleton: entitlements, Info.plist and the Xcode project.

Why this exists
---------------
The app bundle is built in CI with `CODE_SIGNING_ALLOWED=NO`, so it ships **no
entitlements at all** — they are applied when the owner signs it. That makes
`HealthCollector.entitlements` the only statement of what the app will ask the
profile for, and nothing in a normal build reads it. A key lost from that file
would surface as an install failure on a phone, days later, with no log.

The same shape of failure applies to the Xcode project: a Swift file that exists on
disk but is missing from the Sources phase compiles into nothing and breaks
silently, and a `PBXFileReference` whose path does not resolve fails only when
Xcode tries to read it — after a macOS runner has booted.

Everything here runs on Linux in under a second.

Exit codes: 0 clean, 1 violations, 2 cannot check (missing or unparseable input).
Warnings are printed separately and never make the run green by themselves.
"""
from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "HealthCollector.xcodeproj" / "project.pbxproj"
ENTITLEMENTS = ROOT / "HealthCollector" / "HealthCollector.entitlements"
INFO_PLIST = ROOT / "HealthCollector" / "Info.plist"
SOURCES_DIR = ROOT / "HealthCollector"

EXPECTED_ENTITLEMENTS = {
    "com.apple.developer.healthkit",
    "com.apple.developer.healthkit.background-delivery",
}
EXPECTED_BUNDLE_ID = "com.braintimebox.healthcollector"

violations: list[str] = []
warnings: list[str] = []


def fail(message: str) -> None:
    violations.append(message)


def warn(message: str) -> None:
    warnings.append(message)


# --------------------------------------------------------------------------- #
# entitlements
# --------------------------------------------------------------------------- #
def check_entitlements() -> None:
    if not ENTITLEMENTS.is_file():
        fail(f"нет файла entitlements: {ENTITLEMENTS.relative_to(ROOT)}")
        return
    try:
        data = plistlib.loads(ENTITLEMENTS.read_bytes())
    except Exception as exc:  # noqa: BLE001 - a broken plist is the finding
        fail(f"entitlements не читается как plist: {exc}")
        return

    keys = set(data)
    missing = EXPECTED_ENTITLEMENTS - keys
    extra = keys - EXPECTED_ENTITLEMENTS
    if missing:
        fail(f"entitlements: пропущены ключи {sorted(missing)}")
    if extra:
        fail(
            "entitlements: лишние ключи "
            f"{sorted(extra)} — каждый требует своего разрешения в профиле"
        )
    for key in sorted(keys & EXPECTED_ENTITLEMENTS):
        if data[key] is not True:
            fail(f"entitlements: {key} должен быть true, а не {data[key]!r}")


# --------------------------------------------------------------------------- #
# Info.plist
# --------------------------------------------------------------------------- #
def check_info_plist() -> None:
    if not INFO_PLIST.is_file():
        fail(f"нет файла: {INFO_PLIST.relative_to(ROOT)}")
        return
    try:
        data = plistlib.loads(INFO_PLIST.read_bytes())
    except Exception as exc:  # noqa: BLE001
        fail(f"Info.plist не читается как plist: {exc}")
        return

    description = data.get("NSHealthShareUsageDescription")
    if not isinstance(description, str) or len(description.strip()) < 20:
        fail("Info.plist: NSHealthShareUsageDescription отсутствует или пуст")

    if "NSHealthUpdateUsageDescription" in data:
        fail(
            "Info.plist: есть NSHealthUpdateUsageDescription, но приложение ничего "
            "не пишет в Health — строка разрешения на неиспользуемое право"
        )

    if "UIBackgroundModes" in data:
        fail(
            "Info.plist: UIBackgroundModes не нужен — фоновая URLSession это отдельный "
            "механизм, а не background mode"
        )

    if data.get("CFBundleIdentifier") != "$(PRODUCT_BUNDLE_IDENTIFIER)":
        fail("Info.plist: CFBundleIdentifier должен ссылаться на $(PRODUCT_BUNDLE_IDENTIFIER)")
    if data.get("CFBundleExecutable") != "$(EXECUTABLE_NAME)":
        fail("Info.plist: CFBundleExecutable должен ссылаться на $(EXECUTABLE_NAME)")
    if data.get("UILaunchScreen") is None:
        fail("Info.plist: нет UILaunchScreen — iOS отвергает бандл без него")


# --------------------------------------------------------------------------- #
# Xcode project
# --------------------------------------------------------------------------- #
class PBXObject:
    """One object of the project's objects dictionary."""

    def __init__(self, oid: str, name: str, body: str) -> None:
        self.id = oid
        self.name = name or oid
        self.body = body
        isa = re.search(r"isa = (\w+);", body)
        self.isa = isa.group(1) if isa else ""

    def string(self, key: str) -> str | None:
        match = re.search(rf"\b{key} = ([^;]+);", self.body)
        return match.group(1).strip().strip('"') if match else None

    def children(self) -> list[str]:
        match = re.search(r"children = \((.*?)\);", self.body, re.S)
        return re.findall(r"([0-9A-F]{24})", match.group(1)) if match else []


def split_objects(raw: str) -> dict[str, PBXObject]:
    """Split the objects dictionary by definition, not with one global regex.

    A single `re.S` pattern walked from one object's id to the next object's
    `isa` and merged the build-file section into the first group — the group
    parser then reported the mainGroup as missing while the file was fine. The
    dictionary is line-oriented, so it is split on that.
    """
    parts = re.split(r"^\t\t(?=[0-9A-F]{24}\s)", raw, flags=re.M)
    objects: dict[str, PBXObject] = {}
    for part in parts[1:]:
        oid = part[:24]
        header = re.match(r"[0-9A-F]{24}\s*(?:/\* (.*?) \*/)?\s*=", part, re.S)
        name = header.group(1) if header and header.group(1) else ""
        objects[oid] = PBXObject(oid, name, part)
    return objects


def check_balance(raw: str) -> None:
    text = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
    for opening, closing in (("{", "}"), ("(", ")")):
        if text.count(opening) != text.count(closing):
            fail(
                f"pbxproj: несбалансированные {opening}{closing} "
                f"({text.count(opening)} vs {text.count(closing)})"
            )


def resolve_dir(oid: str | None, objects: dict[str, PBXObject]) -> Path:
    parts: list[str] = []
    seen: set[str] = set()
    cursor = oid
    while cursor and cursor in objects and cursor not in seen:
        seen.add(cursor)
        path = objects[cursor].string("path")
        if path:
            parts.append(path)
        parent = None
        for candidate in objects.values():
            if candidate.isa == "PBXGroup" and cursor in candidate.children():
                parent = candidate.id
                break
        cursor = parent
    return ROOT.joinpath(*reversed(parts)) if parts else ROOT


def check_pbxproj() -> None:
    if not PROJECT.is_file():
        fail(f"нет проекта: {PROJECT.relative_to(ROOT)}")
        return
    raw = PROJECT.read_text()
    check_balance(raw)
    objects = split_objects(raw)

    if len(objects) < 8:
        fail(f"pbxproj: разобрано всего {len(objects)} объектов — похоже, это не проект")
        return

    stripped = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
    for token in re.findall(r"\b([0-9A-F]{24})\b", stripped):
        if token not in objects:
            fail(f"pbxproj: ссылка на неопределённый объект {token}")
            break

    project = next((obj for obj in objects.values() if obj.isa == "PBXProject"), None)
    if project is None:
        fail("pbxproj: нет объекта PBXProject")
        return

    main_group = project.string("mainGroup")
    if not main_group or main_group not in objects:
        fail("pbxproj: mainGroup не указывает на существующую группу")

    for obj in objects.values():
        if obj.isa != "PBXFileReference":
            continue
        path = obj.string("path")
        if not path or "BUILT_PRODUCTS_DIR" in obj.body:
            continue
        owner = next(
            (
                candidate.id
                for candidate in objects.values()
                if candidate.isa == "PBXGroup" and obj.id in candidate.children()
            ),
            None,
        )
        resolved = resolve_dir(owner, objects) / path
        if not resolved.exists():
            fail(f"pbxproj: {obj.name} не найден по пути {resolved.relative_to(ROOT)}")

    for key, expected_file in (
        ("CODE_SIGN_ENTITLEMENTS", ENTITLEMENTS),
        ("INFOPLIST_FILE", INFO_PLIST),
    ):
        match = re.search(rf"\b{key} = ([^;]+);", raw)
        if not match:
            fail(f"pbxproj: не задан {key}")
            continue
        value = match.group(1).strip().strip('"')
        target = (ROOT / value).resolve()
        if not target.exists():
            fail(f"pbxproj: {key} = {value}, такого файла нет")
        elif target != expected_file.resolve():
            fail(f"pbxproj: {key} указывает не на тот файл: {value}")

    bundle_id = re.search(r"\bPRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", raw)
    if not bundle_id:
        fail("pbxproj: не задан PRODUCT_BUNDLE_IDENTIFIER")
    elif bundle_id.group(1).strip().strip('"') != EXPECTED_BUNDLE_ID:
        fail(
            f"pbxproj: PRODUCT_BUNDLE_IDENTIFIER = {bundle_id.group(1).strip()}, "
            f"ожидался {EXPECTED_BUNDLE_ID}"
        )

    # Every Swift file on disk must be registered in the Sources phase: one that
    # exists but is unregistered compiles into nothing, and nothing reports it.
    compiled: set[str] = set()
    for obj in objects.values():
        if obj.isa != "PBXSourcesBuildPhase":
            continue
        for build_id in re.findall(r"([0-9A-F]{24})", obj.body):
            build_file = objects.get(build_id)
            if build_file and build_file.isa == "PBXBuildFile":
                compiled.add(build_file.name.replace(" in Sources", "").strip())
    on_disk = {path.name for path in SOURCES_DIR.rglob("*.swift")}
    for name in sorted(on_disk - compiled):
        fail(f"pbxproj: {name} есть на диске, но не в фазе Sources — файл не попадёт в сборку")

    if "AppIcon" not in raw:
        warn("в проекте нет AppIcon: сборка пройдёт, иконка на телефоне будет пустой")


# --------------------------------------------------------------------------- #
def main() -> int:
    check_entitlements()
    check_info_plist()
    check_pbxproj()

    for message in warnings:
        print(f"WARN: {message}")
    for message in violations:
        print(f"FAIL: {message}")

    if violations:
        print(f"ИТОГ: FAIL ({len(violations)}) — предупреждений {len(warnings)}")
        return 1
    print(f"ИТОГ: OK — предупреждений {len(warnings)}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - unknown is not clean
        print(f"UNKNOWN: проверка не выполнена: {exc!r}")
        sys.exit(2)
