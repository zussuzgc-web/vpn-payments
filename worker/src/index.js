import { createHash } from "node:crypto";

const FREEKASSA_FORM = "https://freekassa.ru/merchant/payment.php";
const PAGES = "https://zussuzgc-web.github.io/vpn-payments";
const ORDER_TTL_MIN = 30;

const json = (data, status = 200, headers = {}) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "access-control-allow-origin": "*", ...headers },
  });

const md5 = (value) => createHash("md5").update(value, "utf8").digest("hex");

const normalizeAmount = (value) => {
  const raw = String(value ?? "").replace(",", ".").trim();
  const num = Number(raw);
  return Number.isFinite(num) ? num.toFixed(2) : raw;
};

const expectedSignature = (merchantId, secret, orderId, amount, currency, status) =>
  md5(`${merchantId}:${orderId}:${normalizeAmount(amount)}:${currency}:${status}:${secret}`);

const safeEqual = (a = "", b = "") => {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
};

const readBody = async (request) => {
  const query = Object.fromEntries(new URL(request.url).searchParams.entries());
  const type = request.headers.get("content-type") || "";
  let parsed = null;

  if (type.includes("application/json")) {
    const text = await request.text().catch(() => "");
    if (text.trim()) {
      try {
        parsed = JSON.parse(text);
      } catch {
        parsed = null;
      }
    }
  } else {
    const form = await request.formData().catch(() => null);
    if (form && [...form.keys()].length) parsed = Object.fromEntries(form.entries());
  }

  return { ...query, ...(parsed || {}) };
};

const log = (data) => console.log(JSON.stringify({ ts: new Date().toISOString(), ...data }));

