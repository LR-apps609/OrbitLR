// OrbitLR per Windows: la finestra con la barra laterale e le schede.

import { play, prepareSounds } from "./sounds.js";
import { DEMO, invoke, onDrop, openPath, openUrl, reveal } from "./api.js";
import { kindOfExt } from "./catalog.js";
import { audioPage } from "./audio.js";
import { convertPage } from "./convert.js";
import { getDrawer, getHistory, running, savedThisMonth, subscribe } from "./jobs.js";
import { startWelcome } from "./welcome.js";
import { mediaPage } from "./media.js";
import { videoTab } from "./video.js";
import { activityPage, helpPage, report, settingsPage } from "./pages.js";
import { autoPage } from "./auto.js";
import { showFeedback } from "./feedback.js";
import { env, extOf, fmtBytes, h, ico, modal, store, toast } from "./util.js";
import { t, tr, LANG, isEn } from "./i18n.js";

const VERSION = "0.8.0";
// Numero della compilazione (lo scrive GitHub quando crea l'installazione)
const BUILD = 0;

window.__orbitVersion = VERSION;
const app = {
  version: VERSION,
  engine: null,
  dropTarget: null,
  pages: {},
  current: null,
  applyTheme() {
    const t = store.get("theme", "auto");
    if (t === "auto") document.documentElement.removeAttribute("data-theme");
    else document.documentElement.setAttribute("data-theme", t);
  },
  /** Apre dei file nella scheda giusta (dallo spicchio «Modifica» o dal Cassetto). */
  openIn(tab, paths) {
    show(tab);
    app.pages[tab].add?.(paths);
  },
};
window.orbit = app;

const TABS = [
  { id: "convert", label: t("Conversione"), icon: "arrow-left-right", make: () => convertPage(app) },
  { id: "image", label: t("Immagini"), icon: "image", make: () => mediaPage("image", app) },
  { id: "video", label: t("Video"), icon: "film", make: () => videoTab(app) },
  { id: "audio", label: t("Audio"), icon: "audio-lines", make: () => audioPage(app) },
  { id: "pdf", label: t("File"), icon: "file-text", make: () => mediaPage("pdf", app) },
];
const EXTRA = {
  activity: { label: t("Attività"), make: () => activityPage(app) },
  auto: { label: t("Cartelle automatiche"), make: () => autoPage(app) },
  settings: { label: t("Opzioni"), make: () => settingsPage(app) },
  help: { label: t("Aiuto"), make: () => helpPage(app) },
};

const main = h("main.main");
const navButtons = {};
const activityBadge = h("span.badge", { hidden: true });
const drawerList = h("ul");
const drawerEmpty = h("p", t("I file che crei finiscono qui: un clic per vederli nella cartella."));
const drawerSaved = h("p.saved", { hidden: true });
const updateLink = h("button.btn.brass", { hidden: true, style: { width: "100%", marginBottom: "8px" }, onclick: () => askUpdate() });
// Come sul Mac: in alto a destra, appena c'è un aggiornamento
const updateCorner = h("button.update-corner", { hidden: true, onclick: () => askUpdate() }, ico("circle-arrow-down", 15), t("Nuovo aggiornamento disponibile"));
let pendingUpdate = null;

function show(id) {
  if (!app.pages[id]) {
    const def = TABS.find((t) => t.id === id) || EXTRA[id];
    app.pages[id] = def.make();
  }
  app.current = id;
  store.set("tab", id);
  for (const [k, b] of Object.entries(navButtons)) b.classList.toggle("on", k === id);
  main.replaceChildren(app.pages[id].el);
  app.pages[id].show?.();
}

function sidebar() {
  const nav = h("nav.nav", { "aria-label": t("Schede") });
  for (const t of TABS) {
    navButtons[t.id] = h("button", { onclick: () => show(t.id) }, ico(t.icon, 18), t.label);
    nav.append(navButtons[t.id]);
  }
  nav.append(h("div.nav-sep"));
  navButtons.activity = h("button", { onclick: () => show("activity") }, ico("clock", 18), t("Attività"), activityBadge);
  nav.append(navButtons.activity);
  navButtons.auto = h("button", { onclick: () => show("auto") }, ico("folder-input", 18), t("Cartelle automatiche"));
  nav.append(navButtons.auto);
  const foot = h("div.foot",
    (navButtons.settings = h("button", { onclick: () => show("settings") }, ico("settings", 17), t("Opzioni"))),
    (navButtons.help = h("button", { onclick: () => show("help") }, ico("circle-help", 17), t("Aiuto"))),
    h("button", { onclick: () => report(app) }, ico("bug", 17), t("Segnala")),
    h("button", { title: t("Un’idea, una cosa che manca: mi arriva per email"), onclick: () => showFeedback(VERSION) }, ico("lightbulb", 17), t("Idea")));
  return h("aside.side",
    h("div.brand", h("img", { src: "img/icona.png", alt: "" }), h("div", h("b", "OrbitLR"), h("small", t("per Windows")))),
    nav,
    h("div.side-fill"),
    updateLink,
    h("div.drawer", h("h4", ico("archive", 15), t("Cassetto")), drawerSaved, drawerEmpty, drawerList),
    foot,
    h("div.ver", `OrbitLR ${VERSION}${BUILD ? ` (${BUILD})` : ""}${DEMO ? t(" · prova") : ""}`));
}

