// 2.0.1 · Niente attese infinite e niente finestra bloccata (prova sul codice, senza Windows).
// In Tauri i comandi senza «async» girano nel thread della finestra: se toccano dischi o programmi esterni,
// un disco di rete scollegato o un PowerShell bloccato fanno dire a Windows «Non risponde».
// uso: node --test Tools/prova-attese-windows.mjs
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const main = fs.readFileSync(new URL("../Windows/src-tauri/src/main.rs", import.meta.url), "utf8");
const speech = fs.readFileSync(new URL("../Windows/engine/src/speech.rs", import.meta.url), "utf8");
const conf = JSON.parse(fs.readFileSync(new URL("../Windows/src-tauri/tauri.conf.json", import.meta.url), "utf8"));

/** Il corpo di una funzione Rust (dalla firma alla graffa che la chiude). */
function body(src, name) {
  const at = src.search(new RegExp(`fn ${name}\\b`));
  assert.ok(at >= 0, `manca fn ${name}`);
  let i = src.indexOf("{", at), depth = 0;
  for (let j = i; j < src.length; j++) {
    if (src[j] === "{") depth++;
    if (src[j] === "}" && --depth === 0) return src.slice(at, j + 1);
  }
  return src.slice(at);
}

test("i comandi che guardano i dischi non bloccano la finestra", () => {
  for (const name of ["files_exist", "export_room"]) {
    assert.match(main, new RegExp(`#\\[tauri::command\\]\\s*async fn ${name}\\b`), `${name} deve essere async`);
    assert.match(body(main, name), /spawn_blocking/, `${name} deve lavorare in sottofondo`);
  }
});

test("PowerShell ha sempre un tempo massimo", () => {
  assert.doesNotMatch(body(main, "explorer_selection"), /\.output\(\)/, "Ctrl+Alt+C: PowerShell senza tempo massimo");
  assert.doesNotMatch(body(speech, "voices"), /\.output\(\)/, "elenco delle voci: PowerShell senza tempo massimo");
});

test("la finestra principale non esce dallo schermo", () => {
  const w = conf.app.windows.find((x) => x.label === "main");
  assert.equal(w.preventOverflow, true);
  assert.match(main, /fit_main_window\(app\)/);
});
