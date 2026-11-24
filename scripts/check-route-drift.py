#!/usr/bin/env python3
"""Route drift gate: the client, the contract, the receiver source and the server.

Two sides used to keep their own private route list. The probe called `/v1/health`
while the receiver answered `/health`, so "Test connection" reported a working
server as dead, and nothing failed.

States, and they are not the same thing:

    0  every half that was asked for agrees
    1  drift, named by route id
    2  unknown: a half that was *required* could not be checked

Three rules exist because each was violated by a real mutation:

* `deployed` is not a self-declaration. With `--receiver` the receiver's own source
  is parsed, so marking a served route "not deployed" contradicts the code that
  serves it instead of silencing the gate.
* 401 is its own outcome. A probe refused by auth is not "not 404"; treating it as
  fine made the gate go green the day the receiver's door was closed.
* Route literals are matched with and without the leading slash. The defect that
  started this was written `"v1/health"`, and a scan that only knew `"/v1/..."`
  would have passed the very line it was written for.

Usage:
    check-route-drift.py                                   # contract vs client
    check-route-drift.py --receiver PATH/server.py          # + receiver source
    check-route-drift.py --server URL [--token T]           # + live answers
    ... --require-live --require-receiver                   # a missing half is 2
"""
from __future__ import annotations

import argparse
import json
import os
import re
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
STRING_LITERAL = re.compile(r'"([^"\n]*)"')
ROUTE_IN_LITERAL = re.compile(r"(?:^|/)v1/")


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


def stray_literals() -> list[tuple[str, int, str]]:
    """Any `v1/...` literal outside the route table: a second source of truth.

    A literal that *matches* a table entry is flagged too: the original defect was an
    inline literal that happened to equal nothing on the other side, and a matching
    value proves nothing while two copies exist.
    """
    strays = []
    for base in app_sources():
        for path in sorted(base.rglob("*.swift")):
            if path.resolve() == swift_route_path().resolve():
                continue
            for number, line in enumerate(path.read_text().splitlines(), 1):
                for literal in STRING_LITERAL.findall(line):
                    if NOT_A_ROUTE.match(literal):
                        continue
                    if ROUTE_IN_LITERAL.search(literal):
                        strays.append((str(path.relative_to(ROOT)), number, literal))
    return strays


def receiver_routes(path: Path) -> set[str]:
    """Paths the receiver's own source serves: `@app.<verb>("<path>")` decorators."""
    text = path.read_text()
    return set(re.findall(r'@app\.(?:get|post|put|patch|delete)\(\s*"([^"]+)"', text))


def check_static(contract: dict, routes: dict[str, str]) -> list[str]:
    failures = []
    declared: dict[str, dict] = {}

    for entry in contract["routes"]:
        route_id = entry.get("id") or "<no id>"
        if not entry.get("id"):
            failures.append(
                f"route <no id>: запись контракта без поля id — по чему её называть в отчёте "
                f"({entry.get('path', '?')})"
            )
        client = entry.get("client")
        if not isinstance(client, str) or not client.strip():
            failures.append(
                f"route {route_id}: в контракте нет поля client — гейт не знает, какую константу "
                f"клиента сверять с {entry.get('path', '?')}"
            )
            continue
        name = client.split(".")[-1]
        if not name:
            failures.append(f"route {route_id}: client не назван ({client!r})")
            continue
        declared[name] = entry

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

    for path, line, literal in stray_literals():
        failures.append(
            f"route literal {literal!r} at {path}:{line} is outside ApiRoute — a second route "
            f"table is how /v1/health and /health drifted apart"
        )
    return failures


def check_receiver(contract: dict, path: Path) -> list[str]:
    """`deployed` must match the code that serves the routes, not its own flag."""
    served = receiver_routes(path)
    failures = []
    for entry in contract["routes"]:
        route = entry["path"]
        deployed = bool(entry.get("deployed"))
        if deployed and route not in served:
            failures.append(
                f"route {entry['id']}: contract says deployed but {path.name} declares no "
                f"{route} handler — the flag and the receiver disagree"
            )
        elif not deployed and route in served:
            failures.append(
                f"route {entry['id']}: {path.name} serves {route} but the contract marks it not "
                f"deployed — flipping the flag does not make the route absent"
            )
    return failures


def probe(url: str, method: str, token: str | None, timeout: float = 8.0) -> tuple[int | None, str]:
    request = urllib.request.Request(url, method=method)
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, ""
    except urllib.error.HTTPError as error:
        return error.code, ""
    except (urllib.error.URLError, OSError) as error:
        return None, str(error)


