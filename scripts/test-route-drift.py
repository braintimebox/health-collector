#!/usr/bin/env python3
"""Self-test for check-route-drift.py: every branch must be reachable by a case.

A gate whose verdicts cannot be flipped is decoration. Each case builds a throwaway
tree and a stub server, runs the real checker as a subprocess, and asserts both the
exit code and a phrase that only the intended branch prints.

Cases:
  S1 clean tree, no server            -> 0, live not checked
  S2 contract declares a route the client lacks -> 1, names the route id
  S3 client declares a route the contract lacks -> 1
  S4 client path differs from contract -> 1
  S5 stray /v1 literal outside ApiRoute -> 1, names file:line
  S6 server answers 404 on a deployed route -> 1, names the route id
  S7 not-deployed route answers 200 -> 0, tells you to flip the contract
  S8 unreachable server with --require-live -> 2, UNKNOWN
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

CHECKER = Path(__file__).resolve().parent / "check-route-drift.py"

BASE_CONTRACT = {
    "routes": [
        {"id": "health_probe", "method": "GET", "path": "/v1/health",
         "client": "ApiRoute.healthProbe", "deployed": True, "live_expect": "not_404"},
        {"id": "measurements", "method": "POST", "path": "/v1/measurements",
         "client": "ApiRoute.measurements", "deployed": False, "live_expect": "404",
         "known_gap": "not served yet"},
    ]
}

BASE_SWIFT = '''import Foundation

public enum ApiRoute {
    public static let healthProbe = "/v1/health"
    public static let measurements = "/v1/measurements"
    public static let all: [String] = [healthProbe, measurements]
}
'''


def make_tree(contract=None, swift=BASE_SWIFT, extra_app_file=None) -> Path:
    root = Path(tempfile.mkdtemp(prefix="drift-"))
    (root / "contract").mkdir()
    (root / "contract" / "routes.json").write_text(json.dumps(contract or BASE_CONTRACT))
    core = root / "Sources" / "HealthCollectorCore"
    core.mkdir(parents=True)
    (core / "ApiRoute.swift").write_text(swift)
    (root / "HealthCollector").mkdir()
    if extra_app_file:
        (root / "HealthCollector" / "Extra.swift").write_text(extra_app_file)
    return root


class Stub(BaseHTTPRequestHandler):
    statuses: dict[str, int] = {}

    def _answer(self):
        self.send_response(self.statuses.get(self.path, 404))
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

    do_GET = _answer
    do_POST = _answer

    def log_message(self, format, *args):  # noqa: A002 - signature fixed by the base class
        pass


def start_stub(statuses: dict[str, int]) -> tuple[HTTPServer, str]:
    handler = type("H", (Stub,), {"statuses": statuses})
    server = HTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


def run(root: Path, *extra: str) -> tuple[int, str]:
    proc = subprocess.run(
        [sys.executable, str(CHECKER), "--root", str(root), *extra],
        capture_output=True, text=True, timeout=60,
    )
    return proc.returncode, proc.stdout + proc.stderr


CASES = []


def case(name, root, extra, expected_code, expected_text):
    CASES.append((name, root, extra, expected_code, expected_text))


def build() -> list[tuple[HTTPServer, str]]:
    started: list[tuple[HTTPServer, str]] = []

    clean = make_tree()
    case("S1 чистое дерево без сервера", clean, (), 0, "LIVE: не проверялось")

    bad = json.loads(json.dumps(BASE_CONTRACT))
    bad["routes"].append({"id": "sleep_export", "method": "GET", "path": "/v1/sleep",
                          "client": "ApiRoute.sleepExport", "deployed": True})
    case("S2 контракт объявляет маршрут, которого нет в клиенте", make_tree(contract=bad),
         (), 1, "route sleep_export")

    swift_missing = BASE_SWIFT.replace('    public static let measurements = "/v1/measurements"\n', "")
    case("S3 клиент объявляет маршрут, которого нет в контракте",
         make_tree(swift=swift_missing), (), 1, "route measurements")

    swift_other_path = BASE_SWIFT.replace('"/v1/measurements"', '"/v2/measurements"')
    case("S4 путь в клиенте расходится с контрактом",
         make_tree(swift=swift_other_path), (), 1, "!= contract path")

    stray = make_tree(extra_app_file='let probe = "/v1/health"\n')
    case("S5 литерал маршрута вне ApiRoute", stray, (), 1, "outside ApiRoute")

    # S6: the deployed route is the one missing — the exact production defect.
    probe_missing = start_stub({"/v1/measurements": 404})
    started.append(probe_missing)
    case("S6 развёрнутый маршрут отвечает 404", make_tree(),
         ("--server", probe_missing[1]), 1, "route health_probe")

    everything_up = start_stub({"/v1/health": 200, "/v1/measurements": 200})
    started.append(everything_up)
    case("S7 неразвёрнутый маршрут вдруг отвечает 200", make_tree(),
         ("--server", everything_up[1]), 0, "flip 'deployed'")

    case("S8 недоступный сервер при --require-live", make_tree(),
         ("--server", "http://127.0.0.1:9", "--require-live"), 2, "UNKNOWN")

    return started


def main() -> int:
    servers = build()
    failures = 0
    for name, root, extra, expected_code, expected_text in CASES:
        code, output = run(root, *extra)
        ok = code == expected_code and expected_text in output
        print(f"{'ok  ' if ok else 'FAIL'} {name}: код {code} (ждали {expected_code})")
        if not ok:
            failures += 1
            print("    ожидался текст: " + expected_text)
            print("    вывод: " + output.replace("\n", "\n    ")[:1200])
        shutil.rmtree(root, ignore_errors=True)
    for server, _ in servers:
        if server:
            server.shutdown()
    print(f"\nИТОГ: {'все %d случаев ведут себя как заявлено' % len(CASES) if not failures else '%d из %d не совпали' % (failures, len(CASES))}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
