// L'editor video (come su Mac): Progetti, anteprima, sequenza con clip, testi e musica,
// pannello con Clip, Filtri, Effetti, Testi, Audio, Formato. ⌘Z/Ctrl+Z annulla, si salva da solo.

import { DEMO, fileUrl, invoke, pickFiles, setDemoPick } from "./api.js";
import { dec, t, tr, tc, LOCALE } from "./i18n.js";
import { run } from "./jobs.js";
import { PRESETS, emptyLook, feMatrix, isIdentity, resolve } from "./look.js";
import { resultBar } from "./resultbar.js";
import { ANIMS, COLORS, STYLES, drawText, exportOverlay, newText, stateAt } from "./textdraw.js";
import { baseName, fmtTime, h, ico, modal, store, toast } from "./util.js";
import { levelSeg } from "./levels.js";

const TRANSITIONS = [["fade", t("Dissolvenza")], ["black", t("Al nero")], ["white", t("Al bianco")], ["slide", t("Scorrimento")], ["zoom", t("Zoom")], ["blur", t("Sfocatura")]];
const SPEEDS = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8, 12];
const TOOLS = [["clip", t("Clip"), "scissors"], ["look", t("Filtri"), "sparkles"], ["fx", t("Effetti"), "wand-sparkles"], ["text", t("Testi"), "file-text"], ["audio", t("Audio"), "music"], ["format", t("Formato"), "crop"]];

function newProject(n) {
  return { name: t`Progetto ${n}`, clips: [], texts: [], music: null, originalVolume: 1, originalMuted: false, aspect: "orig", resolution: 1080, fps: 30, look: null };
}

const uid = () => Math.random().toString(36).slice(2, 10);
const clipLen = (c) => Math.max(0, c.out - c.in) / (c.fx?.speed || 1);

