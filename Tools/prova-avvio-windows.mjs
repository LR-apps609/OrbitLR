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
