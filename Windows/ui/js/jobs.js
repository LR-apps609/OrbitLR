// I lavori: partono, mandano l'avanzamento, finiscono in Attività e i file creati nel Cassetto.

import { invoke, onAutoJob, onJob } from "./api.js";
import { actionName } from "./catalog.js";
import { store } from "./util.js";
import { t, tr } from "./i18n.js";
import { AI_ACTIONS } from "./attese.js";

const jobs = new Map(); // id → lavoro
const subs = new Set();
let history = store.get("history", []);
let drawer = store.get("drawer", []);

export function subscribe(fn) {
  subs.add(fn);
  return () => subs.delete(fn);
}
function notify(job) {
  subs.forEach((fn) => fn(job));
}

export function running() {
  return [...jobs.values()].filter((j) => j.state === "running");
}
export function getHistory() {
  return history;
}
/** Spazio risparmiato nel mese corrente (compressioni e conversioni riuscite, escluse quelle annullate), come sul Mac. */
export function savedThisMonth() {
  const now = new Date();
  let sum = 0;
  for (const j of history) {
    if (j.undone || !j.ended) continue;
    const d = new Date(j.ended);
    if (d.getFullYear() !== now.getFullYear() || d.getMonth() !== now.getMonth()) continue;
    for (const r of j.results || []) {
      if (r.error || !r.sourceSize || !r.outputs?.length) continue;
      const after = r.outputs.reduce((a, o) => a + (o.size || 0), 0);
      if (after > 0 && after < r.sourceSize) sum += r.sourceSize - after;
    }
  }
  return sum;
}

/** Un lavoro annullato non conta più nello spazio risparmiato. */
export function markUndone(id) {
  history = history.map((j) => (j.id === id ? { ...j, undone: true } : j));
  store.set("history", history);
  notify({ id });
}

export function getDrawer() {
  return drawer;
}
/** Cancella la cronologia; restituisce quella di prima (per «Annulla», 1.1). */
export function clearHistory() {
  const old = history;
  history = [];
  store.set("history", history);
  notify(null);
  return old;
}
/** Toglie una voce; restituisce la voce e dov'era (per «Annulla», 1.1). */
export function removeFromHistory(id) {
  const at = history.findIndex((j) => j.id === id);
  const item = history[at];
  history = history.filter((j) => j.id !== id);
  store.set("history", history);
  notify(null);
  return item ? { item, at } : null;
}
/** 1.1 · Rimette voci tolte dalla cronologia. */
export function restoreHistory(list) {
  const known = new Set(history.map((j) => j.id));
  const back = list.filter((x) => !known.has(x.item.id)).sort((a, b) => a.at - b.at);
  for (const { item, at } of back) history.splice(Math.min(at, history.length), 0, item);
  store.set("history", history);
  notify(null);
}

/** 2.0.2 · Le scelte che possono restare nella cronologia: mai l'Editor PDF, mai le password, mai oltre 2 KB. */
export function keepParam(action, param) {
  if (param == null) return true;
  if (["pdfedit", "protect", "unprotect"].includes(action)) return false;
  try {
    return JSON.stringify(param).length <= 2048;
  } catch {
    return false;
  }
}

/** 1.1 · «Riprova»: lo stesso lavoro, con gli stessi file e le stesse scelte. */
export function retry(job) {
  return run(job.action, job.files, job.param, job.origin === "auto" ? "activity" : job.origin);
}

/** Dove salvare secondo le Opzioni (null = accanto all'originale). */
export function outDir() {
  const where = store.get("where", "same");
  if (where === "downloads") return store.get("downloadsDir", null);
  if (where === "folder") return store.get("folder", null);
  return null;
}

/**
 * Avvia un'azione. `files`: [{path, name, size}]. Restituisce il lavoro.
 * `origin`: la scheda da cui è partito (per la barra del risultato).
 */
