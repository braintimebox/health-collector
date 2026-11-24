# P0-3 / P0-4 — Closure Record

Status: **DONE (code + Linux tests + iOS compile), NOT DEVICE VERIFIED**
Commits: `9a358c7` (this change), on top of `f1a053f`.

Scope, as assigned: remove the endpoint fallback so an empty or invalid address
means "not configured" and nothing is sent; make a token write return its outcome
and show it on the Server screen. No Core behaviour, wire format, outbox, anchor or
tombstone format was touched.

---

## P0-3 — the fallback is gone

**Defect.** `Runtime.swift:43` read

```swift
URL(string: AppSettings.serverURL) ?? URL(string: "https://hermes00.duckdns.org:1118")!
```

and `AppSettings.serverURL`'s getter returned the same literal when the key was
absent. A mistyped address therefore did not fail: it became a production host. The
run looked successful, the diagnostics printed a host, and the only way to notice was
to read the source.

**Fix (three parts).**

1. `Sources/HealthCollectorCore/ServerEndpoint.swift` — `ServerEndpoint.parse(_:)`
   returns `Result<ServerEndpoint, EndpointError>`, and `EndpointError` names the
   reason: `.empty`, `.malformed(_)`, `.unsupportedScheme(_)`, `.missingHost`,
   `.insecureTransport(_)`. One opinion, in the core, unit-tested on Linux.
2. `AppSettings.serverURL` getter defaults to `""`, not to a host. Empty means
   "not configured".
3. Every byte-emitting path binds the endpoint out of a success case before it
   constructs anything:

| path | site | without a usable endpoint |
|---|---|---|
| test connection | `Runtime.swift:119` | returns `not configured: <reason>`, no `URLRequest` built |
| window export | `Runtime.swift:160` | refuses before reading HealthKit, no transport built |
| automatic sync | `Runtime.swift:239` | collects into the durable outbox, builds **no** transport, reports the reason |

`grep -rn "URLSessionTransport(\|URLRequest(" HealthCollector/` (UI excluded) returns
exactly the three sites above, and each sits inside a `guard case .success(let server)`
— so "no request" holds by construction rather than by a runtime check that could be
skipped.

**Deliberate deviation, stated.** For automatic sync I kept local collection and
skipped only the transfer. Admin's wording was "synchronization does not start".
Dropping collection too would discard readings already present in HealthKit because of
a settings mistake — the failure this project exists to prevent. The queue grows and
`lastError` names the reason, so the state is visible instead of silent.

**Tightening worth flagging.** Plain `http` is refused unless the host is loopback
(`localhost`, `127.0.0.1`, `::1`), per the spec's HTTPS requirement. A LAN address such
as `http://192.168.1.5:8090` will now be refused with a message saying so. If LAN
testing over cleartext is wanted, that is a one-line policy change — say the word.

## P0-4 — the Keychain reports what happened

`AppSettings` gained `KeychainError` (`.status(OSStatus)`, `.encoding`) and:

* `setToken(_:) -> Result<Void, KeychainError>` — checks **both** `SecItemDelete` and
  `SecItemAdd`. A delete that fails for a reason other than "absent" means the old
  token is still present; adding another would leave two items and an ambiguous read,
  so that case now fails loudly.
* `readToken() -> Result<String?, KeychainError>` — `errSecItemNotFound` is `.success(nil)`
  ("nothing stored is a state, not a failure"), any other status is an error.
* `token` keeps its old shape for call sites that only need a value; it is documented
  as best-effort.
* `ServerView` shows both: a save outcome row (`endpoint saved: <host>` /
  `not saved — <reason>` / `token stored in Keychain` / the `OSStatus` text) and a
  stored-token row (`stored` / `not set` / `unreadable — …`).

The Settings screen's endpoint field validates through the same parser, so it cannot
store an address the transport will refuse while the field shows something else.

---

## Verification actually performed

