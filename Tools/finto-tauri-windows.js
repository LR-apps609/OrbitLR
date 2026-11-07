// 2.0.1 · Un finto window.__TAURI__ per le prove dell'interfaccia (Tools/prova-errori-windows.mjs), dal lavoro del tester W07.
// Prende i dati di esempio della modalità prova (api.js) ma fa passare la UI dal ramo «vero» Tauri,
// così si possono provare: trascinamento di file finti, risposte che riescono, falliscono,
// arrivano tardi (10–60 s) o non arrivano mai.
// Configurazione: window.__Fcfg = { seed, mix: {ok, fail, slow, never}, slowMin, slowMax, per: { cmd: {mode, ms, error} }, failMsg }
(() => {
  const cfg = Object.assign({ seed: 1, mix: { ok: 1 }, slowMin: 10000, slowMax: 60000, per: {}, failMsg: "Il disco non risponde (errore finto)" }, window.__Fcfg || {});
  // PRNG con seme (mulberry32), separato da quello del percorso
  let s = (cfg.seed * 2654435761) >>> 0;
  const rnd = () => { s |= 0; s = (s + 0x6d2b79f5) | 0; let t = Math.imul(s ^ (s >>> 15), 1 | s); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  const log = (window.__Flog = []);
  const t0 = performance.now();
  const now = () => Math.round(performance.now() - t0);
  const pending = (window.__Fpending = new Map());
  let seq = 0;

  window.addEventListener("unhandledrejection", (e) => {
    const r = e.reason;
    log.push({ t: now(), type: "unhandledrejection", reason: String(r && r.stack ? r.stack : r).slice(0, 600) });
  });
  window.addEventListener("error", (e) => log.push({ t: now(), type: "error", reason: String(e.error && e.error.stack ? e.error.stack : e.message).slice(0, 600) }));

  const files = {
    "C:\\Utenti\\Prova\\Immagini\\Vacanze al mare.jpg": { kind: "image", size: 603000, width: 4032, height: 3024 },
    "C:\\Utenti\\Prova\\Immagini\\Tramonto.heic": { kind: "image", size: 2100000, width: 4032, height: 3024 },
    "C:\\Utenti\\Prova\\Immagini\\Logo.png": { kind: "image", size: 84000, width: 1024, height: 1024 },
    "C:\\Utenti\\Prova\\Immagini\\Città d'arte – perché sì è un nome molto lungo con accenti e spazi 2026.webp": { kind: "image", size: 1200000, width: 3000, height: 2000 },
    "C:\\Utenti\\Prova\\Video\\Gita al lago.mp4": { kind: "video", size: 48200000, width: 1920, height: 1080, duration: 74.5, fps: 30, has_video: true, has_audio: true, video_bitrate: 5000000 },
    "C:\\Utenti\\Prova\\Video\\Senza audio.mov": { kind: "video", size: 12000000, width: 1280, height: 720, duration: 12, fps: 60, has_video: true, has_audio: false, video_bitrate: 3000000 },
    "C:\\Utenti\\Prova\\Musica\\La mia canzone.mp3": { kind: "audio", size: 7100000, duration: 222, has_audio: true },
    "C:\\Utenti\\Prova\\Musica\\Nota.wav": { kind: "audio", size: 900000, duration: 5, has_audio: true },
    "C:\\Utenti\\Prova\\Documenti\\Contratto.pdf": { kind: "pdf", size: 1400000 },
    "C:\\Utenti\\Prova\\Documenti\\Relazione.docx": { kind: "doc", size: 240000 },
    "C:\\Utenti\\Prova\\Documenti\\Tabella.xlsx": { kind: "doc", size: 40000 },
    "C:\\Utenti\\Prova\\Documenti\\strano.xyz": { kind: "other", size: 1000 },
  };
  window.__Ffiles = files;
  // Cambia il comportamento al volo: __W07mode("probe_files", "slow", 20000); __W07mode(null) = da qui tutto ok
  window.__Fmode = (cmd, mode, ms) => { if (!cmd) { cfg.per = {}; cfg.mix = { ok: 1 }; return; } cfg.per[cmd] = { mode, ms }; };

  function thumb(path) {
    const c = document.createElement("canvas"); c.width = 160; c.height = 120;
    const g = c.getContext("2d"); const hue = [...path].reduce((a, ch) => a + ch.charCodeAt(0), 0) % 360;
    g.fillStyle = `hsl(${hue} 55% 62%)`; g.fillRect(0, 0, 160, 120);
    return c.toDataURL("image/jpeg", 0.7);
  }

  const listeners = {}; // nome evento → Set
  const emit = (name, payload) => (listeners[name] || new Set()).forEach((fn) => { try { fn({ event: name, payload }); } catch (e) { log.push({ t: now(), type: "listener-throw", reason: String(e.stack || e) }); } });
  window.__Femit = emit;
  const timers = {};
  let rules = [{ id: "foto", kind: "foto", path: "C:\\Utenti\\Prova\\Download", param: "", enabled: true }];
  // Come finisce un lavoro partito: "ok" | "fail" (errore sul file) | "stall" (nessun evento dopo il primo)
  window.__FjobEnd = cfg.jobEnd || null;

  function answer(cmd, a) {
    switch (cmd) {
      case "engine_status": return { ready: true, version: "ffmpeg version n9.0 (LGPL)", h264: ["h264_mf"], hevc: [], office: false };
      case "places": return { downloads: "C:\\Utenti\\Prova\\Download", desktop: "C:\\Utenti\\Prova\\Desktop", documents: "C:\\Utenti\\Prova\\Documenti", pictures: null, videos: null, music: null };
      case "probe_files": return (a.paths || []).map((p) => {
        const d = files[p];
        const name = p.split("\\").pop();
        if (!d && !/\.[a-z0-9]+$/i.test(name)) return { ok: false, path: p, error: "È una cartella vuota" };
        const dd = d || { kind: "other", size: 1000 };
        return { ok: true, path: p, info: { path: p, name, ext: name.split(".").pop().toLowerCase(), duration: 0, width: 0, height: 0, fps: 0, has_video: false, has_audio: false, video_bitrate: 0, ...dd } };
      });
      case "thumbnail": return ["image", "video"].includes(files[a.path]?.kind) ? thumb(a.path) : null;
      case "waveform": return Array.from({ length: a.points || 100 }, (_, i) => Math.abs(Math.sin(i / 7)) * 0.8);
      case "startup": return { files: [] };
      case "pdf_info": return { pages: [{ width: 595, height: 842 }, { width: 595, height: 842 }], fields: [{ name: "nome", value: "", kind: "text" }] };
      case "pdf_page": return thumb("pdf" + (a.index || 0));
      case "files_exist": return (a.paths || []).map(() => true);
      case "office_ready": return false;
      case "office_install": return true;
      case "watch_get": return rules;
      case "watch_set": rules = a.rules; return rules;
      case "voices": return [{ name: "Microsoft Elsa Desktop", culture: "it-IT" }];
      case "silences": return [[2, 3.5], [10, 11]];
      case "transcribe_words": return [{ start: 0, end: 2, text: "ciao a tutti", words: [] }];
      case "export_room": return { ok: true, free: 50e9, need: 1e8 };
      case "save_overlay": return "C:\\Temp\\o.png";
      case "phone_share": return { svg: "<svg xmlns='http://www.w3.org/2000/svg' width='120' height='120'><rect width='120' height='120'/></svg>", url: "http://192.168.1.5:7070/f/abc" };
      case "update_check": return cfg.update || null;
      case "update_install": return null;
      case "start_job": {
        const end = window.__FjobEnd || "ok";
        let p = 0;
        timers[a.id] = setInterval(() => {
          p += 0.1;
          if (end === "stall" && p > 0.25) { clearInterval(timers[a.id]); return; }
          if (p < 1) return emit("job", { id: a.id, kind: "progress", progress: p, index: 0, outputs: [], error: null, state: "running" });
          clearInterval(timers[a.id]);
          const src = a.files[0] || "C:\\x.bin";
          const name = src.split("\\").pop().replace(/\.[^.]+$/, "");
          const ext = String(a.action).startsWith("to:") ? a.action.slice(3) : src.split(".").pop();
          if (end === "fail") {
            emit("job", { id: a.id, kind: "file", progress: 1, index: 0, outputs: [], error: cfg.failMsg, state: "running" });
            emit("job", { id: a.id, kind: "done", progress: 1, index: 1, outputs: [], error: null, state: "failed" });
            return;
          }
          emit("job", { id: a.id, kind: "file", progress: 1, index: 0, outputs: [{ path: src.replace(/[^\\]+$/, `${name} (prova).${ext}`), name: `${name} (prova).${ext}`, size: Math.round((files[src]?.size || 100000) * 0.2) }], error: null, state: "running" });
          emit("job", { id: a.id, kind: "done", progress: 1, index: 1, outputs: [], error: null, state: "done" });
        }, 150);
        return null;
      }
      case "cancel_job":
        clearInterval(timers[a.id]);
        emit("job", { id: a.id, kind: "done", progress: 1, index: 0, outputs: [], error: null, state: "cancelled" });
        return null;
      default: return null;
    }
  }

  function pickMode(cmd) {
    const p = cfg.per[cmd];
    if (p) return { mode: p.mode, ms: p.ms, error: p.error };
    // Alcuni comandi non si toccano mai a caso (non fanno attendere nessuno)
    if (["set_lang", "ui_ready", "close_seen", "shelf_show", "shelf_expand"].includes(cmd)) return { mode: "ok" };
    const m = cfg.mix, tot = Object.values(m).reduce((a, b) => a + b, 0);
    let r = rnd() * tot;
    for (const [k, v] of Object.entries(m)) { if ((r -= v) < 0) return { mode: k, ms: k === "slow" ? Math.round(cfg.slowMin + rnd() * (cfg.slowMax - cfg.slowMin)) : 0 }; }
    return { mode: "ok" };
  }

  async function invoke(cmd, args = {}) {
    const id = ++seq;
    const { mode, ms, error } = pickMode(cmd);
    const short = JSON.stringify(args).slice(0, 160);
    const rec = { t: now(), id, cmd, mode, ms: ms || 0, args: short, outcome: "pending" };
    log.push(rec);
    pending.set(id, rec);
    await new Promise((r) => setTimeout(r, 40));
    if (mode === "never") return new Promise(() => {});
    if (mode === "slow") await new Promise((r) => setTimeout(r, ms));
    pending.delete(id);
    if (mode === "fail") { rec.outcome = "rejected"; rec.end = now(); throw error || `${cfg.failMsg} [${cmd}]`; }
    try { const v = answer(cmd, args); rec.outcome = "ok"; rec.end = now(); return v; }
    catch (e) { rec.outcome = "mock-throw " + e; throw e; }
  }

  let dropCb = null;
  window.__Fdrop = (paths, type = "drop") => { if (!dropCb) return false; dropCb({ payload: { type, paths, position: { x: 400, y: 300 } } }); return true; };
  window.__Fpick = null; // se impostato: cosa restituisce la finestra «Apri»
  const pickDefault = (filters) => {
    const ex = (filters && filters[0] && filters[0].extensions) || null;
    const all = Object.keys(files);
    const ok = ex ? all.filter((p) => ex.includes(p.split(".").pop().toLowerCase())) : all.slice(0, 2);
    return ok.length ? ok.slice(0, 2) : all.slice(0, 1);
  };

  window.__TAURI__ = {
    core: { invoke, convertFileSrc: (p) => "data:," + encodeURIComponent(p) },
    event: {
      listen: async (name, fn) => { (listeners[name] ||= new Set()).add(fn); return () => listeners[name].delete(fn); },
    },
    dialog: {
      open: async (o) => {
        log.push({ t: now(), type: "dialog", dir: !!o?.directory });
        if (o?.directory) return "C:\\Utenti\\Prova\\Uscita";
        const v = window.__Fpick;
        return v === undefined || v === null ? pickDefault(o?.filters) : v;
      },
    },
    opener: {
      revealItemInDir: async (p) => { log.push({ t: now(), type: "reveal", p }); },
      openUrl: async (u) => { log.push({ t: now(), type: "openUrl", u: String(u).slice(0, 80) }); },
    },
    webview: { getCurrentWebview: () => ({ onDragDropEvent: (cb) => { dropCb = cb; return Promise.resolve(() => {}); } }) },
  };
})();
