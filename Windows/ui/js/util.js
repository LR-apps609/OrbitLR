// Piccoli aiuti: creare elementi, numeri all'italiana, memoria delle preferenze, avvisi.

import { icon } from "./icons.js";
import { t, isEn } from "./i18n.js";

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
export function toast(msg) {
  document.querySelector(".toast")?.remove();
  const t = h("div.toast", msg);
  document.body.append(t);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.remove(), 3200);
}

export function modal(title, text, buttons) {
  return new Promise((resolve) => {
    const bg = h("div.modal-bg");
    const close = (v) => {
      bg.remove();
      resolve(v);
    };
    const row = h("div.row", buttons.map((b) => h("button.btn" + (b.primary ? ".primary" : ""), { onclick: () => close(b.value) }, b.label)));
    bg.append(h("div.modal", { role: "dialog", "aria-modal": "true" }, h("h3", title), text ? h("p", text) : null, row));
    bg.addEventListener("click", (e) => e.target === bg && close(null));
    document.body.append(bg);
    row.lastChild?.focus();
  });
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