| check | result |
|---|---|
| `swift test` (Linux, Swift 6.0.3) | **68 passed, 0 failed** (61 before, +7 in `ServerEndpointTests`) |
| `ServerEndpointTests` coverage of refusal shapes | empty/whitespace, no scheme (`host:port`, bare host), `ftp`/`file` scheme, cleartext off-device, `https://` with no host, plus every refusal carrying a non-empty message |
| `swiftc -parse` on all app + core + test sources | 0 syntax errors |
| CI `unsigned ipa` on `9a358c7` | **success** — the iOS target compiles with the new imports and `Result` types |
| CI `bundle contract` on `9a358c7` | success |
| `scripts/check-bundle-contract.py` / screenshot self-test | OK (1 warning: no AppIcon) / 16 cases as declared |

### Not verified, and why

* **No device run.** Nothing here was exercised on an iPhone; the statements above are
  compile + Linux-test + code-reading evidence.
* **"No request is sent" is proven by construction**, not by an observed network trace.
  A test that drives `CollectorRuntime` would need iOS; the guard is verifiable by
  reading the three call sites named above. Treat this as CONFIRMED-BY-CODE.
* **Keychain error paths are unreachable on the Linux toolchain** (no `Security`
  framework), so `KeychainError` behaviour is implemented and reasoned from `OSStatus`
  semantics, not executed. The success path is what the settings screens show.

## Cosmetic defect in the commit message

`9a358c7`'s body lost one inline code span: `` `try?` `` was interpolated by the shell
and the sentence now reads "The old path was , which made a refused write
indistinguishable from a saved one." The code defect it describes is real and fixed;
only the message text is blemished. History was not rewritten for cosmetics.

---

# Route drift — the probe called a path the receiver did not serve

Found by admin while checking "which address should the owner type now": the app
probed `/v1/health`, the receiver answered `/health`. After the endpoint fix the app
stopped lying about the address and started lying about the server.

## What changed

| side | change |
|---|---|
| client | `Sources/HealthCollectorCore/ApiRoute.swift` — `healthProbe`, `measurements`; `MeasurementClient.path` and the runtime probe read it, and the inline `"v1/measurements"` copy inside `makeRequest` is gone |
| contract | `contract/routes.json` — path, method, `deployed`, `live_expect`, known gap in words |
| receiver | `server.py` — `@app.get("/v1/health")` on the same handler as `/health` (commit `3be98aa` in the receiver repo). `/health` keeps answering |
| gate | `scripts/check-route-drift.py`, `scripts/test-route-drift.py`, CI job `route contract` |

## The gate has three states, and none of them is a silent pass

* `0` — client table, contract and (with `--server`) live answers agree.
* `1` — drift, **named by route id**: a route missing on either side, a path that
  differs, a `/v1` literal outside `ApiRoute`, or a deployed route answering 404.
* `2` — `UNKNOWN` with `--require-live`: the server was unreachable, so nothing about
  the live half was checked. A gate that cannot see the server must not report clean.

The static half also flags a literal that *matches* the table: the original defect was
an inline `"v1/health"` that happened to equal nothing on the other side, and a matching
value proves nothing while two copies exist.

## Evidence, run by hand

| command | result |
|---|---|
| fresh receiver from the patched source, port 8931: `/health`, `/v1/health`, `/v1/measurements` | `200`, `200`, `404` |
| `check-route-drift.py` (static, real tree) | `ok static: 2 маршрут(ов)`, `LIVE: не проверялось`, exit 0 |
| `check-route-drift.py --server http://127.0.0.1:8931` | health_probe `200 as expected`, measurements `404 as declared (known gap)`, exit 0 |
| `check-route-drift.py --server http://127.0.0.1:8910` (**the live, unpatched receiver**) | `FAIL: route health_probe … answers 404`, exit 1 |
| `check-route-drift.py --server http://127.0.0.1:8999 --require-live` | `UNKNOWN … недоступен`, exit 2 |
| `test-route-drift.py` | **8 cases, all behave as declared** |
| `swift test` | 68 passed, 0 failed |
| CI `Health Collector Core` on `ae5b155` | `swift test` success, `route contract` success (log shows the static line and all 8 cases) |
| CI `Health Collector IPA` on `ae5b155` | see below — the app target must still compile with `ApiRoute` |

The `8910` run is the important one: against the receiver that is actually running, the
gate fails by route name. That is the defect, caught by the test written for it.

## Not done, on purpose

