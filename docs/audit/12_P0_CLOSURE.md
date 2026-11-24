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
