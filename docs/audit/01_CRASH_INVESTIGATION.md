# 01 — Crash investigation: Settings

Статус: **ОТКРЫТО**. Причина не установлена; доказательство отсутствует.

## Факты (CONFIRMED)

- Владелец сообщает падение при открытии App Settings; версия 1.0.0, подписана владельцем.
- В симуляторе (`macos-26`, iOS 26.5) вкладка Settings открывается: снимок `settings.png` снимался
  в каждом прогоне, включая тёмный проход.
- Из шести подэкранов Settings в CI открывался **только Advanced**; остальные пять не открывались
  ни разу (`grep 'capture light settings' .github/workflows/health-collector-ipa.yml` до `852e6e1`).
- `SettingsTab` до `852e6e1` имел `default: EmptyView()` в `navigationDestination` — три пункта из
  шести давали пустой экран.

## Исключено

- Синтаксис слоя Settings: `swiftc -parse` по 8 файлам приложения — 0 ошибок.
- Обрыв навигации: сейчас у каждого из шести пунктов есть назначение, неизвестный маршрут печатает
  текст, а не пустоту.
- Keychain как причина падения в корне Settings: `SecItemCopyMatching` возвращает `nil`, не бросает;
  токен читается только на Server и Export Settings (`AppSettings.swift:33`).

## Гипотезы (POTENTIAL, по убыванию)

1. Падает конкретный подэкран, а не корень. В `PermissionsView` кнопка вызывает
   `runtime.requestPermissions()` — единственный вызов HealthKit в стеке Settings. При профиле без
   `com.apple.developer.healthkit` это отказ, а не падение, но комбинация «отказ + повторный запрос»
   не проверялась ни разу.
2. Повторное открытие экрана: `PermissionsView`/`AdvancedView` держат `@ObservedObject var runtime` и
   мутируют `runtime.snapshot` из `Task`; при повторном входе возможен конфликт обновлений.
3. Подпись/entitlements как корень: без `…healthkit.background-delivery` `enableBackgroundDelivery`
   возвращает отказ, который сейчас игнорируется (`HealthKitSource.swift:115-118`).

## Что нужно

Крэш-лог: Settings → Privacy & Security → Analytics & Improvements → Analytics Data →
`HealthCollector-2026-… .ips`. Плюс уточнение: падает вкладка Settings **внутри приложения** или
страница приложения **в системных Настройках iOS** — это разные места.

## Что уже сделано

- `852e6e1`: все шесть подэкранов достижимы, неизвестный маршрут не рендерит пустоту.
- CI теперь открывает и снимает все шесть подэкранов Settings — «пустой/упавший экран» станет виден
  в прогоне.

## Регрессионный тест

UI-тест на открытие Settings и все шесть переходов **не написан**: в пакете нет UI-тестов, только
модульные на `HealthCollectorCore`. Это зафиксировано в `09_TESTING_GAPS.md` как P0.
