// Il ponte con il motore. Dentro l'app usa Tauri; aperto in un browser normale (per le prove e le foto)
// risponde con dati di esempio, così ogni schermata si può vedere anche senza Windows.

const T = window.__TAURI__;
export const DEMO = !T;

const listeners = new Set();

if (T) {
  T.event.listen("job", (e) => listeners.forEach((fn) => fn(e.payload)));
}

export function onJob(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export async function invoke(cmd, args = {}) {
  if (T) return T.core.invoke(cmd, args);
  return demo(cmd, args);
}

/** Indirizzo per mostrare un file locale in <video>, <audio> o <img>. */
export function fileUrl(path) {
  if (T) return T.core.convertFileSrc(path);
  return "";
}

export async function pickFiles(filters) {
  if (!T) return demoPick();
  const r = await T.dialog.open({ multiple: true, directory: false, filters });
  if (!r) return [];
  return Array.isArray(r) ? r : [r];
}

export async function pickFolder() {
  if (!T) return "C:\\Utenti\\Ledion\\Video";
  const r = await T.dialog.open({ directory: true, multiple: false });
  return typeof r === "string" ? r : null;
}

export async function reveal(path) {
  if (T) return T.opener.revealItemInDir(path);
}

export async function openPath(path) {
  if (T) return T.core.invoke("open_result", { path }).catch((e) => import("./util.js").then((u) => u.toast(String(e))));
}

export async function openUrl(url) {
  if (T) return T.opener.openUrl(url);
  window.open(url, "_blank");
}

/** File trascinati sulla finestra: Tauri dà i percorsi veri. */
export function onDrop(fn) {
  if (!T) return;
  const wv = T.webview.getCurrentWebview();
  wv.onDragDropEvent((ev) => {
    const p = ev.payload;
    fn(p.type, p.paths || [], p.position);
  });
}

// ── Modalità dimostrativa (solo fuori dall'app)

const demoFiles = {
  "C:\\Utenti\\Ledion\\Immagini\\Vacanze al mare.jpg": { kind: "image", size: 603_000, width: 4032, height: 3024 },
  "C:\\Utenti\\Ledion\\Immagini\\Tramonto.heic": { kind: "image", size: 2_100_000, width: 4032, height: 3024 },
  "C:\\Utenti\\Ledion\\Immagini\\Logo.png": { kind: "image", size: 84_000, width: 1024, height: 1024 },
  "C:\\Utenti\\Ledion\\Video\\Gita al lago.mp4": { kind: "video", size: 48_200_000, width: 1920, height: 1080, duration: 74.5, fps: 30, has_video: true, has_audio: true, video_bitrate: 5_000_000 },
  "C:\\Utenti\\Ledion\\Musica\\La mia canzone.mp3": { kind: "audio", size: 7_100_000, duration: 222, has_audio: true },
  "C:\\Utenti\\Ledion\\Documenti\\Contratto.pdf": { kind: "pdf", size: 1_400_000 },
};

let demoPickKind = "image";
export function setDemoPick(kind) {
  demoPickKind = kind;
}

function demoPick() {
  return Object.entries(demoFiles).filter(([, v]) => v.kind === demoPickKind).map(([k]) => k);
}

function demoThumb(path) {
  const c = document.createElement("canvas");
  c.width = 320;
  c.height = 240;
  const g = c.getContext("2d");
  const hue = [...path].reduce((a, ch) => a + ch.charCodeAt(0), 0) % 360;
  const grad = g.createLinearGradient(0, 0, 0, 240);
  grad.addColorStop(0, `hsl(${hue} 55% 72%)`);
  grad.addColorStop(0.62, `hsl(${(hue + 40) % 360} 60% 80%)`);
  grad.addColorStop(1, `hsl(${(hue + 80) % 360} 40% 55%)`);
  g.fillStyle = grad;
  g.fillRect(0, 0, 320, 240);
  g.fillStyle = "rgba(255,240,200,.9)";
  g.beginPath();
  g.arc(230, 100, 30, 0, 7);
  g.fill();
  g.fillStyle = `hsl(${(hue + 150) % 360} 30% 40%)`;
  g.fillRect(0, 170, 320, 70);
  return c.toDataURL("image/jpeg", 0.8);
}

const demoTimers = {};
async function demo(cmd, a) {
  await new Promise((r) => setTimeout(r, 60));
  switch (cmd) {
    case "engine_status":
      return { ready: true, version: "ffmpeg version n9.0 (LGPL)", h264: ["h264_nvenc", "h264_mf"], hevc: ["hevc_nvenc"] };
    case "places":
      return { downloads: "C:\\Utenti\\Ledion\\Download", desktop: "C:\\Utenti\\Ledion\\Desktop", documents: "C:\\Utenti\\Ledion\\Documenti", pictures: null, videos: null, music: null };
    case "probe_files":
      return a.paths.map((p) => {
        const d = demoFiles[p] || { kind: "other", size: 1000 };
        const name = p.split("\\").pop();
        return { ok: true, path: p, info: { path: p, name, ext: name.split(".").pop().toLowerCase(), duration: 0, width: 0, height: 0, fps: 0, has_video: false, has_audio: false, video_bitrate: 0, ...d } };
      });
    case "thumbnail":
      return demoFiles[a.path]?.kind === "image" || demoFiles[a.path]?.kind === "video" ? demoThumb(a.path) : null;
    case "waveform":
      return Array.from({ length: a.points }, (_, i) => Math.abs(Math.sin(i / 7) * 0.6 + Math.sin(i / 2.3) * 0.25) * (i % 50 > 44 ? 0.15 : 1));
    case "startup":
      return { files: [] };
    case "files_exist":
      return a.paths.map(() => true);
    case "start_job": {
      let p = 0;
      demoTimers[a.id] = setInterval(() => {
        p += 0.08;
        if (p < 1) {
          listeners.forEach((fn) => fn({ id: a.id, kind: "progress", progress: p, index: 0, outputs: [], error: null, state: "running" }));
          return;
        }
        clearInterval(demoTimers[a.id]);
        const src = a.files[0];
        const name = src.split("\\").pop().replace(/\.[^.]+$/, "");
        const ext = a.action.startsWith("to:") ? a.action.slice(3) : src.split(".").pop();
        const size = Math.round((demoFiles[src]?.size || 100000) * 0.19);
        listeners.forEach((fn) => fn({ id: a.id, kind: "file", progress: 1, index: 0, outputs: [{ path: src.replace(/[^\\]+$/, `${name} (compresso).${ext}`), name: `${name} (compresso).${ext}`, size }], error: null, state: "running" }));
        listeners.forEach((fn) => fn({ id: a.id, kind: "done", progress: 1, index: 1, outputs: [], error: null, state: "done" }));
      }, 160);
      return null;
    }
    case "cancel_job":
      clearInterval(demoTimers[a.id]);
      listeners.forEach((fn) => fn({ id: a.id, kind: "done", progress: 1, index: 0, outputs: [], error: null, state: "cancelled" }));
      return null;
    default:
      return null;
  }
}
