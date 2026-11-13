// Tester20 · P04 · «Aggiorna adesso», «Interrompi», «Riprova» nell'interfaccia vera (Chromium, finto Tauri):
// update_install manda l'avanzamento e finisce bene, si ferma con update_cancel o non riesce (rete).
// Uso: node p04-ui.mjs <cartella-uscita>
import fs from "node:fs";
import path from "node:path";
import { pw, server, pagina, esito } from "./comune.mjs";

const out = process.argv[2] || "p04ui";
fs.mkdirSync(out, { recursive: true });
const E = esito();
const srv = await server();
const browser = await pw.chromium.launch();
const UPD = { version: "2.0.2", build: 999, notes: "Correzioni (prova Tester20)", notes_en: "", size: 97158248 };
const init = () => {
  const T = window.__TAURI__;
  const orig = T.core.invoke;
  let pending = null;
  window.__T20mode = "hold";
  window.__T20startup = null;
  T.core.invoke = async (cmd, args) => {
    if (cmd === "startup" && window.__T20startup) return window.__T20startup;
    if (cmd === "update_install") {
      return new Promise((ok, ko) => {
        let p = 0; const mode = window.__T20mode;
        const t = setInterval(() => {
          p = Math.min(p + 0.04, mode === "hold" ? 0.6 : 1);
          window.__Femit("update-progress", p);
          if (mode === "fail" && p >= 0.3) { clearInterval(t); pending = null; ko("non riesco a scaricare l'aggiornamento: errore di rete (prova)"); }
          if (mode === "ok" && p >= 1) { clearInterval(t); pending = null; window.__Femit("update-installing", null); setTimeout(() => ok(null), 400); }
        }, 120);
        pending = { t, ko };
      });
    }
    if (cmd === "update_cancel") { if (pending) { clearInterval(pending.t); const k = pending.ko; pending = null; setTimeout(() => k("Interrotto"), 50); } return null; }
    return orig(cmd, args);
  };
};
const corner = (pg) => pg.evaluate(() => { const c = document.querySelector(".update-corner"); return c ? { hidden: c.hidden, text: c.textContent.trim(), failed: c.classList.contains("failed"), stop: !!document.querySelector(".update-stop:not([hidden])") } : null; });
const toastText = (pg) => pg.evaluate(() => [...document.querySelectorAll(".toast")].map((t) => t.textContent.trim()).join(" | "));
const clickBtn = (pg, re) => pg.evaluate((re) => { const b = [...document.querySelectorAll("button")].find((x) => new RegExp(re, "i").test(x.textContent.trim()) && x.getClientRects().length); b?.click(); return !!b; }, re);
const shot = (pg, n) => pg.screenshot({ path: path.join(out, n + ".png") });

