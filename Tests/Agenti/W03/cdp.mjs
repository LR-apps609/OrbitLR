// W03 · Legge la pagina di OrbitLR dentro WebView2 (porta di debug 9222): errori della console,
// testo, caratteri usati davvero (font di sistema), foto della pagina. Uso:
//   node cdp.mjs <uscita.json> [foto.png] [attesa-ms]
import { writeFileSync } from "node:fs";
const [out, shot, waitMs = "4000"] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let targets = [];
for (let i = 0; i < 20; i++) {
  try { targets = await (await fetch("http://127.0.0.1:9222/json")).json(); if (targets.some((t) => t.type === "page")) break; } catch {}
  await sleep(1000);
}
const res = { targets: targets.map((t) => ({ type: t.type, url: t.url, title: t.title })), console: [], exceptions: [], log: [] };
const page = targets.find((t) => t.type === "page" && !/shelf/.test(t.url)) || targets.find((t) => t.type === "page");
if (!page) { res.error = "nessuna pagina sulla porta 9222"; writeFileSync(out, JSON.stringify(res, null, 1)); process.exit(2); }
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
let id = 0; const wait = new Map();
ws.onmessage = (m) => {
  const d = JSON.parse(m.data);
  if (d.id && wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); return; }
  if (d.method === "Runtime.consoleAPICalled") res.console.push({ type: d.params.type, text: d.params.args.map((a) => a.value ?? a.description ?? "").join(" ").slice(0, 400) });
  if (d.method === "Runtime.exceptionThrown") res.exceptions.push((d.params.exceptionDetails.exception?.description || d.params.exceptionDetails.text || "").slice(0, 600));
  if (d.method === "Log.entryAdded") res.log.push({ level: d.params.entry.level, source: d.params.entry.source, text: d.params.entry.text.slice(0, 400), url: d.params.entry.url });
};
const send = (method, params = {}) => new Promise((r) => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => (await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true })).result?.result?.value;
await send("Runtime.enable"); await send("Log.enable"); await send("DOM.enable"); await send("CSS.enable"); await send("Page.enable");
await sleep(Number(waitMs));
res.url = await ev("location.href");
res.ua = await ev("navigator.userAgent");
res.text = await ev("document.body ? document.body.innerText.slice(0, 6000) : ''");
res.fontsLoaded = await ev("Promise.all([...document.fonts].map(f=>f.loaded.then(()=>f.family+' '+f.weight+' ok', ()=>f.family+' '+f.weight+' ERRORE')))");
// Caratteri difficili: frecce, stelle, emoji (come quelle della pagina) con il carattere dell'app
await ev(`(()=>{ const d=document.createElement('div'); d.id='w03'; d.style.cssText='position:fixed;left:0;top:0;font-family:var(--font);font-size:40px;z-index:99999;background:#fff;color:#000';
  const s=(id,t)=>{const e=document.createElement('span'); e.id=id; e.textContent=t; d.appendChild(e);};
  s('w03a','Città ë ç àèìòù'); s('w03b','→ ← ↔ … – −'); s('w03c','★ ✕ ▶ ◀ ⌘ ≈'); s('w03d','😕🙂😍'); document.body.appendChild(d); })()`);
const doc = await send("DOM.getDocument", { depth: -1 });
res.platformFonts = {};
for (const sel of ["#w03a", "#w03b", "#w03c", "#w03d", "body"]) {
  const q = await send("DOM.querySelector", { nodeId: doc.result.root.nodeId, selector: sel });
  const n = q.result?.nodeId;
  if (!n) { res.platformFonts[sel] = "nodo non trovato"; continue; }
  const f = await send("CSS.getPlatformFontsForNode", { nodeId: n });
  res.platformFonts[sel] = f.result?.fonts || f.error;
}
// Emoji a colori? Conta i pixel colorati disegnati su una tela
res.emojiColorPixels = await ev(`(()=>{const c=document.createElement('canvas');c.width=200;c.height=60;const x=c.getContext('2d');x.font='40px '+getComputedStyle(document.body).fontFamily;x.fillStyle='#000';x.fillText('😍🙂',4,46);const d=x.getImageData(0,0,200,60).data;let n=0;for(let i=0;i<d.length;i+=4){const r=d[i],g=d[i+1],b=d[i+2];if(d[i+3]>0&&(Math.abs(r-g)>40||Math.abs(g-b)>40))n++;}return n;})()`);
if (shot) {
  const p = await send("Page.captureScreenshot", { format: "png" });
  if (p.result?.data) writeFileSync(shot, Buffer.from(p.result.data, "base64"));
}
await ev("document.getElementById('w03')?.remove()");
writeFileSync(out, JSON.stringify(res, null, 1));
ws.close();
console.log(`cdp: ${res.console.filter((c) => c.type === "error").length} errori console, ${res.exceptions.length} eccezioni, emoji colorate ${res.emojiColorPixels}px`);
process.exit(0);
