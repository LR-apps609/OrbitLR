// Scheda Audio: come su Mac. A sinistra la forma d'onda con le maniglie, a destra gli strumenti.

import { invoke, pickFiles, setDemoPick } from "./api.js";
import { run } from "./jobs.js";
import { resultBar } from "./resultbar.js";
import { createTrim } from "./trim.js";
import { downloaderBar } from "./downloader.js";
import { fmtBytes, fmtTime, h, ico, store, toast } from "./util.js";
import { t, tr } from "./i18n.js";

const TOOLS = [
  { id: "ringtone", title: t("Suoneria iPhone"), short: t("Suoneria"), icon: "bell-ring", hint: t("Sposta il riquadro sul pezzo che ti piace (fino a 30 secondi): ottieni la suoneria per iPhone o Android."), go: t("Crea la suoneria"), sel: true },
  { id: "cut", title: t("Taglia"), short: t("Taglia"), icon: "scissors", hint: t("Trascina le maniglie per tenere solo il pezzo che serve. Tasti I e O mentre ascolti."), go: t("Taglia"), sel: true },
  { id: "normalize", title: t("Volume uniforme"), short: t("Volume"), icon: "volume-2", hint: t("Rende il volume uniforme: né troppo basso né distorto. Per vocali, lezioni e podcast."), go: t("Rendi uniforme il volume") },
  { id: "voiceclean", title: t("Voce più pulita"), short: t("Pulisci"), icon: "mic", hint: t("Attenua il ronzio e il fruscio di fondo e rende il volume uniforme. La voce resta naturale."), go: t("Pulisci la voce") },
  { id: "speed", title: t("Velocità"), short: t("Velocità"), icon: "gauge", hint: t("Più lento o più veloce, su tutto il file. La voce mantiene il suo tono."), go: t("Cambia la velocità") },
  { id: "silence", title: t("Togli i silenzi"), short: t("Silenzi"), icon: "audio-waveform", hint: t("Toglie le pause lunghe, su tutto il file. Ottimo per lezioni e registrazioni."), go: t("Togli i silenzi") },
  { id: "whatsapp", title: t("Per WhatsApp"), short: "WhatsApp", icon: "smartphone", hint: t("Un vocale leggero con la voce chiara, che parte subito anche con poca rete."), go: t("Crea il vocale") },
  { id: "merge", title: t("Unisci"), short: t("Unisci"), icon: "combine", hint: t("Più file audio in uno solo, nell'ordine dell'elenco."), go: t("Unisci") },
  { id: "transcribe", title: t("Trascrivi"), short: t("Trascrivi"), icon: "file-text", hint: t("Le parole diventano testo (.txt) e sottotitoli (.srt), sul computer. La prima volta scarica il modello della voce (circa 190 MB), poi funziona senza internet."), go: t("Trascrivi") },
  { id: "tts", title: t("Testo in voce"), short: t("Voce"), icon: "message-circle", hint: t("Scrivi o incolla un testo: una voce di Windows lo legge in un file MP3 (in Download)."), go: t("Crea il file audio"), noFile: true },
  { id: "convert", title: t("Converti"), short: t("Converti"), icon: "arrow-left-right", hint: t("In un altro formato. MP3 va ovunque; WAV e FLAC non perdono niente."), go: t("Converti") },
];

