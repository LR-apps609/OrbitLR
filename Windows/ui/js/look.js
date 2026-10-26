// Filtri e regolazioni: la stessa matematica del motore (engine/src/look.rs), così l'anteprima
// coincide con il video esportato. Il colore è una matrice 3×4 usata da un feColorMatrix SVG.

import { t } from "./i18n.js";

export const PRESETS = [
  ["none", t("Nessuno")], ["vivid", t("Vivido")], ["warm", t("Caldo")], ["cool", t("Freddo")], ["mono", t("Bianco e nero")], ["sepia", t("Seppia")],
  ["vintage", t("Vintage")], ["film", t("Pellicola")], ["night", t("Notte")], ["dream", t("Sogno")], ["drama", t("Drammatico")], ["pastel", t("Pastello")], ["radio", t("Radio")],
];

const ID = { m: [[1, 0, 0], [0, 1, 0], [0, 0, 1]], o: [0, 0, 0] };
const LUMA = [0.2126, 0.7152, 0.0722];

function then(a, b) {
  const m = [[0, 0, 0], [0, 0, 0], [0, 0, 0]], o = [0, 0, 0];
  for (let r = 0; r < 3; r++) {
    for (let c = 0; c < 3; c++) m[r][c] = b.m[r][0] * a.m[0][c] + b.m[r][1] * a.m[1][c] + b.m[r][2] * a.m[2][c];
    o[r] = b.m[r][0] * a.o[0] + b.m[r][1] * a.o[1] + b.m[r][2] * a.o[2] + b.o[r];
  }
  return { m, o };
}
const chain = (...xs) => xs.reduce((a, b) => then(a, b));
function mix(a, b, t) {
  return { m: a.m.map((row, r) => row.map((v, c) => v * (1 - t) + b.m[r][c] * t)), o: a.o.map((v, r) => v * (1 - t) + b.o[r] * t) };
}
const saturation = (s) => ({ m: [0, 1, 2].map((r) => [0, 1, 2].map((c) => (1 - s) * LUMA[c] + (r === c ? s : 0))), o: [0, 0, 0] });
const contrast = (c) => ({ m: [[c, 0, 0], [0, c, 0], [0, 0, c]], o: [0.5 * (1 - c), 0.5 * (1 - c), 0.5 * (1 - c)] });
const brightness = (b) => ({ m: ID.m, o: [b, b, b] });
const controls = (b, s, c) => chain(saturation(s), contrast(c), brightness(b));
const tint = (r, g, b) => ({ m: [[r, 0, 0], [0, g, 0], [0, 0, b]], o: [0, 0, 0] });
const lift = (a) => ({ m: tint(1 - a, 1 - a, 1 - a).m, o: [a, a, a] });
const sepia = (k) => mix(ID, { m: [[0.393, 0.769, 0.189], [0.349, 0.686, 0.168], [0.272, 0.534, 0.131]], o: [0, 0, 0] }, k);

function preset(id) {
  switch (id) {
    case "vivid": return [controls(0, 1.45, 1.08), 0, false];
    case "warm": return [tint(1.1, 1.02, 0.86), 0, false];
    case "cool": return [tint(0.88, 1, 1.12), 0, false];
    case "mono": return [controls(0, 0, 1.12), 0, false];
    case "sepia": return [sepia(0.85), 0, false];
    case "vintage": return [chain(sepia(0.35), controls(0, 0.8, 0.92), lift(0.06)), 0.6, false];
    case "film": return [chain(tint(1.03, 1, 0.95), controls(0, 0.88, 1.12), lift(0.03)), 0, false];
    case "night": return [chain(controls(-0.06, 0.75, 1.15), tint(0.9, 0.97, 1.12)), 0, false];
    case "dream": return [controls(0.03, 1.05, 1), 0, true];
    case "drama": return [controls(0, 0.85, 1.3), 0.8, false];
    case "pastel": return [controls(0.06, 0.6, 0.9), 0, false];
    case "radio": return [chain(sepia(0.25), tint(1.04, 1.03, 0.9), controls(0, 0.9, 1.05)), 0.55, false];
    default: return [ID, 0, false];
  }
}

export function emptyLook() {
  return { preset: "none", amount: 1, brightness: 0, contrast: 0, saturation: 0, warmth: 0, sharpness: 0, vignette: 0 };
}

export function isIdentity(l) {
  return !l || ((l.preset === "none" || !l.preset || l.amount < 0.001) && Math.abs(l.brightness) < 0.001 && Math.abs(l.contrast) < 0.001
    && Math.abs(l.saturation) < 0.001 && Math.abs(l.warmth) < 0.001 && l.sharpness < 0.001 && l.vignette < 0.001);
}

/** { a: matrice, vignette 0…1, glow 0…1 } */
export function resolve(l) {
  const amount = Math.max(0, Math.min(1, l.amount ?? 1));
  const [p, pv, glow] = preset(l.preset);
  let a = mix(ID, p, amount);
  if (Math.abs(l.brightness) > 0.001 || Math.abs(l.contrast) > 0.001 || Math.abs(l.saturation) > 0.001) {
    a = then(a, controls(l.brightness * 0.3, 1 + l.saturation, 1 + l.contrast * 0.5));
  }
  if (Math.abs(l.warmth) > 0.001) a = then(a, tint(1 + 0.12 * l.warmth, 1 + 0.02 * l.warmth, 1 - 0.14 * l.warmth));
  return { a, vignette: Math.min(1, Math.max(pv * amount, l.vignette || 0)), glow: glow ? 0.6 * amount : 0 };
}

/** I valori per feColorMatrix (4×5, offset in unità 0…1). */
export function feMatrix(a) {
  const r = [];
  for (let i = 0; i < 3; i++) r.push(a.m[i][0], a.m[i][1], a.m[i][2], 0, a.o[i]);
  r.push(0, 0, 0, 1, 0);
  return r.map((x) => +x.toFixed(4)).join(" ");
}
