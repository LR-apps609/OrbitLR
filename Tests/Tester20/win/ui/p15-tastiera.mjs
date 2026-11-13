// Tester20 · P15W «Tastiera e lettore di schermo»: l'interfaccia vera (Chromium, finto Tauri) usata solo con la tastiera
// (Tab, Maiusc+Tab, Invio, Spazio, Esc) e controllata con axe-core (nomi, ruoli, contrasto).
// Uso: node p15-tastiera.mjs <cartella-uscita>
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { pw, server, pagina, apriScheda, mettiFile, esito, TABS } from "./comune.mjs";

const out = process.argv[2] || "p15";
fs.mkdirSync(out, { recursive: true });
const E = esito();
const require = createRequire(path.join(process.cwd(), "x.js"));
const axeSrc = fs.readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");
const srv = await server();
const browser = await pw.chromium.launch();
const VW = 1366, VH = 688;

/** Dove è il fuoco e se si vede (contorno o ombra diversi da quando il fuoco non c'è). */
function fuoco() {
  const a = document.activeElement;
  if (!a || a === document.body) return { tag: "body", name: "", visibile: false, dentro: true, modal: false };
  const cs = getComputedStyle(a);
  const sig = (c) => [c.outlineStyle, c.outlineWidth, c.outlineColor, c.boxShadow, c.backgroundColor, c.borderColor, c.textDecorationLine].join("|");
  const conFuoco = sig(cs);
  const r = a.getBoundingClientRect();
  const name = (a.getAttribute("aria-label") || a.textContent || a.value || a.getAttribute("title") || "").trim().replace(/\s+/g, " ").slice(0, 40);
  const id = a.tagName.toLowerCase() + ":" + name;
  // Senza fuoco (stesso elemento): si confronta lo stile
  a.setAttribute("data-t20f", "1");
  a.blur();
  const senza = sig(getComputedStyle(document.querySelector("[data-t20f]")));
  const el = document.querySelector("[data-t20f]");
  el.removeAttribute("data-t20f");
  el.focus({ preventScroll: true });
  const outlineVisible = cs.outlineStyle !== "none" && parseFloat(cs.outlineWidth) > 0;
  return { tag: a.tagName.toLowerCase(), name, id, visibile: outlineVisible || conFuoco !== senza, dentro: r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth, modal: !!a.closest(".modal-bg, .pe-bg"), nav: !!a.closest("aside") };
}

async function tabs(pg, n, shift = false) {
  const seq = [];
  for (let i = 0; i < n; i++) {
    await pg.keyboard.press(shift ? "Shift+Tab" : "Tab");
    await pg.waitForTimeout(40);
    seq.push(await pg.evaluate(fuoco));
  }
  return seq;
}

async function axe(pg, dove) {
  await pg.evaluate(axeSrc);
  const res = await pg.evaluate(async () => (await window.axe.run(document, { resultTypes: ["violations"] })).violations.map((v) => ({ id: v.id, impact: v.impact, help: v.help, nodes: v.nodes.length, esempi: v.nodes.slice(0, 3).map((n) => `${n.target.join(" ")} ${n.html.slice(0, 110)}`) })));
  return res.map((r) => ({ ...r, dove }));
}

const axeAll = [];
const senzaFuocoVisibile = new Map(); // nome → schede
const fuoriVista = new Map();

