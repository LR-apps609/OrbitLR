// Piccoli aiuti: creare elementi, numeri all'italiana, memoria delle preferenze, avvisi.

import { icon } from "./icons.js";
import { t, tc, isEn } from "./i18n.js";

/** h("div.cls", {attrs}, ...figli) */
export function h(tag, attrs, ...kids) {
  const [name, ...cls] = tag.split(".");
  const el = document.createElement(name || "div");
  if (cls.length) el.className = cls.join(" ");
  if (attrs && (typeof attrs !== "object" || attrs instanceof Node || Array.isArray(attrs))) {
    kids.unshift(attrs);
    attrs = null;
  }
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k.startsWith("on")) el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === "html") el.innerHTML = v;
    else if (k === "class") el.className += " " + v;
    else if (k === "style" && typeof v === "object") Object.assign(el.style, v);
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const kid of kids.flat(Infinity)) {
    if (kid == null || kid === false) continue;
    el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return el;
}

export function ico(name, size = 18, cls = "") {
  const t = document.createElement("template");
  t.innerHTML = icon(name, size, cls).trim();
  return t.content.firstChild;
}

export function fmtDecimal(x, digits = 1) {
  let s = Number(x).toFixed(digits);
  if (s.includes(".")) s = s.replace(/0+$/, "").replace(/\.$/, "");
  return isEn ? s : s.replace(".", ",");
}

export function fmtBytes(b) {
  if (!b && b !== 0) return "";
  if (b >= 1e9) return fmtDecimal(b / 1e9) + " GB";
  if (b >= 1e6) return fmtDecimal(b / 1e6) + " MB";
  if (b >= 1e3) return Math.round(b / 1e3) + " KB";
  return b + " B";
}

/** 74.5 → «1:14,5» (decimi solo se chiesti); 3725 → «1:02:05» */
export function fmtTime(s, tenths = false) {
  if (!isFinite(s) || s < 0) s = 0;
  const hh = Math.floor(s / 3600), mm = Math.floor((s % 3600) / 60), ss = s % 60;
  let sec = tenths ? fmtDecimal(Math.floor(ss * 10) / 10, 1) : String(Math.floor(ss));
  if (Math.floor(ss) < 10) sec = "0" + sec;
  return hh ? `${hh}:${String(mm).padStart(2, "0")}:${sec}` : `${mm}:${sec}`;
}

export function gainText(before, after) {
  if (!before || !after) return "";
  const pct = Math.round((1 - after / before) * 100);
  const base = t`da ${fmtBytes(before)} a ${fmtBytes(after)}`;
  return pct >= 3 ? `${base} · −${pct}%` : pct <= -3 ? `${base} · +${-pct}%` : base;
}

/** Com'è installata l'app: dal Microsoft Store gli aggiornamenti e il tasto destro funzionano diversamente. */
export const env = { store: false };

export const store = {
  get(k, d) {
    try {
      const v = localStorage.getItem("orbitlr." + k);
      return v == null ? d : JSON.parse(v);
    } catch {
      return d;
    }
  },
  set(k, v) {
    try {
      localStorage.setItem("orbitlr." + k, JSON.stringify(v));
      return true;
    } catch {
      return false;
    }
  },
};

let toastTimer;
/** Una riga in basso che sparisce da sola. `ms`: quanto resta (di base 3,2 s). */
export function toast(msg, ms = 3200) {
  document.querySelector(".toast")?.remove();
  const t = h("div.toast", msg);
  document.body.append(t);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.remove(), ms);
  return t;
}

// 1.1 · «Eliminata «X».» con «Annulla» per 6 secondi; anche Ctrl+Z la annulla finché la riga c'è.
let pendingUndo = null;
/** Una riga con un pulsante (per esempio «Annulla» o «Riprova»). `ms`: quanto resta. */
export function actionToast(msg, label, fn, ms = 6000) {
  const t = toast(msg, ms);
  t.classList.add("act");
  const done = () => { if (pendingUndo === entry) pendingUndo = null; t.remove(); };
  const entry = { fn, done, isUndo: false };
  t.append(h("button.toast-btn", { type: "button", onclick: () => { done(); fn(); } }, label));
  setTimeout(() => { if (pendingUndo === entry) pendingUndo = null; }, ms);
  return entry;
}
export function undoToast(msg, onUndo) {
  const entry = actionToast(msg, tc("undo", "Annulla"), onUndo, 6000);
  entry.isUndo = true;
  pendingUndo = entry;
}
if (typeof document !== "undefined") document.addEventListener("keydown", (e) => {
  if (!pendingUndo?.isUndo || !(e.ctrlKey || e.metaKey) || e.shiftKey || (e.key !== "z" && e.key !== "Z")) return;
  if (e.target instanceof Element && e.target.closest("input, textarea, select")) return;
  e.preventDefault();
  e.stopImmediatePropagation();
  const u = pendingUndo;
  u.done();
  u.fn();
}, true);

/**
 * Una domanda. Pulsanti: { label, value, primary, danger, focus }.
 * Il pulsante scelto con Invio non è mai quello che butta via qualcosa (danger); Esc risponde null.
 */
