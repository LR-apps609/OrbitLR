// «Le mie azioni», come sul Mac: un'azione con la sua scelta (es. «Comprimi · WhatsApp») salvata con un nome.
// Compaiono in cima agli strumenti della scheda e come spicchi con la stella nella torta.

import { KNOBS, TOOLS, actionName } from "./catalog.js";
import { h, store } from "./util.js";

const KEY = "presets";
const MAX = 24;

export function presets(kind) {
  const all = store.get(KEY, []);
  return kind ? all.filter((p) => p.kind === kind) : all;
}

function save(list) {
  store.set(KEY, list.slice(0, MAX));
}

/** Il nome proposto: «Comprimi · WhatsApp». */
export function suggestName(action, value) {
  const knob = Object.entries(TOOLS).find(([id, t]) => (t.id || id) === action)?.[1]?.params;
  const opt = KNOBS[knob]?.options.find((o) => o.value === value);
  const label = opt ? opt.label : value != null && value !== "" ? String(value) : "";
  return label ? `${actionName(action)} · ${label}` : actionName(action);
}

export function addPreset(kind, action, param, name) {
  const list = presets();
  const clean = String(name || "").trim().slice(0, 40) || suggestName(action, param);
  const p = { id: "p" + Date.now().toString(36), kind, action, param, name: clean };
  save([p, ...list.filter((x) => !(x.kind === kind && x.name.toLowerCase() === clean.toLowerCase()))]);
  return p;
}

export function removePreset(id) {
  save(presets().filter((p) => p.id !== id));
}

export function renamePreset(id, name) {
  const n = String(name || "").trim().slice(0, 40);
  if (!n) return;
  save(presets().map((p) => (p.id === id ? { ...p, name: n } : p)));
}

/** Una finestrella con un campo di testo; risolve con il testo o null. */
export function askName(title, value, hint) {
  return new Promise((resolve) => {
    const input = h("input", { type: "text", value, maxlength: "40", "aria-label": "Nome", style: { width: "100%", boxSizing: "border-box", padding: "8px 10px", borderRadius: "10px", border: "1px solid var(--line-2)", background: "var(--card)", color: "var(--ink)", font: "inherit" } });
    const bg = h("div.modal-bg");
    const close = (v) => { bg.remove(); resolve(v); };
    const ok = h("button.btn.primary", { type: "button", onclick: () => close(input.value.trim() || null) }, "Salva");
    input.addEventListener("keydown", (e) => { if (e.key === "Enter") ok.click(); if (e.key === "Escape") close(null); });
    bg.append(h("div.modal", { role: "dialog", "aria-modal": "true" }, h("h3", title), hint ? h("p", hint) : null, input,
      h("div.row", h("button.btn", { type: "button", onclick: () => close(null) }, "Annulla"), ok)));
    bg.addEventListener("click", (e) => e.target === bg && close(null));
    document.body.append(bg);
    input.select();
  });
}
