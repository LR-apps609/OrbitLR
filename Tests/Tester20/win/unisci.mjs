// Tester20 · unisce le parti (parte-*.json) di un profilo in esito.json e lo stampa nel registro (righe T20ESITO|).
// Uso: node unisci.mjs <cartella> <profilo> <runner> <build>
import fs from "node:fs";
import path from "node:path";
const [dir, profilo, runner, build] = process.argv.slice(2);
const e = { profilo, runner, build, passi_fatti: 0, passati: 0, non_eseguiti: [], bug: [], confuso: [], note: [] };
const parti = [];
const walk = (d) => { for (const f of fs.existsSync(d) ? fs.readdirSync(d, { withFileTypes: true }) : []) { const p = path.join(d, f.name); if (f.isDirectory()) walk(p); else if (/^parte-.*\.json$/.test(f.name)) parti.push(p); } };
walk(dir);
const seen = new Set();
for (const p of parti) {
  const base = path.basename(p);
  if (seen.has(base)) continue; // la stessa parte copiata in due cartelle
  seen.add(base);
  let j; try { j = JSON.parse(fs.readFileSync(p, "utf8").replace(/^﻿/, "")); } catch (err) { e.non_eseguiti.push({ cosa: base, perche: "parte illeggibile: " + err.message }); continue; }
  e.passi_fatti += j.passi_fatti || 0; e.passati += j.passati || 0;
  for (const k of ["non_eseguiti", "bug", "confuso", "note"]) e[k].push(...(j[k] || []));
}
if (!parti.length) e.non_eseguiti.push({ cosa: "tutto il profilo", perche: "nessun risultato scritto (lo script si è fermato prima: vedi il registro del lavoro)" });
// Bug uguali una volta sola
const m = new Map();
for (const b of e.bug) if (!m.has(b.titolo)) m.set(b.titolo, b);
e.bug = [...m.values()];
fs.writeFileSync(path.join(dir, "esito.json"), JSON.stringify(e, null, 1));
const s = JSON.stringify(e);
for (let i = 0; i < s.length; i += 3000) console.log(`T20ESITO|${profilo}|${i / 3000}|${s.slice(i, i + 3000)}`);
console.log(`${profilo}: ${e.passati}/${e.passi_fatti} passi, ${e.bug.length} bug, ${e.non_eseguiti.length} non eseguiti, ${e.confuso.length} confusi`);