// 1. Ogni scheda: Tab e Maiusc+Tab, fuoco visibile, nessuna trappola; axe
for (const tab of TABS) {
  const { ctx, pg } = await pagina(browser, pg0Base(), { vw: VW, vh: VH, tab });
  await apriScheda(pg, tab);
  if (["convert", "image", "video", "audio", "pdf"].includes(tab)) await mettiFile(pg, tab);
  await pg.evaluate(() => { document.activeElement?.blur(); window.scrollTo(0, 0); });
  const seq = await tabs(pg, 70);
  const ids = seq.map((s) => s.id);
  const unici = new Set(ids);
  // Trappola: lo stesso elemento per 4 Tab di fila (fuori dai dialoghi)
  let trap = null;
  for (let i = 3; i < ids.length; i++) if (ids[i] && ids[i] === ids[i - 1] && ids[i] === ids[i - 2] && ids[i] === ids[i - 3] && !seq[i].modal) trap = ids[i];
  E.passo(`${tab} · Tab passa avanti senza fermarsi (${unici.size} elementi diversi in 70 Tab)`, !trap && unici.size > 3, trap ? `bloccato su ${trap}` : "");
  if (trap) E.bug(`Tastiera · scheda ${tab}: il Tab resta fermo su «${trap}»`, "medio", [`Apri la scheda ${tab}`, "Premi Tab più volte"], "Il fuoco passa all'elemento dopo", `il fuoco resta su ${trap} per 4 Tab di fila`, `sequenza in ${tab}-tab.txt`);
  for (const s of seq) {
    if (s.tag !== "body" && !s.visibile) { if (!senzaFuocoVisibile.has(s.id)) senzaFuocoVisibile.set(s.id, new Set()); senzaFuocoVisibile.get(s.id).add(tab); }
    if (s.tag !== "body" && !s.dentro) { if (!fuoriVista.has(s.id)) fuoriVista.set(s.id, new Set()); fuoriVista.get(s.id).add(tab); }
  }
  const navReached = seq.filter((s) => s.nav).length;
  E.passo(`${tab} · la barra laterale si raggiunge con Tab`, navReached >= 5, `${navReached} pulsanti laterali toccati`);
  // Maiusc+Tab torna indietro sullo stesso percorso
  const back = await tabs(pg, 5, true);
  const atteso = ids.slice(-6, -1).reverse();
  const ok = back.map((b) => b.id).join("|") === atteso.join("|");
  E.passo(`${tab} · Maiusc+Tab torna indietro sugli stessi elementi`, ok, ok ? "" : `atteso ${atteso.join(" ← ")} · visto ${back.map((b) => b.id).join(" ← ")}`);
  if (!ok) E.nota(`${tab}: Maiusc+Tab diverso (può essere un elemento che compare/scompare): atteso ${atteso.join(" ← ")} · visto ${back.map((b) => b.id).join(" ← ")}`);
  fs.writeFileSync(path.join(out, `${tab}-tab.txt`), seq.map((s, i) => `${i + 1}\t${s.id}\tvisibile=${s.visibile}\tdentro=${s.dentro}`).join("\n") + "\n");
  axeAll.push(...await axe(pg, `scheda ${tab}`));
  await ctx.close();
}

// 2. Invio e Spazio sui pulsanti della barra laterale: cambiano scheda
{
  const { ctx, pg } = await pagina(browser, pg0Base(), { vw: VW, vh: VH, tab: "convert" });
  let cambi = 0, prove = 0;
  for (const [i, key] of [[1, "Enter"], [2, "Space"], [4, "Enter"], [6, "Space"]]) {
    await pg.evaluate((i) => (document.querySelectorAll("aside .nav button, aside .foot button")[i]).focus(), i);
    await pg.keyboard.press(key);
    await pg.waitForTimeout(300);
    prove++;
    const on = await pg.evaluate((i) => document.querySelectorAll("aside .nav button, aside .foot button")[i].classList.contains("on"), i);
    if (on) cambi++;
    else E.nota(`${key} sul pulsante laterale ${i}: la scheda non cambia`);
  }
  if (!E.passo("Invio e Spazio sui pulsanti della barra laterale cambiano scheda", cambi === prove, `${cambi}/${prove}`))
    E.bug("Tastiera · Invio/Spazio sulla barra laterale non apre la scheda", "medio", ["Porta il fuoco su un pulsante della barra laterale con Tab", "Premi Invio o Spazio"], "Si apre la scheda", `${cambi} su ${prove} cambi`, "p15 passo 2");
  // Invio su un'azione (scheda Immagini con un file): parte il lavoro o si apre il pannello
  await pg.evaluate(() => (document.querySelectorAll("aside .nav button")[1]).click());
  await mettiFile(pg, "image");
  const prima = await pg.evaluate(() => document.querySelector("main").innerHTML.length);
  const az = await pg.evaluate(() => { const b = [...document.querySelectorAll("main button")].find((x) => /^Comprimi/.test(x.textContent.trim())); b?.focus(); return !!b; });
  await pg.keyboard.press("Enter");
  await pg.waitForTimeout(1500);
  const dopo = await pg.evaluate(() => document.querySelector("main").innerHTML.length + (document.querySelector(".resultbar") ? 100000 : 0));
  if (az) E.passo("Invio su «Comprimi» (Immagini) fa qualcosa", dopo !== prima);
  else E.nonEseguito("Invio su «Comprimi»", "pulsante non trovato");
  await ctx.close();
}

