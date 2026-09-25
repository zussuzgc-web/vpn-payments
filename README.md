# VPN Payments — FreeKassa × GitHub Pages × Cloudflare Worker

Приём оплаты VPN-подписки в Telegram-боте. Страницы возврата — на GitHub Pages (0 ₽),
URL оповещения и статус заказа — в Cloudflare Worker (0 ₽).

## Установка

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

Вопросы задаёт скрипт, секреты уходят прямо в Cloudflare и в `bot/.env`
(файл в `.gitignore`). Подробности и ручной путь — в **[SETUP.md](SETUP.md)**.

## Адреса

| Назначение | URL |
|---|---|
| URL успешной оплаты | `https://zussuzgc-web.github.io/vpn-payments/success/` |
| URL при неудаче | `https://zussuzgc-web.github.io/vpn-payments/fail/` |
| Статус заказа | `https://zussuzgc-web.github.io/vpn-payments/order/?order_id=<ID>` |
| URL оповещения | `https://vpn-payments-notify.freefi-vpn.workers.dev/notify` |

## Структура

```
success/          страница «оплата прошла»
fail/             страница «оплата не прошла»
order/            страница «ждём оплату», опрашивает /status
assets/           стили, разбор параметров FreeKassa, конфиг адреса Worker'а
worker/src/       Cloudflare Worker: /create, /notify, /status, /ping
worker/test-local.ps1   25 проверок полного цикла без ключей и без интернета
bot/              слой оплаты для aiogram 3 + рабочий пример
setup.ps1         установщик: KV, секреты, деплой, проверка, коммит
```

## Почему Worker, а не Pages

GitHub Pages отдаёт только статику. URL оповещения обязан принять запрос FreeKassa,
проверить `signature = MD5(merchant_id:order_id:order_amount:order_currency:order_status:secret_key)`,
сохранить статус в KV и подтвердить оплату в чат — это исполняемый код.

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
