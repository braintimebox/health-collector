# 08 — Full UX audit

Карта экранов (CONFIRMED по коду и снимкам CI):

```
TabView
├── Export  (grid 2×3)
│   ├── Manual ───────── period picker · result counters · Collect and send
│   ├── Automated ────── toggle · last run · last success · queue · dead letter
│   ├── Server ───────── endpoint · token · test connection · send now
│   ├── Sync to Mac ──── «Not implemented» + что нужно
│   ├── Shortcuts ────── «Not implemented» + план
│   └── Help ─────────── permissions · collection · delivery · troubleshooting
├── Browse
│   ├── Recent (горизонтальные карточки, реальные значения)
│   ├── Metrics → MetricDetail (значение · время · источник · история · график · 5 периодов)
│   ├── Workouts → WorkoutDetail (тип · время · длительность · энергия · дистанция · источник)
│   ├── Sleep → SleepNight (стадии, сегменты)
│   └── Categories (Activity/Body/Nutrition — честно «not implemented»)
└── Settings
    ├── Health Permissions (честно) · Export Settings · Unit Preferences (заглушка)
    ├── Advanced (диагностика + copy) · Notifications (заглушка) · About
```

## Оценка по критериям ТЗ §6

| Критерий | Состояние |
|---|---|
| Информационная архитектура | три вкладки, шесть карточек Export, список Settings — соответствует HAE-структуре |
| Навигация | три независимых стека, состояние не сбрасывается; подэкраны Settings были недоступны (исправлено) |
| Визуальная иерархия | единый grouped-фон после правки; карточки одного веса |
| Терминология | смешана: «Collect and send», «Sync», «Test connection» описывают три разных действия; в Help это объяснено, на кнопках — нет |
| Плотность | Export — карточки (空气), Browse — списки; приемлемо |
| Empty/Loading/Error | Empty и Loading есть везде; offline-состояния **нет ни на одном экране** (POTENTIAL: неотличимо от ошибки сервера) |
| Отсутствие демо-значений | подтверждено: все значения из HealthKit или из состояния |
| Неработающие кнопки | Automatic toggle выглядит работающим и не работает — исключение, которое обязано исчезнуть |

## Что пользователь не может узнать (главная претензия ТЗ §6)

1. Работает ли сбор — нет: тумблер фиктивен, статус фона нигде.
2. Какие данные доступны — да, Browse.
3. Когда была последняя синхронизация — да, но только после ручного запуска.
4. Есть ли данные в очереди — да, Advanced/Export.
5. Есть ли ошибка — да.
6. Доставлены ли серверу — да, при условии, что сервер развёрнут (сейчас нет).

## Wireframes целевой версии (RECOMMENDATION)

1. **Status header на Export** — одна строка: `Collector: running · queue 3 · last sync 2 min ago ·
   server ok`. Заменяет необходимость ходить в Advanced за базовым ответом.
2. **Collection как первая секция Settings** — тумблер, состояние фона, типы, HealthKit.
3. **Server: валидация в строке** — красная строка при неверном URL, сохранение запрещено.
4. **Offline-баннер** — на Export и Browse: «нет сети, очередь сохранена» вместо молчания.
