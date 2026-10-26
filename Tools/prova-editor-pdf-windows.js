const { chromium } = require("playwright");
const http = require("http"), fs = require("fs"), path = require("path");
const root = "/home/claude/orbitlr/Windows/ui";
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png" };
const srv = http.createServer((q, r) => { const u = decodeURIComponent(q.url.split("?")[0]); const p = path.join(root, u === "/" ? "index.html" : u); if (!fs.existsSync(p)) { r.writeHead(404); return r.end(); } r.writeHead(200, { "Content-Type": types[path.extname(p)] || "application/octet-stream" }); fs.createReadStream(p).pipe(r); }).listen(8766);
(async () => {
  const b = await chromium.launch();
  for (const lang of ["it", "en"]) {
    const pg = await (await b.newContext({ viewport: { width: 1200, height: 800 } })).newPage();
    const errs = [];
    pg.on("pageerror", (e) => errs.push(String(e)));
    await pg.addInitScript((l) => localStorage.setItem("orbitlr.appLang", JSON.stringify(l)), lang);
    await pg.goto("http://localhost:8766/");
    await pg.waitForTimeout(1200);
    await pg.evaluate(async () => (await import("/js/pdfeditor.js")).openPdfEditor({ path: "C:\\x\\Modulo.pdf", name: "Modulo.pdf", size: 1000 }));
    await pg.waitForTimeout(500);
    const layer = await pg.$(".pe-layer");
    const box = await layer.boundingBox();
    await pg.mouse.click(box.x + 100, box.y + 120);
    await pg.keyboard.type("Mario Rossi");
    await pg.click(".pe-mode:nth-child(3)");
    await pg.mouse.move(box.x + 200, box.y + 300); await pg.mouse.down(); await pg.mouse.move(box.x + 350, box.y + 340); await pg.mouse.up();
    await pg.click(".pe-mode:nth-child(2)");
    await pg.waitForTimeout(200);
    const pad = await pg.$(".pe-pad");
    const pb = await pad.boundingBox();
    await pg.mouse.move(pb.x + 40, pb.y + 60); await pg.mouse.down(); await pg.mouse.move(pb.x + 160, pb.y + 90); await pg.mouse.move(pb.x + 260, pb.y + 50); await pg.mouse.up();
    await pg.click(".modal .btn.primary");
    await pg.mouse.click(box.x + 300, box.y + 500);
    await pg.fill(".pe-field", "Ledion");
    await pg.screenshot({ path: `shots/pe-${lang}.png` });
    const n = await pg.$$eval(".pe-red, .pe-img-mark, .pe-text-mark", (x) => x.length);
    await pg.click(".pe-head .btn.primary");
    await pg.waitForTimeout(400);
    console.log(lang, "segni:", n, "errori:", errs.length, errs.slice(0, 5).join(" | "));
  }
  await b.close(); srv.close();
})();
