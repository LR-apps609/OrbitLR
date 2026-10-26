// Attività, Opzioni, Aiuto e «Segnala un problema».

import { askName, presets, removePreset, renamePreset, suggestName } from "./presets.js";
import { invoke, openPath, openUrl, pickFolder, reveal } from "./api.js";
import { actionName } from "./catalog.js";
import { clearHistory, getHistory, removeFromHistory, running, subscribe, cancel } from "./jobs.js";
import { fmtBytes, gainText, h, ico, modal, store } from "./util.js";
import { install as installOffice, isInstalling, officeReady } from "./office.js";
import { t, tr, LOCALE } from "./i18n.js";

// ── Attività: in corso in cima, poi la cronologia giorno per giorno
export function activityPage() {
  const body = h("div.list");
  const el = h("div.page",
    h("div.head", h("div", h("h1", t("Attività")), h("div.sub", t("Quello che è in corso e quello che hai fatto"))), h("div.grow"),
      h("button.btn", { onclick: async () => { if (await modal(t("Cancellare la cronologia?"), t("I file creati restano dove sono: si cancella solo questo elenco."), [{ label: t("Annulla"), value: false }, { label: t("Cancella"), value: true, primary: true }])) clearHistory(); } }, ico("trash-2", 15), t("Cancella tutto"))),
    h("div.page-scroll", body));

  function jobCard(j, live) {
    const compare = j.results.length === 1 && !["vproject", "tts", "merge", "vmerge", "amerge", "pdfmerge"].includes(j.action);
    const outs = j.results.flatMap((r) => r.outputs.map((o) => ({ ...o, before: compare && r.outputs.length === 1 ? r.sourceSize : 0 })));
    const errs = j.results.filter((r) => r.error);
    const when = new Date(j.ended || j.started).toLocaleTimeString(LOCALE, { hour: "2-digit", minute: "2-digit" });
    const state = live ? h("span", { style: { color: "var(--brass)" } }, `${Math.round(j.progress * 100)}%`)
      : j.state === "cancelled" ? h("span", { style: { color: "var(--quiet)" } }, t("Interrotto"))
      : errs.length && !outs.length ? h("span", { style: { color: "var(--err)" } }, t("Non riuscito")) : null;
    return h("div.job",
      h("div.top", ico(live ? "loader-circle" : errs.length && !outs.length ? "circle-x" : "circle-check", 18, live ? "spin" : ""),
        h("b", tr(j.title) || actionName(j.action)), h("span", { style: { color: "var(--quiet)" } }, j.files.length === 1 ? j.files[0].name : j.files.length ? t`${j.files.length} file` : ""),
        state, h("span.when", when),
        live ? h("button.btn", { onclick: () => cancel(j.id) }, t("Interrompi")) : h("button.btn.icon.ghost", { "aria-label": t("Togli dalla cronologia"), title: t("Togli dalla cronologia"), onclick: () => removeFromHistory(j.id) }, ico("x", 14))),
      live ? h("div.tuner", h("div.fill", { style: { width: Math.max(2, j.progress * 100) + "%" } }), h("div.scale")) : null,
      outs.map((o) => h("div.out", ico("file", 15), h("span.n", { title: o.path }, o.name), o.before ? h("span.g", gainText(o.before, o.size)) : h("span.g", fmtBytes(o.size)),
        h("button.btn", { onclick: () => reveal(o.path) }, t("Mostra")), h("button.btn", { onclick: () => openPath(o.path) }, t("Apri")))),
      errs.map((r) => h("div.out.err", ico("triangle-alert", 15), h("span.n", `${r.source}: ${tr(r.error)}`))));
  }

  function render() {
    const live = running();
    const hist = getHistory();
    body.replaceChildren();
    if (!live.length && !hist.length) {
      body.append(h("div.empty", h("div.box", { style: { cursor: "default" } }, ico("clock", 40), h("h3", t("Niente ancora")), h("div", t("Qui trovi i lavori in corso e quelli fatti, con i file creati.")))));
      return;
    }
    live.forEach((j) => body.append(jobCard(j, true)));
    let day = "";
    for (const j of hist) {
      const d = new Date(j.ended || j.started);
      const label = sameDay(d, new Date()) ? t("Oggi") : sameDay(d, new Date(Date.now() - 864e5)) ? t("Ieri") : d.toLocaleDateString(LOCALE, { weekday: "long", day: "numeric", month: "long" });
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
      h("input", { type: "radio", name, checked: value === cur || null, onchange: async () => { await on(); render(); } }),
      h("span", h("b", { style: { display: "block" } }, label), sub ? h("span", { style: { color: "var(--quiet)", fontSize: "12.5px" } }, sub) : null));
    const gpu = (eng.h264 || []).map((e) => e.split("_")[1]).filter((x) => ["nvenc", "qsv", "amf", "mf"].includes(x));
    const gpuText = gpu.includes("nvenc") ? t("Scheda video NVIDIA") : gpu.includes("qsv") ? t("Grafica Intel") : gpu.includes("amf") ? t("Scheda video AMD") : gpu.includes("mf") ? t("Codificatore di Windows") : t("Processore (più lento)");
    el.replaceChildren(
      h("div.head", h("div", h("h1", t("Opzioni")), h("div.sub", t("Valgono subito")))),
      h("div.page-scroll", h("div.list",
        h("div.set", h("h3", t("Dove salvare i file creati")),
          radio("where", "same", where, t("Accanto all'originale"), t("Nella stessa cartella, con un nome nuovo: l'originale non si tocca mai"), () => store.set("where", "same")),
          radio("where", "downloads", where, t("Nella cartella Download"), null, async () => { const p = await invoke("places"); store.set("downloadsDir", p.downloads); store.set("where", "downloads"); render(); }),
          radio("where", "folder", where, t("In una cartella che scelgo"), folder || t("Nessuna cartella scelta"), async () => { const f = await pickFolder(); if (f) { store.set("folder", f); store.set("where", "folder"); } render(); })),
        h("div.set", h("h3", t("Lingua del parlato")), h("p", t("Per «Trascrivi» e i sottotitoli automatici. «Automatica» la riconosce da sola.")),
          h("div.opts", [["auto", t("Automatica")], ["it", "Italiano"], ["en", "English"], ["es", "Español"], ["fr", "Français"], ["de", "Deutsch"], ["pt", "Português"], ["sq", "Shqip"]].map(([v, l]) =>
            h("button.opt" + (v === store.get("voiceLang", "auto") ? ".on" : ""), { onclick: () => { store.set("voiceLang", v); render(); } }, l)))),
        h("div.set", h("h3", "Lingua · Language"),
          h("div.opts", [["auto", t("Come Windows")], ["it", "Italiano"], ["en", "English"]].map(([v, l]) =>
            h("button.opt" + (v === store.get("appLang", "auto") ? ".on" : ""), { onclick: () => { if (v === store.get("appLang", "auto")) return; store.set("appLang", v); location.reload(); } }, l)))),
        h("div.set", h("h3", t("Le mie azioni")),
          presets().length ? h("p", t("Le trovi in cima agli strumenti della scheda e come spicchi con la stella nella torta.")) : h("p", t("Nessuna ancora: apri uno strumento con delle scelte (per esempio «Comprimi»), scegli e premi «★ Salva come mia azione».")),
          ...presets().map((p) => h("div.preset-row", h("span.n", "★ " + p.name), h("span.s", suggestName(p.action, p.param)),
            h("button.btn.ghost", { onclick: async () => { const n = await askName(t("Rinomina"), p.name); if (n) { renamePreset(p.id, n); render(); } } }, t("Rinomina")),
            h("button.btn.ghost", { onclick: () => { removePreset(p.id); render(); } }, t("Togli"))))),
        h("div.set", h("h3", t("Aspetto")),
          h("div.opts", [["auto", t("Come Windows")], ["light", t("Chiaro")], ["dark", t("Radio di notte")]].map(([v, l]) =>
            h("button.opt" + (v === theme ? ".on" : ""), { onclick: () => { store.set("theme", v); app.applyTheme(); render(); } }, l)))),
        h("div.set", h("h3", t("Componenti")),
          h("p", eng.office ? t("LibreOffice è installato: Word, Excel e PowerPoint si convertono in PDF e negli altri formati.") : t("LibreOffice (facoltativo, gratuito, circa 350 MB) serve solo per Word, Excel e PowerPoint.")),
          eng.office ? null : h("div", h("button.btn.brass", { disabled: isInstalling() || null, onclick: async () => { await installOffice(app); await officeReady(app); render(); } }, ico("download", 15), isInstalling() ? t("Installazione in corso…") : t("Installa LibreOffice")))),
        h("div.set", h("h3", t("Motore")),
          h("p", eng.ready ? t`Pronto · ${String(eng.version || "").replace(/^ffmpeg version /, "ffmpeg ").split(" Copyright")[0]}` : t("Il motore video non si è avviato: reinstalla OrbitLR.")),
          eng.ready ? h("p", t`Per comprimere usa: ${gpuText}${eng.hevc?.length ? t(" · HEVC disponibile") : ""}`) : null,
          h("p", t("Tutto avviene sul tuo computer: nessun file viene caricato su internet."))))));
  }
  return { el, show: render };
}

