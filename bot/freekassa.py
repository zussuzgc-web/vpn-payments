"""Оплата VPN через FreeKassa для Telegram-бота (aiogram 3).

Здесь только слой оплаты: создание заказа, выдача ссылки, реакция на
оплату. Логику выдачи подписки вызывайте в on_paid().

Переменные окружения (см. .env.example):
    FREEKASSA_API   база Worker'а: https://vpn-payments-notify.<user>.workers.dev
    FREEKASSA_SECRET  значение секрета API_SECRET из wrangler
    BOT_USERNAME    @FreeFi_bot
"""

from __future__ import annotations

import hashlib
import logging
import os
import uuid
from dataclasses import dataclass

import httpx

log = logging.getLogger(__name__)

API = os.getenv("FREEKASSA_API", "https://vpn-payments-notify.zussuzgc-web.workers.dev").rstrip("/")
SECRET = os.getenv("FREEKASSA_SECRET", "")
BOT_USERNAME = os.getenv("BOT_USERNAME", "FreeFi_bot").lstrip("@")
BOT_START_URL = f"https://t.me/{BOT_USERNAME}"


@dataclass(frozen=True)
class Order:
    order_id: str
    amount: str
    payment_url: str
    status_page: str
    success_url: str
    fail_url: str


def new_order_id(user_id: int, plan: str) -> str:
    """Идентификатор заказа для FreeKassa: до 100 символов, уникальный."""
    return f"{user_id}-{plan}-{uuid.uuid4().hex[:8]}"


def verify_signature(
    merchant_id: str,
    secret: str,
    order_id: str,
    amount: str,
    currency: str,
    status: str,
    signature: str,
) -> bool:
    """Локальная проверка подписи — для случая, если бот принимает оповещения сам."""
    raw = f"{merchant_id}:{order_id}:{float(amount):.2f}:{currency}:{status}:{secret}"
    expected = hashlib.md5(raw.encode("utf-8")).hexdigest()
    return expected == signature.lower()


async def create_order(
    client: httpx.AsyncClient,
    *,
    user_id: int,
    chat_id: int,
    amount: float,
    plan: str = "month",
    currency: str = "RUB",
) -> Order:
    """Создаёт заказ у Worker'а и возвращает ссылку на оплату FreeKassa."""
    resp = await client.post(
        f"{API}/create",
        headers={"x-api-secret": SECRET},
        json={
            "order_id": new_order_id(user_id, plan),
            "amount": f"{float(amount):.2f}",
            "currency": currency,
            "chat_id": chat_id,
            "user_id": user_id,
            "plan": plan,
        },
        timeout=15,
    )
    resp.raise_for_status()
    data = resp.json()
    return Order(
        order_id=data["order_id"],
        amount=data["amount"],
        payment_url=data["payment_url"],
        status_page=data["status_page"],
        success_url=data["success_url"],
        fail_url=data["fail_url"],
    )


async def get_status(client: httpx.AsyncClient, order_id: str) -> dict | None:
    try:
        resp = await client.get(f"{API}/status", params={"order_id": order_id}, timeout=10)
    except httpx.HTTPError:
        log.warning("status request failed for %s", order_id)
        return None
    if resp.status_code == 404:
        return None
    resp.raise_for_status()
    return resp.json()


def order_keyboard(order: Order) -> str:
    """HTML-разметка кнопок под сообщением «вот ссылка на оплату» (aiogram: parse_mode=HTML)."""
    return (
        f'<a href="{order.payment_url}">💳 Оплатить {order.amount} ₽</a>\n'
        f'<a href="{order.status_page}">📄 Статус заказа {order.order_id}</a>'
    )


def pay_deeplink(order_id: str) -> str:
    """Кнопка «вернуться в бот» — Worker и страницы ставят такой же deep link."""
    return f"{BOT_START_URL}?start=pay_{order_id}"