// 3. Dialoghi: il fuoco entra, resta dentro con Tab e Maiusc+Tab, Esc chiude
async function provaDialogo(pg, nome, apri) {
  const opened = await apri(pg);
  await pg.waitForTimeout(500);
  const there = await pg.evaluate(() => !!document.querySelector(".modal-bg, .pe-bg"));
  if (!opened || !there) { E.nonEseguito(`dialogo «${nome}»`, "non si è aperto nella prova"); return; }
  const start = await pg.evaluate(fuoco);
  E.passo(`dialogo «${nome}»: il fuoco entra nel dialogo all'apertura`, start.modal, start.id);
  if (!start.modal) E.bug(`Tastiera · dialogo «${nome}»: all'apertura il fuoco resta fuori`, "basso", [`Apri «${nome}»`], "Il fuoco va su un pulsante del dialogo", `fuoco su ${start.id}`, "p15 passo 3");
  const fw = await tabs(pg, 25), bw = await tabs(pg, 25, true);
  const escono = [...fw, ...bw].filter((s) => !s.modal);
  if (!E.passo(`dialogo «${nome}»: Tab e Maiusc+Tab restano dentro`, !escono.length, escono.slice(0, 3).map((s) => s.id).join(", ")))
    E.bug(`Tastiera · dialogo «${nome}»: il fuoco esce dal dialogo`, "medio", [`Apri «${nome}»`, "Premi Tab 25 volte e poi Maiusc+Tab 25 volte"], "Il fuoco resta dentro il dialogo", `fuoco su ${escono.slice(0, 3).map((s) => s.id).join(", ")}`, "p15 passo 3");
  const nascosto = [...fw, ...bw].filter((s) => s.tag !== "body" && !s.visibile).map((s) => s.id);
  if (nascosto.length) { for (const id of new Set(nascosto)) { if (!senzaFuocoVisibile.has(id)) senzaFuocoVisibile.set(id, new Set()); senzaFuocoVisibile.get(id).add(`dialogo ${nome}`); } }
  axeAll.push(...await axe(pg, `dialogo ${nome}`));
  await pg.screenshot({ path: path.join(out, `dialogo-${nome.replace(/[^a-z0-9]+/gi, "-")}.png`) });
  await pg.keyboard.press("Escape");
  await pg.waitForTimeout(400);
  const chiuso = await pg.evaluate(() => !document.querySelector(".modal-bg, .pe-bg"));
  if (!E.passo(`dialogo «${nome}»: Esc lo chiude`, chiuso))
    E.bug(`Tastiera · dialogo «${nome}»: Esc non lo chiude`, "basso", [`Apri «${nome}»`, "Premi Esc"], "Il dialogo si chiude (o chiede se chiudere)", "il dialogo resta aperto", "p15 passo 3");
}
const clickText = (sel, re) => async (pg) => pg.evaluate(({ sel, re }) => { const b = [...document.querySelectorAll(sel)].find((x) => new RegExp(re, "i").test((x.getAttribute("aria-label") || x.textContent).trim()) && x.getClientRects().length); b?.click(); return !!b; }, { sel, re });
const DIALOGHI = [
  ["Benvenuto", { welcomed: false }, async () => true],
  ["Aggiornamento disponibile", { cfg: { update: { version: "2.0.2", build: 999, notes: "Correzioni", notes_en: "", size: 97158248 } } }, async (pg) => { await pg.waitForSelector(".update-corner:not([hidden])", { timeout: 9000 }).catch(() => {}); return clickText(".update-corner", ".")(pg); }],
  ["Segnala un problema", {}, clickText("aside .foot button", "segnala")],
  ["Idea", {}, clickText("aside .foot button", "idea")],
  ["Cancellare la cronologia", { tab: "activity", extra: { history: [{ id: "j1", action: "icompress", title: "Comprimi", origin: "image", state: "done", started: Date.now() - 5000, ended: Date.now(), files: [{ path: "C:\\a.jpg", name: "a.jpg", size: 1 }], results: [{ source: "a.jpg", outputs: [], error: null }] }] } }, async (pg) => { await apriScheda(pg, "activity"); return clickText("main button", "cancella tutto")(pg); }],
  ["Editor PDF", { tab: "pdf" }, async (pg) => { await apriScheda(pg, "pdf"); await mettiFile(pg, "pdf"); return clickText("main button", "^editor pdf")(pg); }],
  ["Al telefono", { tab: "image" }, async (pg) => {
    await apriScheda(pg, "image"); await mettiFile(pg, "image");
    await clickText("main button", "^comprimi")(pg); await pg.waitForTimeout(400);
    await pg.evaluate(() => [...document.querySelectorAll("main .btn.primary")].find((x) => x.getClientRects().length)?.click());
    await pg.waitForTimeout(2500);
    return clickText("button", "al telefono")(pg);
  }],
];
for (const [nome, opts, apri] of DIALOGHI) {
  const { ctx, pg } = await pagina(browser, pg0Base(), { vw: VW, vh: VH, ...opts });
  if (opts.welcomed === false) await pg.waitForSelector(".modal.welcome", { timeout: 8000 }).catch(() => {});
  await provaDialogo(pg, nome, apri);
  await ctx.close();
}

