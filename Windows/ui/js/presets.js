// «Le mie azioni», come sul Mac: un'azione con la sua scelta (es. «Comprimi · WhatsApp») salvata con un nome.
// Compaiono in cima agli strumenti della scheda e come spicchi con la stella nella torta.

import { KNOBS, TOOLS, actionName } from "./catalog.js";
import { h, store } from "./util.js";
import { t } from "./i18n.js";

const KEY = "presets";
const MAX = 24;

/** Cosa fa una mia azione o ricetta, in parole. */
export function describe(p) {
  return p.steps ? p.steps.map((s) => suggestName(s.action, s.param)).join(" → ") : suggestName(p.action, p.param);
}

export function presets(kind) {
  const all = store.get(KEY, []);
  return kind ? all.filter((p) => p.kind === kind) : all;
}

function save(list) {
  store.set(KEY, list.slice(0, MAX));
}

/** Il nome proposto: «Comprimi · WhatsApp». */
export function suggestName(action, value) {
  if (!action) return "";
  const knob = Object.entries(TOOLS).find(([id, t]) => (t.id || id) === action)?.[1]?.params;
  // «9x16|1»: la scelta e l'interruttore (per esempio «Inquadra le persone»)
  const [base, flag] = typeof value === "string" && KNOBS[knob]?.flag ? value.split("|") : [value, null];
  value = base;
  const opt = KNOBS[knob]?.options.find((o) => o.value === value);
  const label = opt ? opt.label : value != null && value !== "" ? String(value) : "";
  const extra = flag === "1" ? ` · ${KNOBS[knob].flag.short}` : "";
  return label ? `${actionName(action)} · ${label}${extra}` : actionName(action);
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
    const input = h("input", { type: "text", value, maxlength: "40", "aria-label": t("Nome"), style: { width: "100%", boxSizing: "border-box", padding: "8px 10px", borderRadius: "10px", border: "1px solid var(--line-2)", background: "var(--card)", color: "var(--ink)", font: "inherit" } });
    const bg = h("div.modal-bg");
    const close = (v) => { bg.remove(); resolve(v); };
    const ok = h("button.btn.primary", { type: "button", onclick: () => close(input.value.trim() || null) }, t("Salva"));
    input.addEventListener("keydown", (e) => { if (e.key === "Enter") ok.click(); if (e.key === "Escape") close(null); });
    bg.append(h("div.modal", { role: "dialog", "aria-modal": "true" }, h("h3", title), hint ? h("p", hint) : null, input,
      h("div.row", h("button.btn", { type: "button", onclick: () => close(null) }, t("Annulla")), ok)));
    bg.addEventListener("click", (e) => e.target === bg && close(null));
    document.body.append(bg);
    input.select();
  });
}

// ───────────────────────── Ricette: più passi di fila con un clic (come sul Mac)
// Se lavori un file appena creato da OrbitLR (per esempio converti in MP3, poi tagli), la barra del risultato
// propone «Salva come ricetta»: la prossima volta i passi partono uno dopo l'altro da soli.

/** La catena di lavori che ha portato a `job` (dal primo al più recente), se ce n'è una di almeno 2 passi. */
export function chainOf(job, history) {
  const steps = [job];
  let cur = job;
  for (let guard = 0; guard < 5; guard++) {
    const src = cur.files?.[0]?.path;
    if (!src || cur.files.length !== 1) break;
    const prev = history.find((h) => h !== cur && h.state === "done" && h.results?.some((r) => r.outputs?.some((o) => o.path === src)) && (cur.started || 0) - (h.ended || 0) < 30 * 60e3);
    if (!prev || prev.files?.length !== 1 || ["link", "tts", "rename", "protect", "unprotect", "pdfedit", "vproject"].includes(prev.action)) break;
    steps.unshift(prev);
    cur = prev;
  }
  if (steps.length < 2) return null;
  return { first: steps[0].files[0].path, steps: steps.map((j) => ({ action: j.action, param: j.param ?? null })) };
}

export function addRecipe(kind, steps, name) {
  const list = presets();
  const p = { id: "r" + Date.now().toString(36), kind, steps, name: String(name || "").trim().slice(0, 40) || steps.map((s) => actionName(s.action)).join(" → ") };
  store.set(KEY, [p, ...list].slice(0, MAX));
  return p;
}

/** Fa i passi uno dopo l'altro: ogni passo lavora i file creati dal passo prima. */
export async function runSteps(steps, files, origin, runFn, subscribeFn) {
  let current = files;
  for (const s of steps) {
    const job = await runFn(s.action, current, s.param, origin);
    const done = await new Promise((resolve) => {
      if (job.state !== "running") return resolve(job);
      const off = subscribeFn((j) => {
        if (j && j.id === job.id && j.state !== "running") { off(); resolve(j); }
      });
    });
    const outs = done.results.flatMap((r) => r.outputs || []);
    if (done.state !== "done" || !outs.length) return false;
    current = outs.map((o) => ({ path: o.path, name: o.name, size: o.size }));
  }
  return true;
}
