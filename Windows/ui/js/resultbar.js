// La barra in basso: avanzamento con la scala della radio, poi il risultato con quanto si è guadagnato.

import { cancel, getHistory, markUndone, retry, subscribe } from "./jobs.js";
import { addRecipe, askName, chainOf } from "./presets.js";
import { actionName, kindOfExt } from "./catalog.js";
import { invoke, openPath, reveal } from "./api.js";
import { openCompare } from "./compare.js";
import { install as installOffice } from "./office.js";
import { askFeedbackOnce } from "./feedback.js";
import { fmtBytes, gainText, h, ico, toast } from "./util.js";
import { t, tr, tc, isEn } from "./i18n.js";
import { stageText } from "./attese.js";

const IMG = ["jpg", "jpeg", "png", "webp", "avif", "bmp", "gif", "tif", "tiff", "jfif"];
const isImg = (p) => IMG.includes(String(p || "").split(".").pop().toLowerCase());

export function resultBar(origin) {
  const el = h("div");
  let current = null;
  let hideTimer, tick;
  let dismissed = null;

  function render(job) {
    clearTimeout(hideTimer);
    el.replaceChildren();
    if (!job) return;
    if (job.state === "running") {
      const pct = Math.round(job.progress * 100);
      const n = job.files.length;
      // 1.1 · Esportando il montaggio: anche quanto manca («Esporto… 42% · circa 2 min»)
      const left = job.action === "vproject" ? timeLeft(job) : "";
      // 2.0.1 · Le attese lunghe (IA, motore che parte) dicono cosa succede e da quanto
      const stage = job.action === "vproject" ? null : stageText(job);
      const what = job.stopping ? t("Interrompo…") : job.stopError ? capital(t`Non si è interrotto: ${job.stopError}`) : job.action === "vproject" ? (pct > 0 ? t`Esporto… ${pct}%` : t("Preparo…")) + (left ? " · " + left : "") : stage || (pct > 0 ? `${pct}%` : t("Preparo…"));
      clearTimeout(tick);
      tick = setTimeout(() => { if (current === job && job.state === "running" && el.isConnected) render(job); }, 1000);
      el.append(
        h("div.resultbar", { role: "status" },
          h("div.ic.run", ico("loader-circle", 20, "spin")),
          h("div.tx",
            h("b", n > 1 ? t`${job.title} · ${n} file` : n === 1 ? `${job.title} · ${job.files[0].name}` : job.title),
            h("span", job.stopError ? { style: { color: "var(--err)" } } : null, what),
            h("div.tuner", h("div.fill", { style: { width: Math.max(2, pct) + "%" } }), h("div.scale"))),
          h("button.btn", { disabled: job.stopping || null, onclick: () => cancel(job.id) }, t("Interrompi")),
          // Non si ferma: la barra si può chiudere (il lavoro resta in Attività)
          job.stopError ? closeBtn() : null));
      return;
    }
    const outs = job.results.flatMap((r) => r.outputs);
    const errs = job.results.filter((r) => r.error);
    if (job.state === "cancelled") {
      el.append(h("div.resultbar", h("div.ic.err", ico("circle-x", 20)), h("div.tx", h("b", t("Interrotto")), h("span", t("Nessun file a metà è rimasto sul disco."))), closeBtn()));
      hideTimer = setTimeout(() => render(null), 5000);
      return;
    }
    if (!outs.length) {
      const e = tr(errs[0]?.error) || t("qualcosa è andato storto");
      // 1.1 · Il pulsante che risolve, oppure «Riprova»
      el.append(h("div.resultbar", h("div.ic.err", ico("triangle-alert", 20)),
        h("div.tx", h("b", t("Non riuscito")), h("span", capital(e))), fixButton(job), closeBtn()));
      return;
    }
    if (job.undone) {
      el.append(h("div.resultbar", h("div.ic.ok", ico("rotate-ccw", 20)), h("div.tx", h("b", t("Risultato eliminato")), h("span", t("Il file creato è nel Cestino; l’originale è dov’era."))), closeBtn()));
      hideTimer = setTimeout(() => render(null), 4000);
      return;
    }
    const first = outs[0];
    const src = job.results[0];
    const canCompare = outs.length === 1 && job.results.length === 1 && src?.sourcePath && isImg(src.sourcePath) && (isImg(first.path) || /\.svg$/i.test(first.path));
    let detail;
    if (job.action === "vproject" || job.action === "tts") {
      detail = h("span", `${job.action === "vproject" ? t("Montaggio pronto") : t("File audio pronto")} · ${fmtBytes(first.size)}`);
    } else if (outs.length === 1 && job.results.length === 1) {
      const before = job.results[0].sourceSize;
      const g = gainText(before, first.size);
      detail = g ? h("span.gain", g) : h("span", fmtBytes(first.size));
    } else {
      const total = outs.reduce((a, o) => a + o.size, 0);
      detail = h("span", t`${outs.length} file creati · ${fmtBytes(total)}`);
    }
    el.append(
      h("div.resultbar", { role: "status" },
        h("div.ic.ok", ico("circle-check", 22)),
        h("div.tx", h("b", outs.length === 1 ? first.name : t`Fatto: ${outs.length} file`), detail,
          errs.length ? h("span", { style: { color: "var(--err)", display: "block" } }, t`${errs.length} non riusciti: ${tr(errs[0].error)}`) : null),
        h("button.btn", { onclick: () => reveal(first.path) }, ico("folder-open", 16), t("Mostra nella cartella")),
        outs.length === 1 ? h("button.btn", { onclick: () => openPath(first.path) }, ico("external-link", 16), t("Apri")) : null,
        outs.length === 1 ? h("button.btn", { title: t("Inquadra il codice con il telefono, sulla stessa rete Wi-Fi"), onclick: () => sendToPhone(first) }, ico("smartphone", 16), t("Al telefono")) : null,
        canCompare ? h("button.btn", { title: t("Originale e risultato, con la linea da trascinare"), onclick: () => openCompare({ path: src.sourcePath, size: src.sourceSize }, first) }, ico("columns-2", 16), t("Confronta")) : null,
        ["link", "rename"].includes(job.action) ? null : h("button.btn.ghost.danger", { title: t("Manda nel Cestino di Windows i file appena creati; l’originale resta com’era"), onclick: () => undo(job, outs) }, ico("trash-2", 16), t("Elimina il risultato")),
        closeBtn()));
    if (job.state === "done") askFeedbackOnce(el.firstChild);
    // Più passi di fila sullo stesso file: si possono salvare come ricetta
    const chain = job.state === "done" ? chainOf(job, getHistory()) : null;
    if (chain && el.firstChild) {
      const names = chain.steps.map((s) => actionName(s.action)).join(" → ");
      el.firstChild.append(h("div.fb-ask", h("span", t`Hai fatto ${chain.steps.length} passi: ${names}`),
        h("button.btn.ghost", { onclick: async (e) => {
          const name = await askName(t("Salva come ricetta"), names, t("La prossima volta i passi partono uno dopo l'altro da soli, da «Le mie azioni»."));
          if (!name) return;
          const k = kindOfExt(chain.first.split(".").pop());
          addRecipe(k === "image" ? "image" : k === "video" ? "video" : k === "pdf" ? "pdf" : k, chain.steps, name);
          e.target.closest(".fb-ask")?.remove();
          toast(t`Ricetta «${name}» salvata in Le mie azioni.`);
        } }, "★ ", t("Salva come ricetta"))));
    }
  }

  async function undo(job, outs) {
    try {
      await invoke("undo_result", { paths: outs.map((o) => o.path) });
      job.undone = true;
      markUndone(job.id);
      render(job);
    } catch (e) {
      toast(tr(String(e)));
    }
  }

  function closeBtn() {
    return h("button.btn.icon.ghost", { title: t("Chiudi"), "aria-label": t("Chiudi"), onclick: () => { dismissed = current?.state === "running" ? current.id : null; current = null; render(null); } }, ico("x", 16));
  }

  subscribe((job) => {
    if (!job || job.origin !== origin) return;
    // Chiusa con la ✕ mentre non si fermava: torna solo quando il lavoro finisce
    if (job.id === dismissed && job.state === "running") return;
    current = job;
    render(job);
  });

  return { el, clear: () => render(null), get job() { return current; } };
}

