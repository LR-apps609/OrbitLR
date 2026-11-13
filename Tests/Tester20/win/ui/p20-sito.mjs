// Tester20 · P20 · il sito pubblico di OrbitLR su un telefono (Chromium con misure di telefono): si apre, niente
// scorrimento di lato, i link funzionano, il pulsante per scaricare c'è e porta a un file vero.
// Uso: node p20-sito.mjs <cartella-uscita> [url]
import fs from "node:fs";
import path from "node:path";
import { pw, esito } from "./comune.mjs";

const out = process.argv[2] || "sito";
const SITO = process.argv[3] || "https://lr-apps609.github.io/OrbitLR/";
fs.mkdirSync(out, { recursive: true });
const E = esito();
const browser = await pw.chromium.launch();
const linkVisti = new Map();
for (const dev of ["iPhone 13", "Pixel 7", "iPhone SE"]) {
  const { defaultBrowserType, ...opts } = pw.devices[dev];
  const ctx = await browser.newContext({ ...opts, locale: "it-IT" });
  const pg = await ctx.newPage();
  const errs = [];
  pg.on("pageerror", (e) => errs.push(String(e).slice(0, 200)));
  const resp = await pg.goto(SITO, { timeout: 30000, waitUntil: "networkidle" }).catch((e) => ({ status: () => "errore " + e.message }));
  const st = resp.status();
  if (typeof st !== "number") { E.nonEseguito(`sito su ${dev}`, `il computer di prova non raggiunge ${SITO}: ${String(st).split("\n")[0]}`); await ctx.close(); continue; }
  if (!E.passo(`sito su ${dev}: si apre`, st === 200, `HTTP ${st}`)) { E.bug(`Il sito ${SITO} non si apre`, "alto", [`Apri ${SITO} dal telefono`], "La pagina di OrbitLR", `HTTP ${st}`, "-"); await ctx.close(); break; }
  await pg.waitForTimeout(800);
  const info = await pg.evaluate(() => {
    const vw = innerWidth;
    const larghi = [...document.querySelectorAll("body *")].filter((e) => { const r = e.getBoundingClientRect(); const cs = getComputedStyle(e); return r.width > 0 && r.right > vw + 2 && cs.position !== "fixed" && !e.closest("[style*='overflow']"); }).slice(0, 6)
      .map((e) => `${e.tagName.toLowerCase()}.${String(e.getAttribute("class") || "").split(" ")[0]} (${Math.round(e.getBoundingClientRect().right)} px)`);
    const piccoli = [...document.querySelectorAll("a[href], button")].filter((e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && (r.height < 24 || r.width < 24) && getComputedStyle(e).visibility !== "hidden"; }).slice(0, 8).map((e) => `«${e.textContent.trim().slice(0, 25)}» ${Math.round(e.getBoundingClientRect().width)}×${Math.round(e.getBoundingClientRect().height)}`);
    const links = [...document.querySelectorAll("a[href]")].map((a) => ({ href: a.href, text: a.textContent.trim().replace(/\s+/g, " ").slice(0, 40) }));
    const scarica = links.filter((l) => /scarica|download|\.exe|\.dmg|releases/i.test(l.text + " " + l.href));
    const fs = [...document.querySelectorAll("p, li")].map((e) => parseFloat(getComputedStyle(e).fontSize)).filter(Boolean);
    return { vw, sw: document.scrollingElement.scrollWidth, larghi, piccoli, links, scarica, minFont: fs.length ? Math.min(...fs) : 0, title: document.title };
  });
  await pg.screenshot({ path: path.join(out, `sito-${dev.replace(/\W+/g, "-")}.png`), fullPage: true });
  if (!E.passo(`sito su ${dev}: niente scorrimento di lato`, info.sw <= info.vw + 1, `${info.sw} su ${info.vw}: ${info.larghi.join(", ")}`))
    E.bug(`Sito al telefono (${dev}): la pagina è più larga dello schermo`, "medio", [`Apri ${SITO} con ${dev}`], "La pagina sta nella larghezza", `larga ${info.sw} px su ${info.vw}; elementi: ${info.larghi.join(", ")}`, `sito-${dev.replace(/\W+/g, "-")}.png`);
  if (info.piccoli.length) E.nota(`sito su ${dev}: link/pulsanti più piccoli di 24 px: ${info.piccoli.join(", ")}`);
  if (info.minFont && info.minFont < 12) E.nota(`sito su ${dev}: testo piccolo (${info.minFont} px)`);
  E.passo(`sito su ${dev}: c'è un pulsante per scaricare`, info.scarica.length > 0, info.scarica.map((l) => `«${l.text}» ${l.href}`).slice(0, 4).join(" · "));
  for (const l of info.links) if (!linkVisti.has(l.href)) linkVisti.set(l.href, l.text);
  errs.forEach((e) => E.nota(`sito su ${dev}: errore JavaScript ${e}`));
  if (dev === "iPhone 13") {
    const s = info.scarica.map((l) => l.href).join(" ");
    if (info.scarica.length && !/iphone|ipad|android|telefono|computer|mac|windows/i.test(await pg.evaluate(() => document.body.innerText)))
      E.confuso("sito al telefono", "il pulsante per scaricare non dice che OrbitLR è per il computer (Mac/Windows)");
  }
  await ctx.close();
}
// I link: tutti rispondono? (pagine di questo sito e file di GitHub)
const rotti = [];
for (const [href, text] of linkVisti) {
  if (!/^https?:/.test(href)) continue;
  const u = href.split("#")[0];
  let st;
  try { const r = await fetch(u, { method: /\.(exe|dmg|zip)$/.test(u) ? "HEAD" : "GET", redirect: "follow" }); st = r.status; if (/\.(exe|dmg|zip)$/.test(u)) E.nota(`file: ${u} → ${st} ${r.headers.get("content-length") || ""} byte`); } catch (e) { st = "errore " + e.message; }
  if (!(st >= 200 && st < 400) && !(st === 429 || st === 999)) rotti.push(`«${text}» ${href} → ${st}`);
}
if (!E.passo(`sito: ${linkVisti.size} link, tutti funzionano`, rotti.length === 0, rotti.join(" · ")))
  E.bug("Sito: link che non funzionano", "medio", [`Apri ${SITO}`, "Tocca i link"], "Ogni link apre una pagina o un file", rotti.slice(0, 8).join(" · "), "elenco nel diario");
E.salva(out, "p20sito");
await browser.close();