export function modal(title, text, buttons) {
  return new Promise((resolve) => {
    const bg = h("div.modal-bg");
    const close = (v) => {
      bg.remove();
      document.removeEventListener("keydown", esc, true);
      resolve(v);
    };
    const els = buttons.map((b) => h("button.btn" + (b.primary ? ".primary" : ""), { type: "button", onclick: () => close(b.value) }, b.label));
    const row = h("div.row", els);
    bg.append(h("div.modal", { role: "dialog", "aria-modal": "true" }, h("h3", title), text ? h("p", text) : null, row));
    bg.addEventListener("click", (e) => e.target === bg && close(null));
    const esc = (e) => { if (e.key === "Escape" && bg.isConnected && [...document.querySelectorAll(".modal-bg")].pop() === bg) { e.preventDefault(); e.stopImmediatePropagation(); close(null); } };
    document.addEventListener("keydown", esc, true);
    document.body.append(bg);
    let i = buttons.findIndex((b) => b.focus);
    if (i < 0 && buttons.some((b) => b.danger)) i = buttons.findIndex((b) => !b.danger);
    if (i < 0) i = els.length - 1;
    els[i]?.focus();
  });
}

/** 1.1 · «Buttare …?» solo quando c'è qualcosa da perdere: «Continua» è la scelta predefinita. */
export function askDiscard(title, text) {
  return modal(title, text || null, [{ label: t("Butta"), value: true, danger: true }, { label: t("Continua"), value: false, primary: true, focus: true }]).then((v) => v === true);
}

// 1.1 · Chi ha del lavoro da perdere (PDF modificato, pannello aperto…) lo dice qui: chiudendo OrbitLR si chiede prima.
const guards = new Set();
/** `fn()` restituisce una frase («Il PDF «X» ha modifiche non salvate.») oppure null. Restituisce la funzione per toglierla. */
export function guardClose(fn) {
  guards.add(fn);
  return () => guards.delete(fn);
}
export function closeReasons() {
  const out = [];
  for (const g of guards) {
    try {
      const r = g();
      if (r) out.push(r);
    } catch {}
  }
  return out;
}

/** 1.1 · Il menu del clic destro: [{ label, icon, onclick, disabled, title }]. */
export function contextMenu(e, items) {
  e.preventDefault();
  e.stopPropagation();
  document.querySelector(".pop.ctx")?.remove();
  const pop = h("div.pop.ctx", { role: "menu" }, items.filter(Boolean).map((it) =>
    h("button.ctx-i", { type: "button", role: "menuitem", disabled: it.disabled || null, title: it.title || null, onclick: () => { pop.remove(); it.onclick(); } }, it.icon ? ico(it.icon, 14) : null, it.label)));
  pop.style.left = Math.max(8, Math.min(window.innerWidth - 230, e.clientX)) + "px";
  pop.style.top = Math.max(8, Math.min(window.innerHeight - 40 * items.length - 20, e.clientY)) + "px";
  document.body.append(pop);
  pop.querySelector("button:not([disabled])")?.focus();
  const off = (ev) => {
    if (ev.type === "keydown" && ev.key !== "Escape") return;
    if (ev.type === "pointerdown" && pop.contains(ev.target)) return;
    pop.remove();
    document.removeEventListener("pointerdown", off, true);
    document.removeEventListener("keydown", off, true);
  };
  setTimeout(() => { document.addEventListener("pointerdown", off, true); document.addEventListener("keydown", off, true); }, 0);
}

/** 1.1 · «1:02,345» ↔ 62.345 secondi (anche «62,3», «1:02.5», «1:00:02,345»). null se non si capisce. */
export function parseTime(s) {
  const txt = String(s || "").trim().replace(/\s+/g, "");
  if (!/^\d+(?::\d{1,2}){0,2}(?:[.,]\d{1,3})?$/.test(txt)) return null;
  const [main, frac = ""] = txt.split(/[.,]/);
  const parts = main.split(":").map(Number);
  if (parts.slice(1).some((x) => x >= 60)) return null;
  const sec = parts.reduce((a, x) => a * 60 + x, 0);
  return sec + (frac ? Number(frac.padEnd(3, "0")) / 1000 : 0);
}
export function fmtTimeMs(s) {
  if (!isFinite(s) || s < 0) s = 0;
  const ms = Math.round(s * 1000);
  const whole = Math.floor(ms / 1000);
  const frac = String(ms % 1000).padStart(3, "0");
  return `${fmtTime(whole)}${isEn ? "." : ","}${frac}`;
}

export function baseName(path) {
  return String(path).split(/[\\/]/).pop();
}

export function dirName(path) {
  const p = String(path);
  const i = Math.max(p.lastIndexOf("\\"), p.lastIndexOf("/"));
  return i > 0 ? p.slice(0, i) : p;
}

export function extOf(path) {
  const n = baseName(path);
  const i = n.lastIndexOf(".");
  return i > 0 ? n.slice(i + 1).toLowerCase() : "";
}
