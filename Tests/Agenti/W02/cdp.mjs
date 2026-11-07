// W02 · Parla con la finestra di OrbitLR (WebView2) attraverso il protocollo DevTools.
// L'app va avviata con WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--remote-debugging-port=9222".
// Uso:
//   node cdp.mjs ready <timeoutMs>        stampa l'ora (epoch ms) in cui l'interfaccia è pronta
//   node cdp.mjs shot <file.png>          foto del contenuto della finestra
//   node cdp.mjs eval "<js>"              valuta e stampa il risultato
//   node cdp.mjs sections <cartella>      apre ogni scheda e la fotografa
//   node cdp.mjs logs                     errori della console (anche quelli già avvenuti)
import { writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const PORT = process.env.CDP_PORT || 9222;
const [, , cmd, ...args] = process.argv;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function pages() {
  const r = await fetch(`http://127.0.0.1:${PORT}/json/list`);
  return (await r.json()).filter((t) => t.type === "page");
}

async function mainPage() {
  const l = await pages();
  return l.find((t) => !/shelf/i.test(t.url)) || l[0];
}

class Session {
  constructor(ws) {
    this.ws = ws; this.id = 0; this.wait = new Map(); this.events = [];
    ws.addEventListener("message", (m) => {
      const d = JSON.parse(m.data);
      if (d.id && this.wait.has(d.id)) { this.wait.get(d.id)(d); this.wait.delete(d.id); }
      else if (d.method) this.events.push(d);
    });
  }
  static async open(t) {
    const ws = new WebSocket(t.webSocketDebuggerUrl);
    await new Promise((ok, ko) => { ws.addEventListener("open", ok); ws.addEventListener("error", ko); });
    return new Session(ws);
  }
  send(method, params = {}) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((ok) => this.wait.set(id, ok));
  }
  async eval(expr) {
    const r = await this.send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
    if (r.result?.exceptionDetails) return { error: r.result.exceptionDetails.exception?.description || r.result.exceptionDetails.text };
    return r.result?.result?.value;
  }
  async shot(file) {
    const r = await this.send("Page.captureScreenshot", { format: "png" });
    if (!r.result?.data) throw new Error("captureScreenshot: " + JSON.stringify(r.error || r));
    writeFileSync(file, Buffer.from(r.result.data, "base64"));
  }
  errors() {
    const out = [];
    for (const e of this.events) {
      if (e.method === "Runtime.exceptionThrown") out.push("ECCEZIONE " + (e.params.exceptionDetails.exception?.description || e.params.exceptionDetails.text));
      if (e.method === "Runtime.consoleAPICalled" && ["error", "warning", "assert"].includes(e.params.type))
        out.push(`console.${e.params.type} ` + e.params.args.map((a) => a.value ?? a.description ?? "").join(" "));
      if (e.method === "Log.entryAdded" && ["error", "warning"].includes(e.params.entry.level))
        out.push(`log.${e.params.entry.level} ${e.params.entry.source} ${e.params.entry.text} ${e.params.entry.url || ""}`);
    }
    return [...new Set(out)];
  }
  close() { try { this.ws.close(); } catch {} }
}

const READY = `(() => !!document.querySelector('nav.nav button') && document.readyState === 'complete')()`;

async function main() {
  if (cmd === "ready") {
    const end = Date.now() + Number(args[0] || 60000);
    while (Date.now() < end) {
      try {
        const t = await mainPage();
        if (t) {
          const s = await Session.open(t);
          const ok = await s.eval(READY);
          s.close();
          if (ok === true) { console.log(Date.now()); return; }
        }
      } catch {}
      await sleep(100);
    }
    console.log("TIMEOUT"); process.exitCode = 2; return;
  }
  const t = await mainPage();
  if (!t) throw new Error("nessuna pagina DevTools");
  const s = await Session.open(t);
  await s.send("Runtime.enable"); await s.send("Log.enable"); await s.send("Page.enable");
  try {
    if (cmd === "shot") await s.shot(args[0]);
    else if (cmd === "eval") console.log(JSON.stringify(await s.eval(args[0])));
    else if (cmd === "logs") { await sleep(800); console.log(JSON.stringify(s.errors())); }
    else if (cmd === "sections") {
      const dir = args[0]; mkdirSync(dir, { recursive: true });
      const res = { pagine: (await pages()).map((p) => p.url) };
      await sleep(500);
      res.modale_prima = await s.eval(`[...document.querySelectorAll('.modal-bg')].map(m => m.innerText.slice(0,120))`);
      await s.shot(join(dir, "00-avvio.png"));
      // Il benvenuto si chiude con Esc?
      for (let i = 0; i < 2; i++) {
        await s.send("Input.dispatchKeyEvent", { type: "keyDown", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 });
        await s.send("Input.dispatchKeyEvent", { type: "keyUp", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 });
        await sleep(500);
      }
      res.modale_dopo_esc = await s.eval(`[...document.querySelectorAll('.modal-bg')].map(m => m.innerText.slice(0,120))`);
      await s.shot(join(dir, "01-dopo-esc.png"));
      const list = await s.eval(`[...document.querySelectorAll('nav.nav button'), ...[...document.querySelectorAll('.foot button')].slice(0,2)].map(b => b.innerText.trim())`);
      res.schede = [];
      for (let i = 0; i < list.length; i++) {
        const t0 = Date.now();
        const r = await s.eval(`(async () => {
          const bs = [...document.querySelectorAll('nav.nav button'), ...[...document.querySelectorAll('.foot button')].slice(0,2)];
          const t0 = performance.now(); bs[${i}].click();
          await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
          const ms = performance.now() - t0;
          const m = document.querySelector('main.main');
          return { ms: Math.round(ms), testo: (m?.innerText || '').replace(/\\s+/g,' ').slice(0, 200), vuota: !m || !m.children.length,
                   larghezza: document.documentElement.scrollWidth, finestra: innerWidth, alta: document.documentElement.scrollHeight, h: innerHeight };
        })()`);
        await sleep(900);
        const nome = `${String(i + 2).padStart(2, "0")}-${list[i].replace(/[^\p{L}\p{N}]+/gu, "-").toLowerCase()}`;
        await s.shot(join(dir, nome + ".png"));
        res.schede.push({ nome: list[i], ...r, totale_ms: Date.now() - t0 });
      }
      res.errori = s.errors();
      writeFileSync(join(dir, "schede.json"), JSON.stringify(res, null, 1));
      console.log(JSON.stringify(res));
    } else throw new Error("comando sconosciuto " + cmd);
  } finally { s.close(); }
}

main().catch((e) => { console.log("ERRORE " + e.message); process.exitCode = 1; });
