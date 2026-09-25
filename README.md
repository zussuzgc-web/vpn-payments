# VPN Payments — FreeKassa × GitHub Pages × Cloudflare Worker

Приём оплаты VPN-подписки в Telegram-боте. Страницы возврата — на GitHub Pages (0 ₽),
URL оповещения — в Cloudflare Worker (0 ₽).

## Адреса

| Назначение | URL |
|---|---|
| URL успешной оплаты | `https://zussuzgc-web.github.io/vpn-payments/success/` |
| URL при неудаче | `https://zussuzgc-web.github.io/vpn-payments/fail/` |
| Статус заказа | `https://zussuzgc-web.github.io/vpn-payments/order/?order_id=<ID>` |
| URL оповещения | `https://<worker>.<subdomain>.workers.dev/notify` |

Инструкция по подключению кабинета FreeKassa, созданию KV и деплою Worker'а —
в **[SETUP.md](SETUP.md)**.

## Структура

```
success/          страница «оплата прошла»
fail/             страница «оплата не прошла»
order/            страница «ждём оплату», опрашивает /status
assets/           стили и JS разбора параметров FreeKassa
worker/src/       Cloudflare Worker: /create, /notify, /status, /ping
bot/              слой оплаты для aiogram 3 + рабочий пример бота
```

## Почему Worker, а не Pages

GitHub Pages отдаёт только статику. URL оповещения обязан принять запрос FreeKassa,
проверить `signature = MD5(merchant_id:order_id:order_amount:order_currency:order_status:secret_key)`,
сохранить статус и подтвердить оплату в чат — это исполняемый код, то есть Worker.

## Конечные точки Worker

| Метод | Путь | Назначение |
|---|---|---|
| `POST` | `/create` | создать заказ (заголовок `x-api-secret`), вернуть ссылку на оплату |
| `POST`/`GET` | `/notify` | URL оповещения FreeKassa, проверка подписи |
| `GET` | `/status?order_id=` | статус заказа для страницы `order/` |
| `GET` | `/ping` | проверка живости |

## Бот

`@FreeFi_bot` — оплата создаётся командой `/buy`, ссылка приходит кнопкой,
после оплаты Worker сам пишет в чат, а `/start pay_<order_id>` отдаёт ключ.
