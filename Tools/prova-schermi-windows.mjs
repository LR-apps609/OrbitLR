// OrbitLR per Windows · l'interfaccia (in modalità prova, senza Tauri) alle misure vere degli schermi di Windows 11.
// Per ogni schermo e scala: area utile = (larghezza / scala, altezza / scala − barra delle applicazioni 48 − barra del titolo 32).
// Due finestre per schermo: «massima» (tutta l'area utile) e «iniziale» (1200×800 ridotta all'area utile, come la apre OrbitLR).
// Controlla che ogni pulsante della barra laterale, le schede e i pulsanti principali siano dentro la finestra
// e che il loro testo non sia tagliato. Uso: node Tools/prova-schermi-windows.mjs <cartella-foto> [1920x1080@125 ...]
import { createRequire } from "node:module";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// (require: trova playwright anche con NODE_PATH)
const { chromium } = createRequire(import.meta.url)("playwright");
const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "Windows", "ui");
const out = process.argv[2] || "schermi";
const TASKBAR = 48, TITLE = 32;
const ALL = ["1920x1080@100", "1920x1080@125", "1920x1080@150", "1366x768@100", "2560x1440@100", "2560x1440@125", "2560x1440@150", "2560x1440@175", "2560x1440@200"];
const wanted = process.argv.slice(3).length ? process.argv.slice(3) : ALL;
fs.mkdirSync(out, { recursive: true });

