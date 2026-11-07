// 2.0.1 · L'interfaccia di Windows quando il motore sbaglia, è lento o non risponde (bug trovati dal tester W07).
// Apre Windows/ui in Chromium con un finto Tauri (Tools/finto-tauri-windows.js), così l'interfaccia segue la strada
// vera dell'app e il motore risponde come vogliamo: bene, con un errore, tardi o mai.
// uso: node --test Tools/prova-errori-windows.mjs   (serve Playwright con Chromium: npm i --no-save playwright)
import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
let pw;
try { pw = require("playwright"); } catch { pw = require(path.join(process.env.HOME || "/root", ".npm-global/lib/node_modules/playwright")); }
const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, "..", "Windows", "ui");
const fake = fs.readFileSync(path.join(here, "finto-tauri-windows.js"), "utf8");

const IMG = "C:\\Utenti\\Prova\\Immagini\\Vacanze al mare.jpg";
const LOGO = "C:\\Utenti\\Prova\\Immagini\\Logo.png";
const VID = "C:\\Utenti\\Prova\\Video\\Gita al lago.mp4";
const MP3 = "C:\\Utenti\\Prova\\Musica\\La mia canzone.mp3";
const PDF = "C:\\Utenti\\Prova\\Documenti\\Contratto.pdf";

const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png", ".woff2": "font/woff2", ".wav": "audio/wav" };
let srv, base, browser;

test.before(async () => {
  srv = http.createServer((q, r) => {
    const rel = decodeURIComponent(q.url.split("?")[0]);
    const p = path.join(root, rel === "/" ? "index.html" : rel);
    if (!p.startsWith(root) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { r.writeHead(404); return r.end(); }
    r.writeHead(200, { "Content-Type": types[path.extname(p)] || "application/octet-stream" });
    fs.createReadStream(p).pipe(r);
  });
  await new Promise((ok) => srv.listen(0, "127.0.0.1", ok));
  base = `http://127.0.0.1:${srv.address().port}/`;
  browser = await pw.chromium.launch({ args: ["--disable-dev-shm-usage", "--disable-gpu"] });
});
test.after(async () => { await browser?.close(); srv?.close(); });

/** Una finestra nuova di OrbitLR. `per`: { comando: { mode: "ok" | "fail" | "slow" | "never", ms } } dall'avvio. */
async function open({ tab = "convert", per = {}, welcome = false, jobEnd = null } = {}) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, locale: "it-IT" });
  await ctx.addInitScript(({ per, welcome, jobEnd }) => {
    window.__Fcfg = { seed: 1, mix: { ok: 1 }, per, jobEnd };
    window.__orbitStopWait = 1500;
    if (welcome) Object.defineProperty(Navigator.prototype, "webdriver", { get: () => false });
  }, { per, welcome, jobEnd });
  await ctx.addInitScript(fake);
  await ctx.addInitScript(({ tab, welcome }) => {
    localStorage.clear();
    const s = { tips: false, tab, appLang: "it", fbAsked: true };
    if (!welcome) s.welcomed = true;
    for (const [k, v] of Object.entries(s)) localStorage.setItem("orbitlr." + k, JSON.stringify(v));
  }, { tab, welcome });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto(base);
  await page.waitForSelector("aside .nav button", { timeout: 10000 });
  await page.waitForTimeout(600);
  const unhandled = () => page.evaluate(() => (window.__Flog || []).filter((l) => l.type === "unhandledrejection" || l.type === "error").map((l) => l.reason.split("\n")[0]));
  const toasts = () => page.evaluate(() => [...document.querySelectorAll(".toast")].map((e) => e.textContent));
  const mode = (cmd, m, ms) => page.evaluate(([c, m, ms]) => window.__Fmode(c, m, ms), [cmd, m, ms]);
  const drop = (paths) => page.evaluate((p) => window.__Fdrop(p), paths);
  const calls = (cmd) => page.evaluate((c) => (window.__Flog || []).filter((l) => l.cmd === c).length, cmd);
  /** Testi «null», «undefined», «NaN» o «[object …]» a schermo. */
  const weird = () => page.evaluate(() => {
    const out = [];
    const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let n;
    while ((n = w.nextNode())) if (/(^|\s)(null|undefined|NaN)(\s|$)|\[object /.test(n.nodeValue) && !n.parentElement?.closest("script,style")) out.push(n.nodeValue.trim().slice(0, 60));
    return out;
  });
  return { ctx, page, errors, unhandled, toasts, mode, drop, calls, weird };
}

