// Tester20 · foto e valutazione nella finestra di OrbitLR (WebView2) attraverso il DevTools, se la porta è aperta.
// Uso: node cdp.mjs <porta> <foto.png> "<espressione js>"
import { writeFileSync } from "node:fs";
const [, , port, png, expr] = process.argv;
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const t = list.find((x) => x.type === "page" && !/shelf/i.test(x.url)) || list[0];
const ws = new WebSocket(t.webSocketDebuggerUrl);
await new Promise((ok, ko) => { ws.addEventListener("open", ok); ws.addEventListener("error", ko); });
let id = 0; const wait = new Map();
ws.addEventListener("message", (m) => { const d = JSON.parse(m.data); if (d.id && wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const send = (method, params = {}) => new Promise((ok) => { const i = ++id; wait.set(i, ok); ws.send(JSON.stringify({ id: i, method, params })); });
const shot = await send("Page.captureScreenshot", { format: "png" });
if (shot.result?.data) writeFileSync(png, Buffer.from(shot.result.data, "base64"));
const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true });
console.log(JSON.stringify(r.result?.result?.value ?? r.result));
ws.close();
