// Le azioni con le parole dell'app per Mac. Gli id sono gli stessi (vcompress, cut, to:mp3…).

export const KINDS = {
  image: { label: "Immagini", icon: "image", color: "#3F8F86" },
  video: { label: "Video", icon: "film", color: "#7E5FA8" },
  audio: { label: "Audio", icon: "audio-lines", color: "#C38A2E" },
  pdf: { label: "PDF", icon: "file-text", color: "#C2553F" },
  doc: { label: "Documenti", icon: "file-text", color: "#4F74B3" },
  other: { label: "Altro", icon: "file", color: "#77796B" },
};

export const IMAGE_EXTS = ["jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "gif", "bmp", "tif", "tiff", "ico", "jfif"];
export const VIDEO_EXTS = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "ts", "mts", "m2ts", "3gp", "ogv", "vob", "mxf", "asf", "f4v"];
export const AUDIO_EXTS = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aac", "wma", "aiff", "aif", "aifc", "caf", "m4b", "m4r", "amr", "ac3", "oga", "mka"];

/** Formati in cui convertire, per tipo (i più usati prima). */
export const CONVERT = {
  image: ["jpg", "png", "webp", "pdf", "avif", "ico", "bmp", "tiff", "gif"],
  video: ["mp4", "mp3", "mov", "mkv", "webm", "gif", "m4a", "wav", "avi"],
  audio: ["mp3", "m4a", "wav", "flac", "ogg", "opus"],
  pdf: [],
  doc: [],
  other: [],
};

const FMT_ICON = { jpg: "image", png: "image", webp: "image", avif: "image", ico: "square-play", bmp: "image", tiff: "image", gif: "film", pdf: "file-text",
  mp4: "film", mov: "film", mkv: "film", webm: "film", avi: "film", mp3: "music", m4a: "music", wav: "audio-waveform", flac: "audio-waveform", ogg: "music", opus: "mic" };
export const fmtIcon = (f) => FMT_ICON[f] || "file";

/** Le azioni (non conversioni). `min`: quanti file servono almeno. `params`: come si sceglie. */
export const TOOLS = {
  // Foto
  icompress: { title: "Comprimi", hint: "Stessa qualità con meno peso, o sotto un peso preciso (moduli, documenti, visti)", icon: "minimize-2", params: "icompress" },
  resize: { title: "Ridimensiona", hint: "Più piccola, in percentuale o in pixel", icon: "move-diagonal-2", params: "resize" },
  rotate: { title: "Ruota", hint: "Di 90° a destra o a sinistra, o capovolgi", icon: "rotate-cw", params: "rotate" },
  strip: { title: "Rimuovi i metadati", hint: "Posizione GPS, fotocamera e date: via, senza perdere qualità", icon: "eye-off" },
  merge: { title: "Unisci in un PDF", hint: "Una foto per pagina, nell'ordine dell'elenco", icon: "file-stack", min: 2 },
  // Video
  vcompress: { title: "Comprimi", hint: "Più leggero senza perdere qualità, o per Discord, WhatsApp ed email", icon: "minimize-2", params: "vcompress" },
  vresize: { title: "Cambia la grandezza", hint: "Full HD, HD o più piccolo, per pesare meno", icon: "monitor-smartphone", params: "vresize" },
  social: { title: "Formato social", hint: "Verticale, quadrato o 4:5 per Reels, TikTok e post", icon: "smartphone", params: "social" },
  cut: { title: "Taglia", hint: "Tieni solo un pezzo: istantaneo e senza perdita", icon: "scissors", params: "trim" },
  gifcut: { title: "GIF da un pezzo", hint: "Un'animazione da un tratto del video", icon: "film", params: "trim" },
  speed: { title: "Cambia la velocità", hint: "Da un quarto a quattro volte; la voce mantiene il tono", icon: "gauge", params: "speed" },
  vmerge: { title: "Unisci i video", hint: "Uno dopo l'altro, nell'ordine dell'elenco", icon: "combine", min: 2 },
  normalize: { title: "Volume uniforme", hint: "Né troppo basso né distorto", icon: "volume-2" },
  voiceclean: { title: "Voce più pulita", hint: "Meno ronzio e fruscio di fondo; il video non si ricomprime", icon: "mic", isNew: true },
  mute: { title: "Togli l'audio", hint: "Istantaneo: il video non si tocca", icon: "volume-x" },
  vrotate: { title: "Ruota", hint: "Senza ricodificare: istantaneo", icon: "rotate-cw", params: "rotate", id: "rotate" },
  // PDF
  pdfmerge: { title: "Unisci", hint: "Più PDF in uno, nell'ordine dell'elenco", icon: "combine", min: 2 },
  split: { title: "Dividi in pagine", hint: "Un PDF per ogni pagina", icon: "split" },
  extract: { title: "Estrai alcune pagine", hint: "Scegli quali, per esempio 1-3, 5", icon: "file-output", params: "pages" },
};

