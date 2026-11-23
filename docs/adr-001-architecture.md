# ADR-001 — архитектура Health Collector (2026-11-23)

Решение принимается оркестратором по запросу владельца: сравнить альтернативы и обосновать выбор,
не создавая новых уровней абстракции.

## Источники

| # | Источник | Что подтверждает |
|---|----------|------------------|
| 1 | `https://github.com/braintimebox/vitalcore` | существующий Worker `health-auto-sync`: маршруты `/telegram /health /status /analyze /drivers /debug /test`, R2-биндинг `HEALTH_JSON` |
| 2 | `https://github.com/hongyangchun/hae-api` | Worker+D1 для HAE REST: `metric_points` с ключом (metric,date,slot), `workouts`, query API, дашборд |
| 3 | `https://github.com/the-momentum/open-wearables` | MIT, 2815★, Python/FastAPI + PostgreSQL + Redis + Celery, Apple Health через собственный iOS SDK или XML-импорт |
| 4 | `https://github.com/lenilsonjr/pulso` | MIT, Rust+Swift, `AnchorStore.swift`/`Serializers.swift`/`TypeRegistry.swift` — готовая схема anchored-курсоров |
| 5 | `https://github.com/MBombeck/healthlog-iOS` | Swift, self-hosted сервер, двусторонний HealthKit-синк, есть в App Store |
| 6 | `/home/openclaw/.hermes/_dev/health-shortcut-bridge/server.py` | локальный приёмник 8910: HAE v2 парсер, запись в markdown-лог по дате |
| 7 | `01-analysis/backend-audit.md` | фактическое состояние канала: разрыв 5 суток, суточные агрегаты, нет идемпотентности |
| 8 | `01-analysis/measurement-api-spec.md` | контракт уровня измерений, который ни одно из готовых решений не закрывает |
| 9 | `https://github.com/braintimebox/health-collector` | наш клиентский репозиторий: ядро 33 теста, скелет цели, entitlements, CI |

Проверено лично: README и код `vitalcore` (worker.js), README + `schema.sql` + список файлов
`hae-api`, README + структура `open-wearables`, дерево файлов `pulso`, описание `healthlog-iOS`.
Не читал построчно: код `open-wearables` (Python, платформа целиком), код `pulso` (Rust/Swift),
код `healthlog-iOS`. Это RESEARCHED, не VERIFIED.

## 1. Что уже есть у нас (и что я пропустил в первом аудите)

| Репозиторий | Изучено | Годное к переиспользованию | Используется |
|---|---|---|---|
| `braintimebox/vitalcore` (private) | README + `worker.js` (33 КБ) | маршруты Telegram-ассистента, R2-хранилище `health-json`, `/analyze` | нет |
| `braintimebox/hermex-plus` (public) | код, 527 `.swift`, CI, entitlements | CI-шаблон сборки, pbxproj-гейты, релизный пайплайн | частично (шаблон CI) |
| `braintimebox/health-collector` (private, создан сегодня) | полностью свой | ядро outbox (33 теста), скелет цели, entitlements-страж | да |
| `~/workspace/health-bridge-measurements` (локальный) | полностью свой | ядро маршрута измерений (17 тестов) | да |
| `braintimebox/feather-plus`, `SideStore`, `StikJIT`, `StosVPN` | только описание | возможные пути доставки подписанного IPA на устройство | нет |
| `braintimebox/ios-biohacking-calculator` | описание | нативный SwiftUI-опыт, не относится к HealthKit | нет |

**Поправка к моему первому аудиту:** я утверждал, что Worker'а нет. Локально его действительно нет,
но репозиторий `vitalcore` существует и содержит выгруженный baseline **развёрнутого** Worker'а
`health-auto-sync`. Он оказался не приёмником измерений: маршруты — `/telegram`, `/health`, `/status`,
`/analyze`, `/drivers`, `/debug`, `/test`, `/telemetry`, хранилище — R2-объекты `health-json`, D1 не
используется. То есть «существующий Worker» — Telegram-ассистент с R2-архивом, а не health-ingest API.

## 2. Внешние решения

| Решение | Что реально реализовано | Гранулярность | Фон | Дедуп/ретраи | История | Цена | Итог |
|---|---|---|---|---|---|---|---|
| Нативный Collector (наш) | — (пишем) | по измерению | observer + BGTask + фоновая `URLSession` | outbox + `(user,uuid)` + tombstone | `nil` anchor = вся история | 0 (свой труд) | выбран |
| HAE + `hae-api` | Worker+D1, парсинг HAE REST, query API, дашборд, 74-assertion тест | **по дню** (`metric_points(metric,date,slot)`) | на усмотрение iOS/HAE | по ключу (metric,date,slot), не по записи | ручной backfill месяцами | подписка HAE | не подходит: суточная агрегация, зависимость от HAE |
| HAE + своя схема в D1 | надо писать | любая | то же | то же | то же | подписка HAE + Worker | хуже нашего: остаётся HAE |
| `open-wearables` (MIT) | платформа целиком: OAuth-провайдеры, вебхуки, SDK, MCP, raw в S3 | по записи | их iOS SDK | их модель | исторический backfill | своя инфраструктура | кандидат на будущее, не сейчас (см. §3) |
| `pulso` (MIT, 11★) | iOS-приложение: anchored store, сериализаторы, реестр типов | по записи | не оценено | — | — | 0 | источник **схемы**, не рантайм |
| `healthlog-iOS` | приложение + self-hosted сервер, двусторонний синк | по записи | не оценено | — | — | 0 | чужой сервер и схема; не компонуется с нашим |
| Terra / Human API / Validic | коммерческие агрегаторы, enterprise-онбординг | по записи | их SDK | есть | есть | enterprise-тарифы, публичных цен нет | отклонено: платно и данные уходят третьей стороне (ТЗ §8) |
| Shortcuts → n8n | шорткат + вебхук | сутки | нет | нет | нет | 0 + сервис | отклонено: это текущий мёртвый канал |

