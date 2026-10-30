// Prove veloci dell'interfaccia Windows (senza browser): tempi scritti al millesimo in «Taglia» e in Audio.
// uso: node --test Tools/prova-tempi-windows.mjs
import test from "node:test";
import assert from "node:assert/strict";

const { parseTime, fmtTimeMs } = await import("../Windows/ui/js/util.js");

test("si scrivono inizio e fine al millesimo", () => {
  assert.equal(parseTime("1:02,345"), 62.345);
  assert.equal(parseTime("1:02.345"), 62.345);
  assert.equal(parseTime("62,3"), 62.3);
  assert.equal(parseTime("0:05"), 5);
  assert.equal(parseTime(" 1:00:02,5 "), 3602.5);
  assert.equal(parseTime("12"), 12);
});

test("i tempi sbagliati non passano", () => {
  for (const s of ["", "abc", "1:75", "1,2,3", "-3", "1:02,3456", "1::2"]) assert.equal(parseTime(s), null, s);
});

test("il tempo si mostra con i millesimi e torna uguale", () => {
  const sep = fmtTimeMs(1).includes(",") ? "," : ".";
  assert.equal(fmtTimeMs(62.345), `1:02${sep}345`);
  assert.equal(fmtTimeMs(5), `0:05${sep}000`);
  assert.equal(fmtTimeMs(-1), `0:00${sep}000`);
  for (const v of [0, 0.001, 9.999, 61.5, 3599.999, 3725.25]) assert.ok(Math.abs(parseTime(fmtTimeMs(v)) - v) < 0.0005, String(v));
});
