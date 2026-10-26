// Schede Immagini, Video e File: i file a sinistra, a destra «Cosa vuoi fare?».
// Un clic su uno strumento senza scelte lo fa partire subito; con le scelte apre il riquadro sotto.

import { invoke, pickFiles, setDemoPick } from "./api.js";
import { CONVERT, GROUPS, KINDS, TOOLS, fmtIcon } from "./catalog.js";
import { run } from "./jobs.js";
import { imageEstimate, knobPanel, videoEstimate } from "./params.js";
import { resultBar } from "./resultbar.js";
import { createTrim } from "./trim.js";
import { createZones } from "./zones.js";
import { downloaderBar } from "./downloader.js";
import { fmtBytes, fmtTime, h, ico, store, toast } from "./util.js";

const COPY = {
  image: { title: "Immagini", one: "foto", many: "foto", empty: "Trascina qui le foto", emptySub: "JPG, PNG, HEIC dell'iPhone, WebP, AVIF e altre", filters: [{ name: "Immagini", extensions: ["jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "gif", "bmp", "tif", "tiff", "ico", "jfif"] }] },
  video: { title: "Video", one: "video", many: "video", empty: "Trascina qui i video", emptySub: "MP4, MOV dell'iPhone, MKV, AVI, WebM e altri. Anche film di ore: si lavorano sul computer.", filters: [{ name: "Video", extensions: ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "ts", "mts", "m2ts", "3gp"] }] },
  pdf: { title: "File", one: "PDF", many: "PDF", empty: "Trascina qui i PDF", emptySub: "Unisci, dividi ed estrai pagine. Word, Excel e PowerPoint arriveranno con un componente facoltativo.", filters: [{ name: "PDF", extensions: ["pdf"] }] },
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
        toast(p.error);
        continue;
      }
      const k = p.info.kind;
      if (k !== kind) {
        skipped++;
        continue;
      }
      files.push({ path: p.info.path, name: p.info.name, size: p.info.size, info: p.info, thumb: null });
    }
    if (skipped) toast(`${skipped} file non ${kind === "image" ? "sono foto" : kind === "video" ? "sono video" : "sono PDF"}: li trovi nella scheda giusta.`);
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
      h("div", h("h1", c.title), h("div.sub", files.length ? `${files.length} ${files.length === 1 ? c.one : c.many} · ${fmtBytes(total)}${selected.size ? ` · ${selected.size} scelti` : ""}` : "Niente ancora")),
      h("div.grow"),
      dl,
      opts.onEditor ? h("div.seg", { role: "tablist" },
        h("button.on", { role: "tab", "aria-selected": "true" }, "Strumenti veloci"),
        h("button", { role: "tab", title: "Montaggio completo (Ctrl+Maiusc+E)", onclick: () => opts.onEditor(targets().map((f) => f.path)) }, ico("film", 14), " Editor")) : null,
      files.length ? h("button.btn", { onclick: pick }, ico("plus", 16), "Aggiungi…") : null,
      files.length ? h("button.btn.icon", { title: "Togli tutto", "aria-label": "Togli tutto", onclick: clearAll }, ico("x", 16)) : null].filter(Boolean));
  }

  function renderGrid() {
    if (!files.length) {
      const box = h("div.box", { role: "button", tabindex: "0", onclick: pick, onkeydown: (e) => e.key === "Enter" && pick() },
        ico(KINDS[kind].icon, 44), h("h3", c.empty), h("div", "oppure clicca per sceglierli"), h("div", { style: { fontSize: "12.5px" } }, c.emptySub));
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
        h("button.rm", { title: "Togli", "aria-label": "Togli " + f.name, onclick: (e) => { e.stopPropagation(); files = files.filter((x) => x !== f); selected.delete(f.path); closeTrim(); render(); } }, ico("x", 13)));
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
    const t = targets();
    const n = t.length;
    right.replaceChildren(
      h("h2", "Cosa vuoi fare?"),
      h("div.sub", !files.length ? `Aggiungi ${kind === "image" ? "delle foto" : kind === "video" ? "dei video" : "dei PDF"} per iniziare` : n === 1 ? `Su «${t[0].name}»` : `Su ${n === files.length ? "tutti i" : ""} ${n} ${c.many}`.replace("  ", " ")));
    if (CONVERT[kind].length) {
      right.append(h("div.group", "Converti in"),
        h("div.fmt-grid", CONVERT[kind].map((f) => h("button.fmt", { onclick: () => go("to:" + f), disabled: !files.length || null, title: `Converti in ${f.toUpperCase()}` }, f.toUpperCase()))));
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
            if (tooFew) return toast(`Servono almeno ${tool.min} file: aggiungine un altro.`);
            if (!tool.params) return go(actionId, null);
            if (tool.params === "trim") return openTrim(id);
            if (tool.params === "zones") return openZones(id);
            openTool = openTool === id ? null : id;
            renderTools();
          } },
          h("span.ic", ico(tool.icon, 18)),
          h("span.txt", h("b", tool.title, tool.isNew ? h("span.new", "NUOVO") : null), h("span", tooFew ? `Scegli almeno ${tool.min} file` : tool.hint)));
        right.append(btn);
        // Taglio e zone hanno il loro riquadro (aggiunto da openTrim / openZones)
        if (openTool === id && tool.params && !["trim", "zones"].includes(tool.params)) right.append(paramsFor(id, actionId, tool));
      }
    }
  }

  function paramsFor(id, actionId, tool) {
    const t = targets();
    if (tool.params === "rename") {
      const base = h("input", { type: "text", placeholder: "es. Vacanze", "aria-label": "Nome" });
      const start = h("input", { type: "text", inputmode: "numeric", value: "1", "aria-label": "Primo numero", style: { width: "70px" } });
      const sample = h("p.hint");
      const upd = () => { const n = Math.max(0, parseInt(start.value, 10) || 1); const b = base.value.trim() || "File"; sample.textContent = `${b} ${String(n).padStart(3, "0")}, ${b} ${String(n + 1).padStart(3, "0")}… (${t.length} file, in ordine di nome)`; };
      base.addEventListener("input", upd);
      start.addEventListener("input", upd);
      upd();
      return h("div.params", h("p.hint", "I file cambiano nome dove sono: non si creano copie."), h("div.field", base), h("div.field", h("span", "Dal numero "), start), sample,
        h("button.btn.primary.big", { onclick: () => { if (/[\\/:*?"<>|]/.test(base.value)) return toast("Il nome non può contenere \\ / : * ? \" < > |"); go(actionId, `${base.value.trim() || "File"}|${Math.max(0, parseInt(start.value, 10) || 1)}|3`); } }, "Rinomina"));
    }
    if (tool.params === "order") {
      const input = h("input", { type: "text", placeholder: "es. 3, 1, 2" });
      return h("div.params", h("p.hint", "Scrivi le pagine nel nuovo ordine: quelle che non scrivi restano dopo, nell'ordine di prima."), h("div.field", input),
        h("button.btn.primary.big", { onclick: () => input.value.trim() ? go(actionId, input.value.trim()) : toast("Scrivi il nuovo ordine, per esempio 3, 1, 2") }, "Riordina"));
    }
    if (tool.params === "password") {
      const lock = actionId === "protect";
      const p1 = h("input", { type: "password", placeholder: "Password", autocomplete: "new-password", "aria-label": "Password" });
      const p2 = lock ? h("input", { type: "password", placeholder: "Ripeti la password", autocomplete: "new-password", "aria-label": "Ripeti la password" }) : null;
      const start = () => {
        const a = p1.value;
        if (lock && a.length < 4) return toast("La password deve avere almeno 4 caratteri.");
        if (lock && a !== p2.value) return toast("Le due password non sono uguali.");
        if (!lock && !a) return toast("Scrivi la password del PDF.");
        p1.value = "";
        if (p2) p2.value = "";
        go(actionId, { password: a });
      };
      return h("div.params", h("p.hint", lock ? "Serve per aprire il PDF (cifratura AES-256). Se la dimentichi non si recupera: scrivila da qualche parte." : "La password con cui si apre il PDF: esce una copia senza password."),
        h("div.field", p1), p2 ? h("div.field", p2) : null, h("button.btn.primary.big", { onclick: start }, lock ? "Proteggi" : "Sblocca"));
    }
    if (tool.params === "pages") {
      const input = h("input", { type: "text", placeholder: "es. 1-3, 5" });
      return h("div.params", h("p.hint", "Le pagine da tenere, in un PDF nuovo."), h("div.field", input),
        h("button.btn.primary.big", { onclick: () => input.value.trim() ? go(actionId, input.value.trim()) : toast("Scrivi quali pagine, per esempio 1-3, 5") }, "Estrai"));
    }
    const extra = {
      goLabel: tool.title,
      estimate: id === "vcompress" ? videoEstimate(t) : id === "icompress" ? imageEstimate(t) : null,
    };
    return knobPanel(tool.params, (v) => go(actionId, v), extra);
  }

  function openTrim(id) {
    const t = targets();
    const f = t.length === 1 ? t[0] : selected.size === 0 && files.length === 1 ? files[0] : null;
    if (!f) return toast("Scegli un video (clic sulla miniatura) e poi «" + TOOLS[id].title + "».");
    closeTrim();
    const isGif = id === "gifcut";
    trim = createTrim({ path: f.path, duration: Math.max(0.1, f.info.duration), media: "video", maxLen: isGif ? 15 : 0 });
    openTool = id;
    const precise = h("input", { type: "checkbox" });
    const panel = h("div.params",
      h("p.hint", isGif ? "Scegli il pezzo (fino a 15 secondi): diventa una GIF animata." : "Sposta le maniglie sul pezzo da tenere. Senza ricodificare il taglio è istantaneo e non perde qualità; l'inizio cade sul fotogramma chiave più vicino."),
      isGif ? null : h("label.check", precise, "Taglio preciso al decimo (ricodifica, più lento)"),
      h("button.btn.primary.big", { onclick: () => {
        const p = { start: +trim.start.toFixed(3), end: +trim.end.toFixed(3) };
        if (!isGif) p.precise = precise.checked;
        run(isGif ? "gifcut" : "cut", [f], p, kind);
      } }, isGif ? "Crea la GIF" : "Taglia"),
      h("button.btn.ghost", { onclick: () => { closeTrim(); render(); } }, "Annulla"));
    render();
    right.querySelector(".tool.on")?.after(panel);
  }

  function openZones(id) {
    const t = targets();
    const f = t.length === 1 ? t[0] : selected.size === 0 && files.length === 1 ? files[0] : null;
    if (!f) return toast(`Scegli ${kind === "image" ? "una foto" : "un video"} (clic sulla miniatura) e poi «Nascondi un logo».`);
    closeTrim();
    trim = createZones({ path: f.path });
    openTool = id;
    let mode = "blur", strength = 0.7;
    const modes = h("div.opts");
    const drawModes = () => modes.replaceChildren(...[["blur", "Sfocatura"], ["pixel", "A quadretti"]].map(([v, l]) => h("button.opt" + (v === mode ? ".on" : ""), { onclick: () => { mode = v; drawModes(); } }, l)));
    drawModes();
    const force = h("input", { type: "range", min: 0.2, max: 1, step: 0.05, value: strength, style: { width: "100%", accentColor: "var(--sage-deep)" }, oninput: (e) => (strength = Number(e.target.value)) });
    const panel = h("div.params", h("p.hint", "Disegna le zone sull'immagine a sinistra."), modes,
      h("div", { style: { fontSize: "12.5px", color: "var(--quiet)" } }, "Forza"), force,
      h("button.btn.primary.big", { onclick: () => {
        const zones = trim.zones;
        if (!zones.length) return toast("Disegna almeno una zona sul logo.");
        run("hidemark", [f], { zones, mode, strength }, kind);
      } }, "Nascondi"),
      h("button.btn.ghost", { onclick: () => { closeTrim(); render(); } }, "Annulla"));
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
