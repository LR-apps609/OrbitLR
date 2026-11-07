// 2.0.1 · Niente attese mute: ogni attesa lunga dice cosa succede, quanto manca quando si sa, e si può interrompere.
// stageText() non tocca il DOM (si prova con node: Tools/prova-avvio-windows.mjs).

import { t, tr } from "./i18n.js";
import { fmtTime } from "./util.js";

/** Le azioni con l'IA che la prima volta scaricano qualcosa e poi lavorano a lungo senza dire niente. */
export const AI_ACTIONS = ["removebg", "aienhance", "upscale"];

/**
 * Cosa sta facendo un lavoro in corso, in parole. `job.fetch`: { what, mb } se all'avvio mancava il motore o il modello.
 * `job.lastMove`: quando l'avanzamento è cambiato l'ultima volta. Restituisce null per i lavori normali (bastano i %).
 */
export function stageText(job, now = Date.now()) {
  const p = Number(job.progress) || 0, pct = Math.round(p * 100);
  const still = now - (job.lastMove || job.started || now);
  const since = still >= 4000 ? " · " + t`ancora al lavoro da ${fmtTime(Math.round((now - (job.started || now)) / 1000))}` : "";
  const fetching = (end) => job.fetch && p < end;
  const dl = (end) => t`Scarico ${tr(job.fetch.what)} (una volta sola, ${job.fetch.mb} MB)… ${Math.round((p / end) * 100)}%`;
  if (job.action === "removebg") {
    if (fetching(0.5)) return dl(0.5);
    if (p < 0.92) return t("L’IA cerca il soggetto e lo ritaglia: può volerci fino a un minuto") + since;
    return t("Salvo il risultato…");
  }
  if (job.action === "aienhance" || job.action === "upscale") {
    if (fetching(0.3)) return dl(0.3);
    if (p <= 0.3005) return t("Avvio l’IA sulla scheda video (la prima volta può volerci un minuto)…") + since;
    if (p < 0.9) return t`L’IA migliora la foto… ${pct}%` + since;
    return t("Salvo il risultato…");
  }
  // Qualunque altro lavoro fermo da un po': si dice che è vivo
  if (since && job.state === "running") return (pct > 0 ? `${pct}%` : t("Preparo…")) + since;
  return null;
}

/**
 * Un'attesa che di solito è breve (leggere i file) ma può durare: dopo `after` ms compare una riga con il motivo
 * (`why()` può essere asincrona) e «Interrompi» (se `canStop`). Interrompendo: `onStop()` e la promessa restituisce `stopped`.
 */
export function waitNotice(promise, why, { after = 900, onStop, stopped, canStop = true } = {}) {
  if (typeof document === "undefined") return promise;
  let box = null, done = false, timer;
  return new Promise((resolve, reject) => {
    const finish = (fn, v) => { if (done) return; done = true; clearTimeout(timer); box?.remove(); fn(v); };
    timer = setTimeout(async () => {
      let text = t("Leggo i file…");
      try { text = (await why()) || text; } catch {}
      if (done) return;
      const btn = document.createElement("button");
      btn.className = "toast-btn";
      btn.type = "button";
      btn.textContent = t("Interrompi");
      btn.onclick = () => { try { onStop?.(); } catch {} finish(resolve, stopped); };
      box = document.createElement("div");
      box.className = "wait-row";
      box.setAttribute("role", "status");
      const sp = document.createElement("span");
      sp.className = "wait-spin";
      box.append(sp, document.createTextNode(text), canStop ? btn : "");
      // Più attese insieme: una sopra l'altra, mai una sopra la scritta dell'altra
      const others = document.querySelectorAll(".wait-row").length;
      if (others) box.style.bottom = `${66 + others * 46}px`;
      document.body.append(box);
    }, after);
    promise.then((v) => finish(resolve, v), (e) => finish(reject, e));
  });
}