/** Un lavoro finito in Converti, con la barra del risultato. */
async function doneJob(w) {
  await w.drop([LOGO]);
  await w.page.waitForSelector(".pie, .dial-wrap svg, .dial-wrap button", { timeout: 5000 });
  await w.page.waitForTimeout(300);
  await w.page.keyboard.press("1");
  await w.page.waitForSelector(".resultbar .ic.ok", { timeout: 8000 });
}

for (const how of ["never", "fail"]) {
  test(`«Interrompi» con il motore che ${how === "never" ? "non risponde" : "dà errore"}: la barra non resta su «Interrompo…»`, async () => {
    const w = await open({ jobEnd: "stall" });
    try {
      await w.drop([LOGO]);
      await w.page.waitForTimeout(500);
      await w.page.keyboard.press("1");
      await w.page.waitForSelector(".resultbar .ic.run", { timeout: 5000 });
      await w.mode("cancel_job", how);
      await w.page.locator(".resultbar button", { hasText: "Interrompi" }).click();
      await w.page.waitForTimeout(how === "never" ? 2500 : 600);
      const bar = await w.page.locator(".resultbar").innerText();
      assert.match(bar, /Non si è interrotto/, bar);
      assert.equal(await w.page.locator(".resultbar button", { hasText: "Interrompi" }).isDisabled(), false, "«Interrompi» deve tornare usabile");
      const x = w.page.locator('.resultbar button[aria-label="Chiudi"]');
      assert.equal(await x.count(), 1, "manca la ✕ per chiudere la barra");
      await x.click();
      assert.equal(await w.page.locator(".resultbar").count(), 0, "la ✕ deve chiudere la barra");
      assert.deepEqual(await w.unhandled(), []);
    } finally { await w.ctx.close(); }
  });
}

test("file che il motore non riesce a leggere: un avviso in tutte e 5 le schede, nessun errore muto", async () => {
  const cases = [["convert", LOGO], ["image", IMG], ["video", VID], ["audio", MP3], ["pdf", PDF]];
  for (const [tab, f] of cases) {
    const w = await open({ tab, per: { probe_files: { mode: "fail" } } });
    try {
      await w.drop([f]);
      await w.page.waitForTimeout(500);
      const msg = (await w.toasts()).join(" | ");
      assert.match(msg, /Non riesco a leggere il file/, `${tab}: ${msg}`);
      assert.deepEqual(await w.unhandled(), [], tab);
    } finally { await w.ctx.close(); }
  }
});

test("controllo del motore che fallisce: avviso, nessun errore muto; nelle Opzioni «Controllo…» mentre è in corso", async () => {
  const w = await open({ per: { engine_status: { mode: "fail" } } });
  try {
    await w.page.waitForTimeout(400);
    assert.match((await w.toasts()).join(" "), /Non riesco a controllare il motore video/);
    assert.deepEqual(await w.unhandled(), []);
  } finally { await w.ctx.close(); }
  const s = await open({ tab: "settings", per: { engine_status: { mode: "never" } } });
  try {
    const txt = await s.page.locator("main").innerText();
    assert.match(txt, /Controllo il motore video…/);
    assert.doesNotMatch(txt, /non si è avviato/);
  } finally { await s.ctx.close(); }
});

test("benvenuto: nessun «null» nei passi", async () => {
  const w = await open({ welcome: true });
  try {
    await w.page.waitForSelector(".welcome", { timeout: 5000 });
    let k = 0;
    while ((await w.page.locator(".welcome").count()) && k < 12) {
      assert.deepEqual(await w.weird(), [], `passo ${++k}`);
      await w.page.locator(".welcome button.primary").click();
      await w.page.waitForTimeout(150);
    }
    assert.ok(k >= 3, "il benvenuto ha almeno 3 passi");
  } finally { await w.ctx.close(); }
});

