// Tester20 · Windows · cose comuni alle prove dell'interfaccia in Chromium (Playwright).
// L'interfaccia vera (Windows/ui) servita da un piccolo server locale, con il finto Tauri di Tools/finto-tauri-windows.js.
import { createRequire } from "node:module";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(path.join(process.cwd(), "x.js"));
export const pw = require("playwright");
const here = path.dirname(fileURLToPath(import.meta.url));
export const repo = path.join(here, "..", "..", "..", "..");
export const uiRoot = path.join(repo, "Windows", "ui");
export const fake = fs.readFileSync(path.join(repo, "Tools", "finto-tauri-windows.js"), "utf8");

const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png", ".svg": "image/svg+xml", ".woff2": "font/woff2", ".json": "application/json", ".wav": "audio/wav", ".mp3": "audio/mpeg" };
export async function server(root = uiRoot) {
  const srv = http.createServer((q, r) => {
    const rel = decodeURIComponent(q.url.split("?")[0]);
    const p = path.join(root, rel === "/" ? "index.html" : rel);
    if (!p.startsWith(root) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { r.writeHead(404); return r.end(); }
    r.writeHead(200, { "Content-Type": types[path.extname(p)] || "application/octet-stream" });
    fs.createReadStream(p).pipe(r);
  });
  await new Promise((ok) => srv.listen(0, "127.0.0.1", ok));
  return { base: `http://127.0.0.1:${srv.address().port}/`, close: () => srv.close() };
}

export const TABS = ["convert", "image", "video", "audio", "pdf", "activity", "auto", "settings", "help"];
// Un file adatto a ogni scheda (tra quelli del finto Tauri)
export const FILE_FOR = {
  convert: "C:\\Utenti\\Prova\\Immagini\\Vacanze al mare.jpg",
  image: "C:\\Utenti\\Prova\\Immagini\\Vacanze al mare.jpg",
  video: "C:\\Utenti\\Prova\\Video\\Gita al lago.mp4",
  audio: "C:\\Utenti\\Prova\\Musica\\La mia canzone.mp3",
  pdf: "C:\\Utenti\\Prova\\Documenti\\Contratto.pdf",
};

/** Una pagina dell'interfaccia: finto Tauri, italiano, benvenuto già visto (o no). */
export async function pagina(browser, base, { vw = 1366, vh = 688, dsf = 1, welcomed = true, tab = "convert", cfg = {}, extra = {}, ctxOpts = {}, init = null } = {}) {
  const ctx = await browser.newContext({ viewport: { width: vw, height: vh }, deviceScaleFactor: dsf, locale: "it-IT", bypassCSP: true, ...ctxOpts });
  await ctx.addInitScript((c) => { window.__Fcfg = Object.assign({ seed: 1, mix: { ok: 1 }, per: {} }, c); }, cfg);
  await ctx.addInitScript(fake);
  if (init) await ctx.addInitScript(init);
  await ctx.addInitScript(({ welcomed, tab, extra }) => {
    Object.defineProperty(Navigator.prototype, "webdriver", { get: () => false });
    const v = { welcomed, tips: false, tab, appLang: "it", ...extra };
    for (const [k, x] of Object.entries(v)) localStorage.setItem("orbitlr." + k, JSON.stringify(x));
  }, { welcomed, tab, extra });
  const pg = await ctx.newPage();
  const errs = [];
  pg.on("pageerror", (e) => errs.push(String(e).slice(0, 300)));
  await pg.goto(base);
  await pg.waitForSelector("aside .nav button", { timeout: 15000 });
  await pg.waitForTimeout(700);
  return { ctx, pg, errs };
}

/** Apre una scheda con la barra laterale (indice nell'ordine di TABS). */
export async function apriScheda(pg, tab) {
  const i = TABS.indexOf(tab);
  const btn = (await pg.$$("aside .nav button, aside .foot button"))[i];
  if (!btn) return false;
  await btn.click({ force: true, timeout: 3000 }).catch(() => {});
  await pg.waitForTimeout(350);
  return true;
}

/** Mette un file nella scheda (come trascinato sulla finestra). */
export async function mettiFile(pg, tab) {
  const f = FILE_FOR[tab];
  if (!f) return false;
  const ok = await pg.evaluate((p) => window.__Fdrop ? window.__Fdrop([p]) : false, f);
  await pg.waitForTimeout(900);
  return ok;
}

/** Il risultato di una parte di profilo, come quello che scrivono gli script PowerShell (parte-*.json). */
export function esito() {
  const r = { passi_fatti: 0, passati: 0, non_eseguiti: [], bug: [], confuso: [], note: [] };
  return {
    r,
    passo(cosa, ok, det = "") { r.passi_fatti++; if (ok) r.passati++; console.log(`PASSO ${ok ? "OK" : "NO"} · ${cosa}${det ? " · " + det : ""}`); return ok; },
    bug(titolo, gravita, passi, atteso, visto, prova) { r.bug.push({ titolo, gravita, passi, atteso, visto, prova }); console.log(`BUG [${gravita}] ${titolo} · ${visto}`); },
    nonEseguito(cosa, perche) { r.non_eseguiti.push({ cosa, perche }); console.log(`NON ESEGUITO ${cosa} · ${perche}`); },
    confuso(cosa, perche) { r.confuso.push({ cosa, perche }); console.log(`CONFUSO ${cosa} · ${perche}`); },
    nota(t) { r.note.push(t); console.log("NOTA " + t); },
    salva(out, nome) { fs.mkdirSync(out, { recursive: true }); fs.writeFileSync(path.join(out, `parte-${nome}.json`), JSON.stringify(r, null, 1)); },
  };
}

/** Controllo «dentro la finestra» di un elemento e dei pulsanti che contiene (eseguito nella pagina). */
export function fuoriFinestra(sel) {
  const vw = innerWidth, vh = innerHeight, bad = [];
  const roots = [...document.querySelectorAll(sel)].filter((e) => e.getClientRects().length);
  const se = document.scrollingElement;
  se.scrollTop = 0; se.scrollLeft = 0;
  for (const root of roots) {
    se.scrollTop = 0; se.scrollLeft = 0;
    const r = root.getBoundingClientRect();
    const name = (root.querySelector("h2,h3,h4,b")?.textContent || root.className).trim().slice(0, 50);
    if (r.left < -1 || r.top < -1 || r.right > vw + 1 || r.bottom > vh + 1) bad.push(`«${name}» esce dalla finestra (${Math.round(r.left)},${Math.round(r.top)} ${Math.round(r.width)}×${Math.round(r.height)}; finestra ${vw}×${vh})`);
    for (const b of root.querySelectorAll("button, a[href], input, select, textarea")) {
      const cs = getComputedStyle(b);
      if (cs.display === "none" || cs.visibility === "hidden" || !b.getClientRects().length) continue;
      b.scrollIntoView({ block: "center", inline: "nearest" });
      // Si scorre solo dentro le aree che scorrono: la finestra intera no (lo dice «la pagina intera scorre»)
      const docMoved = se.scrollTop > 0 || se.scrollLeft > 0;
      se.scrollTop = 0; se.scrollLeft = 0;
      const e = b.getBoundingClientRect();
      if (docMoved && (e.bottom > vh + 1 || e.right > vw + 1)) { bad.push(`«${name}»: «${(b.getAttribute("aria-label") || b.textContent || "").trim().replace(/\s+/g, " ").slice(0, 40)}» si raggiunge solo facendo scorrere la finestra intera`); continue; }
      const label = (b.getAttribute("aria-label") || b.textContent || b.value || b.tagName).trim().replace(/\s+/g, " ").slice(0, 40);
      if (e.right < 0 || e.bottom < 0 || e.left > vw || e.top > vh || e.bottom > vh + 1 || e.right > vw + 1) { bad.push(`«${name}»: «${label}» non si raggiunge (${Math.round(e.left)},${Math.round(e.top)})`); continue; }
      const hit = document.elementFromPoint(Math.min(vw - 1, Math.max(0, e.left + e.width / 2)), Math.min(vh - 1, Math.max(0, e.top + e.height / 2)));
      if (hit && !b.contains(hit) && !hit.contains(b) && !hit.closest(".toast")) bad.push(`«${name}»: «${label}» coperto da ${hit.tagName.toLowerCase()}.${String(hit.className).split(" ")[0]}`);
    }
  }
  se.scrollTop = 0; se.scrollLeft = 0;
  return bad;
}