export function audioPage(app) {
  let file = null; // {path,name,size,info}
  let others = []; // per «Unisci»
  let tool = store.get("audio.tool", "ringtone");
  let trim = null;
  const opts = {
    ringLen: store.get("audio.ringLen", 30), fade: true, normalize: true, ringFmt: store.get("audio.ringFmt", "m4r"),
    speed: "1.5", to: "mp3", text: "", voice: store.get("audio.voice", ""), rate: 0,
  };
  let voices = null;
  const bar = resultBar("audio");
  const el = h("div.page");
  // Il file scaricato arriva qui, pronto da tagliare o da trasformare in suoneria
  const dl = downloaderBar({ video: false, onFile: (p) => { if (tool === "tts") tool = "ringtone"; add([p]); } });

  async function add(paths) {
    const probed = await invoke("probe_files", { paths });
    const ok = probed.filter((p) => p.ok && p.info.has_audio !== false && (p.info.kind === "audio" || p.info.kind === "video"));
    const bad = probed.filter((p) => !p.ok);
    if (bad.length) toast(tr(bad[0].error));
    if (!ok.length) {
      if (!bad.length) toast(t("Nessun audio in questi file."));
      return;
    }
    const items = ok.map((p) => ({ path: p.info.path, name: p.info.name, size: p.info.size, info: p.info }));
    if (tool === "merge" && file) {
      others.push(...items.filter((i) => i.path !== file.path && !others.some((o) => o.path === i.path)));
    } else {
      setFile(items[0]);
      others = items.slice(1);
      if (others.length) tool = "merge";
    }
    render();
  }

  function setFile(f) {
    trim?.destroy();
    file = f;
    trim = createTrim({ path: f.path, duration: Math.max(0.1, f.info.duration), media: "audio", maxLen: tool === "ringtone" ? opts.ringLen : 0 });
    const t = trim;
    invoke("waveform", { path: f.path, points: 900 }).then((p) => { if (trim === t && file === f) trim.setPeaks(p); }).catch(() => {});
  }

  async function pick() {
    setDemoPick("audio");
    const p = await pickFiles([{ name: t("Audio"), extensions: ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aac", "wma", "aiff", "m4b", "amr", "mp4", "mov", "mkv"] }]);
    if (p.length) add(p);
  }

  function start() {
    if (tool === "tts") {
      if (!opts.text.trim()) return toast(t("Scrivi o incolla un testo."));
      store.set("audio.voice", opts.voice);
      return run("tts", [], { text: opts.text, voice: opts.voice, rate: opts.rate }, "audio");
    }
    if (!file) return pick();
    const tl = TOOLS.find((x) => x.id === tool);
    const sel = { start: +trim.start.toFixed(3), end: +trim.end.toFixed(3) };
    switch (tool) {
      case "ringtone": return run("ringtone", [file], { ...sel, fade: opts.fade, normalize: opts.normalize, format: opts.ringFmt }, "audio");
      // Dalla scheda Audio esce sempre un audio, anche partendo da un video
      case "cut": return run("cut", [file], { ...sel, audio: true }, "audio");
      case "speed": return run("speed", [file], { factor: Number(opts.speed), audio: true }, "audio");
      case "merge":
        if (!others.length) return toast(t("Aggiungi almeno un altro file da unire."));
        return run("amerge", [file, ...others], null, "audio");
      case "convert": return run("to:" + opts.to, [file], null, "audio");
      case "transcribe": return run("transcribe", [file], { lang: store.get("voiceLang", "auto") }, "audio");
      default: return run(tl.id, [file], null, "audio");
    }
  }

  function chips(list, value, set) {
    return h("div.opts", list.map(([v, label]) => h("button.opt" + (v === value ? ".on" : ""), { onclick: () => { set(v); render(); } }, label)));
  }

  function options() {
    const tl = TOOLS.find((x) => x.id === tool);
    const box = [h("div.group", tl.title), h("p.hint", { style: { margin: 0, color: "var(--quiet)", fontSize: "13px" } }, tl.hint)];
    if (tool === "ringtone") {
      box.push(
        h("div", { style: { fontSize: "12.5px", color: "var(--quiet)" } }, t("Durata")),
        chips([[20, t("20 secondi")], [30, t("30 secondi")]], opts.ringLen, (v) => { opts.ringLen = v; store.set("audio.ringLen", v); trim?.setMaxLen(v); }),
        h("div", { style: { fontSize: "12.5px", color: "var(--quiet)" } }, t("Per")),
        chips([["m4r", "iPhone (.m4r)"], ["mp3", "Android (.mp3)"]], opts.ringFmt, (v) => { opts.ringFmt = v; store.set("audio.ringFmt", v); }),
        h("label.check", h("input", { type: "checkbox", checked: opts.fade || null, onchange: (e) => (opts.fade = e.target.checked) }), t("Dissolvenza all'inizio e alla fine")),
        h("label.check", h("input", { type: "checkbox", checked: opts.normalize || null, onchange: (e) => (opts.normalize = e.target.checked) }), t("Volume uniforme")),
        h("p", { style: { margin: 0, fontSize: "12.5px", color: "var(--quiet)" } }, t("Su iPhone: apri il file .m4r con iTunes o l'app Dispositivi Apple e trascinalo nelle Suonerie. Su Android: copialo nella cartella «Ringtones».")));
    } else if (tool === "speed") {
      box.push(chips([["0.5", t("0,5×")], ["0.75", t("0,75×")], ["1.25", t("1,25×")], ["1.5", t("1,5×")], ["2", "2×"]], opts.speed, (v) => (opts.speed = v)));
      if (file) box.push(h("p", { style: { margin: 0, fontSize: "12.5px", color: "var(--quiet)" } }, t`Su tutto il file: da ${fmtTime(file.info.duration)} a circa ${fmtTime(file.info.duration / Number(opts.speed))}.`));
    } else if (tool === "tts") {
      if (voices === null) {
        voices = [];
        invoke("voices").then((v) => { voices = v || []; render(); }).catch(() => {});
      }
      const sel = h("select", { style: { width: "100%", padding: "7px", borderRadius: "10px", border: "1px solid var(--line-2)", background: "var(--card)", fontWeight: 700 } },
        h("option", { value: "" }, t("La voce predefinita di Windows")),
        voices.map((v) => h("option", { value: v.name, selected: v.name === opts.voice || null }, `${v.name.replace(/^Microsoft /, "").replace(/ Desktop$/, "")} · ${v.culture}`)));
      sel.addEventListener("change", () => (opts.voice = sel.value));
      const rate = h("input", { type: "range", min: -5, max: 5, step: 1, value: opts.rate, style: { width: "100%", accentColor: "var(--sage-deep)" } });
      rate.addEventListener("input", () => (opts.rate = Number(rate.value)));
      box.push(h("div", { style: { fontSize: "12.5px", color: "var(--quiet)" } }, t("Voce")), sel,
        h("div", { style: { fontSize: "12.5px", color: "var(--quiet)" } }, t("Velocità")), rate,
        h("p", { style: { margin: 0, fontSize: "12.5px", color: "var(--quiet)" } }, t("Altre voci italiane: Impostazioni di Windows → Ora e lingua → Voce → Aggiungi voci.")));
    } else if (tool === "convert") {
      box.push(chips([["mp3", "MP3"], ["m4a", "M4A"], ["wav", "WAV"], ["flac", "FLAC"], ["ogg", "OGG"], ["opus", "OPUS"]], opts.to, (v) => (opts.to = v)));
    } else if (tool === "merge") {
      const list = [file, ...others].filter(Boolean);
      box.push(h("div", { style: { display: "grid", gap: "4px" } }, list.map((f, i) => h("div", { style: { display: "flex", gap: "8px", alignItems: "center", fontSize: "13px" } },
        h("b", { style: { color: "var(--brass)", width: "18px" } }, String(i + 1)),
        h("span", { style: { flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" } }, f.name),
        i > 0 ? h("button.btn.icon.ghost", { "aria-label": t("Togli"), onclick: () => { others = others.filter((o) => o !== f); render(); } }, ico("x", 14)) : null))),
        h("button.btn", { onclick: async () => { setDemoPick("audio"); const p = await pickFiles([{ name: t("Audio"), extensions: ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aac", "wma"] }]); if (p.length) add(p); } }, ico("plus", 14), t("Aggiungi file")));
    }
    return box;
  }

  function render() {
    store.set("audio.tool", tool);
    if (trim) trim.setMaxLen(tool === "ringtone" ? opts.ringLen : 0);
    const tl = TOOLS.find((x) => x.id === tool);
    const head = h("div.head",
      h("div", h("h1", tool === "tts" ? t("Testo in voce") : file ? file.name.replace(/\.[^.]+$/, "") : t("Audio")),
        h("div.sub", file ? `${file.info.ext.toUpperCase()} · ${fmtTime(file.info.duration)} · ${fmtBytes(file.size)}` : t("Suonerie, tagli, volume, voce pulita e altro"))),
      h("div.grow"),
      dl,
      file ? h("button.btn", { onclick: pick }, t("Apri un altro…")) : null,
      file ? h("button.btn.icon", { "aria-label": t("Chiudi il file"), onclick: () => { trim?.destroy(); trim = null; file = null; others = []; render(); } }, ico("x", 16)) : null);
    let leftSide;
    if (tool === "tts") {
      const ta = h("textarea.tts", { placeholder: t("Scrivi o incolla qui il testo da leggere…"), "aria-label": t("Testo da leggere") });
      ta.value = opts.text;
      const count = h("div", { style: { fontSize: "12.5px", color: "var(--quiet)", textAlign: "right" } });
      const upd = () => {
        const w = opts.text.trim() ? opts.text.trim().split(/\s+/).length : 0;
        count.textContent = w ? t`${w} ${w === 1 ? t("parola") : t("parole")} · ${w < 140 ? t("meno di un minuto") : t`circa ${Math.round(w / 150)} min`} di audio` : "";
      };
      ta.addEventListener("input", () => { opts.text = ta.value; upd(); });
      upd();
      leftSide = h("div.wave-card", ta, count);
      setTimeout(() => ta.focus(), 50);
    } else leftSide = file
      ? h("div.wave-card", trim.el)
      : h("div.empty", h("div.box", { role: "button", tabindex: "0", onclick: pick }, ico("audio-lines", 44), h("h3", t("Trascina qui un file audio")), h("div", t("oppure clicca per sceglierlo")), h("div", { style: { fontSize: "12.5px" } }, t("MP3, M4A, WAV, FLAC, OGG e anche l'audio dei video"))));
    const grid = h("div.tool-grid", TOOLS.map((x) => h("button.tg" + (x.id === tool ? ".on" : ""), { onclick: () => { tool = x.id; render(); }, "aria-pressed": x.id === tool ? "true" : "false" }, ico(x.icon, 20), x.short)));
    const side = h("div.side-card",
      h("div.scroll", grid, ...options()),
      h("div.act", h("button.btn.primary.big", { onclick: start, disabled: (!file && !tl.noFile) || (tool === "merge" && !others.length) || null }, tl.go)));
    el.replaceChildren(head, h("div.audio-wrap", leftSide, side), bar.el);
  }

  render();
  return { el, add, kind: "audio", show() {} };
}