// 2.0.1 · «Al telefono» cliccato più volte: una finestra sola (mentre il codice si prepara, i clic in più non contano)
let phoneBusy = false;
async function sendToPhone(file) {
  const open = document.querySelector(".modal.phone");
  if (open) return open.querySelector(".row button.primary")?.focus();
  if (phoneBusy) return;
  phoneBusy = true;
  let r;
  try {
    r = await invoke("phone_share", { path: file.path, en: isEn });
  } catch (e) {
    return toast(tr(String(e)));
  } finally {
    phoneBusy = false;
  }
  if (document.querySelector(".modal.phone")) return;
  const qr = h("div.qr");
  const urlEl = h("p.fb-note", { style: { userSelect: "text" } });
  const expired = h("div", { hidden: true, style: { display: "grid", gap: "8px", justifyItems: "center" } });
  let timer;
  const showCode = (res) => {
    qr.innerHTML = res.svg; // SVG creato dal motore di OrbitLR
    qr.hidden = false;
    urlEl.textContent = res.url;
    urlEl.hidden = false;
    expired.hidden = true;
    clearTimeout(timer);
    // 1.1 · Dopo 15 minuti il collegamento non vale più: lo si dice, con «Rigenera»
    timer = setTimeout(() => {
      invoke("phone_stop").catch(() => {});
      qr.hidden = true;
      urlEl.hidden = true;
      expired.hidden = false;
    }, 15 * 60e3 - 5000);
  };
  expired.append(h("p", { style: { margin: 0, fontWeight: 800 } }, t("Il codice è scaduto.")),
    h("button.btn.primary", { type: "button", onclick: async () => {
      try { showCode(await invoke("phone_share", { path: file.path, en: isEn })); } catch (e) { toast(tr(String(e))); }
    } }, ico("rotate-ccw", 15), t("Rigenera")));
  showCode(r);
  const bg = h("div.modal-bg");
  const close = () => { clearTimeout(timer); invoke("phone_stop").catch(() => {}); bg.remove(); document.removeEventListener("keydown", esc, true); };
  // Esc chiude, come le altre finestre
  const esc = (e) => { if (e.key === "Escape" && bg.isConnected && [...document.querySelectorAll(".modal-bg")].pop() === bg) { e.preventDefault(); e.stopImmediatePropagation(); close(); } };
  document.addEventListener("keydown", esc, true);
  bg.append(h("div.modal.phone", { role: "dialog", "aria-modal": "true", "aria-label": t("Manda al telefono") },
    h("h3", t("Manda al telefono")),
    h("p", t`Inquadra il codice con la fotocamera del telefono e tocca «Scarica». Il telefono deve essere sulla stessa rete Wi-Fi del computer.`),
    qr,
    expired,
    urlEl,
    h("p.fb-note", t("Il collegamento vale 15 minuti e funziona solo in casa: niente passa da internet. Se Windows chiede il permesso per la rete, scegli «Reti private».")),
    h("div.row", h("button.btn.primary", { onclick: close }, t("Fatto")))));
  bg.addEventListener("click", (e) => e.target === bg && close());
  document.body.append(bg);
  bg.querySelector(".row button.primary")?.focus();
}