{
  const { ctx, pg, errs } = await pagina(browser, srv.base, { cfg: { update: UPD }, extra: { updateCheck: 0 }, init });
  await pg.waitForSelector(".update-corner:not([hidden])", { timeout: 10000 }).catch(() => {});
  let c = await corner(pg);
  E.passo("«Nuovo aggiornamento disponibile» compare", c && !c.hidden, c?.text);
  await shot(pg, "1-avviso");
  await pg.click(".update-corner");
  await pg.waitForTimeout(500);
  const m = await pg.evaluate(() => document.querySelector(".modal-bg .modal")?.innerText || "");
  E.passo("clic sull'avviso: domanda con «Aggiorna adesso»", /Aggiorna adesso/.test(m) && /2\.0\.2/.test(m), m.replace(/\s+/g, " ").slice(0, 160));
  await shot(pg, "2-domanda");
  await clickBtn(pg, "^Aggiorna adesso$");
  await pg.waitForTimeout(1200);
  c = await corner(pg);
  E.passo("mentre scarica: percentuale e «Interrompi»", /\d+\s*%/.test(c.text) && c.stop, `${c.text} · Interrompi visibile: ${c.stop}`);
  await shot(pg, "3-scarica");
  await clickBtn(pg, "^Interrompi$");
  await pg.waitForTimeout(900);
  c = await corner(pg);
  const t1 = await toastText(pg);
  if (!E.passo("«Interrompi»: si ferma, lo dice, si può riprovare", !c.stop && /interrott/i.test(t1) && !c.failed, `angolo «${c.text}» · avviso «${t1}»`))
    E.bug("«Interrompi» sull'aggiornamento: l'interfaccia non torna a «Nuovo aggiornamento disponibile»", "medio", ["Aggiorna adesso", "Interrompi"], "Avviso «Aggiornamento interrotto» e si può riprovare", `angolo «${c.text}», avviso «${t1}»`, "4-interrotto.png");
  await shot(pg, "4-interrotto");
  // Non riesce (rete)
  await pg.evaluate(() => { window.__T20mode = "fail"; });
  await pg.click(".update-corner");
  await pg.waitForTimeout(400);
  await clickBtn(pg, "^Aggiorna adesso$");
  await pg.waitForTimeout(2500);
  c = await corner(pg);
  const t2 = await toastText(pg);
  if (!E.passo("aggiornamento non riuscito: motivo e «Riprova» restano visibili", c.failed && /riprova/i.test(c.text) && /rete/i.test(t2 + (await pg.evaluate(() => document.querySelector(".update-corner")?.title || ""))), `angolo «${c.text}» · avviso «${t2}»`))
    E.bug("Aggiornamento non riuscito: non si vede il motivo o «Riprova»", "medio", ["Aggiorna adesso", "la rete cade"], "«Aggiornamento non riuscito · Riprova» e il motivo", `angolo «${c.text}», avviso «${t2}»`, "5-non-riuscito.png");
  await shot(pg, "5-non-riuscito");
  // «Riprova» → riesce
  await pg.evaluate(() => { window.__T20mode = "ok"; });
  const fromToast = await pg.evaluate(() => { const b = [...document.querySelectorAll(".toast button")].find((x) => /riprova/i.test(x.textContent)); b?.click(); return !!b; });
  if (!fromToast) await pg.click(".update-corner");
  await pg.waitForTimeout(4500);
  c = await corner(pg);
  if (!E.passo("«Riprova»: scarica e dice che si installa e si riapre da sola", /installo|si riapre/i.test(c.text), `(${fromToast ? "dall'avviso" : "dall'angolo"}) «${c.text}»`))
    E.bug("«Riprova» dopo un aggiornamento non riuscito non riparte", "medio", ["Aggiornamento non riuscito", "Riprova"], "Riparte lo scaricamento e poi «Installo l'aggiornamento…»", `«${c.text}»`, "6-riprova.png");
  await shot(pg, "6-riprova");
  const news = await pg.evaluate(() => localStorage.getItem("orbitlr.newsPending"));
  E.passo("le novità della 2.0.2 restano per la prossima apertura", /2\.0\.2/.test(news || ""), news?.slice(0, 80));
  errs.forEach((e) => E.nota("errore JavaScript: " + e));
  await ctx.close();
}
// Riaperta con --aggiornamento-non-riuscito
{
  const { ctx, pg } = await pagina(browser, srv.base, { init: () => {
    const T = window.__TAURI__; const orig = T.core.invoke;
    T.core.invoke = async (cmd, args) => cmd === "startup" ? { files: [], update_failed: true } : orig(cmd, args);
  } });
  await pg.waitForTimeout(2500);
  const c = await corner(pg);
  const t = await toastText(pg);
  if (!E.passo("riaperta dopo un installatore non riuscito: lo dice e offre «Riprova»", c && !c.hidden && c.failed, `angolo «${c?.text}» · avviso «${t}»`))
    E.bug("Dopo un installatore non riuscito OrbitLR non dice che l'aggiornamento è fallito", "medio", ["L'installatore dell'aggiornamento esce con errore", "OrbitLR si riapre"], "«Aggiornamento non riuscito · Riprova»", `angolo «${c?.text}», avviso «${t}»`, "7-riaperta-non-riuscito.png");
  await shot(pg, "7-riaperta-non-riuscito");
  await ctx.close();
}
E.salva(out, "p04ui");
await browser.close();
srv.close();
