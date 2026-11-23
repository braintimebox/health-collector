# Health Collector

Native iOS Apple Health collector with a durable outbox, plus the reliability core that
can be proven without a phone. Separate app target and separate repository on purpose:
`hermex-plus` is a different product, and adding health entitlements to a shipping
TestFlight build was rejected as a production risk.

## Состояние (2026-11-23)

| Часть | Где | Статус |
|---|---|---|
| Ядро: outbox, движок синхронизации, курсоры, ретраи | `Sources/HealthCollectorCore` | **54 теста, 0 падений** (Linux, Swift 6.0.3) |
| HealthKit-адаптер: authorization, `HKAnchoredObjectQuery`, `HKObserverQuery`, background delivery, отдельные anchors по типам | `HealthCollector/HealthKitSource.swift` | написан, компилируется, **на устройстве не проверен** |
| Рантайм, HTTPS-транспорт, панель диагностики | `HealthCollector/Runtime.swift` | то же |
| Цель приложения, entitlements, Info.plist | `HealthCollector.xcodeproj` | неподписанный IPA собирается в CI |
| Контракт бандла и проверка сборки | `scripts/check-bundle-contract.py` | 6/6 мутаций ловятся |
| Архитектурное решение | `docs/adr-001-architecture.md` | ADR-001, сравнение восьми вариантов |

## Что НЕ проверено — и почему это написано здесь, а не в отчёте

- **Устройство.** Ни один кейс A1–A8 не прогонялся: нужен подписанный профиль. Компиляция и
  линковка доказаны CI, реальное чтение HealthKit, фоновые доставки и поведение после
  перезагрузки — нет.
- **Профиль.** Несёт ли он `com.apple.developer.healthkit` и `…healthkit.background-delivery`,
  проверяется `scripts/check-profile.py` по файлу профиля до установки: runtime-проба не отличит
  отсутствие entitlement от отказа пользователя.
- **Сеть до сервера.** Транспорт написан и покрыт фейком в ядре, против живого маршрута не гонялся.

## Исправления по ревью fecdad8

| # | Дефект | Исправление | Замок |
|---|---|---|---|
| BUG-01 | `oldestPendingAge()` возвращал `min` — очередь, стоящая сутки, выглядела свежей | `max` | `test_BUG01_*` (3 записи разного возраста) |
| BUG-02 | непрочитанный ack повторялся немедленно — цикл по серверу, который уже плохо себя чувствует | ограниченный backoff через `RetryPolicy.cap`, попытка не переводит строку в dead | `test_BUG02_unconfirmedBackoffGrowsAndIsCapped` |
| BUG-03 | ack по одному `record_id` подтверждал и insert, и delete | batch держит одну операцию на идентичность; неоднозначный batch не подтверждает ничего | `test_BUG03_*` (2 теста) |
| — | acked-записи не чистились никогда | `pruneAcked(keeping:)` вызывается после каждого drain | `test_pruneAcked*`, `test_ackedRowsDoNotGrowForever*` |
| — | модель конкурентного доступа не была определена | один владелец (`CollectorRuntime.queue`), замки в сторах для чтения из UI | `test_concurrentEnqueues*`, `test_anchorStoreIsSafeToReadWhileWriting` |

## Layout

```
Sources/HealthCollectorCore/
  Wire.swift          identity, payloads, HTTPS contract, timestamps with offset
  Outbox.swift        durable queue: states, claim/settle, atomic rewrite, pruning
  Transport.swift     ack/failure shapes, retry policy, classification
  SyncEngine.swift    one drain: claim → send → apply the answer
  Collector.swift     source seam, per-type cursors, collect-then-advance
  Status.swift        diagnostics derived from stored state only
  BatchSpool.swift    batch on disk before a background upload reads it
  BackgroundWake.swift re-arm the next batch when an upload finishes
HealthCollector/
  HealthKitSource.swift  the only file that talks to HealthKit
  Runtime.swift          owner queue, URLSession transport, diagnostics view
  Info.plist, HealthCollector.entitlements
scripts/
  check-bundle-contract.py   entitlements, Info.plist, project references
  test-bundle-contract.sh    six mutations that must make the checker fail
```

## Что доказывает набор тестов

Повторная отправка и дедупликация, backoff с потолком и `Retry-After`, dead-letter на 4xx,
переживание убийства процесса, частичный ack, непрочитанный ack, batch на диске до фоновой
загрузки, повторное взведение триггера, «тишина ≠ HEALTHY», удаление остаётся удалённым после
полного реимпорта, заблокированный стор не равен пустому. Всё это — без телефона.

## Rules encoded here, and why

- **Identity is `(user, source uuid)`.** Type, unit and value are attributes. Folding the type
  into the key turns a re-classification into a duplicate.
- **Persist before send.** Cursor advances only after rows are queued: a crash replays a window,
  never skips one.
- **Deletes are records with tombstones.** The server accepts a delete for an id it has never
  seen; otherwise a full re-import resurrects deleted measurements.
- **A bare 200 is not a proof.** Rows settle only from named ids.
- **Status comes from the store**, never from "the app ran".

## Run

```sh
swift test
python3 scripts/check-bundle-contract.py
```

CI (`.github/workflows/health-collector-ipa.yml`): `contract` на Linux, затем `ipa` на macOS —
`swift test`, сборка приложения, проверка что HealthKit и ядро реально попали в бинарник,
контракт Info.plist/entitlements, неподписанный IPA в артефактах.
