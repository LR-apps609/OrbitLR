// Apre l'interfaccia Windows in modalità prova (senza Tauri), in italiano e in inglese: errori JS e foto delle schede.
const { chromium } = require("playwright");
const http = require("http"), fs = require("fs"), path = require("path");
const root = "/home/claude/orbitlr/Windows/ui";
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png", ".svg": "image/svg+xml", ".woff2": "font/woff2", ".json": "application/json" };
const srv = http.createServer((q, r) => {
  const p = path.join(root, decodeURIComponent(q.url.split("?")[0]) === "/" ? "index.html" : decodeURIComponent(q.url.split("?")[0]));
  if (!p.startsWith(root) || !fs.existsSync(p)) { r.writeHead(404); return r.end(); }
  r.writeHead(200, { "Content-Type": types[path.extname(p)] || "application/octet-stream" });
  fs.createReadStream(p).pipe(r);
}).listen(8765);
(async () => {
  const b = await chromium.launch();
  const out = process.argv[2] || ".";
  let bad = 0;
  for (const lang of ["it", "en"]) {
    const ctx = await b.newContext({ viewport: { width: 1200, height: 800 }, locale: lang === "en" ? "en-US" : "it-IT" });
    const pg = await ctx.newPage();
    const errs = [];
    pg.on("pageerror", (e) => errs.push(String(e)));
    pg.on("console", (m) => m.type() === "error" && errs.push("console: " + m.text()));
    await pg.addInitScript((l) => { localStorage.setItem("orbitlr.appLang", JSON.stringify(l)); localStorage.setItem("orbitlr.audio.projects", JSON.stringify([{ path: "C:\\Musica\\Canzone.mp3", name: "Canzone.mp3", tool: "ringtone", start: 12.5, end: 42.5, others: [], at: 1 }])); }, lang);
    await pg.goto("http://localhost:8765/");
    await pg.waitForTimeout(1500);
    const tabs = await pg.$$eval("aside button", (bs) => bs.map((b) => b.textContent.trim()).filter(Boolean));
    let i = 0;
    for (const name of tabs) {
      const btns = await pg.$$("aside button");
      const btn = btns[i++];
      if (!btn) break;
      await btn.click().catch(() => {});
      await pg.waitForTimeout(500);
      await pg.keyboard.press("Escape").catch(() => {});
      await pg.screenshot({ path: `${out}/${lang}-${String(i).padStart(2, "0")}.png` });
      // chiude finestrelle aperte (Segnala, Idea)
      for (const m of await pg.$$(".modal-bg")) await m.evaluate((n) => n.remove());
    }
    // Testi ancora italiani visibili in inglese
    if (lang === "en") {
      const it = await pg.evaluate(() => document.body.innerText);
      fs.writeFileSync(`${out}/en-text.txt`, it);
    }
    console.log(lang, "schede:", tabs.length, "errori:", errs.length);
    errs.slice(0, 15).forEach((e) => console.log("  ", e.slice(0, 300)));
    bad += errs.length;
    await ctx.close();
  }
  await b.close();
  srv.close();
  process.exit(bad ? 1 : 0);
})();