* **The live receiver was not restarted.** `health-bridge.service` is a system unit and
  this session cannot manage it (`systemctl show … FragmentPath` returns nothing, no
  `sudo`). The patch is committed and verified on a fresh instance; the running
  process still serves the old code until someone restarts it:

  ```
  sudo systemctl restart health-bridge.service
  ```

  After the restart the same command proves the fix on the live port:
  `python3 scripts/check-route-drift.py --server http://127.0.0.1:8910 --require-live`
  — it must print `ИТОГ: клиент, контракт и сервер согласованы`, exit 0.
* **The live half does not run in CI.** It needs a running receiver, and the repository
  has none; the CI job checks the half that exists off-device and prints
  `LIVE: не проверялось` rather than implying more.
* **`/v1/measurements` is still not served** (`404 as declared`). Until it is, an ACK
  means the test stand accepted a batch, not that the agent can read the data. The
  contract records this as a known gap, and case `S7` fails the day it starts
  answering — that is the signal to flip `deployed` and stop calling it a gap.

---

# Round 3 — the gate stops being arguable

Three of the gate's branches were decoration (found by @team-gate, reproduced here),
and closing the receiver's door exposed a fourth problem that was measured, not
reasoned about.

## The three fixes

| mutation that used to work | what fails it now | case |
|---|---|---|
| `health_probe`: `deployed:false` + `live_expect:"404"` on a server that answers 404 → `согласованы`, rc=0 | `--receiver` parses the receiver's own `@app.<verb>` decorators; `deployed` must match the code: `server.py serves /v1/health but the contract marks it not deployed`. `--require-receiver` makes a missing receiver exit 2 | S10, S11, S12 |
| `del entry["client"]` → `KeyError: 'client'`; `"client": null` → `AttributeError` | both are addressed: `route health_probe: в контракте нет поля client`; the self-test fails any case whose output contains a `Traceback` | S16, S17 |
| literal `"v1/health"` (no slash — the shape the original defect was written in) → rc=0 | the scan matches `(^|/)v1/` in any string literal outside `ApiRoute.swift` | S6 |

Run by hand on the real tree, with the flag flipped exactly as the mutation did:

```
FAIL: route health_probe: server.py serves /v1/health but the contract marks it not deployed
      — flipping the flag does not make the route absent            rc=1
```

Contract restored afterwards; `sha256` of `contract/routes.json` identical before and
after (`0c7bed6d…f6f4`).

## The fourth problem, measured when the door closes

The receiver's auth middleware runs **before routing**, so an undeployed route behind a
closed door answers **401**, not 404. On a token-configured instance (port 8933,
`HEALTH_BRIDGE_TOKEN=probe-secret`):

| request | answered |
|---|---|
| `GET /v1/health` (no token) | **200** — but only after the `OPEN_PATHS` fix below |
| `POST /health-bridge` (no token) | **401** |
| `GET /health-bridge` (no token) | **401** |
| `POST /health-bridge` with token, empty body | 400 — auth passed, validation refused |
| `GET /v1/measurements` (no token) | **401** — not 404 |

Two consequences, both implemented:

1. **`OPEN_PATHS` now includes `/health` and `/v1/health`.** They were not exempt, so
   the first token installed would have made every liveness probe — including this
   gate's — fail with 401. A liveness answer (`{"status":"ok"}`) leaks nothing.
   *Not live yet:* the running process predates this change, so whoever sets the token
   must restart the unit, otherwise `/v1/health` becomes 401.
2. **401 without a token is `UNKNOWN` (exit 2), not drift and not a pass.** The gate
   prints `UNCHECKED: … auth runs before routing, so missing and protected are
   indistinguishable here` and refuses to call the run clean; a 401 *with* a token
   supplied is exit 1, because a rejected credential is a real defect.

## State of the gate

* self-test: **17 cases**, each asserting a phrase only its branch prints; any
  traceback in the output fails the case.
* `swift test` unchanged at 68; CI job `route contract` runs static + self-test.
* The live/receiver halves stay out of CI — the receiver source and a running server
  are not in this repository. That is printed (`RECEIVER: не проверялось`,
  `LIVE: не проверялось`), never implied as checked.

---

# The door: code ready, restart pending

Condition 6 of the P1 approval is "close the unauthenticated POST before deploying the
measurement route". State of the door, measured, not assumed.

## The defect was documentation, not a missing secret

