// «Audio Downloader» e «Video Downloader», come sul Mac: in alto a destra in Audio e Video, con il posto
// per incollare il link e «Scarica». Funziona con migliaia di siti; i siti protetti (DRM) no, e lo dice.
// La barra si crea una volta sola: il testo incollato resta anche quando la scheda si ridisegna.

import { run, subscribe } from "./jobs.js";
import { h, ico, toast } from "./util.js";

/** Un link valido: http/https, senza spazi, con un dominio vero. */
export function linkFrom(text) {
  const t = String(text || "").trim();
  if (!t || /\s/.test(t)) return null;
  try {
    const u = new URL(t);
    if (!["http:", "https:"].includes(u.protocol) || !u.hostname.includes(".")) return null;
    return u.href;
  } catch {
    return null;
  }
}

/** video: true per i video (MP4 fino a 1080p), false per l'audio (M4A). onFile(path) quando è pronto. */
export function downloaderBar({ video, onFile }) {
  const name = video ? "Video Downloader" : "Audio Downloader";
  const input = h("input.dl-in", { type: "text", spellcheck: "false", placeholder: "Incolla un link · funziona con migliaia di siti", "aria-label": name + ": incolla un link" });
  const go = h("button.dl-go", { type: "button", title: "Scarica dal link (oppure premi Invio)" }, "Scarica");
  const el = h("div.dl" + (video ? ".video" : ".audio"), { role: "group", "aria-label": name },
    h("span.dl-label", ico("circle-arrow-down", 15), h("span.dl-name", name)), input, go);

  const update = () => go.classList.toggle("ok", !!linkFrom(input.value));
  input.addEventListener("input", update);
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") start(); });
  go.addEventListener("click", start);

  async function start() {
    const link = linkFrom(input.value);
    if (!link) return toast("Copia il link intero, con https:// davanti.");
    input.value = "";
    update();
    toast(video ? "Scarico il video… lo trovi qui quando è pronto." : "Scarico l’audio… lo trovi qui quando è pronto.");
    const job = await run("link", [], { link, mode: video ? "video" : "audio" }, video ? "video" : "audio");
    const done = (j) => {
      const out = j.results.flatMap((r) => r.outputs)[0];
      if (out) onFile?.(out.path);
      else if (j.state === "failed") toast(j.results.find((r) => r.error)?.error || "Non sono riuscito a scaricare da questo link.");
    };
    if (job.state !== "running") return done(job);
    const off = subscribe((j) => {
      if (!j || j.id !== job.id || j.state === "running") return;
      off();
      done(j);
    });
  }
  return el;
}
