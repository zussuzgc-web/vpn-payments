# Настройка: три URL для FreeKassa

Проект состоит из двух частей:

| Часть | Где живёт | Зачем | Стоимость |
|---|---|---|---|
| Страницы `success` / `fail` / `order` | GitHub Pages | то, куда возвращается клиент | 0 ₽ |
| URL оповещения (`/notify`) | Cloudflare Worker | приём, проверка подписи, зачисление | 0 ₽ (100 000 запр./сутки) |

GitHub Pages не исполняет код, поэтому оповещение туда положить нельзя: страница
не проверит MD5-подпись и не сможет записать статус заказа.

---

## 1. Адреса страниц (уже работают)

| Назначение | URL |
|---|---|
| URL успешной оплаты | `https://zussuzgc-web.github.io/vpn-payments/success/` |
| URL при неудаче | `https://zussuzgc-web.github.io/vpn-payments/fail/` |
| Страница статуса заказа | `https://zussuzgc-web.github.io/vpn-payments/order/?order_id=<ID>` |
| Обзор адресов | `https://zussuzgc-web.github.io/vpn-payments/` |

FreeKassa докидывает к адресам свои параметры: `ID`, `order_id`, `amount`,
`currency`, `status`, `signature` — страницы их читают и показывают.
Ничего дописывать не нужно, но можно добавить `&autoredirect=1`, чтобы клиента
через 45 секунд само отправляло в бота.

---

## 2. URL оповещения (Cloudflare Worker, бесплатно)

### 2.1 Аккаунт и установка

```bash
npm i -g wrangler
wrangler login
```

### 2.2 KV-хранилище для заказов

```bash
cd worker
wrangler kv namespace create ORDERS
```

Скопируйте выведенный `id` в `worker/wrangler.toml` вместо `ЗАМЕНИТЬ_НА_ТВОЙ_KV_ID`.

### 2.3 Секреты

Из кабинета FreeKassa → «Настройки кабинета» возьмите **ID кабинета** и
**Секретный ключ**.

```bash
wrangler secret put MERCHANT_ID   # ID кабинета FreeKassa (число)
wrangler secret put SECRET_KEY    # секретный ключ FreeKassa
wrangler secret put BOT_TOKEN     # токен @FreeFi_bot от @BotFather
wrangler secret put API_SECRET    # любой длинный случайный ключ, его знает только бот
```

Сгенерировать `API_SECRET`:

```bash
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

### 2.4 Публикация

```bash
wrangler deploy
```

Адрес в выводе (обычно `https://vpn-payments-notify.<ваш-поддомен>.workers.dev`).
Если поддомен отличается — поправьте его в трёх местах:

* `worker/src/index.js` → константа `PAGES` (только если меняли адрес Pages)
* `bot/.env.example` → `FREEKASSA_API`
* `index.html` → блок «URL оповещения»

### 2.5 Проверка

```bash
curl https://<ваш-worker>.workers.dev/ping
# {"ok":true,"service":"vpn-payments-notify",...}

# создать тестовый заказ
curl -X POST https://<ваш-worker>.workers.dev/create \
  -H "x-api-secret: <API_SECRET>" \
  -H "content-type: application/json" \
  -d '{"order_id":"test-1","amount":"10.00","chat_id":123456789,"plan":"month"}'

# оповещение с ПРАВИЛЬНОЙ подписью (подставьте свои merchant_id/secret)
python -c "import hashlib;print(hashlib.md5(b'12:1:10.00:RUB:PAID:secret').hexdigest())"

curl "https://<ваш-worker>.workers.dev/notify?order_id=1&order_amount=10.00&order_currency=RUB&order_status=PAID&ID=99&signature=<подпись>"
# {"status":"ok"}
```

---

## 3. Что вписать в кабинете FreeKassa

**Настройки → Уведомление URL** (это и есть URL оповещения):

```
https://<ваш-worker>.workers.dev/notify
```

**Проверка подписи** оставьте включённой (Worker проверяет MD5 сам).

**URL успешной оплаты** и **URL при неудаче** в кабинете указывать не обязательно:
бот передаёт их в ссылке на оплату (`success_url` / `fail_url`). Если кабинет
требует их задать — впишите адреса из раздела 1 как значения по умолчанию.

---

## 4. Связка с ботом

`bot/freekassa.py` — весь платёжный слой, `bot/example_bot.py` — рабочий пример.

```bash
cd bot
pip install aiogram httpx
```

`.env.example` → `.env`, заполнить `FREEKASSA_API` и `FREEKASSA_SECRET`
(тот же `API_SECRET`, что и в `wrangler secret put API_SECRET`).

Куда что подключается:

```
/buy в боте
   └─ create_order()  ──POST /create──▶  Worker
                                          └─ вернёт payment_url (freekassa.ru/merchant/payment.php)
   └─ кнопка «Оплатить N ₽» ──▶ FreeKassa
   └─ страница статуса ──GET /status──▶ Worker (обновляет состояние)

FreeKassa (оплата или отказ)
   ├─ клиент ──▶ /success/ или /fail/   (GitHub Pages)
   └─ сервер ──▶ /notify                (Worker): проверка подписи → KV → сообщение в чат
```

Чтобы выдача подписки шла независимо от клиента, Worker сам шлёт
`✅ Оплата получена` в чат пользователя, а бот на `/start pay_<order_id>` отдаёт ключ.
Если бот работает на своём сервере — можно вместо `BOT_TOKEN` принимать оповещение
на `/webhook/pay` и вызывать `verify_signature()` из `bot/freekassa.py`.

---

## 5. Деплой страниц

```bash
git push
```

Pages включены для ветки `main`, корневая папка. Сборка занимает ~1 минуту.
Проверить: `https://zussuzgc-web.github.io/vpn-payments/success/?order_id=demo&amount=299&currency=RUB&status=PAID`
