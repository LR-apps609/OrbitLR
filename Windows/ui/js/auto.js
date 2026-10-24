// Cartelle automatiche: OrbitLR lavora da sola i file nuovi che arrivano in alcune cartelle.
// Il controllo lo fa il motore (ogni 3 secondi, con OrbitLR aperta); qui si scelgono cartelle e opzioni.

import { invoke, pickFolder, reveal } from "./api.js";
import { h, ico, toast } from "./util.js";

const KINDS = [
  {
    kind: "foto",
    icon: "image",
    title: "Foto HEIC e WebP in JPG",
    text: "Le foto dell'iPhone (HEIC) e le immagini WebP scaricate diventano JPG da sole, con posizione e data. Il JPG va accanto all'originale.",
    where: (p) => p.downloads,
    whereLabel: "Download",
  },
  {
    kind: "video",
    icon: "film",
    title: "Video da comprimere",
    text: "Metti un video nella cartella: si alleggerisce da solo. Il video leggero va nella sottocartella «Compressi», l'originale resta dov'è.",
    where: (p) => (p.videos ? p.videos + "\\Da comprimere" : null),
    whereLabel: "Video\\Da comprimere",
    options: [["best", "Stessa qualità, meno peso"], ["15", "WhatsApp"], ["9", "Discord"], ["18", "Email"]],
  },
  {
    kind: "pdf",
    icon: "file-text",
    title: "PDF da comprimere",
    text: "I PDF messi nella cartella diventano leggeri per l'email (testo e link intatti). Vanno nella sottocartella «Compressi».",
    where: (p) => (p.documents ? p.documents + "\\PDF da comprimere" : null),
    whereLabel: "Documenti\\PDF da comprimere",
    options: [["medium", "Schermo ed email"], ["light", "Leggera"], ["strong", "Forte"]],
  },
];

export function autoPage() {
  const list = h("div.list");
  const el = h("div.page",
    h("div.head", h("div", h("h1", "Cartelle automatiche"), h("div.sub", "File nuovi in una cartella → lavorati da soli"))),
    h("div.page-scroll", list));
  let rules = [];

  async function save(next) {
    try {
      rules = await invoke("watch_set", { rules: next });
    } catch (e) {
      toast(String(e));
    }
    render();
  }

  function card(k) {
    const r = rules.find((x) => x.kind === k.kind);
    const set = (patch) => save(rules.map((x) => (x.kind === k.kind ? { ...x, ...patch } : x)));
    const head = h("div.top", ico(k.icon, 20), h("b", k.title), h("div.grow"),
      r ? h("label.check", h("input", { type: "checkbox", checked: r.enabled || null, onchange: (e) => set({ enabled: e.target.checked }) }), r.enabled ? "Attiva" : "Spenta") : null);
    const body = [h("p", k.text)];
    if (!r) {
      body.push(h("div.acts",
        h("button.btn.brass", {
          onclick: async () => {
            const places = await invoke("places");
            const path = k.where(places) || (await pickFolder());
            if (!path) return;
            await save([...rules, { id: k.kind, kind: k.kind, path, param: k.options?.[0][0] || "", enabled: true }]);
            toast(`Attiva: ${k.title}`);
          },
        }, ico("check", 15), `Attiva su «${k.whereLabel}»`),
        h("button.btn", {
          onclick: async () => {
            const path = await pickFolder();
            if (path) await save([...rules, { id: k.kind, kind: k.kind, path, param: k.options?.[0][0] || "", enabled: true }]);
          },
        }, ico("folder-open", 15), "Scegli un'altra cartella")));
    } else {
      body.push(h("div.out", ico("folder-input", 15), h("span.n", { title: r.path }, r.path),
        h("button.btn", { onclick: () => reveal(r.path) }, "Mostra"),
        h("button.btn", { onclick: async () => { const p = await pickFolder(); if (p) set({ path: p }); } }, "Cambia"),
        h("button.btn.icon.ghost", { "aria-label": "Togli", title: "Togli questa cartella automatica", onclick: () => save(rules.filter((x) => x.kind !== k.kind)) }, ico("x", 14))));
      if (k.options) {
        body.push(h("div.opts", k.options.map(([v, l]) => h("button.opt" + ((r.param || k.options[0][0]) === v ? ".on" : ""), { onclick: () => set({ param: v }) }, l))));
      }
    }
    return h("div.set.auto" + (r?.enabled ? ".on" : ""), head, ...body);
  }

  function render() {
    list.replaceChildren(
      ...KINDS.map(card),
      h("div.set", h("h3", "Come funziona"),
        h("p", "OrbitLR controlla le cartelle ogni pochi secondi mentre è aperta (anche ridotta a icona). Prende solo i file arrivati dopo l'attivazione, e solo quando hanno finito di scaricarsi o copiarsi."),
        h("p", "Ogni lavoro compare in Attività, come quelli fatti a mano. Gli originali non si toccano mai.")));
  }

  return {
    el,
    async show() {
      try {
        rules = await invoke("watch_get");
      } catch {
        rules = [];
      }
      render();
    },
  };
}
