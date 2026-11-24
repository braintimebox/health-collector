# 10 — Target architecture 2.0

Каждая абстракция ниже закрывает конкретный дефект из аудита; ничего «для паттерна».

```
┌─ UI (SwiftUI) ────────────────────────────────────────────────────────┐
│ Shell · Export · Browse · Settings                                    │
│ только @ObservedObject AppState + вызовы use-case'ов                  │
└───────────────┬───────────────────────────────────────────────────────┘
┌───────────────▼─ AppState (MainActor, single source of truth) ────────┐
│ @Published config: Config      ← валидируется на записи, результат    │
│ @Published status: Status      ← из core Status, по событию и по таймеру│
│ @Published health: HealthState ← permission + background delivery      │
│ func save(_:Config) -> Result     func sync(reason:) async            │
└───────┬───────────────────────┬───────────────────────┬───────────────┘
        │                       │                       │
┌───────▼──── Config store ─┐ ┌─▼─ Runtime lifecycle ─┐ ┌▼─ HealthKit ──┐
│ UserDefaults + Keychain   │ │ start/background/     │ │ async adapter │
│ результаты записи наружу  │ │ foreground/reboot     │ │ без семафоров │
└───────────────────────────┘ │ один sync за раз      │ └───────────────┘
                              └───────────┬───────────┘
┌─ Domain (без UIKit) ────────────────────▼─────────────────────────────┐
│ Collector · SyncEngine · RetryPolicy · ErrorModel                     │
└───────────┬──────────────────────────────────────┬────────────────────┘
┌───────────▼─ Data ────────────────┐  ┌───────────▼─ Infrastructure ──┐
│ OutboxStore · AnchorStore         │  │ URLSession async transport    │
│ (форматы не меняются)             │  │ TLS · отмена · таймауты       │
└───────────────────────────────────┘  └───────────────────────────────┘
```

## Решения и какую проблему закрывают

| # | Решение | Проблема из аудита |
|---|---|---|
| 1 | `AppState` вместо статических `AppSettings` | два зеркала настройки, запись без результата |
| 2 | `Config.save` возвращает `Result` | молчаливая потеря токена и URL |
| 3 | Валидация endpoint, без fallback | отправка данных на чужой сервер |
| 4 | `AutomationEnabled` читается в `start()` и планировщике | фиктивный тумблер |
| 5 | Async HealthKit-адаптер | семафоры 30 с, стоящая очередь |
| 6 | `HealthState` с `backgroundDelivery: enabled/denied/unknown` | «фон не наблюдается» |
| 7 | Один sync за раз (актор) | параллельные прогоны из observer и UI |
| 8 | Единая `ErrorModel` (transport/storage/permission/config) | разные тексты для одного класса ошибок |
| 9 | Статус обновляется по таймеру и по событию | UI не видит роста очереди без ручного запуска |
| 10 | Расширяемые категории: `TypeRegistry` вместо хардкода | добавление типа требует правок в трёх местах |

## Что НЕ меняется

`Outbox` (формат `outbox.json`), `AnchorStore` (`anchors.json`), `Wire` (контракт `(user_id,
record_id)`, `accepted/rejected`, tombstone), `RetryPolicy`. Это самые проверенные части (61 тест);
менять их ради архитектуры — риск без выгоды.

## Чего в 2.0 сознательно нет

- Мультипользовательности.
- Собственного сервера на телефоне.
- Фоновой загрузки через `BGTaskScheduler` сверх уже зарегистрированной `URLSession`.
- Локализации (структура готова, строки пока инлайн).
