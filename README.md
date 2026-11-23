# Health Collector — reliability core

The part of the Apple Health collector that can be proven without a phone: durable
outbox, per-record acknowledgement, retry classification, tombstones, cursors.

The app target (`com.braintimebox.healthcollector`) and the HealthKit adapter are
not here. They need a Mac with a signing identity: CI in `hermex-plus` archives with
`CODE_SIGNING_ALLOWED=NO` and zips `Payload`, so its IPA cannot be installed on a
phone and no HealthKit fact can be measured from it.

## Layout

```
Sources/HealthCollectorCore/
  Wire.swift          identity, payloads, the HTTPS contract, timestamps with offset
  Outbox.swift        the durable queue: states, claim/settle, atomic rewrite
  Transport.swift     ack shape, failure shape, retry policy and classification
  SyncEngine.swift    one drain: claim → send → apply the answer
  Collector.swift     source seam, per-type cursors, collect-then-advance
  Status.swift        diagnostics derived from stored state only
Tests/HealthCollectorCoreTests/
  Support.swift       fake server (unique constraint + tombstones), scripted source
  DurabilityTests.swift
  SyncTests.swift
  ReimportTests.swift
  WireTests.swift
```

## What the suite proves, and what it cannot

| Behaviour | Proven here | Needs a device |
|---|---|---|
| Network down → rows retained | ✅ fake transport that throws | |
| Network back → backlog drains oldest first | ✅ | |
| 5xx / timeout / 429 → backoff, cap, `Retry-After` | ✅ injected clock | |
| 4xx → dead-letter, not an infinite retry | ✅ | |
| App killed → queue intact, `inflight` reset | ✅ reopen the store from disk | |
| Same batch twice → one row | ✅ | |
| Partial ack → only unacked resent | ✅ | |
| Unreadable ack → unconfirmed, resent | ✅ | |
| Batch is on disk before a background upload reads it | ✅ spool file asserted at send | |
| `handleEventsForBackgroundURLSession` re-arms the next batch | ✅ | |
| Nothing new for 36 h is not called HEALTHY | ✅ | |
| Delete stays deleted after a full reimport (A7) | ✅ tombstones in the fake server | |
| Locked store ≠ empty store | ✅ at the seam | real locked device |
| Observer / background delivery wake | | ✅ |
| Reboot recovery | | ✅ |
| Per-type update frequency | | ✅ — Apple publishes no table |

## Rules encoded here, and why

- **Identity is `(user, source uuid)`.** Type, unit and value are attributes. Folding
  the type into the key turns a re-classification into a duplicate; folding the value
  in turns any correction into one.
- **Persist before send.** The outbox row is on disk before any network call, and the
  cursor advances only after the rows are queued. A crash replays a window; it never
  skips one.
- **Deletes are records with tombstones.** The server must accept a delete for an id it
  has never seen. Without that, a full re-import — which a free Personal Team forces
  weekly — resurrects deleted measurements and the divergence becomes unfixable.
- **A bare 200 is not a proof.** The client settles rows only from named ids. An
  unreadable answer is `unconfirmed`: resend, because idempotency makes it free.
- **Status comes from the store.** Queue depth and the age of the oldest unacked row are
  derivable and checkable; "the app ran" is not.

## Background transfer

The batch is written to disk (`BatchSpool`) before the transport sees it, because
a background `URLSession` uploads from a file and survives the process. The wake
that iOS sends when that upload finishes is handled by `BackgroundWake`: settle the
finished file, then arm the *next* one — otherwise the trigger fires once and the
outbox stays full. A force-quit cancels the transfers and suppresses the relaunch,
so recovery after force-quit happens on the next manual launch, and that is a
platform rule, not a defect.

## Run

```sh
swift test
```

Verified on Swift 6.0.3 (Linux x86_64). The package is pure Foundation: no HealthKit,
no UIKit, no third-party dependency.
