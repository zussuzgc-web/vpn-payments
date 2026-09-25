const params = new URLSearchParams(window.location.search);
const BOT = "FreeFi_bot";
const BOT_URL = "https://t.me/" + BOT;
const ORDER_STATUS_API =
  (params.get("api") || "https://vpn-payments-notify.zussuzgc-web.workers.dev") + "/status";

const money = (value, currency) => {
  const num = Number(value);
  if (!Number.isFinite(num)) return value || "—";
  return (
    num.toLocaleString("ru-RU", { minimumFractionDigits: 2, maximumFractionDigits: 2 }) +
    " " +
    (currency === "RUB" ? "₽" : currency || "")
  );
};

const setText = (id, value) => {
  const el = document.getElementById(id);
  if (el && value !== null && value !== undefined && value !== "") el.textContent = value;
};

const orderId = params.get("order_id") || "—";
const fkId = params.get("ID") || "";
const amount = params.get("amount") || params.get("order_amount") || "";
const currency = params.get("currency") || params.get("order_currency") || "RUB";
const fkStatus = (params.get("status") || "").toUpperCase();

document.querySelectorAll("[data-bot-url]").forEach((el) => {
  el.href = BOT_URL + (orderId !== "—" ? "?start=pay_" + encodeURIComponent(orderId) : "");
});

setText("order-id", orderId);
setText("fk-id", fkId);
setText("amount", amount ? money(amount, currency) : "—");
setText("currency", currency);

const statusBlock = document.getElementById("fk-status");
if (statusBlock) {
  const label = { PAID: "Оплачено", PENDING: "Ожидает", ERROR: "Ошибка" }[fkStatus] || fkStatus || "—";
  statusBlock.innerHTML = '<span class="dot"></span>' + label;
  statusBlock.classList.add(fkStatus === "PAID" ? "ok" : fkStatus === "ERROR" ? "err" : "wait");
}

const startTimer = () => {
  const el = document.getElementById("countdown");
  if (!el) return;
  let left = 45;
  const tick = () => {
    el.textContent = left > 0 ? "Вернёмся в бот через " + left + " с" : "Открываю бота…";
    if (left <= 0) {
      window.location.replace(BOT_URL + "?start=pay_" + encodeURIComponent(orderId));
      return;
    }
    left -= 1;
  };
  tick();
  setInterval(tick, 1000);
};

if (params.get("autoredirect") === "1") startTimer();

const hideSpinner = () => {
  const s = document.getElementById("spinner");
  if (s) s.style.display = "none";
};

const showSpinner = () => {
  const s = document.getElementById("spinner");
  if (s) s.style.display = "block";
  const w = document.getElementById("wait-block");
  if (w) w.style.display = "none";
};

const paint = (state) => {
  hideSpinner();
  const set = (id, text, dot) => {
    const el = document.getElementById(id);
    if (!el) return;
    el.innerHTML = (dot ? '<span class="dot ' + dot + '"></span>' : "") + text;
    el.classList.remove("ok", "wait", "err");
    if (dot) el.classList.add(dot);
  };

  set("state-title", {
    created: "Ожидаем оплату",
    pending: "Ожидаем оплату",
    paid: "Оплата получена",
    error: "Оплата не прошла",
    expired: "Ссылка истекла",
  }[state] || "Ожидаем оплату");

  set("state-note", {
    created: "Мы получили данные заказа. Как только вы оплатите его в FreeKassa, доступ выдастся автоматически.",
    pending: "Платёж ещё обрабатывается. Обычно это занимает несколько секунд — страница обновится сама.",
    paid: "Деньги зачислены, подписка уже активирована в боте. Можно пользоваться.",
    error: "Платёж отклонён или отменён. Деньги не списаны — можно оплатить заново.",
    expired: "Заказ не был оплачен вовремя. Напишите боту, чтобы создать новый.",
  }[state] || "");

  set("state-dot", {
    created: ["Ожидает", "wait"],
    pending: ["В обработке", "wait"],
    paid: ["Оплачено", "ok"],
    error: ["Ошибка", "err"],
    expired: ["Истёк", "err"],
  }[state] || ["Ожидает", "wait"]);

  const box = document.getElementById("state-box");
  if (box) {
    box.className = "badge " + (state === "paid" ? "ok" : state === "error" || state === "expired" ? "err" : "wait");
  }
  const icon = document.getElementById("state-icon");
  if (icon) icon.innerHTML = state === "paid" ? ICONS.check : state === "error" || state === "expired" ? ICONS.cross : ICONS.clock;
};

const ICONS = {
  check:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>',
  cross:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6 6 18M6 6l12 12"/></svg>',
  clock:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>',
};

const poll = async () => {
  showSpinner();
  try {
    const res = await fetch(ORDER_STATUS_API + "?order_id=" + encodeURIComponent(orderId), {
      cache: "no-store",
    });
    if (!res.ok) throw new Error("http " + res.status);
    const data = await res.json();
    setText("amount", data.amount ? money(data.amount, data.currency || "RUB") : "—");
    setText("created-at", data.created_at ? new Date(data.created_at).toLocaleString("ru-RU") : "—");
    setText("paid-at", data.paid_at ? new Date(data.paid_at).toLocaleString("ru-RU") : "—");
    paint(data.status);
    if (data.status === "paid") {
      const t = document.getElementById("countdown");
      if (t) t.textContent = "Возвращаемся в бот…";
      setTimeout(() => window.location.replace(BOT_URL + "?start=pay_" + encodeURIComponent(orderId)), 3000);
    }
  } catch (e) {
    hideSpinner();
    paint("created");
  }
  setTimeout(poll, 5000);
};

const retryBtn = document.getElementById("retry");
if (retryBtn) {
  retryBtn.addEventListener("click", () => {
    paint("created");
    poll();
  });
}

if (document.getElementById("state-title")) poll();
