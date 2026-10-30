// Scegliere un pezzo: anteprima (video o audio), una barra con due maniglie, «Inizio qui» e «Fine qui».
// I tasti I e O mettono inizio e fine mentre si guarda; Spazio avvia e ferma.

import { fileUrl, DEMO } from "./api.js";
import { fmtTime, fmtTimeMs, h, ico, parseTime, toast } from "./util.js";
import { t } from "./i18n.js";

export function createTrim({ path, duration, media, peaks, maxLen = 0, onChange }) {
  let start = 0;
  let end = maxLen ? Math.min(duration, maxLen) : duration;
  const el = h("div.trim");
  const player = media === "video" ? h("video", { preload: "metadata", playsinline: true }) : h("audio", { preload: "metadata" });
  if (!DEMO) player.src = fileUrl(path);
  let previewOk = !DEMO;
  player.addEventListener("error", () => {
    previewOk = false;
    if (media === "video") box.replaceChildren(h("div.nopreview", t("Anteprima non disponibile per questo formato."), h("br"), t("Il taglio funziona lo stesso: scegli i tempi qui sotto.")));
  });
  const box = media === "video" ? h("div.player", DEMO ? h("div.nopreview", t("Anteprima del video")) : player) : h("div");
  if (media !== "video") box.append(player);

  const canvas = h("canvas");
  const sel = h("div.sel");
  const hA = h("div.hd", { role: "slider", tabindex: "0", "aria-label": t("Inizio") });
  const hB = h("div.hd", { role: "slider", tabindex: "0", "aria-label": t("Fine") });
  const ph = h("div.ph");
  const rail = h("div.rail", canvas, sel, ph, hA, hB);
  // 1.1 · Inizio e fine si scrivono, al millesimo («1:02,345»)
  const tStart = h("input.t", { type: "text", spellcheck: "false", "aria-label": t("Inizio (minuti:secondi,millesimi)"), title: t("Scrivi il tempo, per esempio 1:02,345") });
  const tEnd = h("input.t", { type: "text", spellcheck: "false", "aria-label": t("Fine (minuti:secondi,millesimi)"), title: t("Scrivi il tempo, per esempio 1:02,345") });
  const tLen = h("span.t");
  const typed = (inp, which) => {
    const v = parseTime(inp.value);
    if (v == null) { toast(t("Scrivi un tempo come 1:02,345.")); draw(); return; }
    mark(true);
    which === "a" ? setStart(v) : setEnd(v);
  };
  tStart.addEventListener("change", () => typed(tStart, "a"));
  tEnd.addEventListener("change", () => typed(tEnd, "b"));
  for (const inp of [tStart, tEnd]) inp.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); inp.blur(); } if (e.key === "Escape") { e.stopPropagation(); draw(); inp.blur(); } });

  // 1.1 · Ctrl+Z / Ctrl+Y su tutta la selezione (maniglie, «Inizio qui», «Fine qui», tasti, campi)
  const past = [], future = [];
  let base = null, lastMark = 0;
  function mark(force = false) {
    const now = Date.now();
    const top = past[past.length - 1];
    if (!force && now - lastMark < 700 && top) { lastMark = now; return; }
    lastMark = now;
    if (!top || top[0] !== start || top[1] !== end) past.push([start, end]);
    if (past.length > 200) past.shift();
    future.length = 0;
  }
  function undoSel() {
    while (past.length && past[past.length - 1][0] === start && past[past.length - 1][1] === end) past.pop();
    if (!past.length) return toast(t("Niente da annullare."));
    future.push([start, end]);
    [start, end] = past.pop();
    lastMark = 0;
    draw();
  }
  function redoSel() {
    if (!future.length) return toast(t("Niente da rifare."));
    past.push([start, end]);
    [start, end] = future.pop();
    lastMark = 0;
    draw();
  }
  const playBtn = h("button.btn", { onclick: () => playSelection() }, ico("play", 14), t("Ascolta il pezzo"));
  const row = h("div.trim-row",
    h("span", t("Da ")), tStart, h("span", t(" a ")), tEnd, h("span", " · "), tLen,
    h("span.grow"),
    h("button.btn", { onclick: () => { mark(true); setStart(player.currentTime); } }, t("Inizio qui")),
    h("button.btn", { onclick: () => { mark(true); setEnd(player.currentTime); } }, t("Fine qui")),
    playBtn);
  el.append(box, rail, row);

  const x2t = (x) => {
    const r = rail.getBoundingClientRect();
    return Math.min(duration, Math.max(0, ((x - r.left) / r.width) * duration));
  };

  function draw() {
    const pa = (start / duration) * 100, pb = (end / duration) * 100;
    sel.style.left = pa + "%";
    sel.style.width = Math.max(0, pb - pa) + "%";
    hA.style.left = pa + "%";
    hB.style.left = pb + "%";
    if (document.activeElement !== tStart) tStart.value = fmtTimeMs(start);
    if (document.activeElement !== tEnd) tEnd.value = fmtTimeMs(end);
    tLen.textContent = fmtTime(end - start, true);
    hA.setAttribute("aria-valuetext", fmtTime(start));
    hB.setAttribute("aria-valuetext", fmtTime(end));
    onChange?.(start, end);
  }

  function drawWave() {
    const r = rail.getBoundingClientRect();
    if (!r.width) return;
    const dpr = window.devicePixelRatio || 1;
    canvas.width = r.width * dpr;
    canvas.height = r.height * dpr;
    const g = canvas.getContext("2d");
    g.scale(dpr, dpr);
    const css = getComputedStyle(document.documentElement);
    g.fillStyle = css.getPropertyValue("--sage-2").trim() || "#8FB489";
    if (peaks?.length) {
      const n = peaks.length, w = r.width / n, mid = r.height / 2;
      for (let i = 0; i < n; i++) {
        const v = Math.max(0.02, peaks[i]) * (r.height * 0.46);
        g.fillRect(i * w, mid - v, Math.max(1, w - 0.6), v * 2);
      }
    } else {
      g.globalAlpha = 0.25;
      for (let x = 0; x < r.width; x += 8) g.fillRect(x, r.height * 0.35, 4, r.height * 0.3);
    }
  }

  function setStart(t) {
    start = Math.max(0, Math.min(t, end - 0.1));
    if (maxLen && end - start > maxLen) end = Math.min(duration, start + maxLen);
    draw();
  }
  function setEnd(t) {
    end = Math.min(duration, Math.max(t, start + 0.1));
    if (maxLen && end - start > maxLen) start = Math.max(0, end - maxLen);
    draw();
  }

  function drag(handle, which) {
    handle.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      e.stopPropagation();
      mark(true);
      handle.setPointerCapture(e.pointerId);
      const move = (ev) => {
        const t = x2t(ev.clientX);
        which === "a" ? setStart(t) : setEnd(t);
        if (previewOk) player.currentTime = which === "a" ? start : end;
      };
      const up = () => {
        handle.removeEventListener("pointermove", move);
        handle.removeEventListener("pointerup", up);
        handle.removeEventListener("pointercancel", up);
      };
      handle.addEventListener("pointermove", move);
      handle.addEventListener("pointerup", up);
      handle.addEventListener("pointercancel", up);
    });
    handle.addEventListener("keydown", (e) => {
      const step = e.shiftKey ? 1 : 0.1;
      if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
        e.preventDefault();
        mark();
        const d = e.key === "ArrowLeft" ? -step : step;
        which === "a" ? setStart(start + d) : setEnd(end + d);
      }
    });
  }
  drag(hA, "a");
  drag(hB, "b");
  rail.addEventListener("pointerdown", (e) => {
    if (!previewOk) return;
    player.currentTime = x2t(e.clientX);
  });

  let stopAt = null;
  function playSelection() {
    if (!previewOk) return;
    if (!player.paused) {
      player.pause();
      return;
    }
    player.currentTime = start;
    stopAt = end;
    player.play().catch(() => {});
  }
  player.addEventListener("play", () => playBtn.replaceChildren(ico("pause", 14), t("Ferma")));
  player.addEventListener("pause", () => playBtn.replaceChildren(ico("play", 14), t("Ascolta il pezzo")));
  let raf = 0;
  const tick = () => {
    // Pagina nascosta: niente animazione; si riprende quando torna visibile
    if (!el.isConnected) {
      raf = 0;
      setTimeout(() => { if (!raf && !destroyed) raf = requestAnimationFrame(tick); }, 400);
      return;
    }
    ph.style.left = (player.currentTime / duration) * 100 + "%";
    if (stopAt != null && player.currentTime >= stopAt) {
      player.pause();
      stopAt = null;
    }
    raf = requestAnimationFrame(tick);
  };
  raf = requestAnimationFrame(tick);

  let destroyed = false;
  const keys = (e) => {
    if (!el.isConnected || document.querySelector(".modal-bg")) return;
    const k = e.key.toLowerCase();
    if ((e.ctrlKey || e.metaKey) && !(e.target instanceof Element && e.target.closest("input, textarea, select"))) {
      if (k === "z" && !e.shiftKey) { e.preventDefault(); undoSel(); }
      else if (k === "y" || (k === "z" && e.shiftKey)) { e.preventDefault(); redoSel(); }
      return;
    }
    if ((e.target instanceof Element && e.target.closest("input, textarea, select, button")) || e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key === "i" || e.key === "I") { mark(true); setStart(player.currentTime); }
    else if (e.key === "o" || e.key === "O") { mark(true); setEnd(player.currentTime); }
    else if (e.key === " ") {
      e.preventDefault();
      player.paused ? player.play().catch(() => {}) : player.pause();
    }
  };
  document.addEventListener("keydown", keys);
  const ro = new ResizeObserver(drawWave);
  ro.observe(rail);
  requestAnimationFrame(() => {
    drawWave();
    draw();
  });

  return {
    el,
    get start() { return start; },
    get end() { return end; },
    /** 1.1 · La selezione è cambiata da quando si è aperta (c'è qualcosa da perdere). */
    get changed() { const b = base || [0, maxLen ? Math.min(duration, maxLen) : duration]; return Math.abs(start - b[0]) > 0.0005 || Math.abs(end - b[1]) > 0.0005; },
    setPeaks(p) { peaks = p; drawWave(); },
    /** Riprende una selezione salvata (progetti audio). */
    setRange(a, b) {
      start = Math.max(0, Math.min(duration, a));
      end = Math.max(start + 0.1, Math.min(duration, b));
      if (maxLen && end - start > maxLen) end = Math.min(duration, start + maxLen);
      base = [start, end];
      draw();
    },
    setMaxLen(m) { maxLen = m; if (maxLen && end - start > maxLen) end = Math.min(duration, start + maxLen); draw(); },
    playSelection,
    destroy() {
      destroyed = true;
      cancelAnimationFrame(raf);
      document.removeEventListener("keydown", keys);
      ro.disconnect();
      player.pause();
      player.removeAttribute("src");
      player.load();
    },
  };
}
