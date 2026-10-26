// I testi del montaggio, disegnati su un canvas: lo stesso disegno per l'anteprima e per l'esportazione
// (dove ogni testo diventa un PNG trasparente grande come il video).

import { t } from "./i18n.js";

export const STYLES = [["title", t("Titolo")], ["subtitle", t("Sottotitolo")], ["caption", t("Didascalia")], ["big", t("Grande")]];
export const ANIMS = [["fade", t("Dissolvenza")], ["slide", t("Scorrimento")], ["pop", t("Pop")], ["type", t("Macchina da scrivere")], ["word", t("Parola per parola")]];
export const COLORS = [["white", t("Bianco"), "#FFFFFF"], ["black", t("Nero"), "#141414"], ["brass", t("Ottone"), "#D9AB61"], ["sage", t("Salvia"), "#9EC7A1"]];
export const IN_TIME = 0.45, OUT_TIME = 0.35;

const SIZE = { big: [0.12, 900], title: [0.075, 800], subtitle: [0.05, 700], caption: [0.042, 600] };

export function newText(at, canvasH) {
  return { id: "t" + Date.now().toString(36) + Math.random().toString(36).slice(2, 5), text: t("Il tuo testo"), style: "title", start: at, end: at + 3, x: 0.5, y: 0.5, anim: "fade", color: "white", wordTimes: null };
}

export function words(text) {
  return String(text).split(/\s+/).filter(Boolean);
}

/** La parola accesa in un momento (Parola per parola). */
export function wordIndex(t, time) {
  const n = words(t.text).length;
  if (!n) return 0;
  const local = time - t.start;
  if (Array.isArray(t.wordTimes) && t.wordTimes.length === n) {
    let k = 0;
    for (let i = 0; i < n; i++) if (t.wordTimes[i] <= local + 0.001) k = i;
    return k;
  }
  const d = Math.max(0.1, t.end - t.start);
  return Math.min(n - 1, Math.max(0, Math.floor((local / d) * n)));
}

function wrap(g, text, maxW) {
  const lines = [];
  for (const para of String(text).split("\n")) {
    let line = "";
    for (const w of para.split(/\s+/).filter(Boolean)) {
      const t = line ? line + " " + w : w;
      if (g.measureText(t).width > maxW && line) {
        lines.push(line);
        line = w;
      } else line = t;
    }
    lines.push(line);
  }
  return lines;
}

/**
 * Disegna un testo. `opts`: { visibleWords (macchina da scrivere), highlight (parola accesa), alpha, dy, scale }.
 * Restituisce il riquadro occupato (per trascinarlo nell'anteprima).
 */
export function drawText(g, t, W, H, opts = {}) {
  const base = Math.min(H, W * 1.25);
  const [k, weight] = SIZE[t.style] || SIZE.title;
  const size = Math.max(10, base * k);
  g.save();
  g.font = `${weight} ${size}px Nunito, "Segoe UI", sans-serif`;
  g.textBaseline = "middle";
  g.textAlign = "left";
  const all = words(t.text);
  const shown = opts.visibleWords != null ? all.slice(0, opts.visibleWords).join(" ") : t.text;
  const lines = wrap(g, t.text, W * 0.88 - size);
  const lineH = size * 1.22;
  const widths = lines.map((l) => g.measureText(l).width);
  const boxW = Math.max(...widths, 1);
  const boxH = lines.length * lineH;
  const cx = t.x * W, cy = t.y * H + (opts.dy || 0) * (H / 720);
  const box = t.style === "subtitle" || t.style === "caption";
  const padX = box ? size * 0.55 : size * 0.25, padY = box ? size * 0.3 : size * 0.25;
  const rect = { x: cx - boxW / 2 - padX, y: cy - boxH / 2 - padY, w: boxW + padX * 2, h: boxH + padY * 2 };
  g.globalAlpha = opts.alpha ?? 1;
  if (opts.scale && opts.scale !== 1) {
    g.translate(cx, cy);
    g.scale(opts.scale, opts.scale);
    g.translate(-cx, -cy);
  }
  if (box) {
    g.fillStyle = t.color === "black" ? "rgba(255,255,255,0.82)" : "rgba(0,0,0,0.58)";
    const r = size * 0.35;
    g.beginPath();
    g.roundRect(rect.x, rect.y, rect.w, rect.h, r);
    g.fill();
  } else {
    g.shadowColor = t.color === "black" ? "rgba(255,255,255,0.5)" : "rgba(0,0,0,0.45)";
    g.shadowBlur = size * 0.18;
    g.shadowOffsetY = size * 0.05;
  }
  const color = (COLORS.find((c) => c[0] === t.color) || COLORS[0])[2];
  const lit = t.color === "brass" ? "#FFFFFF" : "#FAC75C";
  // Parola per parola e macchina da scrivere: si disegna parola per parola
  let wi = 0;
  const shownCount = words(shown).length;
  lines.forEach((line, li) => {
    const y = cy - boxH / 2 + lineH * li + lineH / 2;
    let x = cx - widths[li] / 2;
    for (const w of line.split(" ").filter(Boolean)) {
      if (wi < shownCount) {
        g.fillStyle = opts.highlight === wi ? lit : color;
        g.fillText(w, x, y);
      }
      x += g.measureText(w + " ").width;
      wi++;
    }
  });
  g.restore();
  return rect;
}