// Fuoco non visibile (raggruppato)
if (senzaFuocoVisibile.size) {
  const l = [...senzaFuocoVisibile.entries()];
  E.bug("Tastiera · alcuni elementi col fuoco non mostrano nessun segno (né contorno né ombra né colore diverso)", "medio",
    ["Usa solo la tastiera", "Premi Tab nelle schede e nei dialoghi"], "Si vede sempre dove è il fuoco",
    `${l.length} elementi: ${l.slice(0, 10).map(([id, s]) => `${id} (${[...s].join(", ")})`).join(" · ")}`, "file <scheda>-tab.txt, colonna visibile=false");
}
E.passo("fuoco visibile su tutti gli elementi raggiunti", !senzaFuocoVisibile.size, `${senzaFuocoVisibile.size} senza segno`);
if (fuoriVista.size) E.nota(`elementi col fuoco ma fuori vista (non portati in vista): ${[...fuoriVista.keys()].slice(0, 10).join(" · ")}`);

// axe: una voce per regola, con dove succede
const perRegola = new Map();
for (const v of axeAll) {
  if (!perRegola.has(v.id)) perRegola.set(v.id, { ...v, dove: new Set([v.dove]), nodi: v.nodes });
  else { const r = perRegola.get(v.id); r.dove.add(v.dove); r.nodi += v.nodes; }
}
fs.writeFileSync(path.join(out, "axe.json"), JSON.stringify(axeAll, null, 1));
E.passo("axe-core: nessuna violazione", perRegola.size === 0, [...perRegola.keys()].join(", "));
for (const r of perRegola.values()) {
  const g = r.impact === "critical" || r.impact === "serious" ? "medio" : "basso";
  E.bug(`Accessibilità (axe-core «${r.id}», ${r.impact}): ${r.help}`, g, [`Apri: ${[...r.dove].slice(0, 6).join(", ")}`, "Controlla con axe-core 4.10 (o un lettore di schermo)"],
    "Nessuna violazione di accessibilità", `${r.nodi} elementi in ${r.dove.size} posti; esempi: ${r.esempi.join(" | ")}`, "axe.json (artifact t20-P15W)");
}
E.salva(out, "p15");
await browser.close();
srv.close();
function pg0Base() { return srv.base; }
