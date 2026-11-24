# 01 — Crash investigation: Settings

Статус: **ОТКРЫТО**. Причина не установлена; ниже — что проверено, что исключено и что нужно
для доказательства.

## Что известно (FACT)

- Владелец сообщает: приложение вылетает при открытии App Settings.
- Версия на устройстве: 1.0.0 (unsiged IPA подписан владельцем — сборочный артефакт подписи не несёт).
- В симуляторе (`macos-26`, iOS 26.5, iPhone 16 Pro) вкладка Settings открывается: до этого релиза
  снимок `settings.png` снимался успешно в каждом прогоне (8 кадров, включая тёмный проход).
- Подэкраны Settings снимались только два: `Advanced` (`advanced.png`). Остальные пять —
  Health Permissions, Export Settings, Unit Preferences, Notifications, About — **ни разу не
  открывались** ни в CI, ни на устройстве (CODE: `.github/workflows/health-collector-ipa.yml`).

## Что исключено

- Синтаксис всех файлов Settings: `swiftc -parse` — 0 ошибок.
- Обрыв навигации в `SettingsTab`: `navigationDestination` имеет ветку для каждого пункта
  (добавлены `Unit Preferences`, `Notifications`, `About`; ранее три пункта давали пустой экран —
  это дефект, но он не роняет процесс).
- Keychain: чтение через `SecItemCopyMatching` возвращает `nil` при любой ошибке, исключения не
  бросает; `AppSettings.token` вызывается только из `ExportSettingsView`/`ServerView`, не из корня
  Settings.

## Гипотезы, по убыванию правдоподобия

1. **Краш на конкретном подэкране, а не на корне Settings.** Все пять непроверенных подэкранов
   содержат либо `Button` с `UIApplication.shared.open("x-apple-health://")`, либо `UIPasteboard`,
   либо ссылку на `runtime.diagnosticsText()`. Любой из них вызывается только по нажатию, поэтому
   краш при «открытии App Settings» скорее означает переход в подраздел.
2. **Подпись/entitlements.** Бандл подписан сторонним сертификатом; если профиль не даёт
   `com.apple.developer.healthkit`, отказ приходит при первом обращении к HealthKit. В корне Settings
   обращений нет, но `PermissionsView` вызывает `runtime.requestPermissions()` — это HealthKit.
   Если владелец открыл именно Permissions, отказ без entitlement может привести к падению.
3. **Повторное открытие экрана.** `PermissionsView` держит `@ObservedObject var runtime` и кнопку,
   которая мутирует `runtime.snapshot` из `Task` — при повторном входе возможен конфликт обновлений.
   Не доказано.

## Что нужно для доказательства

Крэш-лог с устройства: **Settings → Privacy & Security → Analytics & Improvements → Analytics Data →
`HealthCollector-2026-… .ips`**. В нём будет строка `Exception Type` и символ вида
`HealthCollector.<функция>`. Без него любая из трёх гипотез остаётся гипотезой.

## Что сделано в этом раунде

- `navigationDestination` дополнен тремя отсутствовавшими экранами, неизвестный маршрут больше не
  рендерит пустоту.
- CI теперь открывает и снимает **все шесть** подэкранов Settings, поэтому «пустой/упавший экран»
  станет виден в прогоне, а не в отчёте.
