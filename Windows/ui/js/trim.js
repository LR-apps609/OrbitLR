// Scegliere un pezzo: anteprima (video o audio), una barra con due maniglie, «Inizio qui» e «Fine qui».
// I tasti I e O mettono inizio e fine mentre si guarda; Spazio avvia e ferma.

import { fileUrl, DEMO } from "./api.js";
import { fmtTime, h, ico } from "./util.js";

export function createTrim({ path, duration, media, peaks, maxLen = 0, onChange }) {
  let start = 0;
  let end = maxLen ? Math.min(duration, maxLen) : duration;
  const el = h("div.trim");
  const player = media === "video" ? h("video", { preload: "metadata", playsinline: true }) : h("audio", { preload: "metadata" });
  if (!DEMO) player.src = fileUrl(path);
  let previewOk = !DEMO;
  player.addEventListener("error", () => {
    previewOk = false;
    if (media === "video") box.replaceChildren(h("div.nopreview", "Anteprima non disponibile per questo formato.", h("br"), "Il taglio funziona lo stesso: scegli i tempi qui sotto."));
  });
  const box = media === "video" ? h("div.player", DEMO ? h("div.nopreview", "Anteprima del video") : player) : h("div");
  if (media !== "video") box.append(player);

  const canvas = h("canvas");
  const sel = h("div.sel");
  const hA = h("div.hd", { role: "slider", tabindex: "0", "aria-label": "Inizio" });
  const hB = h("div.hd", { role: "slider", tabindex: "0", "aria-label": "Fine" });
  const ph = h("div.ph");
  const rail = h("div.rail", canvas, sel, ph, hA, hB);
  const tStart = h("span.t");
  const tEnd = h("span.t");
  const tLen = h("span.t");
  const playBtn = h("button.btn", { onclick: () => playSelection() }, ico("play", 14), "Ascolta il pezzo");
  const row = h("div.trim-row",
    h("span", "Da "), tStart, h("span", " a "), tEnd, h("span", " · "), tLen,
    h("span.grow"),
    h("button.btn", { onclick: () => setStart(player.currentTime) }, "Inizio qui"),
    h("button.btn", { onclick: () => setEnd(player.currentTime) }, "Fine qui"),
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
    tStart.textContent = fmtTime(start, true);
    tEnd.textContent = fmtTime(end, true);
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
  player.addEventListener("play", () => playBtn.replaceChildren(ico("pause", 14), "Ferma"));
  player.addEventListener("pause", () => playBtn.replaceChildren(ico("play", 14), "Ascolta il pezzo"));
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
    if (!el.isConnected || (e.target instanceof Element && e.target.closest("input, textarea, select, button")) || document.querySelector(".modal-bg")) return;
    if (e.key === "i" || e.key === "I") setStart(player.currentTime);
    else if (e.key === "o" || e.key === "O") setEnd(player.currentTime);
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
    setPeaks(p) { peaks = p; drawWave(); },
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
