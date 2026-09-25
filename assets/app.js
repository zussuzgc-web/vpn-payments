const CFG = window.VPN_PAY || {};
const params = new URLSearchParams(window.location.search);
const BOT = CFG.bot || "FreeFi_bot";
const BOT_URL = "https://t.me/" + BOT;
const ORDER_TTL_MIN = Number(CFG.orderTtlMin) || 30;
const API = String(params.get("api") || CFG.api || "").replace(/\/+$/, "");

const ICONS = {
  check:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>',
  cross:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6 6 18M6 6l12 12"/></svg>',
  clock:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>',
};

const STATES = {
  created: { title: "Ожидаем оплату", note: "Заказ создан, данные переданы в FreeKassa. Как только оплата пройдёт, доступ выдастся автоматически.", dot: "wait", icon: ICONS.clock },
  pending: { title: "Платёж обрабатывается", note: "FreeKassa ещё подтверждает транзакцию. Обычно это занимает несколько секунд — страница обновится сама.", dot: "wait", icon: ICONS.clock },
  paid: { title: "Оплата получена", note: "Деньги зачислены, подписка активирована в боте. Можно подключаться.", dot: "ok", icon: ICONS.check },
  error: { title: "Оплата не прошла", note: "Платёж отклонён или отменён. Деньги не списаны — можно оплатить заново.", dot: "err", icon: ICONS.cross },
  expired: { title: "Срок оплаты истёк", note: "Заказ не был оплачен вовремя. Напишите боту — он создаст новый.", dot: "err", icon: ICONS.cross },
};

const orderId = params.get("order_id") || "";
const fkId = params.get("ID") || "";
const amount = params.get("amount") || params.get("order_amount") || "";
const currency = params.get("currency") || params.get("order_currency") || "RUB";
const fkStatus = (params.get("status") || "").toUpperCase();
const deepLink = BOT_URL + (orderId ? "?start=pay_" + encodeURIComponent(orderId) : "");

const $ = (id) => document.getElementById(id);
const setText = (id, value) => {
  const el = $(id);
  if (el && value !== null && value !== undefined && value !== "") el.textContent = value;
};
const money = (value, cur) => {
  const num = Number(value);
  if (!Number.isFinite(num)) return value || "—";
  return num.toLocaleString("ru-RU", { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + " " + (cur === "RUB" ? "₽" : cur || "");
};
const dt = (value) => (value ? new Date(value).toLocaleString("ru-RU", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" }) : "—");

document.querySelectorAll("[data-bot-url]").forEach((el) => (el.href = deepLink));
document.querySelectorAll("[data-status-url]").forEach((el) => (el.href = `../order/?order_id=${encodeURIComponent(orderId)}`));

setText("order-id", orderId);
setText("fk-id", fkId);
setText("amount", amount ? money(amount, currency) : "—");
setText("currency", currency);

const fkStatusEl = $("fk-status");
if (fkStatusEl) {
  const label = { PAID: "Оплачено", PENDING: "В обработке", ERROR: "Ошибка" }[fkStatus] || fkStatus || "—";
  const dot = fkStatus === "PAID" ? "ok" : fkStatus === "ERROR" ? "err" : "wait";
  fkStatusEl.innerHTML = '<span class="dot ' + dot + '"></span>' + label;
}

if (params.get("autoredirect") === "1" && orderId) {
  let left = Number(params.get("autoredirect_seconds")) || 45;
  const tick = () => {
    const el = $("countdown");
    if (!el) return;
    if (left <= 0) {
      window.location.replace(deepLink);
      return;
    }
    el.textContent = "Вернёмся в бот через " + left + " с";
    left -= 1;
  };
  tick();
  setInterval(tick, 1000);
}

/* ---------------- страница статуса заказа ---------------- */

let current = "created";
let failures = 0;
let timer = null;

const paint = (state, extra = {}) => {
  current = STATES[state] ? state : "created";
  const s = STATES[current];
  const box = $("state-box");
  if (box) box.className = "badge " + (s.dot === "ok" ? "ok" : s.dot === "err" ? "err" : "wait");
  const icon = $("state-icon");
  if (icon) icon.innerHTML = extra.icon || s.icon;
  setText("state-title", s.title);
  setText("state-note", s.note);
  const dot = $("state-dot");
  if (dot) {
    dot.innerHTML = '<span class="dot ' + s.dot + '"></span>' + (extra.dotLabel || { ok: "Оплачено", wait: "Ожидает", err: "Ошибка" }[s.dot]);
  }
  const spin = $("spinner");
  if (spin) spin.style.display = "none";
  const block = $("wait-block");
  if (block) block.style.display = "block";
  const offline = $("offline");
  if (offline) offline.style.display = extra.offline ? "block" : "none";
  if (current === "paid") {
    setText("countdown", "Открываем бота…");
    setTimeout(() => window.location.replace(deepLink), 2500);
  }
};

const showSpinner = () => {
  const spin = $("spinner");
  if (spin) spin.style.display = "block";
  const block = $("wait-block");
  if (block) block.style.display = "none";
  const offline = $("offline");
  if (offline) offline.style.display = "none";
};

const fetchStatus = async () => {
  if (!API) {
    paint("created", { offline: true, icon: ICONS.cross, dotLabel: "нет API" });
    return;
  }
  showSpinner();
  try {
    const res = await fetch(API + "/status?order_id=" + encodeURIComponent(orderId), { cache: "no-store" });
    if (res.status === 404) {
      paint("created", { offline: true, icon: ICONS.cross, dotLabel: "заказ не найден" });
      return;
    }
    if (!res.ok) throw new Error("HTTP " + res.status);
    const data = await res.json();
    failures = 0;
    setText("order-id", data.order_id || orderId);
    setText("amount", data.amount ? money(data.amount, data.currency) : "—");
    setText("created-at", dt(data.created_at));
    setText("paid-at", dt(data.paid_at));
    if (data.plan) setText("plan", data.plan);
    const box = $("expires");
    if (box && data.created_at && data.status !== "paid") {
      const left = Math.max(0, Math.round(ORDER_TTL_MIN - (Date.now() - new Date(data.created_at).getTime()) / 60000));
      box.textContent = left > 0 ? "Оплатить нужно в течение " + left + " мин" : "Время оплаты вышло";
    }
    paint(data.status);
  } catch (e) {
    failures += 1;
    const offline = failures >= 2;
    paint("created", offline ? { offline: true, icon: ICONS.cross, dotLabel: "нет связи" } : {});
  }
};

const schedule = () => {
  clearTimeout(timer);
  const delay = failures === 0 ? 5000 : Math.min(60000, 5000 * 2 ** Math.min(failures, 4));
  timer = setTimeout(run, delay);
};

function run() {
  if (document.hidden) {
    schedule();
    return;
  }
  fetchStatus().then(schedule);
}

const refreshBtn = $("retry");
if (refreshBtn) refreshBtn.addEventListener("click", () => {
  failures = 0;
  fetchStatus().then(schedule);
});

document.addEventListener("visibilitychange", () => {
  if (!document.hidden) {
    clearTimeout(timer);
    fetchStatus().then(schedule);
  }
});

if ($("state-title")) {
  if (orderId) run();
  else paint("created", { offline: true, icon: ICONS.cross, dotLabel: "нет order_id" });
}
