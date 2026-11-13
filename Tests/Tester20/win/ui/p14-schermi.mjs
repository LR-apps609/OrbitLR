// Tester20 · P14W «Schermo piccolo»: l'interfaccia vera di OrbitLR per Windows (Chromium, finto Tauri) alle misure
// della finestra su schermi piccoli e scale alte. Ogni scheda e ogni dialogo che si apre con un clic:
// niente fuori dalla finestra, ogni pulsante raggiungibile. Foto di tutto.
// Uso: node p14-schermi.mjs <cartella-uscita>
import fs from "node:fs";
import path from "node:path";
import { pw, server, pagina, apriScheda, mettiFile, esito, fuoriFinestra, TABS } from "./comune.mjs";

const out = process.argv[2] || "p14";
fs.mkdirSync(out, { recursive: true });
const E = esito();
const TASKBAR = 48, TITLE = 32;
// «800 px di altezza»: schermo 1280×800 al 100%
const SCHERMI = (process.env.T20_SCHERMI || "1366x768@150,1280x720@125,1024x768@100,1280x800@100").split(",");
const MAXCLIC = Number(process.env.T20_MAXCLIC || 80);
const srv = await server();
const browser = await pw.chromium.launch();
const problemi = new Map(); // chiave → { dove, cosa, schermi:Set, foto }
const dialoghi = new Map(); // titolo → Set(schermi)
const nota = (dove, cosa, schermo, foto) => {
  const k = dove + "|" + cosa.replace(/^«[^»]*»: /, "").replace(/\(\-?\d+,\-?\d+[^)]*\)/g, "").replace(/\d+×\d+/g, "");
  if (!problemi.has(k)) problemi.set(k, { dove, cosa, schermi: new Set(), foto });
  problemi.get(k).schermi.add(schermo);
};
// Una voce di cronologia (per «Attività» e «Cancellare la cronologia?»)
const STORIA = [{ id: "jt20", action: "icompress", title: "Comprimi", origin: "image", state: "done", progress: 1, started: Date.now() - 60000, ended: Date.now() - 50000,
  files: [{ path: "C:\\Utenti\\Prova\\Immagini\\Vacanze al mare.jpg", name: "Vacanze al mare.jpg", size: 603000 }],
  results: [{ source: "Vacanze al mare.jpg", outputs: [{ path: "C:\\Utenti\\Prova\\Immagini\\Vacanze al mare (compresso).jpg", name: "Vacanze al mare (compresso).jpg", size: 120000 }], error: null }] }];
const safe = (s) => s.replace(/[^a-z0-9àèéìòù]+/gi, "-").slice(0, 40);

async function topModal(pg) {
  return pg.evaluate(() => {
    const bg = [...document.querySelectorAll(".modal-bg, .pe-bg, .pop[role=dialog]")].pop();
    if (!bg) return null;
    document.querySelectorAll("[data-t20]").forEach((e) => e.removeAttribute("data-t20"));
    const m = bg.querySelector(".modal, [role=dialog]") || bg;
    m.setAttribute("data-t20", "1");
    return (m.querySelector("h2,h3,h4")?.textContent || m.textContent || "").trim().replace(/\s+/g, " ").slice(0, 60);
  });
}

async function chiudiModali(pg) {
  for (let k = 0; k < 4; k++) {
    const n = await pg.evaluate(() => document.querySelectorAll(".modal-bg, .pe-bg, .pop[role=dialog]").length);
    if (!n) return;
    await pg.keyboard.press("Escape");
    await pg.waitForTimeout(200);
    const n2 = await pg.evaluate(() => document.querySelectorAll(".modal-bg, .pe-bg, .pop[role=dialog]").length);
    if (n2 < n) continue;
    const clicked = await pg.evaluate(() => {
      const bg = [...document.querySelectorAll(".modal-bg, .pe-bg, .pop[role=dialog]")].pop();
      const b = [...bg.querySelectorAll("button")].find((x) => /annulla|chiudi|più tardi|^no$|continua|^ok$|bene|salta/i.test(x.textContent.trim()));
      if (b) { b.click(); return true; }
      bg.remove(); return false;
    });
    await pg.waitForTimeout(200);
  }
}

async function controllaDialogo(pg, schermo, dove, vw, vh) {
  const titolo = await topModal(pg);
  if (titolo == null) return false;
  if (!dialoghi.has(titolo)) dialoghi.set(titolo, new Set());
  const nuovo = !dialoghi.get(titolo).has(schermo);
  dialoghi.get(titolo).add(schermo);
  if (!nuovo) return true;
  const bad = await pg.evaluate(fuoriFinestra, "[data-t20]");
  const foto = `${schermo.replace("@", "-")}-dialogo-${safe(titolo)}.png`;
  await pg.screenshot({ path: path.join(out, foto) }).catch(() => {});
  bad.forEach((b) => nota(`dialogo «${titolo}» (da ${dove})`, b, schermo, foto));
  return true;
}

