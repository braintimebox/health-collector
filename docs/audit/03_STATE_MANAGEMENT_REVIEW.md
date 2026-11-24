# 03 — State management review

## Найденные источники истины (CONFIRMED)

| Состояние | Где живёт | Кто пишет | Кто читает |
|---|---|---|---|
| endpoint | `UserDefaults["hc.serverURL"]` (`AppSettings.swift:13`) | ServerView, ExportSettingsView | Runtime (`:43`), diagnostics |
| token | Keychain (`AppSettings.swift:33-34`) | ServerView | Runtime |
| automation | `UserDefaults["hc.automationEnabled"]` | ExportTab:182, SettingsTab:77 | **никто** |
| очередь/статус | `CollectorRuntime.snapshot` (`@Published`) | только `syncNow` | все экраны |
| очередь на диске | `outbox.json` (core) | SyncEngine/Collector | Runtime при сборке снапшота |

## Дефекты

1. **Двойное зеркало настройки.** `ExportTab` держит `@State enabled` и `SettingsTab` — `@State
   automated`, оба инициализируются из `AppSettings` и пишут обратно. Изменение в одном экране не
   обновляет второй: пользователь видит расхождение. (CONFIRMED кодом.)
2. **Значение без потребителя.** `automationEnabled` не влияет ни на `start()`, ни на `syncNow` —
   тумблер декоративен. (CONFIRMED grep'ом: только записи.)
3. **Снапшот обновляется только по событию синхронизации.** Если данные изменились извне (например,
   очередь выросла при фоновом запуске), экран не узнает об этом до следующего ручного запуска.
   (POTENTIAL: зависит от того, вызывает ли background wake `syncNow`; по коду вызывает только
   `startBackgroundDelivery`-колбэк.)
4. **Ошибки записи конфигурации не наблюдаемы.** Интерфейс не различает «сохранено» и «не сохранено».
   (CONFIRMED: `try?`.)

## Предлагаемая модель (RECOMMENDATION)

Один наблюдаемый `AppState` (MainActor), который владеет:

```
AppState {
  @Published config: Config            // единственный источник: url, token, automation, типы
  @Published status: CollectorStatus   // очередь, ошибки, время
  @Published permission: PermissionState
  func save(config:) throws            // валидирует и возвращает ошибку
  func sync(reason:) async
}
```

Правила: View не читает `UserDefaults`/Keychain напрямую (только через `AppState`); запись
конфигурации возвращает `Result`, и экран обязан показать ошибку; `AutomationEnabled` **обязан**
читаться в `start()` и в планировщике пробуждений.
