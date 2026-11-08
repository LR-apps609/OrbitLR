// OrbitLR per Windows 2.0.1 · Il benvenuto al primo avvio su schermi piccoli o con scala alta:
// i pulsanti Salta/Indietro/Avanti/Cominciamo devono stare dentro la finestra e rispondere al clic. Uso: node Tools/prova-benvenuto-windows.mjs
import { createRequire } from "node:module"; import http from "node:http"; import fs from "node:fs"; import path from "node:path"; import { fileURLToPath } from "node:url";
const { chromium } = createRequire(import.meta.url)("playwright");
const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "Windows", "ui");
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png", ".svg": "image/svg+xml", ".woff2": "font/woff2", ".json": "application/json" };
const srv = http.createServer((q, r) => { const rel = decodeURIComponent(q.url.split("?")[0]); const p = path.join(root, rel === "/" ? "index.html" : rel);
  if (!fs.existsSync(p) || fs.statSync(p).isDirectory()) { r.writeHead(404); return r.end(); } r.writeHead(200, { "Content-Type": types[path.extname(p)] || "application/octet-stream" }); fs.createReadStream(p).pipe(r); });
await new Promise(ok => srv.listen(0, ok)); const base = `http://127.0.0.1:${srv.address().port}/`;
const b = await chromium.launch(); let fail = 0;
for (const [W, H, S] of [[1280,720,150],[1366,768,125],[1280,720,125],[1366,768,100],[1920,1080,175],[1920,1080,200],[1024,768,150]]) {
  const vw = Math.round(W / S * 100), vh = Math.round(H / S * 100) - 48 - 32;
  const pg = await b.newPage({ viewport: { width: vw, height: vh }, deviceScaleFactor: S / 100 });
  await pg.addInitScript(() => { Object.defineProperty(Navigator.prototype, "webdriver", { get: () => false }); localStorage.setItem("orbitlr.appLang", '"it"'); });
  await pg.goto(base); await pg.waitForSelector(".modal.welcome", { timeout: 8000 });
  for (let step = 1; step <= 3; step++) {
    await pg.waitForTimeout(900);
    const r = await pg.evaluate(() => [...document.querySelectorAll(".welcome .w-btns .btn")].map(e => { const b = e.getBoundingClientRect(); const hit = document.elementFromPoint(b.left + b.width/2, b.top + b.height/2);
      return { t: e.textContent, ok: b.top >= 0 && b.bottom <= innerHeight && b.width > 0 && (hit === e || e.contains(hit)) }; }));
    const bad = r.filter(x => !x.ok);
    console.log(`${W}x${H}@${S} (${vw}×${vh}) passo ${step}:`, bad.length ? "FUORI " + bad.map(x=>x.t).join(",") : "ok " + r.map(x=>x.t).join("/"));
    if (bad.length) fail++;
        await pg.click(".welcome .btn.primary");
  }
  const gone = await pg.evaluate(() => !document.querySelector(".modal.welcome")); if (!gone) { console.log("non si chiude"); fail++; }
  await pg.close();
}
await b.close(); srv.close(); console.log(fail ? `FALLITI ${fail}` : "TUTTO OK"); process.exit(fail ? 1 : 0);
