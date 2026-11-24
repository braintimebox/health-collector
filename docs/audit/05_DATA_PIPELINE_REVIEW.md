# 05 — Data pipeline review

```
HealthKit ──anchored──▶ Collector ──rows──▶ Outbox(json, atomic) ──claim──▶ SyncEngine
                                                   │                          │
                                          (inflight→pending при старте)       │ WireBatch
                                                                              ▼
                                          ServerAck ◀──HTTPS── URLSessionTransport
                                              │
                                     accepted[] / rejected[permanent]
                                              ▼
                                   measurements / tombstones (SQLite)  [НЕ РАЗВЁРНУТО]
```

| Свойство | Механизм | Тест | Устройство |
|---|---|---|---|
| Нет потери при убийстве процесса | строки на диск до отправки; `inflight→pending` при старте | `testRowsSurviveProcessDeath` (с мутацией) | нет |
| Повторная отправка безопасна | ключ `(user_id, record_id)` на сервере; клиент шлёт повторно | S2, S16, S17 | нет |
| Частичный ACK | settle только по именам id; неименованные → retry с backoff | `testPartialAckResendsOnlyUnacked` | нет |
| Нечитаемый ACK | `unconfirmed` + bounded backoff, не dead-letter | `testUnreadableAckIsUnconfirmed` | нет |
| Backoff | экспонента с потолком и jitter, `Retry-After` | `testBackoffGrowsAndIsCapped`, `testRetryAfterIsHonoured` | нет |
| Dead-letter | 4xx и постоянные отказы | `testClientErrorIsDeadLetteredNotRetriedForever` | нет |
| Удаления | tombstone, в т.ч. для неизвестного UUID; вставка поверх tombstone запрещена | S4, S5, S12 | нет |
| Курсор не уходит вперёд несохранённой строки | порядок collect→persist→save cursor | `testCursorDoesNotAdvanceWhenTheRowCannotBePersisted` | нет |
| Offline | очередь растёт, ничего не теряется | T1/T2 | нет |

## Разрыв, который нельзя закрыть кодом клиента

Серверная часть написана и прогнана (17 тестов, `~/workspace/health-bridge-measurements`), но **не
развёрнута**: маршрут `/v1/measurements` не подключён к сервису на 8910. Следовательно весь правый
край схемы (Storage и далее) существует только в тестах. Пока это так, «данные доставлены» означает
«получен ACK от локального сервера», а не «данные доступны агенту». (CONFIRMED.)

## Оценка

Клиентская половина пайплайна — самая зрелая часть проекта: она проверена 61 модульным тестом, включая
регрессии по четырём дефектам, найденным внешним ревью. Слабое место не в ней, а в двух стыках:
HealthKit→Collector (блокирующее чтение) и Outbox→сервер (сервер не развёрнут).
