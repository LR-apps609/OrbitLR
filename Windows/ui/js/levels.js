// 1.0 · Quanto vedere in ogni scheda (come sul Mac 5.0): «Semplice» (le 6 cose che si fanno di più, in grande),
// «Completo» (tutto, in gruppi che si aprono uno alla volta) e, dove c'è, l'editor della scheda.
// Ogni scheda si apre in Semplice e si ricorda l'ultima scelta.

import { h, store } from "./util.js";
import { t } from "./i18n.js";

/** Le 6 azioni di Semplice, in ordine. «convert» è il riquadro «Cambia formato». */
export const SIMPLE = {
  image: ["icompress", "convert", "removebg", "aienhance", "resize", "vector"],
  video: ["vcompress", "cut", "social", "to:mp3", "transcribe", "gifcut"],
  pdf: ["pdfcompress", "pdfmerge", "extract", "protect", "pdfedit", "pdftext"],
  audio: ["ringtone", "cut", "whatsapp", "voiceclean", "normalize", "transcribe"],
};

/** Il nome dell'editor della scheda (null: non ne ha uno). */
export const EDITOR = { video: () => t("Montaggio"), pdf: () => t("Editor PDF") };

export const getLevel = (kind) => (store.get("level." + kind, "simple") === "complete" ? "complete" : "simple");
export const setLevel = (kind, v) => store.set("level." + kind, v);

/** L'interruttore Semplice · Completo · (Editor). `onEditor`: cosa fa il terzo pulsante. */
export function levelSeg(kind, current, onPick, onEditor) {
  const ed = EDITOR[kind];
  const b = (id, label, click) =>
    h("button" + (current === id ? ".on" : ""), { type: "button", "aria-pressed": current === id ? "true" : "false", onclick: click }, label);
  return h("div.seg.level", { role: "group", "aria-label": t("Quanto vedere"), title: t("Semplice: le cose che si fanno di più. Completo: tutte le funzioni, divise in gruppi.") },
    b("simple", t("Semplice"), () => { setLevel(kind, "simple"); onPick("simple"); }),
    b("complete", t("Completo"), () => { setLevel(kind, "complete"); onPick("complete"); }),
    ed && onEditor ? b("editor", ed(), onEditor) : null);
}
