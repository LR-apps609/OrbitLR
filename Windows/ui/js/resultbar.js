// La barra in basso: avanzamento con la scala della radio, poi il risultato con quanto si è guadagnato.

import { cancel, subscribe } from "./jobs.js";
import { invoke, openPath, reveal } from "./api.js";
import { openCompare } from "./compare.js";
import { askFeedbackOnce } from "./feedback.js";
import { fmtBytes, gainText, h, ico, toast } from "./util.js";

const IMG = ["jpg", "jpeg", "png", "webp", "avif", "bmp", "gif", "tif", "tiff", "jfif"];
const isImg = (p) => IMG.includes(String(p || "").split(".").pop().toLowerCase());

export function resultBar(origin) {
  const el = h("div");
  let current = null;
  let hideTimer;

  function render(job) {
    clearTimeout(hideTimer);
    el.replaceChildren();
    if (!job) return;
    if (job.state === "running") {
      const pct = Math.round(job.progress * 100);
      const n = job.files.length;
      el.append(
        h("div.resultbar", { role: "status" },
          h("div.ic.run", ico("loader-circle", 20, "spin")),
          h("div.tx",
            h("b", n > 1 ? `${job.title} · ${n} file` : n === 1 ? `${job.title} · ${job.files[0].name}` : job.title),
            h("span", pct > 0 ? `${pct}%` : "Preparo…"),
            h("div.tuner", h("div.fill", { style: { width: Math.max(2, pct) + "%" } }), h("div.scale"))),
          h("button.btn", { onclick: () => cancel(job.id) }, "Interrompi")));
      return;
    }
    const outs = job.results.flatMap((r) => r.outputs);
    const errs = job.results.filter((r) => r.error);
    if (job.state === "cancelled") {
      el.append(h("div.resultbar", h("div.ic.err", ico("circle-x", 20)), h("div.tx", h("b", "Interrotto"), h("span", "Nessun file a metà è rimasto sul disco.")), closeBtn()));
      hideTimer = setTimeout(() => render(null), 5000);
      return;
    }
    if (!outs.length) {
      const e = errs[0]?.error || "qualcosa è andato storto";
      el.append(h("div.resultbar", h("div.ic.err", ico("triangle-alert", 20)),
        h("div.tx", h("b", "Non riuscito"), h("span", capital(e))), closeBtn()));
      return;
    }
    if (job.undone) {
      el.append(h("div.resultbar", h("div.ic.ok", ico("rotate-ccw", 20)), h("div.tx", h("b", "Annullato"), h("span", "Il file creato è nel Cestino; l’originale è dov’era.")), closeBtn()));
      hideTimer = setTimeout(() => render(null), 4000);
      return;
    }
    const first = outs[0];
    const src = job.results[0];
    const canCompare = outs.length === 1 && job.results.length === 1 && src?.sourcePath && isImg(src.sourcePath) && isImg(first.path);
    let detail;
    if (job.action === "vproject" || job.action === "tts") {
      detail = h("span", `${job.action === "vproject" ? "Montaggio pronto" : "File audio pronto"} · ${fmtBytes(first.size)}`);
    } else if (outs.length === 1 && job.results.length === 1) {
      const before = job.results[0].sourceSize;
      const g = gainText(before, first.size);
      detail = g ? h("span.gain", g) : h("span", fmtBytes(first.size));
    } else {
      const total = outs.reduce((a, o) => a + o.size, 0);
      detail = h("span", `${outs.length} file creati · ${fmtBytes(total)}`);
    }
    el.append(
      h("div.resultbar", { role: "status" },
        h("div.ic.ok", ico("circle-check", 22)),
        h("div.tx", h("b", outs.length === 1 ? first.name : `Fatto: ${outs.length} file`), detail,
          errs.length ? h("span", { style: { color: "var(--err)", display: "block" } }, `${errs.length} non riusciti: ${errs[0].error}`) : null),
        h("button.btn", { onclick: () => reveal(first.path) }, ico("folder-open", 16), "Mostra nella cartella"),
        outs.length === 1 ? h("button.btn", { onclick: () => openPath(first.path) }, ico("external-link", 16), "Apri") : null,
        canCompare ? h("button.btn", { title: "Originale e risultato, con la linea da trascinare", onclick: () => openCompare({ path: src.sourcePath, size: src.sourceSize }, first) }, ico("columns-2", 16), "Confronta") : null,
        ["link", "rename"].includes(job.action) ? null : h("button.btn.ghost", { title: "Manda nel Cestino i file appena creati", onclick: () => undo(job, outs) }, ico("rotate-ccw", 16), "Annulla"),
        closeBtn()));
    if (job.state === "done") askFeedbackOnce(el.firstChild);
  }

  async function undo(job, outs) {
    try {
      await invoke("undo_result", { paths: outs.map((o) => o.path) });
      job.undone = true;
      render(job);
    } catch (e) {
      toast(String(e));
    }
  }

  function closeBtn() {
    return h("button.btn.icon.ghost", { title: "Chiudi", "aria-label": "Chiudi", onclick: () => { current = null; render(null); } }, ico("x", 16));
  }

  subscribe((job) => {
    if (!job || job.origin !== origin) return;
    current = job;
    render(job);
  });

  return { el, clear: () => render(null), get job() { return current; } };
}

function capital(s) {
  s = String(s || "");
  return s.charAt(0).toUpperCase() + s.slice(1) + (/[.!?]$/.test(s) ? "" : ".");
}