/** Come appare un testo in un momento: null se non si vede. */
export function stateAt(t, time) {
  if (time < t.start || time > t.end) return null;
  const pin = Math.min(1, Math.max(0, (time - t.start) / IN_TIME));
  const pout = Math.min(1, Math.max(0, (t.end - time) / OUT_TIME));
  const ease = (x) => 1 - Math.pow(1 - x, 3);
  const o = { alpha: Math.min(ease(pin), ease(pout)) };
  if (t.anim === "slide") o.dy = (1 - ease(pin)) * 40;
  if (t.anim === "pop") o.scale = 0.7 + 0.3 * ease(pin);
  if (t.anim === "type") {
    const n = words(t.text).length;
    const dur = Math.min(1.5, (t.end - t.start) * 0.6);
    o.visibleWords = Math.max(1, Math.ceil((n * (time - t.start)) / Math.max(0.1, dur)));
    o.alpha = Math.min(1, ease(pout));
  }
  if (t.anim === "word") o.highlight = wordIndex(t, time);
  return o;
}

/**
 * Per l'esportazione: un testo diventa UN ingresso per il motore.
 * Ritorna { start, end, fadeIn, fadeOut, slide, png?: dataUrl, frames?: [{ dataUrl, duration }] }:
 * «Parola per parola» e «Macchina da scrivere» sono una sequenza di immagini.
 */
export function exportOverlay(t, W, H) {
  const parts = exportFrames(t, W, H);
  if (parts.length === 1) {
    const f = parts[0];
    return { start: f.start, end: f.end, fadeIn: f.fadeIn, fadeOut: f.fadeOut, slide: f.slide, png: f.dataUrl };
  }
  // La riga compare dall'inizio del testo (con la prima parola già accesa), come nell'anteprima
  return {
    start: t.start,
    end: parts[parts.length - 1].end,
    fadeIn: parts[0].fadeIn,
    fadeOut: parts[parts.length - 1].fadeOut,
    slide: 0,
    frames: parts.map((f, i) => ({ dataUrl: f.dataUrl, duration: Math.max(0.04, f.end - (i === 0 ? t.start : f.start)) })),
  };
}

export function exportFrames(t, W, H) {
  const frames = [];
  const make = (opts) => {
    const c = document.createElement("canvas");
    c.width = W;
    c.height = H;
    drawText(c.getContext("2d"), t, W, H, opts);
    return c.toDataURL("image/png");
  };
  const n = Math.max(1, words(t.text).length);
  if (t.anim === "word") {
    for (let i = 0; i < n; i++) {
      const s = Array.isArray(t.wordTimes) && t.wordTimes.length === n ? t.start + t.wordTimes[i] : t.start + ((t.end - t.start) * i) / n;
      const e = i + 1 < n ? (Array.isArray(t.wordTimes) && t.wordTimes.length === n ? t.start + t.wordTimes[i + 1] : t.start + ((t.end - t.start) * (i + 1)) / n) : t.end;
      frames.push({ dataUrl: make({ highlight: i }), start: s, end: e, fadeIn: i === 0 ? IN_TIME : 0, fadeOut: i === n - 1 ? OUT_TIME : 0, slide: 0 });
    }
  } else if (t.anim === "type") {
    const dur = Math.min(1.5, (t.end - t.start) * 0.6);
    for (let i = 1; i <= n; i++) {
      const s = t.start + (dur * (i - 1)) / n;
      const e = i < n ? t.start + (dur * i) / n : t.end;
      frames.push({ dataUrl: make({ visibleWords: i }), start: s, end: e, fadeIn: 0, fadeOut: i === n ? OUT_TIME : 0, slide: 0 });
    }
  } else {
    frames.push({ dataUrl: make({}), start: t.start, end: t.end, fadeIn: IN_TIME, fadeOut: OUT_TIME, slide: t.anim === "slide" ? 40 * (H / 720) : 0 });
  }
  return frames;
}
