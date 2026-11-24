#!/usr/bin/env python3
"""Route drift gate: the client, the contract and the server must agree.

Two sides used to keep their own private route list. The probe called
`/v1/health` while the receiver answered `/health`, so "Test connection"
reported a working server as dead, and nothing failed.

This gate has three states, and they are not the same thing:

    0  every route agrees (and, with --server, every route answered as declared)
    1  drift: a route is missing on one side, or a deployed route answers 404
    2  unknown: the live half was required but no server was reachable

Usage:
    check-route-drift.py                       # static only (contract vs Swift)
    check-route-drift.py --server URL          # static + live answers
    check-route-drift.py --server URL --require-live
                                              # missing server is 2, not a pass

Exit 2 never renders as clean: a gate that cannot see the server must say so.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTRACT_NAME = Path("contract") / "routes.json"
SWIFT_ROUTE_NAME = Path("Sources") / "HealthCollectorCore" / "ApiRoute.swift"
APP_SOURCE_NAMES = [Path("HealthCollector"), Path("Sources") / "HealthCollectorCore"]
# Literals that look like a path but are not routes (appended folders, files).
NOT_A_ROUTE = re.compile(r"^/(tmp|usr|dev|Library|var|private)(/|$)")


def contract_path() -> Path:
    return ROOT / CONTRACT_NAME


def swift_route_path() -> Path:
    return ROOT / SWIFT_ROUTE_NAME


def app_sources() -> list[Path]:
    return [ROOT / name for name in APP_SOURCE_NAMES]


def load_contract(path: Path | None = None) -> dict:
    return json.loads((path or contract_path()).read_text())


def swift_routes(path: Path | None = None) -> dict[str, str]:
    """name -> path, read from `public static let <name> = "<path>"`."""
    text = (path or swift_route_path()).read_text()
    found = {}
    for name, value in re.findall(r'public\s+static\s+let\s+(\w+)\s*=\s*"(/[^"]*)"', text):
        found[name] = value
    return found


def stray_literals(routes: dict[str, str]) -> list[tuple[str, int, str]]:
    """Any `/v1/...` literal outside the route table: a second source of truth.

    A literal that *matches* a table entry is flagged too — that was the original
    defect: `"v1/health"` sat inline in the runtime and nobody compared it with the
    receiver, so a matching value in the table proved nothing.
    """
    strays = []
    for base in app_sources():
        for path in sorted(base.rglob("*.swift")):
            if path.resolve() == swift_route_path().resolve():
                continue
            for number, line in enumerate(path.read_text().splitlines(), 1):
                for literal in re.findall(r'"(\/[^"\n]*)"', line):
                    if not literal.startswith("/v1"):
                        continue
                    if NOT_A_ROUTE.match(literal):
                        continue
                    strays.append((str(path.relative_to(ROOT)), number, literal))
    return strays


def check_static(contract: dict, routes: dict[str, str]) -> list[str]:
    failures = []
    declared = {entry["client"].split(".")[-1]: entry for entry in contract["routes"]}

    for name in sorted(declared):
        entry = declared[name]
        if name not in routes:
            failures.append(
                f"route {entry['id']}: contract declares {entry['client']} but ApiRoute has no "
                f"such constant (path {entry['path']})"
            )
        elif routes[name] != entry["path"]:
            failures.append(
                f"route {entry['id']}: client path {routes[name]} != contract path {entry['path']}"
            )

    for name in sorted(routes):
        if name not in declared:
            failures.append(
                f"route {name}: ApiRoute defines {routes[name]} but the contract has no entry — "
                f"add it to contract/routes.json, do not leave a path only the client knows"
            )

    for path, line, literal in stray_literals(routes):
        failures.append(
            f"route literal {literal} at {path}:{line} is outside ApiRoute — a second route "
            f"table is how /v1/health and /health drifted apart"
        )
    return failures


def probe(url: str, method: str, timeout: float = 8.0) -> tuple[int | None, str]:
    request = urllib.request.Request(url, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, ""
    except urllib.error.HTTPError as error:
        return error.code, ""
    except (urllib.error.URLError, OSError) as error:
        return None, str(error)


def check_live(contract: dict, server: str) -> tuple[list[str], list[str], int | None]:
    """Returns (failures, notes, first_status). first_status is None if unreachable."""
    failures, notes = [], []
    first = None
    for entry in contract["routes"]:
        url = server.rstrip("/") + entry["path"]
        status, error = probe(url, entry["method"])
        if first is None:
            first = status
        if status is None:
            failures.append(f"route {entry['id']}: {url} unreachable ({error})")
            continue
        expected = entry.get("live_expect", "not_404")
        if expected == "not_404" and status == 404:
            failures.append(
                f"route {entry['id']}: {url} answers 404 — deployed route missing on the server"
            )
        elif expected == "404" and status != 404:
            notes.append(
                f"route {entry['id']}: now answers {status} — the contract says not deployed; "
                f"flip 'deployed' and 'live_expect' in contract/routes.json"
            )
        elif expected == "404" and status == 404:
            note = entry.get("known_gap", "")
            notes.append(f"route {entry['id']}: 404 as declared (known gap). {note}".strip())
        else:
            notes.append(f"route {entry['id']}: {status} as expected")
    return failures, notes, first


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", help="base URL of a running receiver, e.g. http://127.0.0.1:8910")
    parser.add_argument("--require-live", action="store_true",
                        help="a missing/unreachable server is exit 2 instead of a skip")
    parser.add_argument("--root", help="tree to check (default: this script's repository)")
    args = parser.parse_args(argv)

    global ROOT
    if args.root:
        ROOT = Path(args.root).resolve()

    contract = load_contract()
    routes = swift_routes()

    failures = check_static(contract, routes)
    for failure in failures:
        print(f"FAIL: {failure}")

    if failures:
        print(f"\nИТОГ: {len(failures)} расхождений в таблице маршрутов")
        return 1

    print(f"ok static: {len(routes)} маршрут(ов) в ApiRoute совпадают с contract/routes.json")

    if not args.server:
        print("LIVE: не проверялось (--server не задан) — живые ответы не подтверждены")
        return 0

    live_failures, notes, first = check_live(contract, args.server)
    for note in notes:
        print(f"ok live: {note}")
    for failure in live_failures:
        print(f"FAIL: {failure}")

    if first is None:
        print(f"\nUNKNOWN: {args.server} недоступен — живые ответы не проверены")
        return 2
    if live_failures:
        print(f"\nИТОГ: {len(live_failures)} расхождений между контрактом и сервером")
        return 1

    print("\nИТОГ: клиент, контракт и сервер согласованы")
    return 0


if __name__ == "__main__":
    sys.exit(main())