/** «circa 2 min», «meno di un minuto»: dal ritmo fin qui (dopo qualche secondo, quando è affidabile). */
function timeLeft(job) {
  const p = job.progress || 0;
  const spent = (Date.now() - job.started) / 1000;
  if (p < 0.03 || spent < 4) return "";
  const rest = (spent / p) * (1 - p);
  if (rest < 50) return t("meno di un minuto");
  return t`circa ${Math.round(rest / 60)} min`;
}

/** Dopo un errore: il pulsante che risolve (se si sa quale), altrimenti «Riprova». */
export function fixButton(job) {
  const err = String(job.results.find((r) => r.error)?.error || "");
  if (/LibreOffice/i.test(err) && window.orbit) return h("button.btn.fix", { onclick: async () => { if (await installOffice(window.orbit)) retry(job); } }, t("Installa LibreOffice"));
  // Il file non c'è più: riprovare non servirebbe
  if (/non trovo|spostato o cancellato/i.test(err)) return null;
  // Senza password salvata non si può rifare da qui
  if (["protect", "unprotect"].includes(job.action)) return null;
  return h("button.btn.fix", { onclick: () => retry(job) }, ico("rotate-ccw", 15), t("Riprova"));
}

function capital(s) {
  s = String(s || "");
  return s.charAt(0).toUpperCase() + s.slice(1) + (/[.!?]$/.test(s) ? "" : ".");
}
