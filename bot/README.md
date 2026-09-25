# Бот: слой оплаты

`freekassa.py` — вся работа с оплатой, `example_bot.py` — рабочий пример на aiogram 3.

## Установка

```bash
pip install aiogram httpx
cp .env.example .env      # Windows: copy .env.example .env
```

`.env` создаёт установщик (`setup.ps1`) — руками править не нужно.

| Переменная | Что это |
|---|---|
| `FREEKASSA_API` | адрес Worker'а |
| `FREEKASSA_SECRET` | значение `API_SECRET`, заданное в Worker'е |
| `BOT_USERNAME` | `@FreeFi_bot` |
| `BOT_TOKEN` | токен от @BotFather |
| `MERCHANT_ID` | ID кабинета FreeKassa (для локальной проверки подписи) |

Загрузка `.env` в примере не показана — добавь `python-dotenv` или читай переменные
своего деплоя (systemd EnvironmentFile, переменные Heroku/Railway и т. п.).

## Схема работы

```
/buy ──▶ create_order() ──▶ POST /create ──▶ Worker
                                              │
                        ┌─────────────────────┘
                        ▼
              payment_url → freekassa.ru/merchant/payment.php
                        │
        клиент платит ──┤
                        ├──▶ FreeKassa зовёт /notify (Worker проверяет подпись,
                        │    пишет статус в KV и шлёт «Оплата получена» в чат)
                        ├──▶ клиента выкидывает на /success/ (Pages)
                        └──▶ при отказе клиента выкидывает на /fail/ (Pages)
```

Оплату подтверждает Worker, а не бот: клиент может закрыть вкладку, бот — упасть,
но подписка всё равно выдастся. Бот только запрашивает `/status`, когда клиент
возвращается по `/start pay_<order_id>`.

## Выдача подписки

```python
status = await get_status(client, order_id)
if status and status["status"] == "paid":
    await grant_subscription(user_id, status["plan"])   # <- твоя функция
```

## Проверка подписи локально

Если бот принимает оповещения сам, а не через Worker:

```python
verify_signature(merchant_id, secret, order_id, amount, currency, status, signature)
```

## Чего нет в примере

Хранилища пользователей, выдачи ключа, админки, приёма `/start` для новых заказов —
это уже часть твоего бота, платёжный слой подключается в трёх местах.
