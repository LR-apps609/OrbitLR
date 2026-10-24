// Attività, Opzioni, Aiuto e «Segnala un problema».

import { invoke, openPath, openUrl, pickFolder, reveal } from "./api.js";
import { actionName } from "./catalog.js";
import { clearHistory, getHistory, removeFromHistory, running, subscribe, cancel } from "./jobs.js";
import { fmtBytes, gainText, h, ico, modal, store } from "./util.js";

// ── Attività: in corso in cima, poi la cronologia giorno per giorno
export function activityPage() {
  const body = h("div.list");
  const el = h("div.page",
    h("div.head", h("div", h("h1", "Attività"), h("div.sub", "Quello che è in corso e quello che hai fatto")), h("div.grow"),
      h("button.btn", { onclick: async () => { if (await modal("Cancellare la cronologia?", "I file creati restano dove sono: si cancella solo questo elenco.", [{ label: "Annulla", value: false }, { label: "Cancella", value: true, primary: true }])) clearHistory(); } }, ico("trash-2", 15), "Cancella tutto")),
    h("div.page-scroll", body));

  function jobCard(j, live) {
    const outs = j.results.flatMap((r) => r.outputs.map((o) => ({ ...o, before: j.results.length === 1 && r.outputs.length === 1 ? r.sourceSize : 0 })));
    const errs = j.results.filter((r) => r.error);
    const when = new Date(j.ended || j.started).toLocaleTimeString("it-IT", { hour: "2-digit", minute: "2-digit" });
    const state = live ? h("span", { style: { color: "var(--brass)" } }, `${Math.round(j.progress * 100)}%`)
      : j.state === "cancelled" ? h("span", { style: { color: "var(--quiet)" } }, "Interrotto")
      : errs.length && !outs.length ? h("span", { style: { color: "var(--err)" } }, "Non riuscito") : null;
    return h("div.job",
      h("div.top", ico(live ? "loader-circle" : errs.length && !outs.length ? "circle-x" : "circle-check", 18, live ? "spin" : ""),
        h("b", j.title || actionName(j.action)), h("span", { style: { color: "var(--quiet)" } }, j.files.length === 1 ? j.files[0].name : `${j.files.length} file`),
        state, h("span.when", when),
        live ? h("button.btn", { onclick: () => cancel(j.id) }, "Interrompi") : h("button.btn.icon.ghost", { "aria-label": "Togli dalla cronologia", title: "Togli dalla cronologia", onclick: () => removeFromHistory(j.id) }, ico("x", 14))),
      live ? h("div.tuner", h("div.fill", { style: { width: Math.max(2, j.progress * 100) + "%" } }), h("div.scale")) : null,
      outs.map((o) => h("div.out", ico("file", 15), h("span.n", { title: o.path }, o.name), o.before ? h("span.g", gainText(o.before, o.size)) : h("span.g", fmtBytes(o.size)),
        h("button.btn", { onclick: () => reveal(o.path) }, "Mostra"), h("button.btn", { onclick: () => openPath(o.path) }, "Apri"))),
      errs.map((r) => h("div.out.err", ico("triangle-alert", 15), h("span.n", `${r.source}: ${r.error}`))));
  }

  function render() {
    const live = running();
    const hist = getHistory();
    body.replaceChildren();
    if (!live.length && !hist.length) {
      body.append(h("div.empty", h("div.box", { style: { cursor: "default" } }, ico("clock", 40), h("h3", "Niente ancora"), h("div", "Qui trovi i lavori in corso e quelli fatti, con i file creati."))));
      return;
    }
    live.forEach((j) => body.append(jobCard(j, true)));
    let day = "";
    for (const j of hist) {
      const d = new Date(j.ended || j.started);
      const label = sameDay(d, new Date()) ? "Oggi" : sameDay(d, new Date(Date.now() - 864e5)) ? "Ieri" : d.toLocaleDateString("it-IT", { weekday: "long", day: "numeric", month: "long" });
      if (label !== day) {
        day = label;
        body.append(h("div.day", label));
      }
      body.append(jobCard(j, false));
    }
  }
  let pending = 0;
  subscribe(() => {
    if (!el.isConnected) return;
    cancelAnimationFrame(pending);
    pending = requestAnimationFrame(render);
  });
  return { el, show: render };
}