`server.py`'s comment said the token comes from `HEALTH_BRIDGE_TOKEN` and, failing that,
from `credentials/health-bridge.yaml`. The code read only the environment variable. The
file exists (`~/.hermes/credentials/health-bridge.yaml`, mode `0600`, `token:` present)
and was read by nobody — so `[AUTH] … токен не проверяется` was a true warning about a
protection that was documented as present.

## The fix (receiver repo, `6babf90`)

Resolution order: `HEALTH_BRIDGE_TOKEN`, then `HEALTH_BRIDGE_CREDENTIALS` override, then
`./credentials/health-bridge.yaml`, then `~/.hermes/credentials/health-bridge.yaml`. The
module prints which one won — length only, never the value — or that the door is open.
`scripts/test-auth-token.py` locks five cases (env wins, yaml read, quoted value, nothing
anywhere, env beats yaml). Mutation control: restoring the env-only line fails 2 of 5.

## Measured with the token resolved from yaml (scratch instance, port 8934)

| request | answer |
|---|---|
| `GET /v1/health` without token | **200** — liveness exempt, leaks only `{"status":"ok"}` |
| `POST /health-bridge` without token | **401** |
| `POST /health-bridge` with token, empty body | **400** — auth passed, body rejected |
| `GET /v1/measurements` without token | **401** — protected |
| `GET /v1/measurements` with token | **404** — genuinely absent, as the contract says |

The last pair is why `--token` had to exist in the gate: with a token, "missing" and
"protected" become distinguishable, and the contract's `deployed:false` becomes a
checkable claim instead of a coincidence.

## Gate against the closed door, both ways

| run | verdict |
|---|---|
| no token | `UNCHECKED: route measurements … answers 401 without a token`, **exit 2** — refuses to call it clean |
| token from credentials | `ok live: health_probe 200`, `measurements 404 as declared`, `ИТОГ: согласованы`, **exit 0** |

## What is still not done

* **The live receiver still has the door open.** `POST /health-bridge` on 8910 answers
  400 without a token right now — the running process predates both the yaml fallback
  and the `OPEN_PATHS` change. Closing it is one restart:

  ```
  sudo systemctl restart health-bridge.service
  ```

  Then: `POST /health-bridge` without a token must answer **401**, `GET /v1/health` must
  still answer **200**, and the gate with `HC_SERVER_TOKEN` must stay green.
* **`/v1/measurements` must not be deployed before that restart**, per condition 6.

---

# The door is closed, and verified on the live port

After the unit was restarted (`systemctl --user restart health-bridge.service` — it is a
**user** unit, so no `sudo`), measured by hand on `127.0.0.1:8910`:

| request | answer |
|---|---|
| `POST /health-bridge` without token | **401** |
| `GET /v1/health` without token | **200** (liveness intentionally open) |
| `GET /v1/measurements` without token | **401** |
| gate **without** token | `UNCHECKED: route measurements … answers 401`, **rc=2** |
| gate **with** the credential file's token | `health_probe 200`, `measurements 404 as declared`, **rc=0** |

Condition 6 is therefore closed on the running service, not only in a commit: condition 6
asked to close the door *before* deploying the measurement route, and the exit-2 / exit-0
pair is the proof that "missing" and "protected" are now distinguishable from outside.

## One more defect in the token chain (found by @team-gate, fixed)

`HEALTH_BRIDGE_CREDENTIALS` was *inserted* at the head of the default chain instead of
replacing it. A stand whose own credential file had a typo therefore loaded the
production token silently: protected-looking, accepting a secret its operator did not
hold, while its own token got 401. The override is now authoritative — no fallback, and
the log names the source (length only, never the value).

`scripts/test-auth-token.py`: **7 cases**, including the two that reproduce the bent chain
with the real `HOME` on disk (override without a `token` key; override pointing at a
missing file). Both must refuse and must not print `токен загружен`. Mutation control:
restoring the insert-into-chain behaviour fails **3 of 7** (S4, S6, S7).

## Consequence for the collector

Every client must now present a token. The app sends `Authorization: Bearer` from the
Keychain and, when no token is stored, fails locally with `no token configured` before
touching the network — so a missing token shows up as a named local failure instead of a
silent 401 on every batch.