// ── Aiuto
const FAQ = [
  ["Conversione", t("Come converto un file?"), t("Trascinalo nella finestra (anche più file o una cartella): si apre la torta con i formati. Clic sul formato, oppure il tasto con il suo numero. Il file nuovo va accanto all'originale, che non si tocca.")],
  ["Video", t("Come rendo un video più leggero senza perdere qualità?"), t("Video → scegli il video → «Comprimi» → «Stessa qualità, meno peso». OrbitLR usa la scheda video del computer (NVIDIA, Intel o AMD) quando c'è, ed è molto più veloce.")],
  ["Video", t("Devo mandare un video su WhatsApp, Discord o per email"), t("In «Comprimi» scegli WhatsApp, Discord o Email: il video starà sotto quel peso. Prima si tengono qualità e misura; la risoluzione scende solo se serve.")],
  ["Video", t("Posso lavorare film lunghi, di 2 ore o 5 GB?"), t("Sì: tutto avviene sul computer, senza caricare niente. OrbitLR controlla prima che ci sia spazio sul disco. «Taglia» su un film lungo è istantaneo perché non ricodifica.")],
  ["Video", t("Come faccio un montaggio con testi, filtri e musica?"), t("Video → «Editor» (o Ctrl+Maiusc+E): i video scelti entrano nel montaggio. In basso la sequenza: trascina i bordi per accorciare, S per dividere, il pallino tra due clip per la transizione. A destra Clip, Filtri, Effetti, Testi, Audio e Formato. Si salva da solo; «Esporta» crea il video.")],
  ["Video", t("Come taglio un video?"), t("Video → scegli il video → «Taglia». Sposta le maniglie (o usa I e O mentre guardi). Senza ricodifica il taglio è istantaneo e senza perdita; con «Taglio preciso» cade esattamente dove vuoi.")],
  ["Video", t("Come faccio un video verticale per Reels o TikTok?"), t("Video → «Formato social» → 9:16. Il video resta intero e i bordi si riempiono con lo stesso video sfocato.")],
  ["Audio", t("Come faccio una suoneria?"), t("Audio → apri la canzone → «Suoneria». Sposta il riquadro sul pezzo (fino a 30 secondi), scegli iPhone o Android e premi «Crea la suoneria».")],
  ["Audio", t("La voce si sente con un ronzio o un fruscio di fondo"), t("Scegli «Voce più pulita» (scheda Audio, o Video per l'audio dei video): attenua ronzio e fruscio costante e rende il volume uniforme. Funziona bene su ventole e condizionatori, meno su voci o musica di sottofondo.")],
  ["Immagini", t("Devo mandare una foto sotto 200 KB per un modulo"), t("Immagini → «Comprimi» → 200 KB (o scrivi il peso): OrbitLR tiene la qualità più alta possibile sotto quel peso.")],
  ["Immagini", t("Come tolgo la posizione GPS dalle foto?"), t("Immagini → «Rimuovi i metadati». Via posizione, fotocamera e date, senza perdere qualità; l'orientamento resta, così la foto non si gira.")],
  ["Immagini", t("Le foto HEIC dell'iPhone si aprono?"), t("Sì: trascinale e convertile in JPG con un clic. Se una non si apre, sull'iPhone scegli Impostazioni → Fotocamera → Formati → «Più compatibile».")],
  ["Audio", t("Come trascrivo un audio o un video?"), t("Audio (o Video) → «Trascrivi»: ottieni il testo (.txt) e i sottotitoli (.srt). Tutto sul computer; solo la prima volta si scarica il modello della voce (circa 190 MB). La lingua si sceglie in Opzioni.")],
  ["Video", t("Come aggiungo i sottotitoli automatici?"), t("Nell'editor apri «Testi» e premi «Sottotitoli automatici»: OrbitLR ascolta le clip e scrive le frasi in basso, al momento giusto, con la parola detta che si accende. Poi li correggi come gli altri testi; Ctrl+Z li toglie tutti.")],
  ["File", t("Come rendo un PDF più leggero per l'email?"), t("File → trascina il PDF → «Comprimi» → «Schermo ed email». Le foto dentro vengono ricompresse; testo, link e moduli restano come sono. Se il PDF è già leggero, OrbitLR te lo dice e non crea copie inutili.")],
  ["Generale", t("Posso far convertire o comprimere i file da soli?"), t("Sì: «Cartelle automatiche». Attiva per esempio «Foto HEIC e WebP in JPG» sulla cartella Download: ogni foto HEIC scaricata diventa JPG da sola. Per i video c'è la cartella «Da comprimere». Funziona con OrbitLR aperta, anche ridotta a icona.")],
  ["File", t("Come converto Word, Excel o PowerPoint in PDF?"), t("Trascina il documento in Conversione e scegli PDF (o DOCX, XLSX, CSV…). La prima volta OrbitLR ti propone di installare LibreOffice, gratuito: lo usa in silenzio, senza aprire finestre. Macro e collegamenti esterni dei documenti restano spenti.")],
  ["File", t("Come unisco più PDF?"), t("File → trascina i PDF → «Unisci». L'ordine è quello dell'elenco.")],
  ["Generale", t("Windows dice «Windows ha protetto il PC»"), t("Succede con le app nuove senza la firma a pagamento di Microsoft. Clicca «Ulteriori informazioni» e poi «Esegui comunque». Si fa una volta sola.")],
  ["Conversione", t("Come annullo una conversione?"), t("Nella barra del risultato, in basso, premi «Annulla»: il file appena creato va nel Cestino e l'originale resta dov'era.")],
  ["Conversione", t("Posso convertire tanti file insieme?"), t("Sì: trascina più file o una cartella intera. Con tipi diversi compare una torta per tipo; ogni file nuovo va accanto al suo originale.")],
  ["Conversione", t("Posso scegliere senza mouse?"), t("Sì: ogni spicchio ha un numero, premi il tasto. Invio ripete l'ultima scelta per quel tipo di file, Esc toglie i file.")],
  ["Conversione", t("Come salvo una scelta che uso spesso?"), t("Apri uno strumento con delle scelte (per esempio «Comprimi»), scegli e premi «★ Salva come mia azione». La ritrovi in cima agli strumenti e come spicchio con la stella nella torta. Si rinomina o si toglie nelle Opzioni.")],
  ["Conversione", t("Come confronto il risultato con l'originale?"), t("Dopo aver lavorato una foto, nella barra del risultato premi «Confronta»: originale e risultato uno sopra l'altro, con la linea da trascinare (o le frecce).")],
  ["Immagini", t("Come tolgo lo sfondo da una foto?"), t("Immagini → scegli la foto → «Rimuovi lo sfondo» → trasparente, su bianco o ritagliato. Tutto sul computer: la prima volta scarica il modello (179 MB).")],
  ["Immagini", t("Come rendo una foto più nitida o più grande?"), t("«Migliora con l'IA» la rende più pulita alla stessa misura; «Ingrandisci» la fa 2 o 4 volte più grande con i contorni nitidi. Usano la scheda video del PC; la prima volta scaricano il motore (45 MB).")],
  ["Audio", t("Come scarico una canzone o un video da un link?"), t("In Audio (o Video) incolla il link nella barra in alto a destra e premi Invio: funziona con migliaia di siti. Il file va in Download ed entra subito nella scheda. I siti protetti (Netflix, Spotify…) non si scaricano.")],
  ["Audio", t("Come prendo l'audio da un video?"), t("Trascina il video in Conversione e scegli MP3 (o M4A, WAV). Il video non si tocca.")],
  ["Audio", t("Come trasformo un testo in voce?"), t("Audio → «Testo in voce»: scrivi o incolla il testo, scegli la voce e premi «Crea il file audio». Il file MP3 va in Download. Altre voci: Impostazioni di Windows → Ora e lingua → Voce.")],
  ["File", t("Come metto una password a un PDF?"), t("File → il PDF → «Proteggi con password»: scrivi la password due volte. Cifratura AES-256. Se la dimentichi non si recupera. Per toglierla: «Togli la password».")],
  ["File", t("Come cambio l'ordine delle pagine di un PDF?"), t("File → il PDF → «Riordina le pagine» e scrivi il nuovo ordine, per esempio 3, 1, 2: le pagine che non scrivi restano dopo. «Ruota le pagine» le gira di 90° o le capovolge.")],
  ["Generale", t("Come rinomino tanti file insieme?"), t("Scegli i file in Immagini, Video o File → «Rinomina tutti»: scrivi il nome (per esempio Vacanze) e diventano Vacanze 001, Vacanze 002… in ordine di nome. Non si creano copie.")],
  ["Generale", t("Come aggiorno OrbitLR?"), t("Da sola: quando c'è una versione nuova compare in alto a destra «Nuovo aggiornamento disponibile». Un clic, e OrbitLR scarica, controlla la firma, si aggiorna e si riapre.")],
  ["Generale", t("Un lavoro non è riuscito: cosa faccio?"), t("Leggi il messaggio nella barra in basso: dice cosa è successo e cosa fare. Se non basta, premi «Segnala»: si apre un'email già pronta, senza nomi di file.")],
  ["Generale", t("Come metto OrbitLR in inglese?"), t("Opzioni → «Lingua · Language» → English. Di base OrbitLR segue la lingua di Windows.")],
  ["Generale", t("I miei file vengono caricati su internet?"), t("No. OrbitLR lavora tutto sul tuo computer, anche senza connessione.")],
];

