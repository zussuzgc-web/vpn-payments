# Настройка: три URL для FreeKassa

| Часть | Где живёт | Зачем | Стоимость |
|---|---|---|---|
| Страницы `success` / `fail` / `order` | GitHub Pages | то, куда возвращается клиент | 0 ₽ |
| URL оповещения (`/notify`) | Cloudflare Worker | приём, проверка подписи, зачисление | 0 ₽ |

GitHub Pages не исполняет код, поэтому оповещение туда положить нельзя: страница
не проверит MD5-подпись и не запишет статус заказа.

---

## Быстрый старт

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

Установщик сам: проверит Node → войдёт в Cloudflare (откроется браузер) →
создаст KV → спросит ключи FreeKassa и токен бота → задеплоит Worker →
впишет его адрес в страницы и `bot/.env` → прогоняет живой цикл оплаты →
предложит закоммитить и запушить.

Один раз вручную нужно открыть дашборд Cloudflare, чтобы создался поддомен
`workers.dev` (см. раздел 2) — установщик остановится с понятным сообщением.

---

## 1. Адреса страниц (работают сразу)

| Назначение | URL |
|---|---|
| URL успешной оплаты | `https://zussuzgc-web.github.io/vpn-payments/success/` |
| URL при неудаче | `https://zussuzgc-web.github.io/vpn-payments/fail/` |
| Страница статуса заказа | `https://zussuzgc-web.github.io/vpn-payments/order/?order_id=<ID>` |
| Обзор адресов | `https://zussuzgc-web.github.io/vpn-payments/` |

FreeKassa докидывает к адресам `ID`, `order_id`, `amount`, `currency`, `status`,
`signature` — страницы их читают и показывают.

Дополнительные параметры страниц:

| Параметр | Что делает |
|---|---|
| `&autoredirect=1` | через 45 с вернуть клиента в бота |
| `&autoredirect_seconds=10` | свой таймер (только вместе с `autoredirect=1`) |
| `&api=https://…workers.dev` | адрес Worker'а, если не совпадает с `assets/config.js` |

Ссылка на страницу статуса, которую отдаёт `/create`, уже содержит `order_id` и
`api` — то есть открытая ботом страница работает, даже если `assets/config.js`
ещё не обновлён на GitHub Pages.

---

## 2. Поддомен workers.dev

У этого аккаунта поддомен уже создан: `freefi-vpn.workers.dev`, поэтому адрес Worker'а —
`https://vpn-payments-notify.freefi-vpn.workers.dev`.

Новому аккаунту Cloudflare `wrangler deploy` предложит создать поддомен сам
(вопрос в терминале). Если хочешь выбрать имя вручную — это делается в дашборде:
`https://dash.cloudflare.com/<account-id>/workers/workers-and-pages`. Через API
(`PUT /accounts/<id>/workers/subdomain`) это тоже возможно, но доступно не всем
токенам, поэтому установщик этим не занимается.

---

## 3. Ручная установка (без setup.ps1)

```bash
cd worker
npm install
npx wrangler login
npx wrangler kv namespace create ORDERS        # id вписать в wrangler.toml
npx wrangler secret bulk secrets.json          # {"MERCHANT_ID":"…","SECRET_KEY":"…","BOT_TOKEN":"…","API_SECRET":"…"}
npx wrangler deploy
```

`API_SECRET` — любая длинная строка, её знает только бот:

```bash
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

Проверка:

```bash
curl https://<worker>.workers.dev/ping
curl -X POST https://<worker>.workers.dev/create -H "x-api-secret: <API_SECRET>" \
  -H "content-type: application/json" -d '{"order_id":"t1","amount":"10.00","chat_id":1}'
```

---

## 4. Локальный тест без интернета и ключей

```powershell
powershell -ExecutionPolicy Bypass -File .\worker\test-local.ps1
```

Поднимает `wrangler dev` и проверяет 29 утверждений: создание заказа, сборка
ссылки на оплату, отклонение поддельной подписи (403), приём настоящей,
переход `created → paid → error`, защита `/create`, 404, CORS, приём `GET /notify`.

---

## 5. Что вписать в кабинете FreeKassa

**Настройки кабинета → Уведомление URL:**

```
https://vpn-payments-notify.freefi-vpn.workers.dev/notify
```

**Проверка подписи** — включить: Worker проверяет `signature` сам и отвечает 403
на подделку.

**URL успешной оплаты / при неудаче** в кабинете задавать не обязательно: бот
передаёт их в ссылке (`success_url`, `fail_url`). Если кабинет требует — впиши
адреса из раздела 1 как значения по умолчанию.

---

## 6. Связка с ботом

Подробности в [`bot/README.md`](bot/README.md).

```
/buy в боте
   └─ create_order()  ──POST /create──▶  Worker
                                          └─ вернёт payment_url
   └─ кнопка «Оплатить N ₽» ──▶ FreeKassa
   └─ страница статуса ──GET /status──▶ Worker (каждые 5 с)

FreeKassa
   ├─ клиент ──▶ /success/ или /fail/            (GitHub Pages)
   └─ сервер ──▶ /notify                          (Worker)
                    проверка подписи → KV → сообщение в чат
```

Оплату подтверждает Worker, а не бот: клиент может закрыть вкладку, бот — упасть,
подписка всё равно выдастся.

---

## 7. Доступность FreeKassa для клиентов

`freekassa.ru` может быть недоступен части пользователей из РФ без VPN. Важно,
что именно от этого ломается, а что нет:

| Шаг | Кто делает запрос | Зависит от доступности `freekassa.ru` |
| --- | --- | --- |
| Клиент открывает форму и вводит карту | браузер клиента → `freekassa.ru` | **да, ломается** |
| FreeKassa шлёт оповещение об оплате | сервер FreeKassa из-за границы → Worker | нет |
| Возврат на страницу успеха | браузер клиента → `github.io` | нет |
| Страница статуса заказа | браузер клиента → `github.io` + `workers.dev` | нет |

То есть зачисление и проверка статуса не пострадают — сломан только ввод карты.
Обойти это своим кодом нельзя: платёжная форма лежит на домене FreeKassa.

Что можно сделать:
- проверить, у кого именно не открывается (домашний интернет против мобильного,
  конкретный провайдер или регион) — блокировки часто действуют точечно;
- написать в поддержку FreeKassa;
- поставить второго провайдера запасным (см. раздел 8).

---

## 8. Замена платёжного провайдера

От провайдера не зависят страницы на GitHub Pages, бот, KV, жизненный цикл заказа
и выдача подписки. Привязано к провайдеру только четыре места, все — в
`worker/src/index.js`:

| Место | Строки (сейчас) | Что менять |
| --- | --- | --- |
| `FREEKASSA_FORM` | 3 | домен и адрес платёжной формы |
| сборка query в `/create` | 156–163 | имена и набор параметров ссылки |
| `expectedSignature` | 21–22 | алгоритм подписи |
| чтение тела `/notify` и статусы | 181, 195 | имена полей и словарь статусов |

Порядок: поменять эти четыре места, поправить `setup.ps1` под новые секреты,
прогнать `worker/test-local.ps1` — он проверяет всю цепочку на тестовых данных.