const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png", ".svg": "image/svg+xml", ".woff2": "font/woff2", ".json": "application/json", ".wav": "audio/wav" };
const srv = http.createServer((q, r) => {
  const rel = decodeURIComponent(q.url.split("?")[0]);
  const p = path.join(root, rel === "/" ? "index.html" : rel);
  if (!p.startsWith(root) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { r.writeHead(404); return r.end(); }
  r.writeHead(200, { "Content-Type": types[path.extname(p)] || "application/octet-stream" });
  fs.createReadStream(p).pipe(r);
});
await new Promise((ok) => srv.listen(0, ok));
const base = `http://127.0.0.1:${srv.address().port}/`;

/** Elementi che devono stare dentro la finestra, con il testo intero. */
function check() {
  const vw = innerWidth, vh = window.__visibleH || innerHeight, bad = [];
  const sel = ["aside .nav button", "aside .foot button", "aside .brand", "[data-test]", "main .dl", "main .dl-go", "main .seg button", "main .btn.primary"];
  const seen = new Set();
  for (const s of sel) {
    for (const el of document.querySelectorAll(s)) {
      if (seen.has(el)) continue;
      seen.add(el);
      const cs = getComputedStyle(el);
      if (cs.display === "none" || cs.visibility === "hidden" || !el.getClientRects().length) continue;
      // I pulsanti dentro un'area che scorre si raggiungono scorrendo: conta solo che l'area sia visibile
      let scroller = el.parentElement;
      while (scroller && !/(auto|scroll)/.test(getComputedStyle(scroller).overflowY)) scroller = scroller.parentElement;
      const r = (scroller && scroller !== document.body ? scroller : el).getBoundingClientRect();
      const e = el.getBoundingClientRect();
      const name = (el.getAttribute("data-test") || el.getAttribute("aria-label") || el.textContent || el.className).trim().replace(/\s+/g, " ").slice(0, 40);
      const box = scroller && scroller !== document.body ? r : e;
      if (box.left < -1 || box.top < -1 || box.right > vw + 1 || box.bottom > vh + 1 || e.width < 1 || e.height < 1) {
        bad.push(`fuori dalla finestra: «${name}» (${Math.round(e.left)},${Math.round(e.top)} ${Math.round(e.width)}×${Math.round(e.height)}; finestra ${vw}×${vh})`);
        continue;
      }
      if (!scroller || scroller === document.body) {
        // Coperto da qualcos'altro (per esempio tagliato da un contenitore con overflow nascosto)
        const cx = Math.min(vw - 1, Math.max(0, e.left + e.width / 2)), cy = Math.min(vh - 1, Math.max(0, e.top + e.height / 2));
        const hit = document.elementFromPoint(cx, cy);
        if (hit && !el.contains(hit) && !hit.contains(el) && !hit.closest(".modal-bg, .tip-card, .toast")) bad.push(`coperto: «${name}» da ${hit.tagName.toLowerCase()}.${String(hit.className).split(" ")[0]}`);
      }
      // Testo tagliato (con i puntini o nascosto)
      for (const t of [el, ...el.querySelectorAll("span, b")]) {
        const ts = getComputedStyle(t);
        if (ts.overflowX !== "visible" || ts.textOverflow === "ellipsis") {
          if (t.scrollWidth > t.clientWidth + 1 && t.clientWidth > 0) bad.push(`testo tagliato: «${name}» (${t.scrollWidth} > ${t.clientWidth})`);
        }
      }
    }
  }
  return bad;
}

const b = await chromium.launch();
let fails = 0;
const report = [];
for (const spec of wanted) {
  const [, W, H, S] = spec.match(/^(\d+)x(\d+)@(\d+)$/).map(Number);
  const s = S / 100;
  const availW = Math.floor(W / s), availH = Math.floor(H / s) - TASKBAR - TITLE;
  // «oggi» (2.0.0): la finestra resta 1200×800 anche se lo schermo è più basso; si vede solo la parte sopra la barra delle applicazioni
  const windows = [["massima", availW, availH, availH], ["iniziale", Math.min(1200, availW), Math.min(800, availH), Math.min(800, availH)], ["oggi", Math.min(1200, availW), 800, Math.min(800, availH)]];
  for (const [kind, vw, vh, visible] of windows) {
    const ctx = await b.newContext({ viewport: { width: vw, height: vh }, deviceScaleFactor: s, locale: "it-IT" });
    await ctx.addInitScript((v) => { window.__visibleH = v; }, visible);
    await ctx.addInitScript(() => {
      for (const [k, v] of Object.entries({ welcomed: true, tips: false, tab: "convert", appLang: "it" })) localStorage.setItem("orbitlr." + k, JSON.stringify(v));
    });
    const pg = await ctx.newPage();
    const errs = [];
    pg.on("pageerror", (e) => errs.push(String(e)));
    await pg.goto(base);
    await pg.waitForTimeout(1200);
    const tabs = ["convert", "image", "video", "audio", "pdf", "activity", "auto", "settings", "help"];
    const names = await pg.$$eval("aside .nav button, aside .foot button", (bs) => bs.length);
    const probs = [];
    for (let i = 0; i < tabs.length; i++) {
      const btn = (await pg.$$("aside .nav button, aside .foot button"))[i];
      if (!btn) break;
      await btn.click({ force: true, timeout: 3000 }).catch(() => {});
      await pg.waitForTimeout(350);
      for (const m of await pg.$$(".modal-bg")) await m.evaluate((n) => n.remove());
      const bad = await pg.evaluate(check);
      bad.forEach((x) => probs.push(`${tabs[i]}: ${x}`));
      if (i < 5 || bad.length) await pg.screenshot({ path: `${out}/${W}x${H}-${S}-${kind}-${tabs[i]}.png`, clip: { x: 0, y: 0, width: vw, height: visible } });
    }
    const uniq = [...new Set(probs)];
    const line = `${spec} ${kind} ${vw}×${vh}${visible < vh ? ` (visibili ${visible})` : ""} (scala ${s}): ${uniq.length ? "PROBLEMI " + uniq.length : "ok"}${errs.length ? " · errori JS " + errs.length : ""} · pulsanti laterali ${names}`;
    console.log(line);
    uniq.slice(0, 12).forEach((p) => console.log("   " + p));
    errs.slice(0, 5).forEach((e) => console.log("   JS: " + e.slice(0, 200)));
    report.push(line, ...uniq.map((p) => "   " + p), ...errs.map((e) => "   JS: " + e));
    if ((uniq.length && kind !== "oggi") || errs.length) fails++;
    await ctx.close();
  }
}
fs.writeFileSync(`${out}/risultati.txt`, report.join("\n") + "\n");
await b.close();
srv.close();
console.log(fails ? `${fails} finestre con problemi` : "tutte le finestre a posto");
process.exit(fails ? 1 : 0);