for (const schermo of SCHERMI) {
  const [, W, H, S] = schermo.match(/^(\d+)x(\d+)@(\d+)$/).map(Number);
  const s = S / 100;
  const vw = Math.floor(W / s), vh = Math.floor(H / s) - TASKBAR - TITLE;
  console.log(`── ${schermo}: finestra ${vw}×${vh} (scala ${s})`);

  // 1. Il benvenuto (primo avvio): ogni passo dentro la finestra
  {
    const { ctx, pg, errs } = await pagina(browser, srv.base, { vw, vh, dsf: s, welcomed: false });
    const c = await pg.waitForSelector(".modal.welcome", { timeout: 8000 }).then(() => true).catch(() => false);
    if (E.passo(`${schermo} · benvenuto compare`, c)) {
      for (let step = 1; step <= 3; step++) {
        await pg.waitForTimeout(700);
        const bad = await pg.evaluate(fuoriFinestra, ".modal.welcome");
        const foto = `${schermo.replace("@", "-")}-benvenuto-${step}.png`;
        await pg.screenshot({ path: path.join(out, foto) });
        bad.forEach((b) => nota(`benvenuto passo ${step}`, b, schermo, foto));
        E.passo(`${schermo} · benvenuto passo ${step} dentro la finestra`, !bad.length, bad.join("; "));
        await pg.click(".welcome .btn.primary", { timeout: 3000 }).catch(() => {});
      }
    }
    errs.forEach((e) => nota("benvenuto", "errore JavaScript: " + e, schermo, ""));
    await ctx.close();
  }

  // 2. Ogni scheda, senza e con un file, e i dialoghi che si aprono con un clic
  for (const tab of (process.env.T20_TABS ? process.env.T20_TABS.split(",") : TABS)) {
    for (const conFile of tab in { convert: 1, image: 1, video: 1, audio: 1, pdf: 1 } ? [false, true] : [false]) {
      const { ctx, pg, errs } = await pagina(browser, srv.base, { vw, vh, dsf: s, tab, cfg: { update: { version: "2.0.2", build: 999, notes: "Correzioni (prova)", notes_en: "", size: 97158248 } }, extra: { history: STORIA } });
      await apriScheda(pg, tab);
      if (conFile) {
        await mettiFile(pg, tab);
        // Tutte le funzioni («Completo»), non solo le principali
        await pg.evaluate(() => [...document.querySelectorAll("main button")].find((x) => x.textContent.trim() === "Completo")?.click());
        await pg.waitForTimeout(300);
      }
      await chiudiModali(pg);
      const dove = `${tab}${conFile ? " con un file" : ""}`;
      const bad = [...await pg.evaluate(fuoriFinestra, "aside.side"), ...await pg.evaluate(fuoriFinestra, "main")];
      const foto = `${schermo.replace("@", "-")}-${tab}${conFile ? "-file" : ""}.png`;
      await pg.screenshot({ path: path.join(out, foto) });
      bad.forEach((b) => nota(`scheda ${dove}`, b, schermo, foto));
      E.passo(`${schermo} · scheda ${dove}: tutto dentro la finestra`, !bad.length, bad.slice(0, 4).join("; "));
      // I dialoghi: si clicca ogni pulsante della scheda (uno alla volta) e si guarda se si apre qualcosa
      // (dialogo, menu a comparsa o pannello di scelte dentro la scheda)
      if (tab === "convert" && !conFile) await pg.waitForTimeout(4500); // l'avviso dell'aggiornamento arriva dopo 4 s
      const SEL = "main button:not([disabled]), .update-corner:not([hidden]), aside .foot button:nth-child(n+3)";
      const n = await pg.evaluate((SEL) => document.querySelectorAll(SEL).length, SEL);
      let aperti = 0;
      for (let i = 0; i < Math.min(n, MAXCLIC); i++) {
        const before = await pg.evaluate(() => document.querySelectorAll(".modal-bg, .pe-bg, .pop[role=dialog]").length);
        const label = await pg.evaluate(({ i, SEL }) => {
          const b = [...document.querySelectorAll(SEL)][i];
          if (!b || !b.getClientRects().length || /^Togli/.test((b.getAttribute("aria-label") || b.textContent || "").trim())) return null;
          b.scrollIntoView({ block: "nearest" }); b.click();
          return (b.getAttribute("aria-label") || b.textContent || "").trim().replace(/\s+/g, " ").slice(0, 30);
        }, { i, SEL }).catch(() => null);
        if (label == null) continue;
        if (process.env.T20_DEBUG) console.log("      clic", i, label);
        await pg.waitForTimeout(260);
        const after = await pg.evaluate(() => document.querySelectorAll(".modal-bg, .pe-bg, .pop[role=dialog]").length);
        if (after > before && await controllaDialogo(pg, schermo, `${dove} → «${label}»`, vw, vh)) aperti++;
        else {
          // Un menu a comparsa o un pannello: anche quello dentro la finestra
          const badPop = [...await pg.evaluate(fuoriFinestra, ".pop, .menu, [role=menu]"), ...await pg.evaluate(fuoriFinestra, "main")];
          if (badPop.length) {
            const f = `${schermo.replace("@", "-")}-${tab}-dopo-${safe(label)}.png`;
            await pg.screenshot({ path: path.join(out, f) }).catch(() => {});
            badPop.forEach((b) => nota(`scheda ${dove}, dopo alcuni clic (per esempio «${label}»)`.replace(/ \(per esempio.*$/, ""), b, schermo, f));
          }
        }
        await chiudiModali(pg);
        await pg.keyboard.press("Escape").catch(() => {});
      }
      if (aperti) console.log(`   ${dove}: ${aperti} dialoghi aperti`);
      // (errori JavaScript durante i clic a raffica: solo nota, la prova toglie a volte i dialoghi a mano)
      errs.forEach((e) => E.nota(`${schermo} · ${dove} · errore JavaScript durante i clic: ${e}`));
      await ctx.close();
    }
  }

  // 3. «Al telefono» dalla barra del risultato (dopo un lavoro finito) e la domanda dell'aggiornamento
  {
    const { ctx, pg } = await pagina(browser, srv.base, { vw, vh, dsf: s, tab: "image" });
    await apriScheda(pg, "image");
    await mettiFile(pg, "image");
    const azione = await pg.evaluate(() => {
      const b = [...document.querySelectorAll("main button")].find((x) => /comprimi|converti|jpg/i.test(x.textContent) && x.getClientRects().length);
      if (b) { b.click(); return b.textContent.trim().slice(0, 40); } return null;
    });
    await pg.waitForTimeout(400);
    // Se si è aperto un pannello di scelte, il pulsante principale
    await pg.evaluate(() => { const p = [...document.querySelectorAll("main .btn.primary")].find((x) => x.getClientRects().length); p?.click(); });
    await pg.waitForTimeout(2500);
    const tel = await pg.evaluate(() => { const b = [...document.querySelectorAll("button")].find((x) => /al telefono/i.test(x.textContent) && x.getClientRects().length); if (b) { b.click(); return true; } return false; });
    await pg.waitForTimeout(800);
    if (tel) { E.passo(`${schermo} · «Al telefono» dopo «${azione}»`, await controllaDialogo(pg, schermo, "barra del risultato")); }
    else E.nonEseguito(`${schermo} · dialogo «Al telefono»`, `dopo «${azione}» la barra del risultato non mostra «Al telefono» nel finto Tauri`);
    await ctx.close();
  }
}

// Bug: uno per posto e per tipo di problema, con gli elementi e gli schermi dove succede
const gruppi = new Map();
for (const p of problemi.values()) {
  const c = p.cosa.replace(/^«[^»]*»: /, "");
  const tipo = c.startsWith("errore JavaScript") ? "errore JavaScript" : /esce dalla finestra/.test(c) ? "esce dalla finestra" : /coperto da/.test(c) ? "pulsanti coperti da altri elementi" : /finestra intera/.test(c) ? "pulsanti raggiungibili solo facendo scorrere la finestra intera" : "pulsanti che non si raggiungono";
  const k = p.dove + "|" + tipo;
  if (!gruppi.has(k)) gruppi.set(k, { dove: p.dove, tipo, cose: new Set(), schermi: new Set(), foto: p.foto });
  const g = gruppi.get(k);
  g.cose.add(c.replace(/\s*\(.*$/, "").slice(0, 90)); p.schermi.forEach((x) => g.schermi.add(x));
}
for (const g of gruppi.values()) {
  const cose = [...g.cose];
  const grave = g.tipo === "errore JavaScript" || (g.tipo !== "pulsanti raggiungibili solo facendo scorrere la finestra intera" && cose.some((c) => /esporta|salva|chiudi|avanti|cominciamo|aggiorna|converti|comprimi/i.test(c))) ? "medio" : "basso";
  E.bug(`Schermo piccolo · ${g.dove}: ${g.tipo}`, grave,
    [`Apri OrbitLR con la finestra di ${[...g.schermi].join(", ")} (finestra = schermo / scala − barra delle applicazioni 48 − titolo 32)`, `Vai a: ${g.dove}`],
    "Tutto il contenuto e tutti i pulsanti stanno dentro la finestra o si raggiungono scorrendo l'area che scorre, senza essere coperti",
    `${cose.length} elementi: ${cose.slice(0, 10).join(" · ")}${cose.length > 10 ? " …" : ""}${cose.some((c) => /update-corner/.test(c)) ? " (update-corner = l'avviso «Nuovo aggiornamento disponibile» in alto a destra)" : ""}`,
    `foto ${g.foto} (artifact t20-P14W); interfaccia vera in Chromium con finto Tauri`);
}
E.nota(`dialoghi visti: ${[...dialoghi.entries()].map(([t, s]) => `«${t}» (${[...s].length} schermi)`).join(" · ")}`);
fs.writeFileSync(path.join(out, "dialoghi.txt"), [...dialoghi.entries()].map(([t, s]) => `${t}\t${[...s].join(",")}`).join("\n") + "\n");
E.salva(out, "p14");
await browser.close();
srv.close();
