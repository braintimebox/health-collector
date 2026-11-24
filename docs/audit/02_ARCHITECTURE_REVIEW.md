# 02 — Architecture review

Слои и границы (CONFIRMED по коду):

```
┌──────────────────────────── UI (SwiftUI) ────────────────────────────┐
│ Shell.swift (TabView + 3 NavigationStack)                            │
│ ExportTab / BrowseTab / SettingsTab (+ Views: Manual, Automated,     │
│ Server, Help, Workouts, Sleep, Permissions, Advanced, About…)        │
└───────────────┬──────────────────────────────────────────────────────┘
                │ @ObservedObject snapshot, вызовы syncNow/testServer
┌───────────────▼────────── Application / State ───────────────────────┐
│ CollectorRuntime (@MainActor ObservableObject)                       │
│   Snapshot (published) · serial DispatchQueue · settings-чтение      │
│ AppSettings (static, UserDefaults + Keychain)                        │
└───────┬───────────────────────────────┬──────────────────────────────┘
        │                               │
┌───────▼──────── HealthKit ─────┐  ┌───▼──────── Transport ───────────┐
│ HealthKitSource (HKHealthStore)│  │ URLSessionTransport              │
│ anchored+observer+bg delivery  │  │ (URLSession + DispatchSemaphore) │
└───────┬────────────────────────┘  └───┬──────────────────────────────┘
        │ FetchResult                    │ WireBatch → ServerAck
┌───────▼──────────────── Collection Core (package, Linux-tested) ────┐
│ Collector (anchors→outbox→cursor) · OutboxStore · SyncEngine         │
│ AnchorStore · Transport (policy/classification) · Wire · BatchSpool  │
│ BackgroundWake · Status                                              │
└──────────────────────────────────────────────────────────────────────┘
```

| Компонент | Назначение | Зависит от | Источник состояния | Тесты |
|---|---|---|---|---|
| Shell | 3 вкладки, стеки, launch-args | Runtime | локальный `@State` | нет |
| ExportTab/Browse/Settings | презентация | Runtime, AppSettings, HealthKitBrowse | `@State` + snapshot | нет |
| CollectorRuntime | владелец очереди и цикла | core, HealthKitSource, Transport | `@Published snapshot` | нет |
| AppSettings | конфигурация | UserDefaults, Keychain | статические геттеры | нет |
| HealthKitSource | чтение HealthKit | HealthKit | курсовики в AnchorStore | косвенно (фейк) |
| Collector/Outbox/SyncEngine | durability и доставка | — | файлы на диске | 61 тест |

## Runtime lifecycle (фактический)

```
Shell.task ──▶ runtime.start()                    каждый запуск, включая после reboot
                 ├─ HealthKitSource.startObservers { syncNow("observer") }   HKObserverQuery
                 └─ snapshot ← CollectorStatus.make(...)
scenePhase: background / foreground ──▶ Shell: runtime.refresh()
кнопки Manual / Server / Advanced ──▶ syncNow("manual")
queue.async { collectOnce → drain }  ──▶ Task{@MainActor} snapshot
```

Чего нет: `BGTaskScheduler`, планировщика по времени, дедупликации одновременных запусков. Два
нажатия подряд ставят в serial-очередь два полных прохода (не параллельно, но дважды). Запуск
синхронизации **не зависит** от `automationEnabled` — это и есть дефект «фиктивного тумблера».

## Точки отказа (CONFIRMED)

1. `Runtime.swift:43` — неверный URL молча заменяется production-адресом.
2. `HealthKitSource.swift:158,204` и `Runtime.swift:280` — блокирующее ожидание 30/45 с; очередь стоит,
   пока не истечёт таймаут.
3. `AppSettings.swift:33-34` — ошибки Keychain проглатываются.
4. `HealthKitSource.swift:115-118` — результат `enableBackgroundDelivery` не сохраняется и не виден в
   диагностике: «фон включён» нигде не подтверждается.

## Покрытие тестами

Слой core — 61 тест. Слой приложения (Runtime, AppSettings, все View) — **ноль тестов**. Это главный
архитектурный разрыв: всё, что знает про iOS, не проверяется вообще.
