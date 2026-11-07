// 2.0.1 · Chi installa adesso: linguetta spenta e «Lo sapevi?» solo nei primi 3 giorni; chi c'era già tiene le sue scelte.
// Più: ogni testo dell'interfaccia ha l'inglese (Design/DESIGN.md: «Ogni testo è in italiano e inglese»).
// uso: node --test Tools/prova-avvio-windows.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const { firstRunDefaults, tipAllowed, shelfOn, TIP_DAYS } = await import("../Windows/ui/js/primavolta.js");
const mem = (init = {}) => {
  const m = new Map(Object.entries(init));
  return { get: (k, d) => (m.has(k) ? m.get(k) : d), set: (k, v) => m.set(k, v), m };
};
const DAY = 86400e3, now = Date.UTC(2026, 10, 7);

test("installazione nuova: linguetta spenta, consigli per 3 giorni", () => {
  const s = mem();
  assert.equal(firstRunDefaults(s, false, now), true);
  assert.equal(shelfOn(s), false);
  assert.equal(tipAllowed(s, now + 1000), true);
  assert.equal(tipAllowed(s, now + (TIP_DAYS * DAY) - 1), true);
  assert.equal(tipAllowed(s, now + TIP_DAYS * DAY), false);
  assert.equal(tipAllowed(s, now + 30 * DAY), false);
});

test("chi usava già OrbitLR: la linguetta resta com'era, niente più consigli", () => {
  const never = mem({ welcomed: true });
  firstRunDefaults(never, true, now);
  assert.equal(shelfOn(never), true, "mai toccata = accesa come in 2.0");
  assert.equal(tipAllowed(never, now), false);
  const off = mem({ welcomed: true, shelf: false });
  firstRunDefaults(off, true, now);
  assert.equal(shelfOn(off), false);
});

test("si decide una volta sola: le scelte dopo restano", () => {
  const s = mem();
  firstRunDefaults(s, false, now);
  s.set("shelf", true);
  assert.equal(firstRunDefaults(s, true, now + 5 * DAY), false);
  assert.equal(shelfOn(s), true);
  assert.equal(s.get("installedAt"), now);
});

test("ogni testo dell'interfaccia ha l'inglese", async () => {
  const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
  const keys = JSON.parse(execFileSync(process.execPath, [path.join(root, "Tools", "testi-windows.mjs"), path.join(root, "Windows", "ui", "js")], { encoding: "utf8", maxBuffer: 1 << 26 }));
  const { EN } = await import(pathToFileURL(path.join(root, "Windows", "ui", "js", "en.js")).href);
  const missing = Object.keys(keys).filter((k) => !(k in EN));
  assert.deepEqual(missing, [], "manca l'inglese in en.js:\n" + missing.join("\n"));
});

test("le attese lunghe dell'IA dicono cosa succede (e da quanto)", async () => {
  // (i testi in italiano, qualunque sia la lingua del computer di prova)
  globalThis.localStorage ??= { getItem: (k) => (k === "orbitlr.appLang" ? '"it"' : null), setItem() {} };
  const { stageText } = await import("../Windows/ui/js/attese.js");
  const t0 = 1_000_000;
  const job = (action, progress, extra = {}) => ({ action, progress, state: "running", started: t0, lastMove: t0, ...extra });
  assert.match(stageText(job("removebg", 0.2, { fetch: { what: "il modello per togliere lo sfondo", mb: 179 } }), t0 + 1000), /Scarico il modello per togliere lo sfondo \(una volta sola, 179 MB\)… 40%/);
  assert.match(stageText(job("removebg", 0.05), t0 + 30000), /L’IA cerca il soggetto.*ancora al lavoro da 0:30/);
  assert.match(stageText(job("aienhance", 0.3), t0 + 1000), /Avvio l’IA/);
  assert.match(stageText(job("upscale", 0.6), t0 + 1000), /L’IA migliora la foto… 60%/);
  assert.match(stageText(job("upscale", 0.95), t0 + 1000), /Salvo il risultato/);
  assert.equal(stageText(job("compress", 0.5), t0 + 1000), null, "un lavoro che va avanti non cambia");
  assert.match(stageText(job("compress", 0.5), t0 + 65000), /50% · ancora al lavoro da 1:05/);
});