def check_live(contract: dict, server: str,
               token: str | None) -> tuple[list[str], list[str], list[str], bool]:
    """Returns (failures, notes, unchecked, reachable).

    `unchecked` holds routes the server refused to answer without a token. Auth runs
    before routing, so a 401 says "protected", not "missing" — treating it as either
    drift or a pass would be a claim the probe cannot make.
    """
    failures, notes, unchecked = [], [], []
    reachable = False
    for entry in contract["routes"]:
        url = server.rstrip("/") + entry["path"]
        status, error = probe(url, entry["method"], token)
        if status is not None:
            reachable = True
        if status is None:
            failures.append(f"route {entry['id']}: {url} unreachable ({error})")
            continue

        if status == 401:
            if token:
                failures.append(
                    f"route {entry['id']}: {url} answers 401 with the supplied token — the "
                    f"credential was rejected, which is not the same as a missing route"
                )
            else:
                unchecked.append(
                    f"route {entry['id']}: {url} answers 401 without a token — auth runs before "
                    f"routing, so missing and protected are indistinguishable here"
                )
            continue

        expected = entry.get("live_expect", "not_404")
        if expected == "not_404":
            if status == 404:
                failures.append(
                    f"route {entry['id']}: {url} answers 404 — deployed route missing on the server"
                )
            elif 200 <= status < 400:
                notes.append(f"route {entry['id']}: {status} as expected")
            else:
                failures.append(
                    f"route {entry['id']}: {url} answers {status} — reachable, but not a passing "
                    f"probe (declare live_expect if that is intended)"
                )
        elif expected == "404":
            if status == 404:
                note = entry.get("known_gap", "")
                notes.append(f"route {entry['id']}: 404 as declared (known gap). {note}".strip())
            else:
                notes.append(
                    f"route {entry['id']}: now answers {status} — the contract says not deployed; "
                    f"flip 'deployed' and 'live_expect' in contract/routes.json"
                )
    return failures, notes, unchecked, reachable


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", help="base URL of a running receiver, e.g. http://127.0.0.1:8910")
    parser.add_argument("--receiver", help="path to the receiver's source file (server.py)")
    parser.add_argument("--token", help="bearer token for the live probe (or HC_SERVER_TOKEN)")
    parser.add_argument("--require-live", action="store_true",
                        help="an unreachable server is exit 2 instead of a skip")
    parser.add_argument("--require-receiver", action="store_true",
                        help="no --receiver is exit 2 instead of a skip")
    parser.add_argument("--root", help="tree to check (default: this script's repository)")
    args = parser.parse_args(argv)

    global ROOT
    if args.root:
        ROOT = Path(args.root).resolve()

    token = args.token or os.environ.get("HC_SERVER_TOKEN")
    contract = load_contract()
    routes = swift_routes()

    failures = check_static(contract, routes)
    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        print(f"\nИТОГ: {len(failures)} расхождений в таблице маршрутов")
        return 1
    print(f"ok static: {len(routes)} маршрут(ов) в ApiRoute совпадают с contract/routes.json")

    if args.receiver:
        receiver_failures = check_receiver(contract, Path(args.receiver))
        for failure in receiver_failures:
            print(f"FAIL: {failure}")
        if receiver_failures:
            print(f"\nИТОГ: {len(receiver_failures)} расхождений между контрактом и исходником "
                  f"приёмника")
            return 1
        print(f"ok receiver: deployed-флаги {len(contract['routes'])} маршрут(ов) совпадают с "
              f"{Path(args.receiver).name}")
    elif args.require_receiver:
        print("UNKNOWN: --require-receiver задан, а --receiver нет — флаги deployed не сверены с "
              "кодом приёмника и остаются самообъявлением")
        return 2
    else:
        print("RECEIVER: не проверялось (--receiver не задан) — deployed-флаги сейчас самообъявление")

    if not args.server:
        print("LIVE: не проверялось (--server не задан) — живые ответы не подтверждены")
        return 0

    live_failures, notes, unchecked, reachable = check_live(contract, args.server, token)
    for note in notes:
        print(f"ok live: {note}")
    for failure in live_failures:
        print(f"FAIL: {failure}")
    for line in unchecked:
        print(f"UNCHECKED: {line}")

    if not reachable:
        print(f"\nUNKNOWN: {args.server} недоступен — живые ответы не проверены")
        return 2
    if live_failures:
        print(f"\nИТОГ: {len(live_failures)} расхождений между контрактом и сервером")
        return 1
    if unchecked:
        print(f"\nUNKNOWN: {len(unchecked)} маршрут(ов) не проверены — сервер требует токен; "
              f"задай --token или HC_SERVER_TOKEN, иначе «согласованы» было бы утверждением "
              f"сильнее прогона")
        return 2

    if not token:
        print("AUTH: проба шла без токена — 401 на этом прогоне обнаружен быть не мог")
    print("\nИТОГ: клиент, контракт и сервер согласованы")
    return 0


if __name__ == "__main__":
    sys.exit(main())