export function helpPage(app) {
  const list = h("div", { style: { display: "grid", gap: "8px" } });
  const input = h("input", { type: "search", placeholder: t("Cerca: «suoneria», «WhatsApp», «GPS»…"), "aria-label": t("Cerca nell'aiuto") });
  const norm = (s) => s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");
  function render() {
    const q = norm(input.value.trim());
    const items = FAQ.filter(([s, a, b]) => !q || norm(t(s) + " " + a + " " + b).includes(q));
    list.replaceChildren(...(items.length ? items.map(([s, a, b]) => h("details.faq", h("summary", ico("chevron-right", 16), a, h("span", { style: { marginLeft: "auto", fontSize: "11px", color: "var(--brass)", fontWeight: 900, textTransform: "uppercase" } }, t(s))), h("p", b)))
      : [h("p", { style: { color: "var(--quiet)" } }, t("Nessuna risposta: prova un'altra parola, oppure «Segnala» e scrivici."))]));
  }
  input.addEventListener("input", render);
  render();
  const el = h("div.page", h("div.head", h("div", h("h1", t("Aiuto")), h("div.sub", t("Le domande più frequenti")))), h("div.page-scroll", h("div.search", ico("search", 16), input), list));
  return { el, show() { input.focus(); } };
}

/** «Segnala»: una email già pronta, senza nomi di file né percorsi. */
export async function report(app) {
  const ok = await modal(t("Segnala un problema"), t("Si apre un'email già pronta con la versione di OrbitLR e del motore. Non contiene nomi di file né percorsi: scrivi tu cosa è successo."), [{ label: t("Annulla"), value: false }, { label: t("Scrivi l'email"), value: true, primary: true }]);
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
