// Schede Immagini, Video e File: i file a sinistra, a destra «Cosa vuoi fare?».
// Un clic su uno strumento senza scelte lo fa partire subito; con le scelte apre il riquadro sotto.

import { invoke, pickFiles, setDemoPick } from "./api.js";
import { AI_LOGO, CONVERT, GROUPS, KINDS, TOOLS, fmtIcon } from "./catalog.js";
import { run } from "./jobs.js";
import { imageEstimate, knobPanel, videoEstimate } from "./params.js";
import { resultBar } from "./resultbar.js";
import { createTrim } from "./trim.js";
import { createZones } from "./zones.js";
import { downloaderBar } from "./downloader.js";
import { openPdfEditor } from "./pdfeditor.js";
import { addPreset, askName, presets, runSteps, suggestName } from "./presets.js";
import { subscribe } from "./jobs.js";
import { fmtBytes, fmtTime, h, ico, store, toast } from "./util.js";
import { t, tr, tc } from "./i18n.js";

const COPY = {
  image: { title: t("Immagini"), one: tc("one", "foto"), many: tc("many", "foto"), empty: t("Trascina qui le foto"), emptySub: t("JPG, PNG, HEIC dell'iPhone, WebP, AVIF e altre"), filters: [{ name: t("Immagini"), extensions: ["jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "gif", "bmp", "tif", "tiff", "ico", "jfif"] }] },
  video: { title: t("Video"), one: tc("one", "video"), many: tc("many", "video"), empty: t("Trascina qui i video"), emptySub: t("MP4, MOV dell'iPhone, MKV, AVI, WebM e altri. Anche film di ore: si lavorano sul computer."), filters: [{ name: t("Video"), extensions: ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "ts", "mts", "m2ts", "3gp"] }] },
  pdf: { title: t("File"), one: "PDF", many: "PDF", empty: t("Trascina qui i PDF"), emptySub: t("Unisci, dividi ed estrai pagine. Word, Excel e PowerPoint arriveranno con un componente facoltativo."), filters: [{ name: "PDF", extensions: ["pdf"] }] },
};

export function mediaPage(kind, app, opts = {}) {
  const c = COPY[kind];
  let files = [];
  let selected = new Set();
  let openTool = null;
  let trim = null;

  const bar = resultBar(kind);
  // Video: il video scaricato da un link arriva nell'elenco, pronto da tagliare, comprimere o montare
  const dl = kind === "video" ? downloaderBar({ video: true, onFile: (p) => add([p]) }) : null;
  const head = h("div.head");
  const grid = h("div.grid");
  const left = h("div.files");
  const right = h("div.tools-scroll");
  const el = h("div.page", h("div.split", left, h("div.tools", right)));

  function targets() {
    return selected.size ? files.filter((f) => selected.has(f.path)) : files;
  }

  async function add(paths) {
    const fresh = paths.filter((p) => !files.some((f) => f.path === p));
    if (!fresh.length) return;
    const probed = await invoke("probe_files", { paths: fresh });
    let skipped = 0;
    for (const p of probed) {
      if (!p.ok) {
        toast(tr(p.error));
        continue;
      }
      const k = p.info.kind;
      if (k !== kind) {
        skipped++;
        continue;
      }
      files.push({ path: p.info.path, name: p.info.name, size: p.info.size, info: p.info, thumb: null });
    }
    if (skipped) toast(t`${skipped} file non ${kind === "image" ? t("sono foto") : kind === "video" ? t("sono video") : t("sono PDF")}: li trovi nella scheda giusta.`);
    closeTrim();
    render();
    if (kind !== "pdf") queueThumbs();
  }

  let thumbsRunning = 0;
  function queueThumbs() {
    while (thumbsRunning < 3) {
      const f = files.find((x) => !x.thumb);
      if (!f) return;
      f.thumb = "loading";
      thumbsRunning++;
      loadThumb(f).finally(() => { thumbsRunning--; queueThumbs(); });
    }
  }

  async function loadThumb(f) {
    const t = await invoke("thumbnail", { path: f.path, side: 320 }).catch(() => null);
    f.thumb = t || "none";
    const img = grid.querySelector(`[data-path="${CSS.escape(f.path)}"] .th`);
    if (img && t) img.replaceChildren(h("img", { src: t, alt: "" }));
  }

  async function pick() {
    setDemoPick(kind);
    const p = await pickFiles(c.filters);
    if (p.length) add(p);
  }

  function clearAll() {
    files = [];
    selected.clear();
    closeTrim();
    render();
  }

  function renderHead() {
    const total = files.reduce((a, f) => a + f.size, 0);
    head.replaceChildren(...[
      h("div", h("h1", c.title), h("div.sub", files.length ? `${files.length} ${files.length === 1 ? c.one : c.many} · ${fmtBytes(total)}${selected.size ? t` · ${selected.size} scelti` : ""}` : t("Niente ancora"))),
      h("div.grow"),
      dl,
      opts.onEditor ? h("div.seg", { role: "tablist" },
        h("button.on", { role: "tab", "aria-selected": "true" }, t("Strumenti veloci")),
        h("button", { role: "tab", title: t("Montaggio completo (Ctrl+Maiusc+E)"), onclick: () => opts.onEditor(targets().map((f) => f.path)) }, ico("film", 14), " Editor")) : null,
      files.length ? h("button.btn", { onclick: pick }, ico("plus", 16), t("Aggiungi…")) : null,
      files.length ? h("button.btn.icon", { title: t("Togli tutto"), "aria-label": t("Togli tutto"), onclick: clearAll }, ico("x", 16)) : null].filter(Boolean));
  }

  function renderGrid() {
    if (!files.length) {
      const box = h("div.box", { role: "button", tabindex: "0", onclick: pick, onkeydown: (e) => e.key === "Enter" && pick() },
        ico(KINDS[kind].icon, 44), h("h3", c.empty), h("div", t("oppure clicca per sceglierli")), h("div", { style: { fontSize: "12.5px" } }, c.emptySub));
      left.replaceChildren(head, h("div.empty", box), bar.el);
      return;
    }
    grid.replaceChildren(...files.map((f) => {
      const tile = h("div.tile" + (selected.has(f.path) ? ".sel" : ""), { "data-path": f.path, tabindex: "0", role: "option", "aria-selected": selected.has(f.path) ? "true" : "false",
        onclick: (e) => {
          if (e.ctrlKey || e.metaKey || e.shiftKey) selected.has(f.path) ? selected.delete(f.path) : selected.add(f.path);
          else selected = selected.size === 1 && selected.has(f.path) ? new Set() : new Set([f.path]);
          closeTrim();
          render();
        } },
        h("div.th", f.thumb && f.thumb !== "none" && f.thumb !== "loading" ? h("img", { src: f.thumb, alt: "" }) : ico(kind === "pdf" ? "file-text" : KINDS[kind].icon, 34)),
        kind === "video" && f.info.duration ? h("span.dur", fmtTime(f.info.duration)) : null,
        h("div.nm", { title: f.name }, f.name),
        h("div.mt", meta(f)),
        h("button.rm", { title: t("Togli"), "aria-label": t`Togli ${f.name}`, onclick: (e) => { e.stopPropagation(); files = files.filter((x) => x !== f); selected.delete(f.path); closeTrim(); render(); } }, ico("x", 13)));
      return tile;
    }));
    left.replaceChildren(head, trim ? h("div.page-scroll", trim.el) : grid, bar.el);
  }

  function meta(f) {
    const i = f.info;
    if (kind === "image" && i.width) return `${i.width}×${i.height} · ${fmtBytes(f.size)}`;
    if (kind === "video" && i.width) return `${Math.min(i.width, i.height)}p · ${fmtBytes(f.size)}`;
    return fmtBytes(f.size);
  }

  function go(action, param) {
    const t = targets();
    if (action === "transcribe") param = { lang: store.get("voiceLang", "auto") };
    if (!t.length) return pick();
    run(action, t, param, kind);
  }

  function renderTools() {
    const tg = targets();
    const n = tg.length;
    right.replaceChildren(
      h("h2", t("Cosa vuoi fare?")),
      h("div.sub", !files.length ? t`Aggiungi ${kind === "image" ? t("delle foto") : kind === "video" ? t("dei video") : t("dei PDF")} per iniziare` : n === 1 ? t`Su «${tg[0].name}»` : t`Su ${n === files.length ? t("tutti i") : ""} ${n} ${c.many}`.replace("  ", " ")));
    const mine = presets(kind);
    if (mine.length) {
      right.append(h("div.group", t("Le mie azioni")));
      for (const p of mine) {
        const what = p.steps ? p.steps.map((s) => suggestName(s.action, s.param)).join(" → ") : suggestName(p.action, p.param);
        right.append(h("button.tool.mine", { disabled: !files.length || null, onclick: () => (p.steps ? runSteps(p.steps, targets(), kind, run, subscribe) : go(p.action, p.param)), title: what },
          h("span.ic", "★"), h("span.txt", h("b", p.name), h("span", what))));
      }
    }
    if (CONVERT[kind].length) {
      right.append(h("div.group", t("Converti in")),
        h("div.fmt-grid", CONVERT[kind].map((f) => h("button.fmt", { onclick: () => go("to:" + f), disabled: !files.length || null, title: t`Converti in ${f.toUpperCase()}` }, f.toUpperCase()))));
    }
    for (const [g, ids] of GROUPS[kind] || []) {
      right.append(h("div.group", g));
      for (const id of ids) {
        const tool = TOOLS[id];
        const actionId = tool.id || id;
        const tooFew = tool.min && n < tool.min;
        const btn = h("button.tool" + (openTool === id ? ".on" : ""), {
          disabled: !files.length || null,
          onclick: () => {
            if (tooFew) return toast(t`Servono almeno ${tool.min} file: aggiungine un altro.`);
            if (!tool.params) return go(actionId, null);
            if (tool.params === "trim") return openTrim(id);
            if (tool.params === "zones") return openZones(id);
            if (tool.params === "pdfedit") {
              const one = tg.length === 1 ? tg[0] : null;
              return one ? openPdfEditor(one) : toast(t("Scegli un PDF solo (clic sulla miniatura) e poi «Compila, firma e oscura»."));
            }
            openTool = openTool === id ? null : id;
            renderTools();
          } },
          h("span.ic", ico(tool.icon, 18)),
          h("span.txt", h("b", tool.title, tool.isNew ? h("span.new", t("NUOVO")) : null), h("span", tooFew ? t`Scegli almeno ${tool.min} file` : tool.hint)));
        right.append(btn);
        // Taglio e zone hanno il loro riquadro (aggiunto da openTrim / openZones)
        if (openTool === id && tool.params && !["trim", "zones"].includes(tool.params)) right.append(paramsFor(id, actionId, tool));
      }
    }
  }

  function paramsFor(id, actionId, tool) {
    const tg = targets();
    if (tool.params === "rename") {
      const base = h("input", { type: "text", placeholder: t("es. Vacanze"), "aria-label": t("Nome") });
      const start = h("input", { type: "text", inputmode: "numeric", value: "1", "aria-label": t("Primo numero"), style: { width: "70px" } });
      const sample = h("p.hint");
      const upd = () => { const n = Math.max(0, parseInt(start.value, 10) || 1); const b = base.value.trim() || "File"; sample.textContent = t`${b} ${String(n).padStart(3, "0")}, ${b} ${String(n + 1).padStart(3, "0")}… (${tg.length} file, in ordine di nome)`; };
      base.addEventListener("input", upd);
      start.addEventListener("input", upd);
      upd();
      return h("div.params", h("p.hint", t("I file cambiano nome dove sono: non si creano copie.")), h("div.field", base), h("div.field", h("span", t("Dal numero ")), start), sample,
        h("button.btn.primary.big", { onclick: () => { if (/[\\/:*?"<>|]/.test(base.value)) return toast(t("Il nome non può contenere \\ / : * ? \" < > |")); go(actionId, `${base.value.trim() || "File"}|${Math.max(0, parseInt(start.value, 10) || 1)}|3`); } }, t("Rinomina")));
    }
    if (tool.params === "order") {
      const input = h("input", { type: "text", placeholder: t("es. 3, 1, 2") });
      return h("div.params", h("p.hint", t("Scrivi le pagine nel nuovo ordine: quelle che non scrivi restano dopo, nell'ordine di prima.")), h("div.field", input),
        h("button.btn.primary.big", { onclick: () => input.value.trim() ? go(actionId, input.value.trim()) : toast(t("Scrivi il nuovo ordine, per esempio 3, 1, 2")) }, t("Riordina")));
    }
    if (tool.params === "password") {
      const lock = actionId === "protect";
      const p1 = h("input", { type: "password", placeholder: "Password", autocomplete: "new-password", "aria-label": "Password" });
      const p2 = lock ? h("input", { type: "password", placeholder: t("Ripeti la password"), autocomplete: "new-password", "aria-label": t("Ripeti la password") }) : null;
      const start = () => {
        const a = p1.value;
        if (lock && a.length < 4) return toast(t("La password deve avere almeno 4 caratteri."));
        if (lock && a !== p2.value) return toast(t("Le due password non sono uguali."));
        if (!lock && !a) return toast(t("Scrivi la password del PDF."));
        p1.value = "";
        if (p2) p2.value = "";
        go(actionId, { password: a });
      };
      return h("div.params", h("p.hint", lock ? t("Serve per aprire il PDF (cifratura AES-256). Se la dimentichi non si recupera: scrivila da qualche parte.") : t("La password con cui si apre il PDF: esce una copia senza password.")),
        h("div.field", p1), p2 ? h("div.field", p2) : null, h("button.btn.primary.big", { onclick: start }, lock ? t("Proteggi") : t("Sblocca")));
    }
    if (tool.params === "pages") {
      const input = h("input", { type: "text", placeholder: t("es. 1-3, 5") });
      return h("div.params", h("p.hint", t("Le pagine da tenere, in un PDF nuovo.")), h("div.field", input),
        h("button.btn.primary.big", { onclick: () => input.value.trim() ? go(actionId, input.value.trim()) : toast(t("Scrivi quali pagine, per esempio 1-3, 5")) }, t("Estrai")));
    }
    const extra = {
      goLabel: tool.title,
      onSave: async (v) => {
        const name = await askName(t("Salva come mia azione"), suggestName(actionId, v), t("La ritrovi in cima agli strumenti e come spicchio con la stella nella torta."));
        if (!name) return;
        addPreset(kind, actionId, v, name);
        toast(t`«${name}» salvata in Le mie azioni.`);
        renderTools();
      },
      estimate: id === "vcompress" ? videoEstimate(tg) : id === "icompress" ? imageEstimate(tg) : null,
    };
    return knobPanel(tool.params, (v) => go(actionId, v), extra);
  }

  function openTrim(id) {
    const tg = targets();
    const f = tg.length === 1 ? tg[0] : selected.size === 0 && files.length === 1 ? files[0] : null;
    if (!f) return toast(t`Scegli un video (clic sulla miniatura) e poi «${TOOLS[id].title}».`);
    closeTrim();
    const isGif = id === "gifcut";
    trim = createTrim({ path: f.path, duration: Math.max(0.1, f.info.duration), media: "video", maxLen: isGif ? 15 : 0 });
    openTool = id;
    const precise = h("input", { type: "checkbox" });
    const panel = h("div.params",
      h("p.hint", isGif ? t("Scegli il pezzo (fino a 15 secondi): diventa una GIF animata.") : t("Sposta le maniglie sul pezzo da tenere. Senza ricodificare il taglio è istantaneo e non perde qualità; l'inizio cade sul fotogramma chiave più vicino.")),
      isGif ? null : h("label.check", precise, t("Taglio preciso al decimo (ricodifica, più lento)")),
      h("button.btn.primary.big", { onclick: () => {
        const p = { start: +trim.start.toFixed(3), end: +trim.end.toFixed(3) };
        if (!isGif) p.precise = precise.checked;
        run(isGif ? "gifcut" : "cut", [f], p, kind);
      } }, isGif ? t("Crea la GIF") : t("Taglia")),
      h("button.btn.ghost", { onclick: () => { closeTrim(); render(); } }, t("Annulla")));
    render();
    right.querySelector(".tool.on")?.after(panel);
  }

  function openZones(id) {
    const tg = targets();
    const f = tg.length === 1 ? tg[0] : selected.size === 0 && files.length === 1 ? files[0] : null;
    if (!f) return toast(t`Scegli ${kind === "image" ? t("una foto") : t("un video")} (clic sulla miniatura) e poi «Nascondi un logo».`);
    closeTrim();
    trim = createZones({ path: f.path });
    openTool = id;
    let mode = "blur", strength = 0.7;
    const modes = h("div.opts");
    // Sulle foto anche «Togli con l'IA»: ricostruisce quello che c'era dietro (la prima volta scarica il modello)
    const choices = [["blur", t("Sfocatura")], ["pixel", t("A quadretti")], ...(kind === "image" && AI_LOGO ? [["ai", t("Togli con l'IA")]] : [])];
    const forceLabel = h("div", { style: { fontSize: "12.5px", color: "var(--quiet)" } }, t("Forza"));
    const aiHint = h("p.hint", { style: { display: "none" } }, t("Ricostruisce lo sfondo dietro il logo, sul computer. La prima volta scarica il modello (208 MB)."));
    const drawModes = () => {
      modes.replaceChildren(...choices.map(([v, l]) => h("button.opt" + (v === mode ? ".on" : ""), { onclick: () => { mode = v; drawModes(); } }, l)));
      const ai = mode === "ai";
      forceLabel.style.display = force.style.display = ai ? "none" : "";
      aiHint.style.display = ai ? "" : "none";
    };
    const force = h("input", { type: "range", min: 0.2, max: 1, step: 0.05, value: strength, style: { width: "100%", accentColor: "var(--sage-deep)" }, oninput: (e) => (strength = Number(e.target.value)) });
    drawModes();
    const panel = h("div.params", h("p.hint", t("Disegna le zone sull'immagine a sinistra.")), modes, aiHint,
      forceLabel, force,
      h("button.btn.primary.big", { onclick: () => {
        const zones = trim.zones;
        if (!zones.length) return toast(t("Disegna almeno una zona sul logo."));
        run("hidemark", [f], { zones, mode, strength }, kind);
      } }, t("Nascondi")),
      h("button.btn.ghost", { onclick: () => { closeTrim(); render(); } }, t("Annulla")));
    render();
    right.querySelector(".tool.on")?.after(panel);
  }

  function closeTrim() {
    if (trim) trim.destroy();
    trim = null;
    if (openTool && ["trim", "zones"].includes(TOOLS[openTool]?.params)) openTool = null;
  }

  function render() {
    renderHead();
    renderGrid();
    renderTools();
  }

  render();
  return { el, add, kind, show() {}, get count() { return files.length; } };
}
