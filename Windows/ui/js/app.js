// OrbitLR per Windows: la finestra con la barra laterale e le schede.

import { DEMO, invoke, onDrop, openPath, reveal } from "./api.js";
import { kindOfExt } from "./catalog.js";
import { audioPage } from "./audio.js";
import { convertPage } from "./convert.js";
import { getDrawer, running, subscribe } from "./jobs.js";
import { mediaPage } from "./media.js";
import { activityPage, helpPage, report, settingsPage } from "./pages.js";
import { extOf, fmtBytes, h, ico, modal, store, toast } from "./util.js";

const VERSION = "0.1.0";

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
  { id: "convert", label: "Conversione", icon: "arrow-left-right", make: () => convertPage(app) },
  { id: "image", label: "Immagini", icon: "image", make: () => mediaPage("image", app) },
  { id: "video", label: "Video", icon: "film", make: () => mediaPage("video", app) },
  { id: "audio", label: "Audio", icon: "audio-lines", make: () => audioPage(app) },
  { id: "pdf", label: "File", icon: "file-text", make: () => mediaPage("pdf", app) },
];
const EXTRA = {
  activity: { label: "Attività", make: () => activityPage(app) },
  settings: { label: "Opzioni", make: () => settingsPage(app) },
  help: { label: "Aiuto", make: () => helpPage(app) },
};

const main = h("main.main");
const navButtons = {};
const activityBadge = h("span.badge", { hidden: true });
const drawerList = h("ul");
const drawerEmpty = h("p", "I file che crei finiscono qui: un clic per vederli nella cartella.");

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
  const nav = h("nav.nav", { "aria-label": "Schede" });
  for (const t of TABS) {
    navButtons[t.id] = h("button", { onclick: () => show(t.id) }, ico(t.icon, 18), t.label);
    nav.append(navButtons[t.id]);
  }
  nav.append(h("div.nav-sep"));
  navButtons.activity = h("button", { onclick: () => show("activity") }, ico("clock", 18), "Attività", activityBadge);
  nav.append(navButtons.activity);
  const foot = h("div.foot",
    (navButtons.settings = h("button", { onclick: () => show("settings") }, ico("settings", 17), "Opzioni")),
    (navButtons.help = h("button", { onclick: () => show("help") }, ico("circle-help", 17), "Aiuto")),
    h("button", { onclick: () => report(app) }, ico("bug", 17), "Segnala"));
  return h("aside.side",
    h("div.brand", h("img", { src: "img/icona.png", alt: "" }), h("div", h("b", "OrbitLR"), h("small", "per Windows"))),
    nav,
    h("div.side-fill"),
    h("div.drawer", h("h4", ico("archive", 15), "Cassetto"), drawerEmpty, drawerList),
    foot,
    h("div.ver", `OrbitLR ${VERSION}${DEMO ? " · prova" : ""}`));
}

function renderDrawer() {
  const items = getDrawer().slice(0, 12);
  drawerEmpty.hidden = items.length > 0;
  drawerList.replaceChildren(...items.map((d) => h("li", { title: `${d.name}\nClic: mostra nella cartella · Doppio clic: apri`, onclick: () => reveal(d.path), ondblclick: () => openPath(d.path) },
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
    toast(`Li apro in ${TABS.find((t) => t.id === tab).label}`);
    show(tab);
    return app.pages[tab].add(paths);
  }
  show("convert");
  app.pages.convert.add(paths);
}

async function boot() {
  app.applyTheme();
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => app.applyTheme());
  const splash = h("div.splash", h("img", { src: "img/icona.png", alt: "OrbitLR" }));
  document.body.append(h("div.app", sidebar(), main), splash);
  show(store.get("tab", "convert"));
  renderDrawer();
  subscribe(() => {
    renderDrawer();
    const n = running().length;
    activityBadge.hidden = n === 0;
    activityBadge.textContent = String(n);
  });
  onDrop((type, paths) => {
    document.querySelectorAll(".dropzone, .empty .box").forEach((d) => d.classList.toggle("over", type === "enter" || type === "over"));
    if (type === "drop") handleDrop(paths);
  });
  // Niente menu del browser e niente navigazione accidentale trascinando un link
  window.addEventListener("dragover", (e) => e.preventDefault());
  window.addEventListener("drop", (e) => e.preventDefault());
  if (!DEMO) document.addEventListener("contextmenu", (e) => { if (!e.target.closest("input, textarea")) e.preventDefault(); });
  invoke("engine_status").then((s) => {
    app.engine = s;
    if (!s.ready) toast("Il motore video non si è avviato: reinstalla OrbitLR.");
    if (app.current === "settings") app.pages.settings.show();
  });
  // Chiudere con dei lavori in corso
  window.__TAURI__?.event.listen("close-requested", async () => {
    const n = running().length;
    const ok = await modal("Ci sono lavori in corso", `${n === 1 ? "Un lavoro non è" : n + " lavori non sono"} ancora finit${n === 1 ? "o" : "i"}. Se chiudi adesso si interrompono e i file a metà vengono cancellati.`,
      [{ label: "Continua a lavorare", value: false }, { label: "Interrompi e chiudi", value: true, primary: true }]);
    if (ok) invoke("quit_now");
  });
  // File passati all'avvio (Apri con…); nelle prove automatiche anche scheda e azione
  invoke("startup").then(async (st) => {
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
  setTimeout(() => splash.classList.add("out"), 450);
  setTimeout(() => splash.remove(), 900);
}

boot();