export const GROUPS = {
  image: [
    ["Modifica", ["icompress", "resize", "rotate", "strip"]],
    ["Più foto", ["merge"]],
  ],
  video: [
    ["Peso e grandezza", ["vcompress", "vresize", "social"]],
    ["Taglia e unisci", ["cut", "gifcut", "vmerge", "speed"]],
    ["Audio", ["voiceclean", "normalize", "mute"]],
    ["Altro", ["vrotate"]],
  ],
  pdf: [["Organizza", ["pdfmerge", "split", "extract"]]],
};

/** Le scelte dei parametri, come le manopole dell'app per Mac. */
export const KNOBS = {
  vcompress: {
    hint: "Prima si tengono qualità e misura; la risoluzione scende solo se serve.",
    options: [
      { value: "best", label: "Stessa qualità, meno peso", small: "di solito la metà" },
      { value: "9", label: "Discord", small: "9 MB" },
      { value: "15", label: "WhatsApp", small: "15 MB" },
      { value: "18", label: "Email", small: "18 MB" },
      { value: "50", label: "50 MB" },
      { value: "100", label: "100 MB" },
    ],
    custom: { label: "Altro peso", unit: "MB", placeholder: "es. 30" },
    default: "best",
  },
  icompress: {
    hint: "Per moduli e documenti scegli il peso richiesto: OrbitLR tiene la qualità più alta possibile.",
    options: [
      { value: "best", label: "Stessa qualità, meno peso" },
      { value: "1000", label: "1 MB" },
      { value: "500", label: "500 KB" },
      { value: "200", label: "200 KB" },
      { value: "100", label: "100 KB" },
      { value: "50", label: "50 KB" },
      { value: "20", label: "20 KB" },
    ],
    custom: { label: "Altro peso", unit: "KB", placeholder: "es. 300" },
    default: "best",
  },
  vresize: {
    options: [
      { value: "1080", label: "Full HD", small: "1080p" },
      { value: "720", label: "HD", small: "720p" },
      { value: "480", label: "480p" },
      { value: "360", label: "360p" },
      { value: "hevc", label: "Stessa misura in HEVC", small: "più leggero" },
    ],
    default: "720",
  },
  social: {
    options: [
      { value: "9x16", label: "9:16", small: "Reels, TikTok, Shorts" },
      { value: "1x1", label: "1:1", small: "post" },
      { value: "4x5", label: "4:5", small: "feed" },
      { value: "16x9", label: "16:9", small: "YouTube" },
    ],
    hint: "Il video resta intero: i bordi si riempiono con lo stesso video sfocato.",
    default: "9x16",
  },
  speed: {
    options: [
      { value: "0.5", label: "0,5×" },
      { value: "0.75", label: "0,75×" },
      { value: "1.25", label: "1,25×" },
      { value: "1.5", label: "1,5×" },
      { value: "2", label: "2×" },
      { value: "4", label: "4×" },
    ],
    default: "1.5",
  },
  resize: {
    options: [
      { value: "75%", label: "75%" },
      { value: "50%", label: "50%" },
      { value: "25%", label: "25%" },
      { value: "3840", label: "4K", small: "3840 px" },
      { value: "1920", label: "1920 px" },
      { value: "1280", label: "1280 px" },
    ],
    custom: { label: "Lato lungo", unit: "px", placeholder: "es. 1600" },
    default: "50%",
  },
  rotate: {
    options: [
      { value: "90", label: "A destra", small: "90°" },
      { value: "270", label: "A sinistra", small: "90°" },
      { value: "180", label: "Capovolgi", small: "180°" },
    ],
    default: "90",
  },
};

export function kindOfExt(ext) {
  const e = (ext || "").toLowerCase();
  if (IMAGE_EXTS.includes(e)) return "image";
  if (VIDEO_EXTS.includes(e)) return "video";
  if (AUDIO_EXTS.includes(e)) return "audio";
  if (e === "pdf") return "pdf";
  if (["docx", "doc", "odt", "rtf", "txt", "md", "html", "htm", "xlsx", "xls", "ods", "csv", "pptx", "ppt", "odp", "epub"].includes(e)) return "doc";
  return "other";
}

export const ACTION_NAMES = {
  vcompress: "Comprimi", icompress: "Comprimi", vresize: "Cambia la grandezza", social: "Formato social", cut: "Taglia", gifcut: "GIF da un pezzo",
  speed: "Cambia la velocità", vmerge: "Unisci i video", amerge: "Unisci", normalize: "Volume uniforme", voiceclean: "Voce più pulita", mute: "Togli l'audio",
  rotate: "Ruota", resize: "Ridimensiona", strip: "Rimuovi i metadati", merge: "Unisci in un PDF", pdfmerge: "Unisci i PDF", split: "Dividi in pagine",
  extract: "Estrai pagine", ringtone: "Suoneria", silence: "Togli i silenzi", whatsapp: "Vocale per WhatsApp", tts: "Testo in voce",
};

export function actionName(id) {
  if (id.startsWith("to:")) return "Converti in " + id.slice(3).toUpperCase();
  return ACTION_NAMES[id] || id;
}