export async function run(action, files, param, origin) {
  const id = "j" + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
  const job = {
    id,
    action,
    title: actionName(action),
    origin,
    files: files.map((f) => ({ path: f.path, name: f.name, size: f.size })),
    // Le password non restano mai nella cronologia
    param: ["protect", "unprotect"].includes(action) ? null : param,
    state: "running",
    progress: 0,
    results: [], // { source, outputs:[{path,name,size}], error }
    started: Date.now(),
  };
  jobs.set(id, job);
  notify(job);
  // 2.0.1 · L'IA la prima volta scarica motore o modello: lo si sa prima, così la barra lo dice
  if (AI_ACTIONS.includes(action)) job.fetch = await invoke("ai_pending", { action }).catch(() => null);
  // 2.0.2 · Un file spostato o cancellato dopo averlo scelto non fa più fallire tutto il lotto (con l'errore sul primo file):
  // si toglie, si dice quale manca, e gli altri partono
  if (job.files.length) {
    const exist = await invoke("files_exist", { paths: job.files.map((f) => f.path) }).catch(() => null);
    if (Array.isArray(exist) && exist.length === job.files.length && exist.some((x) => !x)) {
      const gone = job.files.filter((_, i) => !exist[i]);
      job.files = job.files.filter((_, i) => exist[i]);
      for (const f of gone) job.results.push({ source: f.name, outputs: [], error: t("il file non c'è più: è stato spostato o cancellato?") });
      if (!job.files.length) {
        job.state = "failed";
        finish(job);
        return job;
      }
    }
  }
  try {
    await invoke("start_job", { id, action, files: job.files.map((f) => f.path), param: param ?? null, outDir: outDir() });
    param = null;
  } catch (e) {
    job.state = "failed";
    job.results.push({ source: job.files[0]?.name, outputs: [], error: String(e) });
    finish(job);
  }
  return job;
}

/** Quanto si aspetta che un lavoro si fermi dopo «Interrompi» (le prove lo accorciano). */
const stopWait = () => (typeof window !== "undefined" && window.__orbitStopWait) || 15000;

/**
 * «Interrompi». 2.0.1 · Se il motore dà errore o non risponde (né conferma né «interrotto» entro 15 s),
 * il lavoro non resta su «Interrompo…»: `stopError` dice perché e si può riprovare o chiudere la barra.
 */
export function cancel(id) {
  const job = jobs.get(id);
  if (job) {
    job.stopping = true;
    job.stopError = null;
    notify(job);
  }
  let over = false;
  const fail = (why) => {
    if (over) return;
    over = true;
    const j = jobs.get(id);
    if (!j || j.state !== "running") return;
    j.stopping = false;
    j.stopError = why;
    notify(j);
  };
  const timer = setTimeout(() => fail(t("il motore non risponde")), stopWait());
  invoke("cancel_job", { id }).catch((e) => {
    clearTimeout(timer);
    fail(tr(String(e?.message || e || "")) || t("errore sconosciuto"));
  });
}

function finish(job) {
  job.ended = Date.now();
  jobs.delete(job.id);
  const record = { ...job };
  // 2.0.2 · Nella cronologia salvata non restano dati personali o pesanti: testi, campi e firma dell'Editor PDF
  // (prima ogni firma, in PNG, restava per sempre e riempiva lo spazio fino a non salvare più i progetti).
  // Il lavoro in memoria li tiene: «Riprova» in questa sessione funziona come prima.
  if (!keepParam(record.action, record.param)) record.param = null;
  history = [record, ...history].slice(0, 300);
  store.set("history", history);
  const made = job.results.flatMap((r) => r.outputs.map((o) => ({ ...o, at: job.ended, action: job.action })));
  if (made.length) {
    drawer = [...made.reverse(), ...drawer.filter((d) => !made.some((m) => m.path === d.path))].slice(0, 40);
    store.set("drawer", drawer);
  }
  notify(job);
}

// Cartelle automatiche: il lavoro parte dal motore, qui si registra come gli altri
onAutoJob((a) => {
  const job = {
    id: a.id,
    action: a.action,
    title: t`${a.rule} · in automatico`,
    origin: "auto",
    files: a.files,
    param: a.param,
    state: "running",
    progress: 0,
    results: [],
    started: Date.now(),
  };
  jobs.set(a.id, job);
  notify(job);
});

onJob((ev) => {
  const job = jobs.get(ev.id);
  if (!job) return;
  if (ev.progress !== job.progress) job.lastMove = Date.now();
  if (ev.kind === "progress") {
    job.progress = ev.progress;
  } else if (ev.kind === "file") {
    job.progress = ev.progress;
    const src = job.files[ev.index] || job.files[0];
    job.results.push({ source: src?.name, sourcePath: src?.path, sourceSize: src?.size, outputs: ev.outputs || [], error: ev.error });
  } else if (ev.kind === "done") {
    job.state = ev.state;
    job.progress = 1;
    finish(job);
    return;
  }
  notify(job);
});