test("Editor PDF: nessun «null» nel pannello; se si cambia scheda mentre si apre, non si apre più da solo", async () => {
  const w = await open({ tab: "pdf" });
  try {
    await w.drop([PDF]);
    await w.page.waitForTimeout(500);
    await w.page.locator("main button.tool", { hasText: "Editor PDF" }).first().click();
    await w.page.waitForSelector(".pe-side", { timeout: 5000 });
    await w.page.waitForTimeout(300);
    assert.deepEqual(await w.weird(), []);
  } finally { await w.ctx.close(); }
  const s = await open({ tab: "pdf" });
  try {
    await s.drop([PDF]);
    await s.page.waitForTimeout(500);
    await s.mode("pdf_info", "slow", 2000);
    await s.page.locator("main button.tool", { hasText: "Editor PDF" }).first().click();
    await s.page.waitForTimeout(1200);
    assert.equal(await s.page.locator(".wait-row").count(), 1, "manca il segno d'attesa «Apro il PDF…»");
    await s.page.locator("aside .foot button", { hasText: "Aiuto" }).click();
    await s.page.waitForTimeout(1800);
    assert.equal(await s.page.locator(".pe-bg").count(), 0, "l'editor si è aperto sopra un'altra scheda");
  } finally { await s.ctx.close(); }
});

test("lettura lenta: lo stesso file trascinato due volte compare una volta sola (Immagini, Video, PDF)", async () => {
  for (const [tab, f] of [["image", IMG], ["video", VID], ["pdf", PDF]]) {
    const w = await open({ tab });
    try {
      await w.mode("probe_files", "slow", 1500);
      await w.drop([f]);
      await w.page.waitForTimeout(300);
      await w.drop([f]);
      await w.page.waitForTimeout(2200);
      const n = await w.page.evaluate((name) => [...document.querySelectorAll("main [data-path]")].filter((e) => e.getAttribute("data-path").endsWith(name)).length, f.split("\\").pop());
      assert.equal(n, 1, tab);
    } finally { await w.ctx.close(); }
  }
});

test("«Completo»: un doppio clic su un formato fa partire un lavoro solo", async () => {
  const w = await open({ tab: "image" });
  try {
    await w.drop([IMG]);
    await w.page.waitForTimeout(500);
    await w.page.locator("main button", { hasText: "Completo" }).first().click();
    await w.page.waitForTimeout(300);
    await w.page.locator("main .tools button.fmt", { hasText: /^\s*PNG\s*$/ }).first().dblclick();
    await w.page.waitForTimeout(800);
    assert.equal(await w.calls("start_job"), 1);
  } finally { await w.ctx.close(); }
});

test("Cartelle automatiche: se il salvataggio non riesce l'errore resta, niente «Attiva»", async () => {
  const w = await open({ tab: "auto" });
  try {
    await w.mode("watch_set", "fail");
    await w.page.locator("main button", { hasText: "Attiva su" }).first().click();
    await w.page.waitForTimeout(500);
    const msg = (await w.toasts()).join(" | ");
    assert.match(msg, /Non riesco a salvare le cartelle automatiche/, msg);
    assert.doesNotMatch(msg, /Attiva:/);
    await w.mode("places", "fail");
    await w.mode("watch_set", "ok");
    await w.page.locator("main button", { hasText: "Attiva su" }).first().click();
    await w.page.waitForTimeout(500);
    assert.ok((await w.page.evaluate(() => (window.__Flog || []).filter((l) => l.type === "dialog").length)) >= 1, "senza «places» si sceglie la cartella a mano");
    assert.deepEqual(await w.unhandled(), []);
  } finally { await w.ctx.close(); }
});

test("«Al telefono»: tre clic aprono una finestra sola, Esc la chiude", async () => {
  const w = await open();
  try {
    await doneJob(w);
    await w.mode("phone_share", "slow", 1200);
    const btn = w.page.locator(".resultbar button", { hasText: "Al telefono" });
    for (let i = 0; i < 3; i++) { await btn.click(); await w.page.waitForTimeout(150); }
    await w.page.waitForTimeout(1500);
    assert.equal(await w.page.locator(".modal.phone").count(), 1);
    assert.equal(await w.calls("phone_share"), 1);
    await w.page.keyboard.press("Escape");
    await w.page.waitForTimeout(200);
    assert.equal(await w.page.locator(".modal.phone").count(), 0, "Esc deve chiudere la finestra");
  } finally { await w.ctx.close(); }
});
