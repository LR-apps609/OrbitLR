// I lavori: partono, mandano l'avanzamento, finiscono in Attività e i file creati nel Cassetto.

import { invoke, onAutoJob, onJob } from "./api.js";
import { actionName } from "./catalog.js";
import { store } from "./util.js";
import { t } from "./i18n.js";

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
export function getDrawer() {
  return drawer;
}
export function clearHistory() {
  history = [];
  store.set("history", history);
  notify(null);
}
export function removeFromHistory(id) {
  history = history.filter((j) => j.id !== id);
  store.set("history", history);
  notify(null);
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

export function cancel(id) {
  invoke("cancel_job", { id });
}

function finish(job) {
  job.ended = Date.now();
  jobs.delete(job.id);
  const record = { ...job };
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
