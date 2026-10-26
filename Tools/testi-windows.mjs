// Raccoglie i testi da tradurre dell'interfaccia Windows: t("…") e t`…${x}…` → chiavi con {0}, {1}…
// uso: node Tools/testi-windows.mjs Windows/ui/js  → stampa un JSON {chiave: [file…]}
import fs from "node:fs";
import path from "node:path";

const dir = process.argv[2] || "Windows/ui/js";
const out = {};

function add(key, file) {
  (out[key] ||= []).includes(file) || out[key].push(file);
}

// Legge una stringa tra virgolette a partire da i (s[i] è la virgoletta); restituisce [testo, fine]
function readQuoted(s, i) {
  const q = s[i];
  let r = "";
  for (let j = i + 1; j < s.length; j++) {
    const c = s[j];
    if (c === "\\") {
      const n = s[j + 1];
      r += n === "n" ? "\n" : n === "t" ? "\t" : n;
      j++;
    } else if (c === q) return [r, j];
    else r += c;
  }
  return [null, s.length];
}

// Legge un template `…` a partire da i; i pezzi ${…} diventano {n}
function readTemplate(s, i) {
  let r = "", n = 0;
  for (let j = i + 1; j < s.length; j++) {
    const c = s[j];
    if (c === "\\") {
      const x = s[j + 1];
      r += x === "n" ? "\n" : x === "`" ? "`" : x === "$" ? "$" : x;
      j++;
    } else if (c === "`") return [r, j];
    else if (c === "$" && s[j + 1] === "{") {
      let depth = 1, k = j + 2;
      while (k < s.length && depth) {
        const d = s[k];
        if (d === '"' || d === "'") k = readQuoted(s, k)[1];
        else if (d === "`") k = readTemplate(s, k)[1];
        else if (d === "{") depth++;
        else if (d === "}") depth--;
        k++;
      }
      r += `{${n++}}`;
      j = k - 1;
    } else r += c;
  }
  return [null, s.length];
}

for (const f of fs.readdirSync(dir).filter((x) => x.endsWith(".js") && x !== "en.js" && x !== "icons.js" && x !== "i18n.js")) {
  const s = fs.readFileSync(path.join(dir, f), "utf8");
  for (let i = 0; i < s.length; i++) {
    // Un «t» da solo (non parte di un altro nome), seguito da ( o `
    if (s[i] !== "t" || /[\w$.]/.test(s[i - 1] || "")) continue;
    let j = i + 1;
    if (s[j] === "`") {
      const [txt, end] = readTemplate(s, j);
      if (txt != null) add(txt, f);
      i = end;
    } else if (s[j] === "(") {
      let k = j + 1;
      while (/\s/.test(s[k])) k++;
      if (s[k] === '"' || s[k] === "'") {
        const [txt, end] = readQuoted(s, k);
        let e = end + 1;
        while (/\s/.test(s[e])) e++;
        if (txt != null && s[e] === ")") add(txt, f);
      }
    }
  }
}
process.stdout.write(JSON.stringify(out, null, 1));