## 3. Почему выбран нативный Collector + локальный мост

1. **Требование ТЗ §4 (исходные измерения, UUID, unit, source, метки времени) не закрывает ни одно
   готовое решение из списка.** `hae-api` хранит день/слот, `open-wearables` — свою унифицированную
   модель под своим SDK, `healthlog` — свой сервер. Выбор готового решения означал бы отказаться от
   главного требования.
2. **`open-wearables` не убирает работу, а заменяет её.** Он требует Docker + PostgreSQL + Redis +
   Celery (+Svix), свой деплой и свой iOS SDK — то есть отдельное приложение, которое всё равно надо
   подписывать и ставить. На хосте 40 ГБ свободно (82% занято). Взамен мы получаем чужую схему и
   чужой темп изменений. Держим как кандидата, если появится второй девайс или несколько
   пользователей — там его OAuth-провайдеры действительно экономят месяцы.
3. **`vitalcore` не трогаем.** Telegram-ассистент с Groq и R2 — рабочая поверхность; health-ingest
   рядом с ним увеличивает радиус поражения, а D1 в нём не подключён вовсе. Приём — на мосту,
   который уже принимает данные с телефона через HTTPS-прокси.
4. **Из чужого берём ровно две вещи:** схему anchored-курсоров и сериализаторов (по `pulso`) и
   правила разбора HAE-полезной нагрузки (по `hae-api`, у него это покрыто 74 ассертами) — как
   справку, не как код.

Что пишем сами: HealthKit-адаптер (за протоколом), приложение-цель, движок outbox, триггеры доставки,
маршрут измерений на сервере. Ядро outbox и ядро маршрута уже написаны и прогнаны (33 + 17 тестов).

Принятые компромиссы: своя кодовая база (обслуживаем сами), SQLite на хосте (диск — реальное
ограничение), зависимость от сторонней подписи (риск отзыва), iOS не даёт гарантий фонового запуска.

Остающиеся риски: профиль может не нести `…background-delivery` (P1-гейт закрывает это чтением до
установки); отзыв сертификата — парируется полным реимпортом с сервера (D11); `deletedObjects`
временны — парируется tombstone (D8/D10).

## 4. Статус IPA по лестнице P0–P5

| # | Требование | Статус | Доказательство |
|---|------------|--------|----------------|
| P0 | полноценный app target, не только SPM | IMPLEMENTED | `https://github.com/braintimebox/health-collector`, коммит `4f0319c`: `HealthCollector.xcodeproj`, `Info.plist`, `HealthCollector.entitlements` (два ключа HealthKit), страж бандла 6/6 мутаций |
| P1 | CI собирает конкретный IPA | **IMPLEMENTED + VERIFIED** | run [45206846365](https://github.com/braintimebox/health-collector/actions/runs/45206846365) на `macos-26`, коммит `fecdad8`. Артефакт: `HealthCollector-0.1.0.ipa`, 12 КБ, sha256 `ba536a4ac7acaa29991a61fd6bd1cf46e871faec0acad330983f48d4c45d4495`, внутри `Payload/HealthCollector.app` (executable 92 КБ, Info.plist, PkgInfo), `CFBundleIdentifier = com.braintimebox.healthcollector`, `MinimumOSVersion = 18.0`, `NSHealthShareUsageDescription` на месте, `_CodeSignature` отсутствует (как и задумано). Лог: `02-evidence/raw/ipa-verification.txt`, копия IPA — `02-evidence/raw/ipa/` |
| P2 | IPA подписан и ставится на iPhone | BLOCKED | нужен профиль/сертификат владельца; P1-гейт `scripts/check-profile.py` готов и проверен (6 фикстур + реальный профиль). Первый прогон CI упал дважды — оба раза по моей вине: `-derivedDataPath` несовместим с `-target` (exit 64), и `.build` (612 файлов) был закоммичен в репозиторий |
| P3 | запрос разрешений и чтение реальных данных | NOT IMPLEMENTED | HealthKit-адаптер ещё не написан (намеренно: сначала подпись) |
| P4 | отправка в существующий backend | PARTIAL | серверное ядро готово и прогнано (17 тестов), маршрут в сервис не подключён; клиентская отправка есть в ядре, но не в приложении |
| P5 | повторы, дедуп, догрузка, фон | PARTIAL | повторы/дедуп/догрузка покрыты T1–T8 и S1–S17; фон требует устройства (A2–A5) |
