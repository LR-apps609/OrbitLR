// La barra in basso: avanzamento con la scala della radio, poi il risultato con quanto si è guadagnato.

import { cancel, subscribe } from "./jobs.js";
import { openPath, reveal } from "./api.js";
import { fmtBytes, gainText, h, ico } from "./util.js";

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
            h("b", `${job.title} · ${n > 1 ? `${n} file` : job.files[0]?.name}`),
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
    const first = outs[0];
    let detail;
    if (outs.length === 1 && job.results.length === 1) {
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
        closeBtn()));
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