function sameDay(a, b) {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

// ── Opzioni: si applicano subito
export function settingsPage(app) {
  const el = h("div.page");
  async function render() {
    const where = store.get("where", "same");
    const theme = store.get("theme", "auto");
    const eng = app.engine || {};
    const folder = store.get("folder", null);
    const radio = (name, value, cur, label, sub, on) => h("label.check", { style: { alignItems: "flex-start" } },
      h("input", { type: "radio", name, checked: value === cur || null, onchange: () => { on(); render(); } }),
      h("span", h("b", { style: { display: "block" } }, label), sub ? h("span", { style: { color: "var(--quiet)", fontSize: "12.5px" } }, sub) : null));
    const gpu = (eng.h264 || []).map((e) => e.split("_")[1]).filter((x) => ["nvenc", "qsv", "amf", "mf"].includes(x));
    const gpuText = gpu.includes("nvenc") ? "Scheda video NVIDIA" : gpu.includes("qsv") ? "Grafica Intel" : gpu.includes("amf") ? "Scheda video AMD" : gpu.includes("mf") ? "Codificatore di Windows" : "Processore (più lento)";
    el.replaceChildren(
      h("div.head", h("div", h("h1", "Opzioni"), h("div.sub", "Valgono subito"))),
      h("div.page-scroll", h("div.list",
        h("div.set", h("h3", "Dove salvare i file creati"),
          radio("where", "same", where, "Accanto all'originale", "Nella stessa cartella, con un nome nuovo: l'originale non si tocca mai", () => store.set("where", "same")),
          radio("where", "downloads", where, "Nella cartella Download", null, async () => { const p = await invoke("places"); store.set("downloadsDir", p.downloads); store.set("where", "downloads"); }),
          radio("where", "folder", where, "In una cartella che scelgo", folder || "Nessuna cartella scelta", async () => { const f = await pickFolder(); if (f) { store.set("folder", f); store.set("where", "folder"); } render(); })),
        h("div.set", h("h3", "Aspetto"),
          h("div.opts", [["auto", "Come Windows"], ["light", "Chiaro"], ["dark", "Radio di notte"]].map(([v, l]) =>
            h("button.opt" + (v === theme ? ".on" : ""), { onclick: () => { store.set("theme", v); app.applyTheme(); render(); } }, l)))),
        h("div.set", h("h3", "Motore"),
          h("p", eng.ready ? `Pronto · ${String(eng.version || "").replace(/^ffmpeg version /, "ffmpeg ").split(" Copyright")[0]}` : "Il motore video non si è avviato: reinstalla OrbitLR."),
          eng.ready ? h("p", `Per comprimere usa: ${gpuText}${eng.hevc?.length ? " · HEVC disponibile" : ""}`) : null,
          h("p", "Tutto avviene sul tuo computer: nessun file viene caricato su internet.")))));
  }
  return { el, show: render };
}

// ── Aiuto
const FAQ = [
  ["Conversione", "Come converto un file?", "Trascinalo nella finestra (anche più file o una cartella): si apre la torta con i formati. Clic sul formato, oppure il tasto con il suo numero. Il file nuovo va accanto all'originale, che non si tocca."],
  ["Video", "Come rendo un video più leggero senza perdere qualità?", "Video → scegli il video → «Comprimi» → «Stessa qualità, meno peso». OrbitLR usa la scheda video del computer (NVIDIA, Intel o AMD) quando c'è, ed è molto più veloce."],
  ["Video", "Devo mandare un video su WhatsApp, Discord o per email", "In «Comprimi» scegli WhatsApp, Discord o Email: il video starà sotto quel peso. Prima si tengono qualità e misura; la risoluzione scende solo se serve."],
  ["Video", "Posso lavorare film lunghi, di 2 ore o 5 GB?", "Sì: tutto avviene sul computer, senza caricare niente. OrbitLR controlla prima che ci sia spazio sul disco. «Taglia» su un film lungo è istantaneo perché non ricodifica."],
  ["Video", "Come taglio un video?", "Video → scegli il video → «Taglia». Sposta le maniglie (o usa I e O mentre guardi). Senza ricodifica il taglio è istantaneo e senza perdita; con «Taglio preciso» cade esattamente dove vuoi."],
  ["Video", "Come faccio un video verticale per Reels o TikTok?", "Video → «Formato social» → 9:16. Il video resta intero e i bordi si riempiono con lo stesso video sfocato."],
  ["Audio", "Come faccio una suoneria?", "Audio → apri la canzone → «Suoneria». Sposta il riquadro sul pezzo (fino a 30 secondi), scegli iPhone o Android e premi «Crea la suoneria»."],
  ["Audio", "La voce si sente con un ronzio o un fruscio di fondo", "Scegli «Voce più pulita» (scheda Audio, o Video per l'audio dei video): attenua ronzio e fruscio costante e rende il volume uniforme. Funziona bene su ventole e condizionatori, meno su voci o musica di sottofondo."],
  ["Immagini", "Devo mandare una foto sotto 200 KB per un modulo", "Immagini → «Comprimi» → 200 KB (o scrivi il peso): OrbitLR tiene la qualità più alta possibile sotto quel peso."],
  ["Immagini", "Come tolgo la posizione GPS dalle foto?", "Immagini → «Rimuovi i metadati». Via posizione, fotocamera e date, senza perdere qualità; l'orientamento resta, così la foto non si gira."],
  ["Immagini", "Le foto HEIC dell'iPhone si aprono?", "Sì: trascinale e convertile in JPG con un clic. Se una non si apre, sull'iPhone scegli Impostazioni → Fotocamera → Formati → «Più compatibile»."],
  ["File", "Come unisco più PDF?", "File → trascina i PDF → «Unisci». L'ordine è quello dell'elenco."],
  ["Generale", "Windows dice «Windows ha protetto il PC»", "Succede con le app nuove senza la firma a pagamento di Microsoft. Clicca «Ulteriori informazioni» e poi «Esegui comunque». Si fa una volta sola."],
  ["Generale", "I miei file vengono caricati su internet?", "No. OrbitLR lavora tutto sul tuo computer, anche senza connessione."],
];

export function helpPage(app) {
  const list = h("div", { style: { display: "grid", gap: "8px" } });
  const input = h("input", { type: "search", placeholder: "Cerca: «suoneria», «WhatsApp», «GPS»…", "aria-label": "Cerca nell'aiuto" });
  const norm = (s) => s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");
  function render() {
    const q = norm(input.value.trim());
    const items = FAQ.filter(([s, a, b]) => !q || norm(s + " " + a + " " + b).includes(q));
    list.replaceChildren(...(items.length ? items.map(([s, a, b]) => h("details.faq", h("summary", ico("chevron-right", 16), a, h("span", { style: { marginLeft: "auto", fontSize: "11px", color: "var(--brass)", fontWeight: 900, textTransform: "uppercase" } }, s)), h("p", b)))
      : [h("p", { style: { color: "var(--quiet)" } }, "Nessuna risposta: prova un'altra parola, oppure «Segnala» e scrivici.")]));
  }
  input.addEventListener("input", render);
  render();
  const el = h("div.page", h("div.head", h("div", h("h1", "Aiuto"), h("div.sub", "Le domande più frequenti"))), h("div.page-scroll", h("div.search", ico("search", 16), input), list));
  return { el, show() { input.focus(); } };
}

/** «Segnala»: una email già pronta, senza nomi di file né percorsi. */
export async function report(app) {
  const ok = await modal("Segnala un problema", "Si apre un'email già pronta con la versione di OrbitLR e del motore. Non contiene nomi di file né percorsi: scrivi tu cosa è successo.", [{ label: "Annulla", value: false }, { label: "Scrivi l'email", value: true, primary: true }]);
  if (!ok) return;
  const eng = app.engine || {};
  const body = [
    "Cosa stavo facendo:",
    "",
    "Cosa è successo:",
    "",
    "---",
    `OrbitLR per Windows ${app.version}`,
    `Motore: ${eng.ready ? String(eng.version).split(" Copyright")[0] : "non avviato"}`,
    `Codificatori: ${(eng.h264 || []).join(", ") || "nessuno"}`,
    `Sistema: ${navigator.userAgent.match(/Windows NT [\d.]+/)?.[0] || navigator.platform}`,
  ].join("\n");
  openUrl(`mailto:ledion.proaccs@gmail.com?subject=${encodeURIComponent("OrbitLR per Windows: un problema")}&body=${encodeURIComponent(body)}`);
}
