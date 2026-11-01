// 1.2 «Sistema»: una parola per cosa (Design/DESIGN.md). Le parole doppie vecchie non devono più comparire
// nei testi dell'interfaccia Windows; le nuove devono avere l'inglese. Uso: node --test Tools/prova-parole-windows.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "Windows", "ui", "js");
const files = fs.readdirSync(dir).filter((f) => f.endsWith(".js") && f !== "en.js");

/** Il codice senza i commenti (// … e /* … *\/), così una parola vecchia citata in un commento non conta. */
function code(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, "").split("\n").map((l) => (/^\s*\/\//.test(l) ? "" : l.replace(/\s\/\/ .*$/, ""))).join("\n");
}

const OLD = ["Togli i silenzi", "Inizio qui", "Parte qui", "Fine qui", "Finisce qui", "Compila e firma", "Compila, firma e oscura",
  "Sblocca", "Inserisci la password", "Togli la password", "Segnala un bug", "Spegni l’audio", "Spegni l'audio", "Riaccendi l",
  "Muta questa clip", "Muti tutti", "Rimuovi la musica", "Rimuovi il testo", "Aggiungi file", "Apri un altro", "Spegni da qui",
  "Togli l'audio", "Togli l’audio", "Mostra nel Finder", "Mostra in Esplora", "Dissolvenza iniziale", "Dissolvenza finale",
  "Riattiva l'audio", "\"Intera\"", "Conversione\""];

test("le parole doppie vecchie non ci sono più nei .js dell'interfaccia", () => {
  const found = [];
  for (const f of files) {
    const src = code(fs.readFileSync(path.join(dir, f), "utf8"));
    for (const w of OLD) if (src.includes(w)) found.push(`${f}: «${w}»`);
  }
  assert.deepEqual(found, [], "usa la parola di Design/DESIGN.md:\n" + found.join("\n"));
});

const NEW = ["Rimuovi i silenzi", "Inizia qui", "Finisci qui", "Mostra nella cartella", "Editor PDF", "Rimuovi la password…",
  "Rimuovi la password", "Segnala un problema", "Togli la clip", "Togli la musica", "Togli il testo", "Muta la clip", "Riattiva l’audio",
  "Muta tutti i video", "Dissolvenza della musica", "Dissolvenza della clip", "Elimina il risultato", "Aggiungi…", "Apri…", "Interrompi",
  "Audio della clip: in «Audio». Transizione: clicca il pallino tra due clip.", "Rimuovi l’audio", "Risultato eliminato"];

test("le parole nuove hanno l'inglese", async () => {
  const { EN } = await import(pathToFileURL(path.join(dir, "en.js")).href);
  const missing = NEW.filter((k) => !EN[k]);
  assert.deepEqual(missing, [], "manca l'inglese in en.js (rigenerarlo): " + missing.join(", "));
});
