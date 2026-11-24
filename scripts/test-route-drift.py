#!/usr/bin/env python3
"""Self-test for check-route-drift.py: every branch must be reachable by a case.

A gate whose verdicts cannot be flipped is decoration; a gate whose *messages* fall
back to a Python traceback is decoration with noise. Each case builds a throwaway
tree, a stub receiver source and, where needed, a stub server, then runs the real
checker as a subprocess and asserts the exit code plus a phrase that only the
intended branch prints.

  S1  clean tree, nothing supplied                   -> 0, both halves say "not checked"
  S2  contract declares a route the client lacks     -> 1, named by route id
  S3  client declares a route the contract lacks     -> 1
  S4  client path differs from the contract          -> 1
  S5  literal with a leading slash outside ApiRoute   -> 1
  S6  literal without a leading slash (the original defect shape) -> 1
  S7  deployed route answers 404 on the server       -> 1, named by route id
  S8  not-deployed route answers 200 on the server   -> 0, tells you to flip
  S9  unreachable server with --require-live         -> 2, UNKNOWN
  S10 served route marked "not deployed" (the flag that muted the gate) -> 1
  S11 contract says deployed but the receiver declares no handler -> 1
  S12 --require-receiver without --receiver          -> 2, UNKNOWN
  S13 probe answered 401 without a token             -> 1, not "not 404"
  S14 probe answered 401 with a wrong token          -> 1
  S15 token is really sent (stub answers 200 only with the header) -> 0
  S16 contract entry without "client"                -> 1, addressed message
  S17 contract entry with "client": null             -> 1, addressed message
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

# The receiver after the alias: /v1/health served, /v1/measurements not.
BASE_RECEIVER = '''from fastapi import FastAPI

app = FastAPI()


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/v1/health")
async def v1_health():
    return {"status": "ok"}
'''


def make_tree(contract=None, swift=BASE_SWIFT, extra_app_file=None,
              receiver: str | None = BASE_RECEIVER) -> Path:
    root = Path(tempfile.mkdtemp(prefix="drift-"))
    (root / "contract").mkdir()
    (root / "contract" / "routes.json").write_text(json.dumps(contract or BASE_CONTRACT))
    core = root / "Sources" / "HealthCollectorCore"
    core.mkdir(parents=True)
    (core / "ApiRoute.swift").write_text(swift)
    (root / "HealthCollector").mkdir()
    if extra_app_file:
        (root / "HealthCollector" / "Extra.swift").write_text(extra_app_file)
    if receiver is not None:
        (root / "receiver.py").write_text(receiver)
    return root


class Stub(BaseHTTPRequestHandler):
    statuses: dict[str, int] = {}
    requires_token: str | None = None

    def _answer(self):
        if self.requires_token and self.headers.get("Authorization") != f"Bearer {self.requires_token}":
            status = 401
        else:
            status = self.statuses.get(self.path, 404)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

    do_GET = _answer
    do_POST = _answer

    def log_message(self, format, *args):  # noqa: A002 - signature fixed by the base class
        pass


def start_stub(statuses: dict[str, int], requires_token: str | None = None) -> tuple[HTTPServer, str]:
    handler = type("H", (Stub,), {"statuses": statuses, "requires_token": requires_token})
    server = HTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


def run(root: Path, *extra: str) -> tuple[int, str]:
    resolved = tuple(str(root / item) if index and extra[index - 1] == "--receiver" else item
                     for index, item in enumerate(extra))
    proc = subprocess.run(
        [sys.executable, str(CHECKER), "--root", str(root), *resolved],
        capture_output=True, text=True, timeout=60,
    )
    return proc.returncode, proc.stdout + proc.stderr


CASES: list[tuple[str, Path, tuple[str, ...], int, str]] = []


def case(name, root, extra, expected_code, expected_text):
    CASES.append((name, root, extra, expected_code, expected_text))


def build() -> list[tuple[HTTPServer, str]]:
    started: list[tuple[HTTPServer, str]] = []

    case("S1 чистое дерево без сервера", make_tree(), (), 0, "LIVE: не проверялось")

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

    case("S5 литерал маршрута со слэшем вне ApiRoute",
         make_tree(extra_app_file='let probe = "/v1/health"\n'), (), 1, "outside ApiRoute")

    # The shape the original defect was written in: no leading slash.
    case("S6 литерал маршрута без слэша вне ApiRoute",
         make_tree(extra_app_file='let probe = "v1/health"\n'), (), 1, "outside ApiRoute")

    probe_missing = start_stub({"/v1/measurements": 404})
    started.append(probe_missing)
    case("S7 развёрнутый маршрут отвечает 404", make_tree(),
         ("--server", probe_missing[1]), 1, "route health_probe")

    everything_up = start_stub({"/v1/health": 200, "/v1/measurements": 200})
    started.append(everything_up)
    case("S8 неразвёрнутый маршрут вдруг отвечает 200", make_tree(),
         ("--server", everything_up[1]), 0, "flip 'deployed'")

    case("S9 недоступный сервер при --require-live", make_tree(),
         ("--server", "http://127.0.0.1:9", "--require-live"), 2, "UNKNOWN")

    # S10: the mutation that muted the gate — flip the flag, leave the receiver serving.
    flipped = json.loads(json.dumps(BASE_CONTRACT))
    flipped["routes"][0]["deployed"] = False
    flipped["routes"][0]["live_expect"] = "404"
    case("S10 флаг deployed перевёрнут, а приёмник маршрут обслуживает",
         make_tree(contract=flipped), ("--receiver", "receiver.py"), 1,
         "serves /v1/health but the contract marks it not deployed")

    # S11: the opposite lie — deployed claims a handler the receiver does not declare.
    claims = json.loads(json.dumps(BASE_CONTRACT))
    claims["routes"][1]["deployed"] = True
    claims["routes"][1]["live_expect"] = "not_404"
    case("S11 контракт говорит deployed, в приёмнике обработчика нет",
         make_tree(contract=claims), ("--receiver", "receiver.py"), 1,
         "declares no /v1/measurements handler")

    case("S12 --require-receiver без --receiver", make_tree(),
         ("--require-receiver",), 2, "UNKNOWN")

    rejected = start_stub({"/v1/health": 200}, requires_token="secret")
    started.append(rejected)
    case("S13 проба отвергнута 401 без токена", make_tree(),
         ("--server", rejected[1]), 1, "answers 401")

    case("S14 проба отвергнута 401 с неверным токеном", make_tree(),
         ("--server", rejected[1], "--token", "wrong"), 1, "answers 401")

    case("S15 токен действительно отправлен", make_tree(),
         ("--server", rejected[1], "--token", "secret"), 0, "согласованы")

    no_client = json.loads(json.dumps(BASE_CONTRACT))
    del no_client["routes"][0]["client"]
    case("S16 в контракте нет поля client", make_tree(contract=no_client), (), 1,
         "нет поля client")

    null_client = json.loads(json.dumps(BASE_CONTRACT))
    null_client["routes"][0]["client"] = None
    case("S17 client: null в контракте", make_tree(contract=null_client), (), 1,
         "нет поля client")

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
        if "Traceback" in output:
            failures += 1
            print("    FAIL: трейсбек вместо адресного сообщения")
        shutil.rmtree(root, ignore_errors=True)
    for server, _ in servers:
        server.shutdown()
    total = len(CASES)
    if failures:
        print(f"\nИТОГ: {failures} из {total} случаев не совпали")
    else:
        print(f"\nИТОГ: все {total} случаев ведут себя как заявлено")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