async function notifyTelegram(env, chatId, text, buttonUrl) {
  if (!chatId || !env.BOT_TOKEN) return;
  const payload = {
    chat_id: chatId,
    text,
    parse_mode: "HTML",
    disable_web_page_preview: true,
  };
  if (buttonUrl) {
    payload.reply_markup = { inline_keyboard: [[{ text: "🔑 Моя подписка", url: buttonUrl }]] };
  }
  await fetch(`https://api.telegram.org/bot${env.BOT_TOKEN}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
}

const statusText = {
  paid: "✅ <b>Оплата получена!</b>\n\nЗаказ <code>{order}</code> на <b>{amount} ₽</b> оплачен.\nПодписка активирована — можно подключаться.",
  pending: "⏳ <b>Платёж в обработке</b>\n\nЗаказ <code>{order}</code> на {amount} ₽ обрабатывается FreeKassa.",
  error: "❌ <b>Оплата не прошла</b>\n\nЗаказ <code>{order}</code> отклонён. Деньги не списаны — можно оплатить заново.",
  expired: "⌛ <b>Заказ истёк</b>\n\nОплата заказа <code>{order}</code> не поступила за 30 минут.",
};

function renderStatus(text, order) {
  return text
    .replaceAll("{order}", order.order_id)
    .replaceAll("{amount}", String(order.amount ?? "—"));
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";

    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": "*",
          "access-control-allow-methods": "GET,POST,OPTIONS",
          "access-control-allow-headers": "content-type,x-api-secret",
        },
      });
    }

    try {
      /* ---------- 1. Страница статуса (публично) ---------- */
      if (path === "/status") {
        const orderId = url.searchParams.get("order_id");
        if (!orderId) return json({ error: "order_id required" }, 400);
        const raw = await env.ORDERS.get(`order:${orderId}`);
        if (!raw) return json({ error: "order not found" }, 404);
        const order = JSON.parse(raw);

        if (order.status === "created" || order.status === "pending") {
          const ageMin = (Date.now() - new Date(order.created_at).getTime()) / 60000;
          if (ageMin > ORDER_TTL_MIN) {
            order.status = "expired";
            order.updated_at = new Date().toISOString();
            ctx.waitUntil(env.ORDERS.put(`order:${orderId}`, JSON.stringify(order)));
            ctx.waitUntil(notifyTelegram(env, order.chat_id, renderStatus(statusText.expired, order), botStartUrl(order)));
          }
        }
        return json({
          order_id: order.order_id,
          amount: order.amount,
          currency: order.currency || "RUB",
          status: order.status,
          plan: order.plan || null,
          created_at: order.created_at,
          paid_at: order.paid_at || null,
        });
      }

      /* ---------- 2. Создание заказа ботом ---------- */
      if (path === "/create" && request.method === "POST") {
        if (!safeEqual(request.headers.get("x-api-secret") || "", env.API_SECRET || "")) {
          return json({ error: "forbidden" }, 403);
        }
        const body = await readBody(request);
        const orderId = String(body.order_id || "").trim();
        const amount = normalizeAmount(body.amount);
        if (!orderId || !amount || Number(amount) <= 0) {
          return json({ error: "order_id and amount are required" }, 400);
        }

        const order = {
          order_id: orderId,
          amount,
          currency: String(body.currency || "RUB").toUpperCase(),
          status: "created",
          chat_id: body.chat_id ? Number(body.chat_id) : null,
          user_id: body.user_id ? Number(body.user_id) : null,
          plan: body.plan || null,
          created_at: new Date().toISOString(),
          paid_at: null,
        };
        await env.ORDERS.put(`order:${orderId}`, JSON.stringify(order));

        const fk = new URL(FREEKASSA_FORM);
        fk.searchParams.set("merchant_id", String(env.MERCHANT_ID));
        fk.searchParams.set("order_id", orderId);
        fk.searchParams.set("order_amount", amount);
        fk.searchParams.set("order_currency", order.currency);
        fk.searchParams.set("language", "ru-RU");
        fk.searchParams.set("success_url", `${PAGES}/success/`);
        fk.searchParams.set("fail_url", `${PAGES}/fail/`);

        const origin = new URL(request.url).origin;
        const apiParam = encodeURIComponent(origin);
        return json({
          order_id: orderId,
          amount,
          payment_url: fk.toString(),
          status_page: `${PAGES}/order/?order_id=${encodeURIComponent(orderId)}&api=${apiParam}`,
          success_url: `${PAGES}/success/`,
          fail_url: `${PAGES}/fail/`,
          notify_url: `${origin}/notify`,
        });
      }

      /* ---------- 3. URL оповещения FreeKassa ---------- */
      if (path === "/notify" || path === "/callback") {
        const body = await readBody(request);
        const { order_id: orderId, order_amount: amount, order_currency: currency, order_status: status } = body;
        const signature = String(body.signature || "");

        if (!orderId || !status) return json({ error: "bad request" }, 400);

        const expected = expectedSignature(env.MERCHANT_ID, env.SECRET_KEY, orderId, amount, currency, status);
        if (!safeEqual(signature.toLowerCase(), expected)) {
          log(env, { event: "signature_mismatch", order_id: orderId, got: signature, expected });
          return json({ error: "invalid signature" }, 403);
        }

        const key = `order:${orderId}`;
        const raw = await env.ORDERS.get(key);
        const order = raw ? JSON.parse(raw) : { order_id: orderId, amount: normalizeAmount(amount), currency, chat_id: null };
        const next = String(status).toUpperCase() === "PAID" ? "paid" : String(status).toUpperCase() === "ERROR" ? "error" : "pending";

        order.status = next;
        order.amount = normalizeAmount(amount);
        order.fk_id = body.ID || order.fk_id || null;
        order.updated_at = new Date().toISOString();
        if (next === "paid" && !order.paid_at) order.paid_at = order.updated_at;

        await env.ORDERS.put(key, JSON.stringify(order));
        log(env, { event: "notify", order_id: orderId, status: next, amount: order.amount });

        const text = renderStatus(statusText[next] || "ℹ️ Заказ обновлён: <b>{status}</b>", { ...order, order: orderId });
        ctx.waitUntil(notifyTelegram(env, order.chat_id, text, botStartUrl(order)));

        return new Response("{\"status\":\"ok\"}", {
          headers: { "content-type": "application/json; charset=utf-8" },
        });
      }

      /* ---------- 4. Служебное ---------- */
      if (path === "/ping") {
        return json({ ok: true, service: "vpn-payments-notify", pages: PAGES, ts: Date.now() });
      }

      return json(
        {
          service: "vpn-payments-notify",
          pages: { success: `${PAGES}/success/`, fail: `${PAGES}/fail/`, status: `${PAGES}/order/` },
          endpoints: {
            "POST /create": "создать заказ (заголовок x-api-secret)",
            "POST /notify": "URL оповещения FreeKassa",
            "GET /status?order_id=": "статус заказа",
            "GET /ping": "проверка живости",
          },
        },
        200,
      );
    } catch (e) {
      console.error("worker error", e);
      return json({ error: "internal error" }, 500);
    }
  },
};

function botStartUrl(order) {
  return `https://t.me/FreeFi_bot?start=pay_${encodeURIComponent(order.order_id)}`;
}
