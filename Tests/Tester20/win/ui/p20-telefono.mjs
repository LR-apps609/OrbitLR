// Tester20 · P20 · la pagina di «Al telefono» (server vero del motore) aperta da Chromium con misure di telefono:
// nome e peso giusti, pulsante «Scarica» dentro lo schermo, il file scaricato è uguale all'originale.
// Uso: node p20-telefono.mjs <cartella-uscita> <url> <file>
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { pw, esito } from "./comune.mjs";

const [out, url, file] = process.argv.slice(2);
fs.mkdirSync(out, { recursive: true });
const E = esito();
const name = path.basename(file);
const size = fs.statSync(file).size;
const sha = (p) => crypto.createHash("sha256").update(fs.readFileSync(p)).digest("hex");
const orig = sha(file);
const browser = await pw.chromium.launch();
E.nota("telefoni emulati in Chromium (misure, tocco, user agent): non è Safari vero né un telefono vero");
for (const dev of ["iPhone 13", "Pixel 7", "iPhone SE"]) {
  const d = pw.devices[dev];
  const { defaultBrowserType, ...opts } = d;
  const ctx = await browser.newContext({ ...opts, acceptDownloads: true, locale: "it-IT" });
  const pg = await ctx.newPage();
  const resp = await pg.goto(url, { timeout: 20000 }).catch((e) => ({ status: () => "errore " + e.message }));
  const st = resp.status();
  if (!E.passo(`${dev}: la pagina si apre`, st === 200, `HTTP ${st}`)) { await ctx.close(); continue; }
  const info = await pg.evaluate(() => {
    const a = document.querySelector("a[download]"); const r = a?.getBoundingClientRect();
    return { text: document.body.innerText, btn: a ? { top: r.top, bottom: r.bottom, left: r.left, right: r.right, w: r.width, h: r.height } : null, vw: innerWidth, vh: innerHeight, sw: document.scrollingElement.scrollWidth };
  });
  await pg.screenshot({ path: path.join(out, `${dev.replace(/\W+/g, "-")}.png`) });
  E.passo(`${dev}: si legge il nome del file con emoji e accento`, info.text.includes(name), info.text.split("\n")[0]);
  E.passo(`${dev}: si legge il peso`, /\d+([,.]\d+)?\s*(KB|MB)/i.test(info.text), info.text.replace(/\s+/g, " ").slice(0, 120));
  const dentro = info.btn && info.btn.bottom <= info.vh && info.btn.right <= info.vw && info.btn.left >= 0;
  if (!E.passo(`${dev}: «Scarica» dentro lo schermo, grande abbastanza per il dito`, dentro && info.btn.h >= 40, JSON.stringify(info.btn)))
    E.bug(`Al telefono (${dev}): il pulsante «Scarica» è fuori dallo schermo o piccolo`, "medio", ["Al telefono", `Apri il codice con ${dev}`], "Pulsante grande e visibile", JSON.stringify(info.btn), `${dev}.png`);
  if (!E.passo(`${dev}: niente scorrimento di lato`, info.sw <= info.vw + 1, `${info.sw} > ${info.vw}`))
    E.bug(`Al telefono (${dev}): la pagina scorre di lato`, "basso", ["Al telefono", `Apri con ${dev}`], "La pagina sta nella larghezza del telefono", `larga ${info.sw} px su ${info.vw}`, `${dev}.png`);
  const [dl] = await Promise.all([pg.waitForEvent("download", { timeout: 30000 }).catch(() => null), pg.tap("a[download]").catch(() => pg.click("a[download]"))]);
  if (!dl) { E.bug(`Al telefono (${dev}): toccando «Scarica» non parte lo scaricamento`, "alto", ["Al telefono", "Tocca Scarica"], "Il file si scarica", "nessuno scaricamento in 30 s", `${dev}.png`); await ctx.close(); continue; }
  const dest = path.join(out, `${dev.replace(/\W+/g, "-")}-${dl.suggestedFilename()}`);
  await dl.saveAs(dest);
  const okName = dl.suggestedFilename() === name;
  if (!E.passo(`${dev}: il file scaricato ha lo stesso nome`, okName, `«${dl.suggestedFilename()}»`))
    E.bug(`Al telefono: il file arriva con un nome diverso («${dl.suggestedFilename()}»)`, "basso", ["Al telefono con «" + name + "»", "Scarica"], `«${name}»`, `«${dl.suggestedFilename()}»`, dest);
  const s2 = fs.statSync(dest).size, h2 = sha(dest);
  if (!E.passo(`${dev}: il file scaricato è uguale (peso e impronta)`, s2 === size && h2 === orig, `${s2}/${size} byte`))
    E.bug("Al telefono: il file scaricato è diverso dall'originale", "alto", ["Al telefono", "Scarica"], "Lo stesso file", `${s2} byte invece di ${size}`, dest);
  fs.rmSync(dest, { force: true });
  await ctx.close();
}
// Indirizzo con il segreto sbagliato: niente file
{
  const bad = url.replace(/\/([0-9a-f]{24})\//, (m, t) => "/" + t.split("").reverse().join("") + "/");
  const r = await fetch(bad).then((x) => x.status).catch((e) => "errore " + e.message);
  const r2 = await fetch(url.replace(/\/[0-9a-f]{24}\/$/, "/")).then((x) => x.status).catch((e) => "errore " + e.message);
  E.passo("indirizzo con il segreto sbagliato o senza segreto: niente (404)", r === 404 && r2 === 404, `${r} / ${r2}`);
}
E.salva(out, "p20tel");
await browser.close();