function renderDrawer() {
  const items = getDrawer().slice(0, 12);
  drawerEmpty.hidden = items.length > 0;
  // 0.7 · Come sul Mac: «Questo mese hai risparmiato 3,4 GB»
  const saved = savedThisMonth();
  drawerSaved.hidden = saved <= 0;
  drawerSaved.replaceChildren(ico("circle-arrow-down", 14), h("span", t`Questo mese hai risparmiato ${fmtBytes(saved)}`));
  let clickTimer;
  drawerList.replaceChildren(...items.map((d) => h("li", { title: t`${d.name}\nClic: mostra nella cartella · Doppio clic: apri`,
    onclick: () => { clearTimeout(clickTimer); clickTimer = setTimeout(() => reveal(d.path), 260); },
    ondblclick: () => { clearTimeout(clickTimer); openPath(d.path); } },
    ico(iconFor(d.name), 15), h("span.n", d.name), h("span.s", fmtBytes(d.size)))));
}

function iconFor(name) {
  const k = kindOfExt(extOf(name));
  return { image: "image", video: "film", audio: "music", pdf: "file-text" }[k] || "file";
}

/** File trascinati sulla finestra: nella scheda aperta se va bene lì, altrimenti in quella giusta. */
async function handleDrop(paths) {
  if (!paths.length) return;
  const cur = app.current;
  const kinds = new Set(paths.map((p) => kindOfExt(extOf(p))));
  const folderLike = paths.some((p) => !extOf(p));
  if (cur === "convert" || folderLike || ["activity", "settings", "help"].includes(cur)) {
    if (cur !== "convert") show("convert");
    return app.pages.convert.add(paths);
  }
  const fits = { image: ["image"], video: ["video"], audio: ["audio", "video"], pdf: ["pdf"] }[cur] || [];
  if ([...kinds].every((k) => fits.includes(k))) return app.pages[cur].add(paths);
  if (kinds.size === 1) {
    const k = [...kinds][0];
    const tab = k === "doc" || k === "other" ? "convert" : k;
    toast(t`Li apro in ${TABS.find((t) => t.id === tab).label}`);
    show(tab);
    return app.pages[tab].add(paths);
  }
  show("convert");
  app.pages.convert.add(paths);
}

/** Ogni 3 ore: c'è un aggiornamento firmato più nuovo? (solo GitHub, nessun dato personale) */
async function checkUpdate(force = false) {
  if (DEMO) return null;
  const last = store.get("updateCheck", 0);
  if (!force && Date.now() - last < 3 * 3600e3 && !pendingUpdate) return null;
  if (pendingUpdate && !force) return pendingUpdate.version;
  try {
    const u = await invoke("update_check", { version: VERSION, build: BUILD });
    store.set("updateCheck", Date.now());
    if (u) {
      pendingUpdate = u;
      updateLink.hidden = false;
      updateLink.textContent = t`Aggiorna alla ${u.version}`;
      updateCorner.hidden = false;
      document.body.classList.add("has-update");
      return u.version;
    }
  } catch {}
  return null;
}

async function askUpdate() {
  if (!pendingUpdate) return;
  const u = pendingUpdate;
  const busy = running().length;
  const notes = (isEn && u.notes_en) || u.notes;
  const text = [notes, t`Si scarica (${fmtBytes(u.size)}), OrbitLR si chiude, si aggiorna da sola e si riapre.`, busy ? t`Attenzione: ${busy === 1 ? t("c'è un lavoro in corso") : t`ci sono ${busy} lavori in corso`}, verrà interrotto.` : ""].filter(Boolean).join("\n\n");
  const ok = await modal(`OrbitLR ${u.version}`, text, [{ label: t("Più tardi"), value: false }, { label: t("Aggiorna adesso"), value: true, primary: true }]);
  if (!ok) return;
  // Le novità si mostrano alla prossima apertura, dalla versione nuova
  store.set("newsPending", { version: u.version, notes: notes || "" });
  updateCorner.disabled = true;
  updateLink.disabled = true;
  const show = (p) => { updateCorner.textContent = t`Scarico l’aggiornamento… ${Math.round(p * 100)}%`; };
  show(0);
  const off = window.__TAURI__?.event?.listen ? await window.__TAURI__.event.listen("update-progress", (e) => show(Number(e.payload) || 0)) : null;
  try {
    await invoke("update_install", { version: VERSION, build: BUILD });
  } catch (e) {
    off?.();
    updateCorner.disabled = false;
    updateLink.disabled = false;
    updateCorner.replaceChildren(ico("circle-arrow-down", 15), t("Nuovo aggiornamento disponibile"));
    toast(t`L’aggiornamento non è riuscito: ${tr(String(e))}`);
  }
}