export function editorPage(app, onBack) {
  const el = h("div.page.editor");
  let library = store.get("projects", []); // [{id, name, updated, data}]
  let current = null; // voce della libreria
  let p = null; // progetto aperto
  let infos = {}; // path → info
  let thumbs = {}; // path → dataUrl
  let undo = [], redo = [];
  let sel = { kind: "clip", index: 0 }; // clip | text
  let tool = "clip";
  let time = 0, playing = false;
  let pps = 60; // pixel per secondo nella sequenza
  const rects = new Map(); // id del testo → riquadro disegnato nell'anteprima
  const bar = resultBar("editor");

  // ── Libreria dei progetti
  let saveWarned = false;
  function saveLibrary() {
    return store.set("projects", library);
  }
  let saveTimer;
  function scheduleSave() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      if (!current) return;
      current.data = p;
      current.name = p.name;
      current.updated = Date.now();
      if (!saveLibrary() && !saveWarned) {
        saveWarned = true;
        toast(t("Non riesco a salvare il progetto: troppi progetti grandi. Eliminane qualcuno da «Progetti»."));
      }
    }, 400);
  }

  /** 1.0.1 · «Salva progetto»: subito, con la conferma. */
  function saveNow() {
    clearTimeout(saveTimer);
    if (!current) return;
    current.data = p;
    current.name = p.name;
    current.updated = Date.now();
    toast(saveLibrary() ? t("Progetto salvato") : t("Non riesco a salvare il progetto: troppi progetti grandi. Eliminane qualcuno da «Progetti»."));
  }

  function showProjects() {
    stop();
    current = null;
    p = null;
    const grid = h("div.grid", { style: { padding: "4px 0 24px" } },
      h("div.tile", { role: "button", tabindex: "0", onclick: () => openProject(null) },
        h("div.th", { style: { background: "color-mix(in srgb, var(--sage) 18%, var(--bg-2))", color: "var(--sage-deep)" } }, ico("plus", 40)),
        h("div.nm", t("Nuovo progetto")), h("div.mt", t("Video, testi e musica"))),
      library.slice().sort((a, b) => b.updated - a.updated).map((item) => {
        const d = item.data;
        const dur = (d.clips || []).reduce((a, c) => a + clipLen(c), 0);
        const cover = d.clips?.[0] && thumbs[d.clips[0].path];
        const tile = h("div.tile", { role: "button", tabindex: "0", onclick: () => openProject(item) },
          h("div.th", cover ? h("img", { src: cover, alt: "" }) : ico("film", 34)),
          h("span.dur", fmtTime(dur)),
          h("div.nm", item.name), h("div.mt", new Date(item.updated).toLocaleDateString(LOCALE, { day: "numeric", month: "short" })),
          h("button.rm", { title: t("Elimina"), "aria-label": t`Elimina ${item.name}`, onclick: async (e) => {
            e.stopPropagation();
            if (await modal(t`Eliminare «${item.name}»?`, t("I video non si toccano: si elimina solo il progetto."), [{ label: t("Annulla"), value: false }, { label: t("Elimina"), value: true, primary: true }])) {
              library = library.filter((x) => x !== item);
              saveLibrary();
              showProjects();
            }
          } }, ico("x", 13)));
        if (d.clips?.[0] && !thumbs[d.clips[0].path]) loadThumb(d.clips[0].path).then(() => { if (!current) showProjects(); });
        return tile;
      }));
    el.replaceChildren(
      h("div.head", h("div", h("h1", t("Progetti")), h("div.sub", t("Montaggi con tagli, filtri, testi e musica: si salvano da soli"))), h("div.grow"),
        levelSeg("video", "editor", () => onBack(), () => {})),
      h("div.page-scroll", grid));
  }

  async function loadThumb(path) {
    if (thumbs[path]) return thumbs[path];
    const t = await invoke("thumbnail", { path, side: 240 }).catch(() => null);
    if (t) thumbs[path] = t;
    return t;
  }

  async function openProject(item, paths = []) {
    if (!item) {
      item = { id: uid(), name: "", updated: Date.now(), data: newProject(library.length + 1) };
      library.push(item);
    }
    current = item;
    p = JSON.parse(JSON.stringify(item.data));
    p.texts = p.texts || [];
    undo = [];
    redo = [];
    time = 0;
    sel = { kind: "clip", index: 0 };
    // I file del progetto: esistono ancora?
    const paths0 = [...new Set([...(p.clips || []).map((c) => c.path), p.music?.path].filter(Boolean))];
    if (paths0.length) {
      const probed = await invoke("probe_files", { paths: paths0 });
      const lost = [];
      for (const r of probed) {
        if (r.ok) infos[r.info.path] = r.info;
        else lost.push(r.path);
      }
      if (lost.length) {
        p.clips = p.clips.filter((c) => !lost.includes(c.path));
        if (p.music && lost.includes(p.music.path)) p.music = null;
        toast(t`Non trovo più ${lost.length === 1 ? t("un file") : t`${lost.length} file`} del progetto: spostato o cancellato.`);
      }
    }
    buildEditor();
    if (paths.length) addClips(paths);
  }

  // ── Modifiche con annulla
  function change(fn) {
    undo.push(JSON.stringify(p));
    if (undo.length > 120) undo.shift();
    redo = [];
    fn(p);
    afterChange();
  }
  function afterChange() {
    scheduleSave();
    renderAll();
  }
  function doUndo() {
    if (!undo.length) return;
    redo.push(JSON.stringify(p));
    p = JSON.parse(undo.pop());
    afterChange();
  }
  function doRedo() {
    if (!redo.length) return;
    undo.push(JSON.stringify(p));
    p = JSON.parse(redo.pop());
    afterChange();
  }

  async function addClips(paths) {
    const probed = await invoke("probe_files", { paths });
    const ok = probed.filter((r) => r.ok && (r.info.kind === "video" || (r.info.kind === "image")));
    if (!ok.length) return toast(t("Aggiungi dei video."));
    change((pp) => {
      for (const r of ok) {
        infos[r.info.path] = r.info;
        const d = r.info.kind === "image" ? 3 : Math.max(0.1, r.info.duration);
        pp.clips.push({ id: uid(), path: r.info.path, in: 0, out: d, muted: false, look: null, transition: null, fx: null });
      }
    });
    ok.forEach((r) => loadThumb(r.info.path).then(renderTimeline));
  }

  // ── Tempo: in quale clip siamo
  const starts = () => {
    let t = 0;
    return p.clips.map((c) => { const s = t; t += clipLen(c); return s; });
  };
  const total = () => p.clips.reduce((a, c) => a + clipLen(c), 0);
  function clipAt(t) {
    const s = starts();
    for (let i = 0; i < p.clips.length; i++) {
      if (t < s[i] + clipLen(p.clips[i]) - 1e-6 || i === p.clips.length - 1) return { i, local: Math.max(0, Math.min(clipLen(p.clips[i]), t - s[i])) };
    }
    return null;
  }

  // ── Anteprima
  const vA = h("video", { playsinline: true, preload: "auto" });
  const vB = h("video", { playsinline: true, preload: "auto" });
  vA.className = "pv";
  vB.className = "pv";
  const music = h("audio", { preload: "auto" });
  const overlay = h("canvas.ov");
  const veil = h("div.veil");
  const vig = h("div.vig");
  const svgDefs = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svgDefs.setAttribute("width", "0");
  svgDefs.setAttribute("height", "0");
  svgDefs.style.position = "absolute";
  const still = h("img.pv.still", { alt: "", hidden: true });
  const canvasBox = h("div.canvas", vA, vB, still, veil, vig, overlay);
  const stage = h("div.stage", canvasBox, svgDefs);
  let active = vA, spare = vB, activeIndex = -1;

  function canvasSize() {
    const first = p.clips[0] && infos[p.clips[0].path];
    let w = first?.width || 1920, hh = first?.height || 1080;
    if (p.clips[0]?.fx?.rotate % 180 === 90) [w, hh] = [hh, w];
    const r = { "9x16": 9 / 16, "1x1": 1, "4x5": 4 / 5, "16x9": 16 / 9 }[p.aspect];
    if (r) [w, hh] = w / hh > r ? [hh * r, hh] : [w, w / r];
    const k = Math.min(1, (p.resolution || 1080) / Math.min(w, hh));
    const even = (x) => Math.max(2, Math.round(x / 2) * 2);
    return [even(w * k), even(hh * k)];
  }

  function layoutStage() {
    const [w, hh] = canvasSize();
    const r = stage.getBoundingClientRect();
    if (!r.width) return;
    const k = Math.min((r.width - 16) / w, (r.height - 16) / hh);
    canvasBox.style.width = Math.floor(w * k) + "px";
    canvasBox.style.height = Math.floor(hh * k) + "px";
    overlay.width = Math.floor(w * k * (window.devicePixelRatio || 1));
    overlay.height = Math.floor(hh * k * (window.devicePixelRatio || 1));
    const fit = !p.aspect || p.aspect === "orig" ? "contain" : "cover";
    vA.style.objectFit = fit;
    vB.style.objectFit = fit;
  }

  function lookFilter(c, i) {
    const l = c.look || p.look;
    const parts = [];
    let vigAmount = 0;
    if (l && !isIdentity(l)) {
      const r = resolve(l);
      let f = svgDefs.querySelector(`#lk${i}`);
      if (!f) {
        f = document.createElementNS("http://www.w3.org/2000/svg", "filter");
        f.id = `lk${i}`;
        f.setAttribute("color-interpolation-filters", "sRGB");
        const m = document.createElementNS("http://www.w3.org/2000/svg", "feColorMatrix");
        m.setAttribute("type", "matrix");
        f.append(m);
        svgDefs.append(f);
      }
      f.firstChild.setAttribute("values", feMatrix(r.a));
      parts.push(`url(#lk${i})`);
      if (r.glow > 0) parts.push(`brightness(${1 + r.glow * 0.08})`);
      vigAmount = r.vignette;
    }
    if (c.fx?.blur > 0.01) parts.push(`blur(${(c.fx.blur * 25 * canvasBox.clientHeight) / 1080}px)`);
    return { filter: parts.join(" ") || "none", vig: vigAmount };
  }

  function clipTransform(c, local) {
    const fx = c.fx || {};
    const t = [];
    if (fx.rotate) t.push(`rotate(${fx.rotate}deg)`);
    if (fx.flipH) t.push("scaleX(-1)");
    if (fx.flipV) t.push("scaleY(-1)");
    if (fx.zoom === "in" || fx.zoom === "out") {
      const k = Math.min(1, local / Math.max(0.1, clipLen(c)));
      const z = fx.zoom === "in" ? 1 + 0.15 * k : 1.15 - 0.15 * k;
      t.push(`scale(${z})`);
    }
    return t.join(" ") || "none";
  }

  function loadInto(v, c) {
    if (DEMO) return;
    const src = fileUrl(c.path);
    if (v.dataset.path !== c.path) {
      v.dataset.path = c.path;
      v.src = src;
    }
  }

  /** Mostra il fotogramma al tempo t (fermi o in riproduzione). */
  function showAt(t, seek = true) {
    if (!p.clips.length) return;
    const at = clipAt(t);
    if (!at) return;
    const c = p.clips[at.i];
    if (at.i !== activeIndex) {
      // La clip pronta di riserva diventa quella visibile
      if (spare.dataset.path === c.path && spare.dataset.index == at.i) [active, spare] = [spare, active];
      loadInto(active, c);
      active.dataset.index = at.i;
      activeIndex = at.i;
      const next = p.clips[at.i + 1];
      if (next) {
        loadInto(spare, next);
        spare.dataset.index = at.i + 1;
        try { spare.currentTime = next.in; } catch {}
      }
      seek = true;
    }
    const isImage = infos[c.path]?.kind === "image";
    still.hidden = !isImage;
    if (isImage && !DEMO && still.dataset.path !== c.path) { still.dataset.path = c.path; still.src = fileUrl(c.path); }
    active.style.opacity = isImage ? 0 : 1;
    spare.style.opacity = 0;
    still.style.objectFit = !p.aspect || p.aspect === "orig" ? "contain" : "cover";
    const speed = c.fx?.speed || 1;
    if (seek) {
      try { active.currentTime = c.in + at.local * speed; } catch {}
    }
    active.playbackRate = speed;
    active.muted = c.muted || p.originalMuted;
    // 1.0.1 · Ogni pezzo diviso ha il suo volume
    active.volume = Math.min(1, (p.originalVolume ?? 1) * (c.volume ?? 1));
    const lf = lookFilter(c, at.i);
    active.style.filter = lf.filter;
    active.style.transform = clipTransform(c, at.local);
    still.style.filter = lf.filter;
    still.style.transform = clipTransform(c, at.local);
    vig.style.opacity = lf.vig;
    // Dissolvenze della clip e transizioni (approssimate nell'anteprima)
    const len = clipLen(c);
    let dark = 0;
    if (c.fx?.fadeIn > 0 && at.local < c.fx.fadeIn) dark = 1 - at.local / c.fx.fadeIn;
    if (c.fx?.fadeOut > 0 && len - at.local < c.fx.fadeOut) dark = Math.max(dark, 1 - (len - at.local) / c.fx.fadeOut);
    const nextT = p.clips[at.i + 1]?.transition;
    const prevT = c.transition;
    let white = false;
    if (nextT && len - at.local < nextT.duration / 2) {
      const k = 1 - (len - at.local) / (nextT.duration / 2);
      if (nextT.kind === "black" || nextT.kind === "white") { dark = Math.max(dark, k); white = nextT.kind === "white"; }
      else spare.style.opacity = k * 0.5;
    }
    if (prevT && at.local < prevT.duration / 2 && (prevT.kind === "black" || prevT.kind === "white")) {
      dark = Math.max(dark, 1 - at.local / (prevT.duration / 2));
      white = prevT.kind === "white";
    }
    veil.style.background = white ? "#fff" : "#000";
    veil.style.opacity = dark;
    drawOverlay(t);
    syncMusic(t, seek);
  }

  function drawOverlay(t) {
    const g = overlay.getContext("2d");
    g.clearRect(0, 0, overlay.width, overlay.height);
    for (const tx of p.texts) {
      const st = stateAt(tx, t);
      if (!st) continue;
      rects.set(tx.id, drawText(g, tx, overlay.width, overlay.height, st));
    }
  }

  function syncMusic(t, seek) {
    const m = p.music;
    if (!m || DEMO) {
      music.pause();
      return;
    }
    if (music.dataset.path !== m.path) {
      music.dataset.path = m.path;
      music.src = fileUrl(m.path);
    }
    const local = t - (m.offset || 0);
    music.volume = Math.min(1, m.volume ?? 0.8);
    if (local < 0 || !playing || t >= musicStop(m)) {
      music.pause();
      if (seek && local >= 0) try { music.currentTime = (m.in || 0) + local; } catch {}
      return;
    }
    const want = (m.in || 0) + local;
    if (seek || Math.abs(music.currentTime - want) > 0.3) try { music.currentTime = want; } catch {}
    if (music.paused) music.play().catch(() => {});
  }

  let raf = 0;
  function loop() {
    if (!playing) return;
    const at = clipAt(time);
    if (!at) return stop();
    const c = p.clips[at.i];
    const speed = c.fx?.speed || 1;
    const isImage = infos[c.path]?.kind === "image";
    if (!DEMO && !isImage && active.readyState >= 2) {
      const local = (active.currentTime - c.in) / speed;
      time = starts()[at.i] + Math.max(0, local);
      if (active.currentTime >= c.out - 0.04 || local >= clipLen(c) - 0.02) {
        // Clip successiva
        if (at.i + 1 >= p.clips.length) return stop(true);
        time = starts()[at.i + 1] + 0.001;
        showAt(time, true);
        active.play().catch(() => {});
      } else showAt(time, false);
    } else {
      // Foto (o video non ancora pronto): l'orologio va avanti da solo
      const now = performance.now();
      time += Math.min(0.1, (now - (loop.last || now)) / 1000);
      loop.last = now;
      if (time >= total()) return stop(true);
      const next = clipAt(time);
      if (next && next.i !== at.i) {
        showAt(time, true);
        if (infos[p.clips[next.i].path]?.kind !== "image") active.play().catch(() => {});
      } else showAt(time, false);
    }
    if (!isImage || DEMO) loop.last = performance.now();
    updatePlayhead();
    raf = requestAnimationFrame(loop);
  }
  function play() {
    if (!p.clips.length) return;
    if (time >= total() - 0.05) time = 0;
    playing = true;
    showAt(time, true);
    active.play().catch(() => {});
    playBtn.replaceChildren(ico("pause", 18));
    raf = requestAnimationFrame(loop);
  }
  function stop(atEnd) {
    playing = false;
    cancelAnimationFrame(raf);
    vA.pause();
    vB.pause();
    music.pause();
    if (atEnd) time = total();
    playBtn?.replaceChildren(ico("play", 18));
    if (p) updatePlayhead();
  }
  function seekTo(t) {
    time = Math.max(0, Math.min(total(), t));
    if (playing) {
      showAt(time, true);
      active.play().catch(() => {});
    } else showAt(time, true);
    updatePlayhead();
  }

  // ── Struttura dell'editor
  let playBtn, timeLabel, nameInput, timelineEl, inspector, playheadEl, toolbar;
  function buildEditor() {
    nameInput = h("input.name", { value: p.name, "aria-label": t("Nome del progetto"), onchange: () => change((pp) => (pp.name = nameInput.value.trim() || pp.name)) });
    playBtn = h("button.btn.icon", { "aria-label": t("Riproduci"), title: t("Riproduci (Spazio)"), onclick: () => (playing ? stop() : play()) }, ico("play", 18));
    timeLabel = h("span.tlabel");
    toolbar = h("div.ed-tools", TOOLS.map(([id, label, icn]) => h("button" + (tool === id ? ".on" : ""), { "data-tool": id, onclick: () => { tool = id; renderInspector(); renderToolbar(); } }, ico(icn, 17), label)));
    inspector = h("div.inspector");
    timelineEl = h("div.timeline");
    const top = h("div.ed-top",
      h("button.btn", { onclick: () => { stop(); showProjects(); } }, t("‹ Progetti")),
      nameInput,
      h("div.grow"),
      h("button.btn.icon", { title: t("Annulla (Ctrl+Z)"), "aria-label": tc("undo", "Annulla"), onclick: doUndo }, ico("undo-2", 16)),
      h("button.btn.icon", { title: t("Rifai (Ctrl+Y)"), "aria-label": t("Rifai"), onclick: doRedo, style: { transform: "scaleX(-1)" } }, ico("undo-2", 16)),
      h("button.btn", { onclick: pickClips }, ico("plus", 15), t("Aggiungi video")),
      // 1.0.1 · Salva subito (oltre al salvataggio automatico)
      h("button.btn", { title: t("Salva il progetto adesso (Ctrl+S). Lo ritrovi in Progetti"), onclick: saveNow }, ico("save", 15), t("Salva progetto")),
      h("button.btn.brass", { onclick: exportVideo }, ico("download", 15), t("Esporta")));
    const ctrl = h("div.ed-ctrl", playBtn, timeLabel, h("div.grow"),
      h("button.btn", { title: t("Testo (T)"), onclick: addText }, ico("plus", 14), t("Testo")),
      h("button.btn", { title: t("Dividi qui (S)"), onclick: splitHere }, ico("scissors", 14), t("Dividi")));
    el.replaceChildren(h("div.ed", top, h("div.ed-mid", h("div.ed-left", stage, ctrl), h("div.ed-right", toolbar, inspector)), timelineEl, bar.el));
    activeIndex = -1;
    requestAnimationFrame(() => { layoutStage(); renderAll(); });
  }

  function renderToolbar() {
    toolbar.querySelectorAll("button").forEach((b) => b.classList.toggle("on", b.dataset.tool === tool));
  }

  function renderAll() {
    if (!p || !inspector) return;
    if (nameInput && document.activeElement !== nameInput) nameInput.value = p.name;
    layoutStage();
    renderTimeline();
    renderInspector();
    activeIndex = -1;
    if (time > total()) time = total();
    showAt(time, true);
    updatePlayhead();
  }

  // ── Sequenza
  function updatePlayhead() {
    if (timeLabel) timeLabel.textContent = `${pps >= 300 ? fmtMs(time, 0.001) : fmtTime(time, true)} / ${fmtTime(total())}`;
    if (playheadEl) playheadEl.style.left = 12 + time * pps + "px";
  }

  function renderTimeline() {
    if (!timelineEl) return;
    const T = total();
    const width = Math.max(600, 24 + T * pps + 200);
    const ruler = h("div.ruler", { style: { width: width + "px" } });
    // 1.0.1 · Con lo zoom il righello arriva ai millisecondi; si disegnano solo i segni visibili
    const step = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60].find((st) => st * pps >= 70) || 60;
    const fillRuler = (left, w) => {
      const v0 = Math.max(0, (left - 400) / pps), v1 = (left + w + 400) / pps;
      const marks = [];
      for (let k = Math.floor(v0 / step); k * step <= Math.min(T + 5, v1); k++) {
        const s = k * step;
        marks.push(h("span", { style: { left: 12 + s * pps + "px" } }, step < 1 ? fmtMs(s, step) : fmtTime(s)));
      }
      ruler.replaceChildren(...marks);
    };
    const clipsRow = h("div.row.clips", { style: { width: width + "px" } });
    let x = 12;
    p.clips.forEach((c, i) => {
      const w = Math.max(14, clipLen(c) * pps);
      const th = thumbs[c.path];
      const blk = h("div.blk" + (sel.kind === "clip" && sel.index === i ? ".on" : ""), {
        style: { left: x + "px", width: w - 2 + "px", backgroundImage: th ? `url(${th})` : "none" },
        title: `${baseName(c.path)} · ${fmtTime(clipLen(c), true)}`,
        onpointerdown: (e) => dragClip(e, i),
      },
      h("span.lbl", (c.fx?.speed && c.fx.speed !== 1 ? `${dec(String(c.fx.speed).replace(".", ","))}× · ` : "") + baseName(c.path)),
      c.muted ? h("span.badge-ic", ico("volume-x", 12)) : null,
      (c.look && !isIdentity(c.look)) ? h("span.badge-ic.l", ico("sparkles", 12)) : null,
      h("div.edge.l", { onpointerdown: (e) => trimClip(e, i, "in") }),
      h("div.edge.r", { onpointerdown: (e) => trimClip(e, i, "out") }));
      clipsRow.append(blk);
      if (i > 0) {
        const trn = c.transition;
        clipsRow.append(h("button.tdot" + (trn ? ".on" : ""), { style: { left: x - 9 + "px" }, title: trn ? t`Transizione: ${TRANSITIONS.find((k) => k[0] === trn.kind)?.[1]}` : t("Aggiungi una transizione"),
          onclick: (e) => { e.stopPropagation(); transitionMenu(i, e.currentTarget); } }, trn ? ico("sparkles", 11) : ico("plus", 11)));
      }
      x += w;
    });
    if (!p.clips.length) clipsRow.append(h("div.hint", { style: { left: "12px" } }, t("Aggiungi dei video: trascinali qui o premi «Aggiungi video»")));
    const textRow = h("div.row.texts", { style: { width: width + "px" } },
      p.texts.map((t, k) => h("div.tblk" + (sel.kind === "text" && sel.index === k ? ".on" : ""), {
        style: { left: 12 + t.start * pps + "px", width: Math.max(12, (t.end - t.start) * pps) + "px" },
        onpointerdown: (e) => dragText(e, k),
      }, h("span.lbl", t.text), h("div.edge.l", { onpointerdown: (e) => trimText(e, k, "start") }), h("div.edge.r", { onpointerdown: (e) => trimText(e, k, "end") }))));
    // 1.0.1 · La barra della musica: trasparente con l'onda dentro, si trascina, il bordo destro decide dove finisce
    let musicRow;
    if (p.music) {
      const m = p.music;
      const mEnd = musicStop(m);
      const wave = h("canvas.mwave");
      const blk = h("div.mblk.wave", { style: { left: 12 + (m.offset || 0) * pps + "px", width: Math.max(20, (mEnd - (m.offset || 0)) * pps) + "px" },
        onpointerdown: (e) => dragMusic(e) },
        wave, ico("music", 12), h("span.lbl", baseName(m.path)), h("div.edge.r", { onpointerdown: (e) => trimMusicEnd(e) }));
      musicRow = h("div.row.music", { style: { width: width + "px" } }, blk);
      requestAnimationFrame(() => drawMusicWave(wave, m));
    } else musicRow = h("div.row.music", { style: { width: width + "px" } });
    playheadEl = h("div.playhead");
    const inner = h("div.tl-inner", { style: { width: width + "px" } }, ruler, clipsRow, textRow, musicRow, playheadEl);
    inner.addEventListener("pointerdown", (e) => {
      if ((e.target instanceof Element && e.target.closest(".blk, .tblk, .mblk, .tdot"))) return;
      const r = inner.getBoundingClientRect();
      const move = (ev) => seekTo((ev.clientX - r.left - 12) / pps);
      move(e);
      inner.setPointerCapture(e.pointerId);
      inner.onpointermove = move;
      inner.onpointerup = () => { inner.onpointermove = null; };
    });
    // 1.0.1 · Zoom fino al millisecondo: cursore logaritmico, da 8 a 4000 pixel al secondo
    const zoom = h("input", { type: "range", min: 0, max: 1000, value: Math.round(ppsToZoom(pps)), "aria-label": t("Zoom della sequenza"), title: t("Zoom della sequenza: Ctrl + rotella, oppure + e −"), oninput: (e) => zoomTo(zoomToPps(Number(e.target.value))) });
    const scroller = h("div.tl-scroll", inner);
    const prevScroll = timelineEl.querySelector(".tl-scroll")?.scrollLeft || 0;
    timelineEl.replaceChildren(h("div.tl-side", h("span", ico("film", 14)), h("span", ico("file-text", 14)), h("span", ico("music", 14)), h("div.zoom", ico("search", 13), zoom)), scroller);
    scroller.scrollLeft = prevScroll;
    fillRuler(scroller.scrollLeft, scroller.clientWidth || 2000);
    let rulerRaf = 0;
    scroller.addEventListener("scroll", () => {
      cancelAnimationFrame(rulerRaf);
      rulerRaf = requestAnimationFrame(() => fillRuler(scroller.scrollLeft, scroller.clientWidth));
    });
    scroller.addEventListener("wheel", (e) => {
      if (e.ctrlKey) {
        e.preventDefault();
        const r = scroller.getBoundingClientRect();
        zoomTo(pps * (e.deltaY < 0 ? 1.18 : 0.85), (scroller.scrollLeft + e.clientX - r.left - 12) / pps, e.clientX - r.left);
      }
    }, { passive: false });
    updatePlayhead();
  }

  function dragClip(e, i) {
    if (e.target.classList.contains("edge")) return;
    e.preventDefault();
    sel = { kind: "clip", index: i };
    tool = tool === "text" ? "clip" : tool;
    const startX = e.clientX;
    let moved = false;
    const blk = e.currentTarget;
    blk.setPointerCapture(e.pointerId);
    blk.onpointermove = (ev) => {
      const dx = ev.clientX - startX;
      if (Math.abs(dx) > 6) moved = true;
      if (moved) blk.style.transform = `translateX(${dx}px)`;
    };
    blk.onpointerup = (ev) => {
      blk.onpointermove = null;
      blk.onpointerup = null;
      if (!moved) {
        seekTo(starts()[i] + 0.001 + Math.max(0, (ev.clientX - blk.getBoundingClientRect().left) / pps));
        renderTimeline();
        renderInspector();
        renderToolbar();
        return;
      }
      // Nuova posizione: dove cade il centro della clip
      const center = starts()[i] + clipLen(p.clips[i]) / 2 + (ev.clientX - startX) / pps;
      const s = starts();
      let to = p.clips.findIndex((c, k) => center < s[k] + clipLen(c) / 2);
      if (to < 0) to = p.clips.length;
      if (to > i) to--;
      if (to !== i) change((pp) => { const [c] = pp.clips.splice(i, 1); pp.clips.splice(to, 0, c); sel = { kind: "clip", index: to }; });
      else renderTimeline();
    };
  }

  function trimClip(e, i, side) {
    e.preventDefault();
    e.stopPropagation();
    const c = p.clips[i];
    const info = infos[c.path];
    const maxOut = info?.kind === "image" ? 3600 : info?.duration || c.out;
    const before = JSON.stringify(p);
    const x0 = e.clientX, in0 = c.in, out0 = c.out, speed = c.fx?.speed || 1;
    capture(e, (ev) => {
      const d = ((ev.clientX - x0) / pps) * speed;
      if (side === "in") c.in = Math.max(0, Math.min(c.out - 0.1, in0 + d));
      else c.out = Math.min(maxOut, Math.max(c.in + 0.1, out0 + d));
      renderTimeline();
      showAt(side === "in" ? starts()[i] : starts()[i] + clipLen(c) - 0.01, true);
    }, () => {
      if (JSON.stringify(p) !== before) { undo.push(before); redo = []; afterChange(); }
    });
  }

  function dragText(e, k) {
    if (e.target.classList.contains("edge")) return;
    e.preventDefault();
    sel = { kind: "text", index: k };
    tool = "text";
    renderToolbar();
    const t = p.texts[k];
    const before = JSON.stringify(p);
    const x0 = e.clientX, s0 = t.start, len = t.end - t.start;
    capture(e, (ev) => {
      t.start = Math.max(0, Math.min(Math.max(0, total() - len), s0 + (ev.clientX - x0) / pps));
      t.end = t.start + len;
      renderTimeline();
    }, () => {
      if (JSON.stringify(p) !== before) { undo.push(before); redo = []; afterChange(); } else { seekTo(t.start + 0.05); renderAll(); }
    });
  }

  function trimText(e, k, side) {
    e.preventDefault();
    e.stopPropagation();
    const t = p.texts[k];
    const before = JSON.stringify(p);
    const x0 = e.clientX, v0 = t[side];
    capture(e, (ev) => {
      const v = v0 + (ev.clientX - x0) / pps;
      if (side === "start") {
        const old = t.start;
        t.start = Math.max(0, Math.min(t.end - 0.3, v));
        // Le parole restano dove sono dette
        if (Array.isArray(t.wordTimes)) t.wordTimes = t.wordTimes.map((w) => Math.max(0, w + old - t.start));
      } else t.end = Math.min(total(), Math.max(t.start + 0.3, v));
      renderTimeline();
    }, () => {
      if (JSON.stringify(p) !== before) { undo.push(before); redo = []; afterChange(); }
    });
  }

  /** Trascinamento: la cattura sta sul contenitore della sequenza, che resta anche quando la sequenza si ridisegna. */
  // ── 1.0.1 · Musica: fine, onda, trascinamento
  const musicPeaks = {}; // path → picchi (50 al secondo)
  const PEAKS_RATE = 50;
  function songLen(m) { return infos[m.path]?.duration || 0; }
  /** Dove finisce la musica nel montaggio: la fine scelta, la fine del brano (se non si ripete) o la fine del video. */
  function musicStop(m) {
    const T = total(), off = m.offset || 0;
    let e = m.end != null ? Math.min(T, Math.max(off + 0.1, m.end)) : T;
    const sl = songLen(m);
    if (!m.looped && sl > 0) e = Math.min(e, off + Math.max(0.05, sl - (m.in || 0)));
    return e;
  }
  function drawMusicWave(cv, m) {
    if (!cv.isConnected) return;
    const r = cv.getBoundingClientRect();
    // Una tela non può superare ~32 000 pixel: con lo zoom alto si disegna a risoluzione ridotta
    const kx = Math.min(devicePixelRatio, 30000 / Math.max(1, r.width));
    cv.width = Math.max(1, Math.round(r.width * kx));
    cv.height = Math.max(1, Math.round(r.height * devicePixelRatio));
    const pk = musicPeaks[m.path];
    const sl = songLen(m);
    if (!pk) {
      if (sl > 0 && musicPeaks[m.path] === undefined) {
        musicPeaks[m.path] = null;
        invoke("waveform", { path: m.path, points: Math.max(50, Math.min(200000, Math.round(sl * PEAKS_RATE))) })
          .then((v) => { musicPeaks[m.path] = v; renderTimeline(); }).catch(() => {});
      }
      return;
    }
    const g = cv.getContext("2d");
    const rate = pk.length / Math.max(0.05, sl);
    const avail = Math.max(0.05, sl - (m.in || 0));
    const step = Math.max(1, 2.5 * kx), mid = cv.height / 2 + 3 * devicePixelRatio, maxH = cv.height / 2 - 5 * devicePixelRatio;
    g.fillStyle = getComputedStyle(cv).color;
    for (let x = 0; x < cv.width; x += step) {
      let tt = x / kx / pps;
      if (tt >= avail) { if (m.looped) tt %= avail; else break; }
      const a = Math.floor(((m.in || 0) + tt) * rate), b = Math.floor(((m.in || 0) + tt + step / kx / pps) * rate);
      let v = 0;
      for (let j = Math.max(0, a); j <= Math.min(pk.length - 1, Math.max(a, b)); j++) if (pk[j] > v) v = pk[j];
      const hh = Math.max(0.5, v * maxH);
      g.fillRect(x, mid - hh, Math.max(0.5, step - kx), hh * 2);
    }
  }
  function dragMusic(e) {
    if (e.target.classList.contains("edge")) return;
    e.preventDefault();
    tool = "audio"; renderToolbar(); renderInspector();
    const m = p.music, before = JSON.stringify(p);
    const x0 = e.clientX, o0 = m.offset || 0, e0 = m.end;
    capture(e, (ev) => {
      const o = Math.max(0, Math.min(Math.max(0, total() - 0.5), o0 + (ev.clientX - x0) / pps));
      m.offset = o;
      if (e0 != null) m.end = e0 + (o - o0);
      renderTimeline();
    }, () => { if (JSON.stringify(p) !== before) { undo.push(before); redo = []; afterChange(); } });
  }
  function trimMusicEnd(e) {
    e.preventDefault();
    e.stopPropagation();
    const m = p.music, before = JSON.stringify(p);
    const x0 = e.clientX, v0 = musicStop(m);
    capture(e, (ev) => {
      const v = Math.max((m.offset || 0) + 0.2, Math.min(total(), v0 + (ev.clientX - x0) / pps));
      m.end = v >= total() - 0.01 ? null : v;
      renderTimeline();
    }, () => { if (JSON.stringify(p) !== before) { undo.push(before); redo = []; afterChange(); } });
  }
  /** 1.0.1 · «Stacca l'audio»: l'audio della clip diventa la traccia audio sotto il video; la clip resta muta. */
  function detachAudio(ci) {
    const c = p.clips[ci];
    if (!c) return;
    if (p.music) return toast(t("C’è già una musica: c’è posto per una traccia audio sola. Togli la musica e riprova."));
    if ((c.fx?.speed || 1) !== 1) return toast(t("Prima riporta la clip a velocità 1×: l’audio staccato va alla velocità normale."));
    if (infos[c.path] && !infos[c.path].has_audio) return toast(t("Questa clip non ha audio."));
    const start = p.clips.slice(0, ci).reduce((a, x) => a + clipLen(x), 0);
    change((pp) => {
      pp.music = { path: c.path, offset: start, in: c.in, end: start + clipLen(c), looped: false, volume: 1, fadeIn: 0, fadeOut: 0, duck: false };
      pp.clips[ci].muted = true;
    });
  }

  // ── 1.0.1 · Zoom della sequenza fino al millisecondo
  const PPS_MIN = 8, PPS_MAX = 4000;
  function ppsToZoom(v) { return (Math.log(v / PPS_MIN) / Math.log(PPS_MAX / PPS_MIN)) * 1000; }
  function zoomToPps(z) { return PPS_MIN * Math.pow(PPS_MAX / PPS_MIN, z / 1000); }
  /** Cambia lo zoom tenendo fermo un momento (sotto il puntatore, o l'indicatore). */
  function zoomTo(v, anchorT = time, anchorX = null) {
    const sc = timelineEl.querySelector(".tl-scroll");
    const ax = anchorX ?? (sc ? 12 + anchorT * pps - sc.scrollLeft : 0);
    pps = Math.max(PPS_MIN, Math.min(PPS_MAX, v));
    renderTimeline();
    const sc2 = timelineEl.querySelector(".tl-scroll");
    if (sc2) sc2.scrollLeft = Math.max(0, 12 + anchorT * pps - ax);
  }
  /** «0:03,250»: i millesimi quando lo zoom li fa vedere. */
  function fmtMs(s, step) {
    const digits = step < 0.01 ? 3 : step < 0.1 ? 2 : 1;
    const whole = Math.floor(s + 1e-9);
    const frac = Math.round((s - whole) * 10 ** digits);
    return `${fmtTime(whole)},${String(Math.min(frac, 10 ** digits - 1)).padStart(digits, "0")}`;
  }

  function capture(e, move, up) {
    timelineEl.setPointerCapture(e.pointerId);
    const end = () => {
      timelineEl.removeEventListener("pointermove", move);
      timelineEl.removeEventListener("pointerup", end);
      timelineEl.removeEventListener("pointercancel", end);
      try { timelineEl.releasePointerCapture(e.pointerId); } catch {}
      up();
    };
    timelineEl.addEventListener("pointermove", move);
    timelineEl.addEventListener("pointerup", end);
    timelineEl.addEventListener("pointercancel", end);
  }

  function transitionMenu(i, anchor) {
    document.querySelector(".pop")?.remove();
    const c = p.clips[i];
    const cur = c.transition;
    const pop = h("div.pop", { role: "dialog" },
      h("b", t("Transizione")),
      h("div.opts", h("button.opt" + (!cur ? ".on" : ""), { onclick: () => { change((pp) => (pp.clips[i].transition = null)); pop.remove(); } }, t("Nessuna")),
        TRANSITIONS.map(([k, l]) => h("button.opt" + (cur?.kind === k ? ".on" : ""), { onclick: () => { change((pp) => (pp.clips[i].transition = { kind: k, duration: cur?.duration || 0.6 })); pop.remove(); } }, l))),
      h("div", { style: { fontSize: "12.5px", color: "var(--quiet)" } }, t("Durata")),
      h("div.opts", [0.3, 0.6, 1, 1.5].map((d) => h("button.opt" + (cur?.duration === d ? ".on" : ""), { onclick: () => { change((pp) => (pp.clips[i].transition = { kind: cur?.kind || "fade", duration: d })); pop.remove(); } }, dec(String(d).replace(".", ",") + " s")))),
      h("button.btn", { onclick: () => { change((pp) => pp.clips.forEach((cc, k) => { if (k > 0) cc.transition = { kind: cur?.kind || "fade", duration: cur?.duration || 0.6 }; })); pop.remove(); } }, t("Applica a tutte le clip")));
    const r = anchor.getBoundingClientRect();
    pop.style.left = Math.max(10, Math.min(window.innerWidth - 300, r.left - 130)) + "px";
    pop.style.top = Math.max(10, r.top - 230) + "px";
    document.body.append(pop);
    setTimeout(() => document.addEventListener("pointerdown", function off(ev) { if (!pop.contains(ev.target)) { pop.remove(); document.removeEventListener("pointerdown", off); } }), 0);
  }

  // ── Azioni
  async function pickClips() {
    setDemoPick("video");
    const paths = await pickFiles([{ name: t("Video e foto"), extensions: ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "mts", "m2ts", "3gp", "jpg", "jpeg", "png", "heic", "webp"] }]);
    if (paths.length) addClips(paths);
  }

  function splitHere() {
    const at = clipAt(time);
    if (!at) return;
    const c = p.clips[at.i];
    const speed = c.fx?.speed || 1;
    const cut = c.in + at.local * speed;
    if (cut - c.in < 0.1 || c.out - cut < 0.1) return toast(t("Sposta l'indicatore un po' dentro la clip per dividerla."));
    change((pp) => {
      const a = pp.clips[at.i];
      const b = JSON.parse(JSON.stringify(a));
      b.id = uid();
      b.in = cut;
      b.transition = null;
      if (b.fx) b.fx.fadeIn = 0;
      a.out = cut;
      if (a.fx) a.fx.fadeOut = 0;
      pp.clips.splice(at.i + 1, 0, b);
      sel = { kind: "clip", index: at.i + 1 };
    });
  }

  // «Togli i silenzi»: la clip si divide e le pause lunghe spariscono (tagli netti, come nei video dei social)
  async function removeSilences(ci) {
    const c = p.clips[ci];
    if (!c) return;
    toast(t("Ascolto la clip per trovare le pause…"));
    let gaps;
    try {
      gaps = await invoke("silences", { path: c.path });
    } catch (e) {
      return toast(tr(String(e)));
    }
    const keep = 0.12; // un respiro prima e dopo ogni pezzo
    const parts = [];
    let from = c.in;
    for (const [s, e] of gaps || []) {
      if (e <= c.in || s >= c.out) continue;
      const a = Math.max(c.in, s + keep), b = Math.min(c.out, e - keep);
      if (b - a < 0.3) continue;
      if (a - from > 0.15) parts.push([from, a]);
      from = b;
    }
    if (c.out - from > 0.15) parts.push([from, c.out]);
    if (parts.length <= 1 && (!parts.length || parts[0][1] - parts[0][0] > c.out - c.in - 0.3)) return toast(t("Non ho trovato pause lunghe in questa clip."));
    const before = clipLen(c);
    change((pp) => {
      const base = pp.clips[ci];
      const made = parts.map(([a, b], k) => {
        const x = JSON.parse(JSON.stringify(base));
        x.id = uid();
        x.in = a;
        x.out = b;
        if (k > 0) x.transition = null;
        if (x.fx) { if (k > 0) x.fx.fadeIn = 0; if (k < parts.length - 1) x.fx.fadeOut = 0; }
        return x;
      });
      pp.clips.splice(ci, 1, ...made);
      sel = { kind: "clip", index: ci };
    });
    const after = parts.reduce((a, [x, y]) => a + (y - x), 0) / (c.fx?.speed || 1);
    toast(t`Tolti ${fmtTime(before - after, true)} di pause in ${parts.length} pezzi. Ctrl+Z per tornare indietro.`);
  }

  function deleteSelected() {
    if (sel.kind === "text") {
      if (!p.texts[sel.index]) return;
      const k = sel.index;
      sel = { kind: "clip", index: 0 };
      change((pp) => pp.texts.splice(k, 1));
      return;
    }
    if (!p.clips[sel.index]) return;
    const k = sel.index;
    sel = { kind: "clip", index: Math.max(0, Math.min(k, p.clips.length - 2)) };
    change((pp) => {
      pp.clips.splice(k, 1);
      if (pp.clips[0]) pp.clips[0].transition = null;
    });
  }

  function addText() {
    if (!p.clips.length) return toast(t("Aggiungi prima un video."));
    const nt = newText(Math.min(time, Math.max(0, total() - 1)));
    nt.end = Math.min(total(), nt.start + 3);
    change((pp) => pp.texts.push(nt));
    sel = { kind: "text", index: p.texts.length - 1 };
    tool = "text";
    renderToolbar();
    renderInspector();
    setTimeout(() => inspector.querySelector("textarea")?.select(), 30);
  }

  // Trascinare un testo sull'anteprima
  overlay.addEventListener("pointerdown", (e) => {
    const r = overlay.getBoundingClientRect();
    const k = overlay.width / r.width;
    const px = (e.clientX - r.left) * k, py = (e.clientY - r.top) * k;
    const idx = p.texts.findIndex((t) => { const r = rects.get(t.id); return r && stateAt(t, time) && px >= r.x && px <= r.x + r.w && py >= r.y && py <= r.y + r.h; });
    if (idx < 0) return;
    e.preventDefault();
    sel = { kind: "text", index: idx };
    tool = "text";
    renderToolbar();
    const t = p.texts[idx];
    const before = JSON.stringify(p);
    const x0 = t.x, y0 = t.y, sx = e.clientX, sy = e.clientY;
    overlay.setPointerCapture(e.pointerId);
    overlay.onpointermove = (ev) => {
      t.x = Math.max(0.05, Math.min(0.95, x0 + (ev.clientX - sx) / r.width));
      t.y = Math.max(0.05, Math.min(0.95, y0 + (ev.clientY - sy) / r.height));
      drawOverlay(time);
    };
    overlay.onpointerup = () => {
      overlay.onpointermove = null;
      if (JSON.stringify(p) !== before) { undo.push(before); redo = []; scheduleSave(); }
      renderInspector();
    };
  });

  // ── Pannello a destra
  const slider = (label, value, min, max, step, onInput, fmt) => {
    const out = h("span.v", fmt ? fmt(value) : String(value));
    const before = { s: null };
    const inp = h("input", { type: "range", min, max, step, value });
    inp.addEventListener("pointerdown", () => (before.s = JSON.stringify(p)));
    inp.addEventListener("input", () => { onInput(Number(inp.value)); out.textContent = fmt ? fmt(Number(inp.value)) : inp.value; showAt(time, false); });
    inp.addEventListener("change", () => { if (before.s && before.s !== JSON.stringify(p)) { undo.push(before.s); redo = []; } before.s = null; afterChange(); });
    return h("label.sl", h("span.k", label), inp, out);
  };
  const chips = (list, cur, on) => h("div.opts", list.map(([v, l]) => h("button.opt" + (v === cur ? ".on" : ""), { onclick: () => on(v) }, l)));
  const pct = (v) => (v > 0 ? "+" : "") + Math.round(v * 100);

  function renderInspector() {
    if (!inspector || !p) return;
    const c = p.clips[sel.kind === "clip" ? sel.index : -1] || p.clips[clipAt(time)?.i ?? -1];
    const ci = c ? p.clips.indexOf(c) : -1;
    const box = [];
    if (tool === "clip") {
      if (!c) box.push(h("p.hint", t("Aggiungi dei video con «Aggiungi video» o trascinandoli qui.")));
      else {
        box.push(h("div.group", t`Clip ${ci + 1} di ${p.clips.length}`), h("p.hint", t`${baseName(c.path)} · da ${fmtTime(c.in, true)} a ${fmtTime(c.out, true)} · ${fmtTime(clipLen(c), true)}`),
          // 1.0.1 · «Funzioni»: tagli, spostamenti e la velocità della clip, nello stesso posto (come sul Mac 5.0.1)
          h("div.group", t("Funzioni")),
          h("div.btns",
            h("button.btn", { onclick: splitHere }, ico("scissors", 14), t("Dividi qui")),
            h("button.btn", { title: t("Toglie le pause lunghe: utile per i video in cui parli"), onclick: () => removeSilences(ci) }, ico("audio-waveform", 14), t("Togli i silenzi")),
            h("button.btn", { onclick: () => change((pp) => pp.clips.splice(ci + 1, 0, { ...JSON.parse(JSON.stringify(c)), id: uid(), transition: null })) }, t("Duplica")),
            h("button.btn", { onclick: () => change((pp) => (pp.clips[ci].muted = !pp.clips[ci].muted)) }, ico(c.muted ? "volume-2" : "volume-x", 14), c.muted ? t("Riattiva l'audio") : t("Togli l'audio")),
            h("button.btn", { title: t("L’audio della clip diventa la traccia audio sotto il video: lo sposti, lo accorci e lo tagli da solo. La clip resta muta"), onclick: () => detachAudio(ci) }, ico("audio-waveform", 14), t("Stacca l’audio")),
            // 1.0.1 · Solo il pezzo tenuto nella clip, in un file audio accanto al video
            h("button.btn", { title: t("Solo il pezzo tenuto nella clip"), onclick: () => run("cut", [{ path: c.path, name: baseName(c.path), size: infos[c.path]?.size || 0 }], { start: +c.in.toFixed(3), end: +c.out.toFixed(3), audio: true }, "editor") }, ico("music", 14), t("Estrai l’audio della clip")),
            h("button.btn", { disabled: ci === 0 || null, onclick: () => change((pp) => { const [x] = pp.clips.splice(ci, 1); pp.clips.splice(ci - 1, 0, x); sel.index = ci - 1; }) }, t("◀ Sposta")),
            h("button.btn", { disabled: ci === p.clips.length - 1 || null, onclick: () => change((pp) => { const [x] = pp.clips.splice(ci, 1); pp.clips.splice(ci + 1, 0, x); sel.index = ci + 1; }) }, t("Sposta ▶")),
            h("button.btn", { onclick: () => { sel = { kind: "clip", index: ci }; deleteSelected(); } }, ico("trash-2", 14), t("Elimina"))),
          h("div.group", t("Velocità")),
          chips(SPEEDS.map((s) => [s, dec(String(s).replace(".", ",") + "×")]), c.fx?.speed || 1,
            (v) => change((pp) => { const f = (pp.clips[ci].fx = pp.clips[ci].fx || {}); f.speed = v; })),
          h("p.hint", t("Trascina i bordi della clip nella sequenza per accorciarla; trascinala per spostarla. Tasti: S divide, Canc elimina, Ctrl+Z annulla.")));
      }
    } else if (tool === "look") {
      const scopeAll = store.get("ed.lookAll", false);
      const getL = () => (scopeAll ? p.look : c?.look) || emptyLook();
      const setL = (fn) => change((pp) => {
        const target = scopeAll ? (pp.look = pp.look || emptyLook()) : c ? (pp.clips[ci].look = pp.clips[ci].look || emptyLook()) : null;
        if (target) fn(target);
      });
      const L = getL();
      box.push(chips([[false, t("Questa clip")], [true, t("Tutto il video")]], scopeAll, (v) => { store.set("ed.lookAll", v); renderInspector(); }));
      const th = c && thumbs[c.path];
      box.push(h("div.looks", PRESETS.map(([id, name]) => {
        const r = resolve({ ...emptyLook(), preset: id, amount: 1 });
        return h("button.lk" + (L.preset === id ? ".on" : ""), { onclick: () => setL((l) => { l.preset = id; if (l.amount < 0.05) l.amount = 1; }) },
          h("span.im", { style: { backgroundImage: th ? `url(${th})` : "none", filter: id === "none" ? "none" : `url(#pv-${id})` } }), name);
      })));
      ensurePresetDefs();
      box.push(slider(t("Forza"), L.amount, 0, 1, 0.05, (v) => setDirect((l) => (l.amount = v)), (v) => Math.round(v * 100) + "%"));
      box.push(h("div.group", t("Regolazioni")));
      for (const [k, label] of [["brightness", t("Luminosità")], ["contrast", t("Contrasto")], ["saturation", t("Saturazione")], ["warmth", t("Calore")]]) {
        box.push(slider(label, L[k], -1, 1, 0.05, (v) => setDirect((l) => (l[k] = v)), pct));
      }
      box.push(slider(t("Nitidezza"), L.sharpness, 0, 1, 0.05, (v) => setDirect((l) => (l.sharpness = v)), (v) => Math.round(v * 100)));
      box.push(slider(t("Vignettatura"), L.vignette, 0, 1, 0.05, (v) => setDirect((l) => (l.vignette = v)), (v) => Math.round(v * 100)));
      box.push(h("button.btn", { onclick: () => change((pp) => { if (scopeAll) pp.look = null; else if (c) pp.clips[ci].look = null; }) }, t("Togli filtro e regolazioni")));
      function setDirect(fn) {
        const target = scopeAll ? (p.look = p.look || emptyLook()) : c ? (p.clips[ci].look = p.clips[ci].look || emptyLook()) : null;
        if (target) fn(target);
      }
    } else if (tool === "fx") {
      if (!c) box.push(h("p.hint", t("Scegli una clip nella sequenza.")));
      else {
        const fx = c.fx || {};
        const setFx = (fn) => change((pp) => { const f = (pp.clips[ci].fx = pp.clips[ci].fx || {}); fn(f); });
        box.push(h("div.group", t("Velocità")), chips(SPEEDS.map((s) => [s, dec(String(s).replace(".", ",") + "×")]), fx.speed || 1, (v) => setFx((f) => (f.speed = v))),
          h("p.hint", t("La voce mantiene il suo tono.")),
          h("div.group", t("Zoom lento")), chips([["none", t("Nessuno")], ["in", t("Avvicina")], ["out", t("Allontana")]], fx.zoom || "none", (v) => setFx((f) => (f.zoom = v))),
          h("div.group", t("Capovolgi e ruota")),
          h("div.btns",
            h("button.btn" + (fx.flipH ? ".brass" : ""), { onclick: () => setFx((f) => (f.flipH = !f.flipH)) }, t("Specchia")),
            h("button.btn" + (fx.flipV ? ".brass" : ""), { onclick: () => setFx((f) => (f.flipV = !f.flipV)) }, t("Capovolgi")),
            h("button.btn", { onclick: () => setFx((f) => (f.rotate = ((f.rotate || 0) + 90) % 360)) }, ico("rotate-cw", 14), t`Ruota${fx.rotate ? ` (${fx.rotate}°)` : ""}`)),
          h("div.group", t("Altro")),
          slider(t("Sfocatura"), fx.blur || 0, 0, 1, 0.05, (v) => { (p.clips[ci].fx = p.clips[ci].fx || {}).blur = v; }, (v) => Math.round(v * 100)),
          slider(t("Dissolvenza in entrata"), fx.fadeIn || 0, 0, 3, 0.1, (v) => { (p.clips[ci].fx = p.clips[ci].fx || {}).fadeIn = v; }, (v) => dec(String(v.toFixed(1)).replace(".", ",") + " s")),
          slider(t("Dissolvenza in uscita"), fx.fadeOut || 0, 0, 3, 0.1, (v) => { (p.clips[ci].fx = p.clips[ci].fx || {}).fadeOut = v; }, (v) => dec(String(v.toFixed(1)).replace(".", ",") + " s")),
          h("button.btn", { onclick: () => change((pp) => pp.clips.forEach((cc) => (cc.fx = JSON.parse(JSON.stringify(fx))))) }, t("Applica a tutte le clip")));
      }
    } else if (tool === "text") {
      const tx = sel.kind === "text" ? p.texts[sel.index] : null;
      box.push(h("div.btns", h("button.btn.primary", { onclick: addText }, ico("plus", 14), t("Aggiungi un testo")),
        subsBusy ? h("button.btn", { onclick: () => subsJob && invoke("cancel_job", { id: subsJob }) }, t("Interrompi"))
          : h("button.btn", { onclick: autoSubtitles }, ico("message-circle", 14), t("Sottotitoli automatici"))),
        subsStatus,
        h("p.hint", t("Il testo compare all'indicatore per 3 secondi. Trascinalo sull'anteprima per spostarlo, e nella riga «Testi» per cambiare quando si vede.")));
      if (tx) {
        const k = sel.index;
        const ta = h("textarea", { rows: 3, "aria-label": t("Testo") });
        ta.value = tx.text;
        let before = null;
        ta.addEventListener("focus", () => (before = JSON.stringify(p)));
        ta.addEventListener("input", () => { tx.text = ta.value; drawOverlay(time); });
        ta.addEventListener("blur", () => { if (before && before !== JSON.stringify(p)) { undo.push(before); redo = []; afterChange(); } });
        const setT = (fn) => change((pp) => fn(pp.texts[k]));
        box.push(h("div.group", t("Testo")), ta,
          h("div.group", t("Modello")), chips(STYLES, tx.style, (v) => setT((x) => { x.style = v; if (v === "subtitle") x.y = 0.86; if (v === "caption") x.y = 0.85; })),
          h("div.group", t("Animazione")), chips(ANIMS, tx.anim, (v) => setT((x) => (x.anim = v))),
          h("div.group", t("Colore")), h("div.opts", COLORS.map(([id, name, hex]) => h("button.opt" + (tx.color === id ? ".on" : ""), { onclick: () => setT((x) => (x.color = id)) }, h("span.sw", { style: { background: hex } }), name))),
          h("div.group", t("Quando")), h("p.hint", t`Da ${fmtTime(tx.start, true)} a ${fmtTime(tx.end, true)}`),
          h("div.btns",
            h("button.btn", { onclick: () => setT((x) => { x.start = Math.min(time, x.end - 0.3); }) }, t("Inizia qui")),
            h("button.btn", { onclick: () => setT((x) => { x.end = Math.max(time, x.start + 0.3); }) }, t("Finisci qui")),
            h("button.btn", { onclick: () => { deleteSelected(); } }, ico("trash-2", 14), t("Elimina"))));
      } else if (p.texts.length) {
        box.push(h("div.group", t("Testi")), p.texts.map((t, k) => h("button.tool", { onclick: () => { sel = { kind: "text", index: k }; seekTo(t.start + 0.05); renderAll(); } },
          h("span.ic", ico("file-text", 16)), h("span.txt", h("b", t.text.slice(0, 40)), h("span", `${fmtTime(t.start)} – ${fmtTime(t.end)}`)))));
      }
    } else if (tool === "audio") {
      // 1.0.1 · Prima la clip scelta (un pezzo diviso è una clip a sé), poi tutti i video insieme
      if (c) {
        box.push(h("div.group", t("Audio di questa clip")),
          h("p.hint", t`Clip ${ci + 1} di ${p.clips.length}: vale solo per questo pezzo`),
          h("label.check", h("input", { type: "checkbox", checked: c.muted || null, onchange: (e) => change((pp) => (pp.clips[ci].muted = e.target.checked)) }), t("Muta questa clip")),
          slider(t("Volume della clip"), c.volume ?? 1, 0, 2, 0.05, (v) => (p.clips[ci].volume = v), (v) => Math.round(v * 100) + "%"));
      }
      box.push(h("div.group", t("Tutti i video insieme")),
        h("label.check", h("input", { type: "checkbox", checked: p.originalMuted || null, onchange: (e) => change((pp) => (pp.originalMuted = e.target.checked)) }), t("Muti tutti")),
        slider(t("Volume"), p.originalVolume ?? 1, 0, 2, 0.05, (v) => (p.originalVolume = v), (v) => Math.round(v * 100) + "%"));
      box.push(h("div.group", t("Musica")));
      if (!p.music) {
        box.push(h("button.btn.primary", { onclick: pickMusic }, ico("music", 14), t("Aggiungi musica")), h("p.hint", t("Una canzone o l'audio di un video. Si abbassa da sola quando nel video si parla.")));
      } else {
        const m = p.music;
        const setM = (fn) => change((pp) => fn(pp.music));
        box.push(h("p.hint", baseName(m.path)),
          slider(t("Volume"), m.volume ?? 0.8, 0, 1.5, 0.05, (v) => (p.music.volume = v), (v) => Math.round(v * 100) + "%"),
          h("label.check", h("input", { type: "checkbox", checked: m.duck !== false || null, onchange: (e) => setM((x) => (x.duck = e.target.checked)) }), t("Abbassa la musica quando si parla")),
          h("label.check", h("input", { type: "checkbox", checked: m.looped || null, onchange: (e) => setM((x) => (x.looped = e.target.checked)) }), t("Ricomincia finché il video non finisce")),
          slider(t("Dissolvenza iniziale"), m.fadeIn ?? 1, 0, 5, 0.5, (v) => (p.music.fadeIn = v), (v) => dec(String(v).replace(".", ",") + " s")),
          slider(t("Dissolvenza finale"), m.fadeOut ?? 2, 0, 5, 0.5, (v) => (p.music.fadeOut = v), (v) => dec(String(v).replace(".", ",") + " s")),
          h("div.btns",
            h("button.btn", { onclick: () => setM((x) => { x.offset = time; if (x.end != null && x.end < time + 0.2) x.end = null; }) }, t("Parte qui")),
            h("button.btn", { title: t("La musica finisce nel punto dell’indicatore (oppure trascina il bordo destro della sua barra)"), onclick: () => { if (time > (m.offset || 0) + 0.2) setM((x) => (x.end = time)); } }, t("Finisce qui")),
            m.end != null ? h("button.btn", { onclick: () => setM((x) => (x.end = null)) }, t("Fino alla fine")) : null,
            h("button.btn", { onclick: pickMusic }, t("Cambia")),
            h("button.btn", { onclick: () => change((pp) => (pp.music = null)) }, ico("trash-2", 14), t("Togli"))));
      }
    } else if (tool === "format") {
      const [w, hh] = canvasSize();
      box.push(h("div.group", t("Formato")), chips([["orig", t("Originale")], ["9x16", "9:16 Reels"], ["1x1", "1:1 Post"], ["4x5", "4:5 Feed"], ["16x9", "16:9 YouTube"]], p.aspect, (v) => change((pp) => (pp.aspect = v))),
        h("div.group", t("Risoluzione")), chips([[720, "720p"], [1080, "1080p"], [2160, "4K"]], p.resolution, (v) => change((pp) => (pp.resolution = v))),
        h("div.group", t("Fluidità")), chips([[24, "24"], [30, "30"], [60, "60"]], p.fps, (v) => change((pp) => (pp.fps = v))),
        h("p.hint", t`Il video sarà ${w}×${hh}, ${p.fps} fotogrammi al secondo, ${fmtTime(total())}. Mai più grande dell'originale.`));
    }
    inspector.replaceChildren(...box.flat());
  }

  // Miniature dei filtri: le stesse matrici, come filtri SVG
  function ensurePresetDefs() {
    for (const [id] of PRESETS) {
      if (id === "none" || svgDefs.querySelector(`#pv-${id}`)) continue;
      const f = document.createElementNS("http://www.w3.org/2000/svg", "filter");
      f.id = `pv-${id}`;
      f.setAttribute("color-interpolation-filters", "sRGB");
      const m = document.createElementNS("http://www.w3.org/2000/svg", "feColorMatrix");
      m.setAttribute("type", "matrix");
      m.setAttribute("values", feMatrix(resolve({ ...emptyLook(), preset: id, amount: 1 }).a));
      f.append(m);
      svgDefs.append(f);
    }
  }

  // ── Sottotitoli automatici: si ascoltano le clip (sul computer), le parole diventano righe
  // facili da leggere (al massimo 7 parole, 42 caratteri, 3,5 secondi; si va a capo alle pause e ai punti)
  let subsBusy = false;
  let subsJob = null;
  const subsStatus = h("p.hint", { "aria-live": "polite" });
  function makeLines(words) {
    const out = [];
    let cur = [];
    const flush = () => {
      if (!cur.length) return;
      const a = cur[0], b = cur[cur.length - 1];
      out.push({ text: cur.map((w) => w.text).join(" "), start: a.start, end: Math.max(b.end, a.start + 1), words: cur.slice() });
      cur = [];
    };
    for (const w of words) {
      if (!w.text.trim()) continue;
      if (cur.length) {
        const first = cur[0], last = cur[cur.length - 1];
        const chars = cur.map((x) => x.text).join(" ").length + 1 + w.text.length;
        if (w.start - last.end > 0.6 || cur.length >= 7 || chars > 42 || w.end - first.start > 3.5) flush();
      }
      cur.push(w);
      if (/[.!?]$/.test(w.text)) flush();
    }
    flush();
    for (let i = 0; i < out.length - 1; i++) if (out[i].end > out[i + 1].start) out[i].end = Math.max(out[i].start + 0.3, out[i + 1].start);
    return out;
  }
  async function autoSubtitles() {
    if (!p.clips.length) return toast(t("Aggiungi prima un video."));
    if (DEMO) return toast(t("Nella prova non si può ascoltare: funziona nell'app."));
    subsBusy = true;
    renderInspector();
    const lang = store.get("voiceLang", "auto");
    const paths = [...new Set(p.clips.filter((c) => infos[c.path]?.has_audio).map((c) => c.path))];
    if (!paths.length) { subsBusy = false; renderInspector(); return toast(t("Le clip non hanno audio.")); }
    let which = 0;
    const startedOn = current;
    subsJob = "v" + uid();
    const un = await window.__TAURI__.event.listen("voice-progress", (e) => {
      const { stage, progress } = e.payload;
      subsStatus.textContent = stage === "modello" ? t`Scarico il modello della voce (solo la prima volta)… ${Math.round(progress * 100)}%`
        : t`Ascolto ${paths.length > 1 ? t`la clip ${which + 1} di ${paths.length}` : t("la clip")}… ${Math.round(progress * 100)}%`;
    });
    const byPath = {};
    try {
      for (which = 0; which < paths.length; which++) {
        subsStatus.textContent = t("Preparo…");
        const segs = await invoke("transcribe_words", { path: paths[which], lang, id: subsJob });
        if (current !== startedOn || !p) throw new Error("annullato");
        byPath[paths[which]] = segs.flatMap((s) => (s.words?.length ? s.words : s.text.split(/\s+/).map((t, k, all) => ({ text: t, start: s.start + ((s.end - s.start) * k) / all.length, end: s.start + ((s.end - s.start) * (k + 1)) / all.length }))));
      }
    } catch (e) {
      un();
      subsBusy = false;
      subsJob = null;
      subsStatus.textContent = "";
      if (current === startedOn && p) renderInspector();
      if (String(e).includes("annullato") || String(e).includes("interrotto")) return;
      return toast(tr(String(e)));
    }
    un();
    subsJob = null;
    if (current !== startedOn || !p) return;
    const st = starts();
    const made = [];
    p.clips.forEach((c, i) => {
      const words = byPath[c.path];
      if (!words || c.muted) return;
      const speed = c.fx?.speed || 1;
      for (const line of makeLines(words)) {
        // Solo le parole dentro il pezzo usato della clip
        const ws = line.words.filter((w) => w.start >= c.in - 0.05 && w.start < c.out - 0.05);
        if (!ws.length) continue;
        const a = Math.max(c.in, ws[0].start), b = Math.min(line.end, c.out);
        if (b - a <= 0.15) continue;
        const tStart = st[i] + (a - c.in) / speed, tEnd = st[i] + (b - c.in) / speed;
        made.push({ id: "t" + uid(), text: ws.map((w) => w.text).join(" "), style: "subtitle", start: tStart, end: tEnd, x: 0.5, y: 0.86, anim: "word", color: "white",
          wordTimes: ws.map((w) => Math.max(0, st[i] + (Math.max(w.start, c.in) - c.in) / speed - tStart)) });
      }
    });
    subsBusy = false;
    subsStatus.textContent = made.length ? t`Fatto: ${made.length} righe di sottotitoli. Correggile come gli altri testi; Ctrl+Z le toglie tutte.` : t("Non ho sentito parole nelle clip.");
    if (made.length) change((pp) => pp.texts.push(...made));
    else renderInspector();
  }

  async function pickMusic() {
    setDemoPick("audio");
    const paths = await pickFiles([{ name: t("Musica"), extensions: ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aac", "mp4", "mov"] }]);
    if (!paths.length) return;
    const r = (await invoke("probe_files", { paths: [paths[0]] }))[0];
    if (!r?.ok || !r.info.has_audio) return toast(t("In questo file non c'è audio."));
    infos[r.info.path] = r.info;
    change((pp) => (pp.music = { path: r.info.path, offset: 0, in: 0, looped: false, volume: 0.8, fadeIn: 1, fadeOut: 2, duck: true }));
  }

  // ── Esportazione
  async function exportVideo() {
    if (!p.clips.length) return toast(t("Aggiungi almeno un video."));
    stop();
    const [W, H] = canvasSize();
    const overlays = [];
    try {
      for (const t of p.texts) {
        if (!t.text.trim() || t.end <= t.start) continue;
        const o = exportOverlay(t, W, H);
        const save = (d) => (DEMO ? "demo.png" : invoke("save_overlay", { pngBase64: d }));
        if (o.frames) {
          const frames = [];
          for (const f of o.frames) frames.push({ png: await save(f.dataUrl), duration: f.duration });
          overlays.push({ frames, png: "", start: o.start, end: o.end, fade_in: o.fadeIn, fade_out: o.fadeOut, slide: 0 });
        } else {
          overlays.push({ png: await save(o.png), start: o.start, end: o.end, fade_in: o.fadeIn, fade_out: o.fadeOut, slide: o.slide });
        }
      }
    } catch (e) {
      return toast(t`Non riesco a preparare i testi: ${tr(String(e))}`);
    }
    const lk = (l) => (l && !isIdentity(l) ? { preset: l.preset, amount: l.amount, brightness: l.brightness, contrast: l.contrast, saturation: l.saturation, warmth: l.warmth, sharpness: l.sharpness, vignette: l.vignette } : null);
    const project = {
      name: p.name,
      clips: p.clips.map((c) => ({
        path: c.path, in_point: c.in, out_point: c.out, muted: !!c.muted, volume: c.volume ?? null, look: lk(c.look),
        transition: c.transition ? { kind: c.transition.kind, duration: c.transition.duration } : null,
        fx: c.fx ? { speed: c.fx.speed || 1, zoom: c.fx.zoom || "none", flip_h: !!c.fx.flipH, flip_v: !!c.fx.flipV, rotate: c.fx.rotate || 0, blur: c.fx.blur || 0, fade_in: c.fx.fadeIn || 0, fade_out: c.fx.fadeOut || 0 } : null,
      })),
      music: p.music ? { path: p.music.path, offset: p.music.offset || 0, in_point: p.music.in || 0, looped: !!p.music.looped, volume: p.music.volume ?? 0.8, fade_in: p.music.fadeIn ?? 1, fade_out: p.music.fadeOut ?? 2, duck: p.music.duck !== false, end: p.music.end ?? null } : null,
      original_volume: p.originalVolume ?? 1,
      original_muted: !!p.originalMuted,
      aspect: p.aspect || "orig",
      resolution: p.resolution || 1080,
      fps: p.fps || 30,
      look: lk(p.look),
      overlays,
    };
    const files = [...new Set(p.clips.map((c) => c.path))].map((path) => ({ path, name: baseName(path), size: infos[path]?.size || 0 }));
    run("vproject", files, project, "editor");
  }

  // ── Tasti
  function onKey(e) {
    if (!el.isConnected || !p || !inspector || document.querySelector(".modal-bg")) return;
    if ((e.target instanceof Element && e.target.closest("input, textarea, select"))) return;
    const k = e.key;
    if ((e.ctrlKey || e.metaKey) && (k === "z" || k === "Z")) { e.preventDefault(); e.shiftKey ? doRedo() : doUndo(); return; }
    if ((e.ctrlKey || e.metaKey) && (k === "y" || k === "Y")) { e.preventDefault(); doRedo(); return; }
    if ((e.ctrlKey || e.metaKey) && (k === "s" || k === "S")) { e.preventDefault(); saveNow(); return; }
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    if (k === " " && !(e.target instanceof Element && e.target.closest("button"))) { e.preventDefault(); playing ? stop() : play(); }
    else if (k === "s" || k === "S") splitHere();
    else if (k === "t" || k === "T") addText();
    else if (k === "Delete" || k === "Backspace") deleteSelected();
    else if (k === "j" || k === "J") seekTo(time - 1);
    else if (k === "k" || k === "K") stop();
    else if (k === "l" || k === "L") play();
    // 1.0.1 · ← → un fotogramma, Maiusc un secondo, Alt un millisecondo; + e − lo zoom della sequenza
    else if (k === "ArrowLeft") { e.preventDefault(); seekTo(time - (e.altKey ? 0.001 : e.shiftKey ? 1 : 1 / (p.fps || 30))); }
    else if (k === "ArrowRight") { e.preventDefault(); seekTo(time + (e.altKey ? 0.001 : e.shiftKey ? 1 : 1 / (p.fps || 30))); }
    else if (k === "+" || k === "=") { e.preventDefault(); zoomTo(pps * 1.6, time); }
    else if (k === "-" || k === "_") { e.preventDefault(); zoomTo(pps / 1.6, time); }
    else if (k === "Home") seekTo(0);
    else if (k === "End") seekTo(total());
  }
  document.addEventListener("keydown", onKey);
  new ResizeObserver(() => { if (p) { layoutStage(); showAt(time, false); } }).observe(stage);

  showProjects();
  return {
    el,
    /** Apre l'editor con questi video (nuovo progetto) */
    openWith(paths) { openProject(null, paths); },
    add(paths) { if (p) addClips(paths); else openProject(null, paths); },
    leave() { stop(); },
  };
}
