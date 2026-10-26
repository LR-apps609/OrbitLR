// La lingua di OrbitLR per Windows: di base quella di Windows (italiano o inglese), oppure scelta nelle Opzioni.
// I testi si scrivono in italiano dentro t`…`: in inglese si cercano nel dizionario (en.js).
//   t`Su ${n} file`  → chiave «Su {0} file» → «On {0} files»
// Un testo che manca nel dizionario resta in italiano (mai una schermata vuota).

import { EN, EN_PATTERNS } from "./en.js";

function readLang() {
  let pick = "auto";
  try {
    pick = JSON.parse(localStorage.getItem("orbitlr.appLang") || '"auto"');
  } catch {}
  if (pick === "it" || pick === "en") return pick;
  const sys = (navigator.languages && navigator.languages[0]) || navigator.language || "it";
  return sys.toLowerCase().startsWith("it") ? "it" : "en";
}

export const LANG = readLang();
export const isEn = LANG === "en";
/** Per date e ore. */
export const LOCALE = isEn ? "en-US" : "it-IT";
try {
  document.documentElement.lang = LANG;
} catch {}

function fill(text, vals) {
  return text.replace(/\{(\d+)\}/g, (_, i) => (vals[i] === undefined ? "" : String(vals[i])));
}

/** Tag dei testi: t`Ciao ${nome}`. Con le stringhe semplici: t("Ciao"). */
export function t(strings, ...vals) {
  if (typeof strings === "string") return isEn ? EN[strings] ?? strings : strings;
  let key = strings[0];
  for (let i = 1; i < strings.length; i++) key += `{${i - 1}}` + strings[i];
  const out = isEn ? EN[key] ?? key : key;
  return fill(out, vals);
}

/** Stesso testo italiano, significati diversi: tc("undo", "Annulla") → in inglese la chiave «undo|Annulla». */
export function tc(ctx, it) {
  if (!isEn) return it;
  return EN[ctx + "|" + it] ?? EN[it] ?? it;
}

/** Un testo nato altrove (motore, cronologia): esatto nel dizionario, oppure con un modello. */
export function tr(text) {
  if (!isEn || text == null) return text;
  const s = String(text);
  if (EN[s] !== undefined) return EN[s];
  for (const [re, out] of EN_PATTERNS) {
    const m = s.match(re);
    if (m) return out.replace(/\$(\d)/g, (_, i) => m[Number(i)] ?? "");
  }
  // «nome.ext: messaggio» → si traduce solo il messaggio
  const i = s.indexOf(": ");
  if (i > 0 && s.slice(0, i).includes(".")) {
    const rest = tr(s.slice(i + 2));
    if (rest !== s.slice(i + 2)) return s.slice(0, i + 2) + rest;
  }
  return s;
}

/** Numeri con la virgola in italiano, col punto in inglese. */
export function dec(s) {
  return isEn ? String(s).replace(/(\d),(\d)/g, "$1.$2") : String(s);
}