function newer(a, b) {
  const x = a.split(".").map(Number), y = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0);
  return false;
}

async function boot() {
  invoke("set_lang", { lang: LANG }).catch(() => {});
  app.applyTheme();
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => app.applyTheme());
  const splash = h("div.splash", h("img", { src: "img/icona.png", alt: "OrbitLR" }));
  document.body.append(h("div.app", sidebar(), main), updateCorner, splash);
  const saved = store.get("tab", "convert");
  show(TABS.some((t) => t.id === saved) || EXTRA[saved] ? saved : "convert");
  renderDrawer();
  prepareSounds();
  subscribe((job) => {
    // Un «ding» a lavoro finito, un suono se non è riuscito (come sul Mac)
    if (job && job.ended && !job._sounded && job.state) {
      job._sounded = true;
      if (job.state === "failed" || (job.results || []).some((r) => r.error)) play("fail");
      else if (job.state === "done") play("done");
    }
    renderDrawer();
    const n = running().length;
    activityBadge.hidden = n === 0;
    activityBadge.textContent = String(n);
  });
  onDrop((type, paths) => {
    document.querySelectorAll(".dropzone, .empty .box").forEach((d) => d.classList.toggle("over", type === "enter" || type === "over"));
    if (type === "drop") { play("drop"); handleDrop(paths); }
  });
  // Niente menu del browser e niente navigazione accidentale trascinando un link
  window.addEventListener("dragover", (e) => e.preventDefault());
  window.addEventListener("drop", (e) => e.preventDefault());
  if (!DEMO) document.addEventListener("contextmenu", (e) => { if (!(e.target instanceof Element && e.target.closest("input, textarea"))) e.preventDefault(); });
  invoke("engine_status").then((s) => {
    app.engine = s;
    if (!s.ready) toast(t("Il motore video non si è avviato: reinstalla OrbitLR."));
    if (app.current === "settings") app.pages.settings.show();
  });
  // Chiudere con dei lavori in corso
  window.__TAURI__?.event.listen("close-requested", async () => {
    const n = running().length;
    const ok = await modal(t("Ci sono lavori in corso"), t`${n === 1 ? t("Un lavoro non è") : t`${n} lavori non sono`} ancora finit${n === 1 ? "o" : "i"}. Se chiudi adesso si interrompono e i file a metà vengono cancellati.`,
      [{ label: t("Continua a lavorare"), value: false }, { label: t("Interrompi e chiudi"), value: true, primary: true }]);
    if (ok) invoke("quit_now");
  });
  // «Apri con OrbitLR» mentre l'app è già aperta
  window.__TAURI__?.event.listen("open-files", (e) => handleDrop(e.payload || []));
  // File passati all'avvio (Apri con…); nelle prove automatiche anche scheda e azione
  invoke("startup").then(async (st) => {
    env.store = !!st?.store;
    if (!st || !st.files?.length) return;
    if (st.tab) {
      show(st.tab);
      await app.pages[st.tab].add(st.files);
    } else {
      await handleDrop(st.files);
    }
    if (st.action) {
      const { run } = await import("./jobs.js");
      const probed = await invoke("probe_files", { paths: st.files });
      const files = probed.filter((p) => p.ok).map((p) => ({ path: p.info.path, name: p.info.name, size: p.info.size }));
      let param = st.param ?? null;
      try { param = JSON.parse(param); } catch {}
      run(st.action, files, param, app.current);
    }
  }).catch(() => {});
  setTimeout(() => checkUpdate(), 4000);
  // Dopo un aggiornamento: cosa c'è di nuovo (una volta sola)
  const news = store.get("newsPending", null);
  // 0.7 · Benvenuto al primo avvio, poi «Lo sapevi?» (non nelle prove automatiche; chi usa già l'app non rivede il benvenuto)
  if (!store.get("welcomed", false) && (getHistory().length || store.get("updateCheck", 0))) store.set("welcomed", true);
  if (!navigator.webdriver) startWelcome(!!(news && news.version === VERSION));
  if (news && news.version === VERSION) {
    store.set("newsPending", null);
    setTimeout(() => modal(t`Benvenuto nella ${VERSION}`, news.notes || t("OrbitLR è aggiornata."), [{ label: t("Bene!"), value: true, primary: true }]), 1200);
  } else if (news && news.version !== VERSION && Date.now() - store.get("updateCheck", 0) > 7 * 86400e3) {
    store.set("newsPending", null);
  }
  setInterval(() => checkUpdate(), 3600e3);
  app.checkUpdate = checkUpdate;
  setTimeout(() => splash.classList.add("out"), 450);
  setTimeout(() => splash.remove(), 900);
}

boot();
