# aiogram 3 — минимальный пример связки: кнопка «Оплатить» -> FreeKassa -> выдача ключа.
# pip install aiogram httpx

import asyncio
import logging

from aiogram import Bot, Dispatcher, F
from aiogram.client.default import DefaultBotProperties
from aiogram.filters import CommandStart
from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup, Message

from freekassa import create_order, get_status, order_keyboard, pay_deeplink

BOT_TOKEN = "123456:AA..."
PLANS = {"month": ("1 месяц", 299.0), "quarter": ("3 месяца", 799.0), "year": ("1 год", 2490.0)}

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("bot")
bot = Bot(token=BOT_TOKEN, default=DefaultBotProperties(parse_mode="HTML"))
dp = Dispatcher()


@dp.message(CommandStart())
async def start(message: Message) -> None:
    if message.text and message.text.startswith("pay_"):
        order_id = message.text.removeprefix("pay_")
        async with get_session() as client:
            status = await get_status(client, order_id)
        if status and status["status"] == "paid":
            text = "✅ Оплата получена! Ваша подписка активна.\n\n<code>/vpn</code> — подключиться."
        else:
            text = "⏳ Платёж пока не зачислен. Проверьте статус или оплатите снова."
        await message.answer(text)
        return

    await message.answer(
        "🛡️ <b>FreeFi VPN</b>\nВыберите тариф:",
        reply_markup=InlineKeyboardMarkup(
            inline_keyboard=[
                [InlineKeyboardButton(text=f"{name} — {price:.0f} ₽", callback_data=f"pay:{key}")]
                for key, (name, price) in PLANS.items()
            ]
        ),
    )


@dp.callback_query(F.data.startswith("pay:"))
async def buy(callback: Message) -> None:
    plan = callback.data.split(":", 1)[1]
    name, price = PLANS[plan]

    async with get_session() as client:
        order = await create_order(
            client,
            user_id=callback.from_user.id,
            chat_id=callback.from_user.id,
            amount=price,
            plan=plan,
        )

    await callback.message.edit_text(
        f"Заказ <code>{order.order_id}</code>\n"
        f"Тариф: <b>{name}</b>\n"
        f"Сумма: <b>{order.amount} ₽</b>\n\n"
        f"{order_keyboard(order)}\n\n"
        f"После оплаты вернись в бота — ключ выдастся автоматически.\n"
        f'<a href="{pay_deeplink(order.order_id)}">↩ Вернуться в бот</a>',
        disable_web_page_preview=True,
    )
    await callback.answer()


def get_session():
    import httpx

    return httpx.AsyncClient()


async def main() -> None:
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
