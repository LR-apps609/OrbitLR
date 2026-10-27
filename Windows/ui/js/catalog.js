// Le azioni con le parole dell'app per Mac. Gli id sono gli stessi (vcompress, cut, to:mp3…).

import { t, tc } from "./i18n.js";

export const KINDS = {
  image: { label: t("Immagini"), icon: "image", color: "#3F8F86" },
  video: { label: t("Video"), icon: "film", color: "#7E5FA8" },
  audio: { label: t("Audio"), icon: "audio-lines", color: "#C38A2E" },
  pdf: { label: "PDF", icon: "file-text", color: "#C2553F" },
  doc: { label: t("Documenti"), icon: "file-text", color: "#4F74B3" },
  other: { label: tc("kind", "Altro"), icon: "file", color: "#77796B" },
};

export const IMAGE_EXTS = ["jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "gif", "bmp", "tif", "tiff", "ico", "jfif"];
export const VIDEO_EXTS = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "ts", "mts", "m2ts", "3gp", "ogv", "vob", "mxf", "asf", "f4v"];
export const AUDIO_EXTS = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aac", "wma", "aiff", "aif", "aifc", "caf", "m4b", "m4r", "amr", "ac3", "oga", "mka"];

/** Formati in cui convertire, per tipo (i più usati prima). */
export const CONVERT = {
  image: ["jpg", "png", "webp", "pdf", "svg", "avif", "ico", "bmp", "tiff", "gif"],
  video: ["mp4", "mp3", "mov", "mkv", "webm", "gif", "m4a", "wav", "avi"],
  audio: ["mp3", "m4a", "wav", "flac", "ogg", "opus"],
  pdf: ["png", "jpg"],
  doc: [],
  other: [],
};

const FMT_ICON = { docx: "file-text", odt: "file-text", rtf: "file-text", txt: "file-text", xlsx: "list-ordered", ods: "list-ordered", csv: "list-ordered", pptx: "square-play", odp: "square-play", jpg: "image", png: "image", webp: "image", avif: "image", ico: "square-play", bmp: "image", tiff: "image", gif: "film", pdf: "file-text", svg: "pen-tool",
  mp4: "film", mov: "film", mkv: "film", webm: "film", avi: "film", mp3: "music", m4a: "music", wav: "audio-waveform", flac: "audio-waveform", ogg: "music", opus: "mic" };
/** Word, Excel e PowerPoint (con LibreOffice): in cosa si può convertire un documento. */
const DOC_GROUPS = [
  [["docx", "doc", "odt", "rtf", "txt", "wps"], ["pdf", "docx", "odt", "txt", "rtf"]],
  [["xlsx", "xls", "ods", "csv"], ["pdf", "xlsx", "ods", "csv"]],
  [["pptx", "ppt", "odp"], ["pdf", "pptx", "odp"]],
];
export function docTargets(ext) {
  const g = DOC_GROUPS.find(([from]) => from.includes(String(ext).toLowerCase()));
  return g ? g[1].filter((t) => t !== String(ext).toLowerCase()) : [];
}

export const fmtIcon = (f) => FMT_ICON[f] || "file";

/** «Nascondi un logo» → «Togli con l'IA»: acceso quando il modello LaMa per Windows è pubblicato e provato. */
export const AI_LOGO = true;

/** Le azioni (non conversioni). `min`: quanti file servono almeno. `params`: come si sceglie. */
export const TOOLS = {
  // Foto
  icompress: { title: t("Comprimi"), hint: t("Stessa qualità con meno peso, o sotto un peso preciso (moduli, documenti, visti)"), icon: "minimize-2", params: "icompress" },
  resize: { title: t("Ridimensiona"), hint: t("Più piccola, in percentuale o in pixel"), icon: "move-diagonal-2", params: "resize" },
  rotate: { title: t("Ruota"), hint: t("Di 90° a destra o a sinistra, o capovolgi"), icon: "rotate-cw", params: "rotate" },
  hidemark: { title: t("Nascondi un logo"), hint: t("Sfocalo, coprilo a quadretti o, sulle foto, toglilo con l'IA"), icon: "eye-off", params: "zones", isNew: true },
  strip: { title: t("Rimuovi i metadati"), hint: t("Posizione GPS, fotocamera e date: via, senza perdere qualità"), icon: "eye-off" },
  ocr: { title: t("Estrai il testo"), hint: t("Dalle foto e dagli screenshot, in un file di testo (con il riconoscimento di Windows)"), icon: "file-text", isNew: true },
  merge: { title: t("Unisci in un PDF"), hint: t("Una foto per pagina, nell'ordine dell'elenco"), icon: "file-stack", min: 2 },
  removebg: { title: t("Rimuovi lo sfondo"), hint: t("Resta solo il soggetto, su sfondo trasparente (la prima volta scarica il modello, 179 MB)"), icon: "scissors", params: "removebg", isNew: true },
  aienhance: { title: t("Migliora con l'IA"), hint: t("Più nitida e pulita, senza inventare dettagli (la prima volta scarica il motore, 45 MB)"), icon: "sparkles", params: "aienhance", isNew: true },
  straighten: { title: t("Raddrizza un documento"), hint: t("La foto storta di un foglio diventa una pagina dritta, come uno scanner"), icon: "crop", params: "straighten", isNew: true },
  stack: { title: t("Unisci più scatti"), hint: t("Più foto della stessa scena, allineate e fuse: meno rumore al buio"), icon: "layers", min: 2, isNew: true },
  upscale: { title: t("Ingrandisci"), hint: t("Due o quattro volte più grande, con i contorni nitidi"), icon: "zoom-in", params: "upscale", isNew: true },
  vector: { title: t("Vettoriale (SVG)"), hint: t("Loghi, disegni, firme e foto diventano un SVG: nitido a qualunque misura"), icon: "pen-tool", params: "vector", isNew: true },
  // Video
  vcompress: { title: t("Comprimi"), hint: t("Più leggero senza perdere qualità, o per Discord, WhatsApp ed email"), icon: "minimize-2", params: "vcompress" },
  vresize: { title: t("Cambia la grandezza"), hint: t("Full HD, HD o più piccolo, per pesare meno"), icon: "monitor-smartphone", params: "vresize" },
  social: { title: t("Formato social"), hint: t("Verticale, quadrato o 4:5 per Reels, TikTok e post"), icon: "smartphone", params: "social" },
  cut: { title: t("Taglia"), hint: t("Tieni solo un pezzo: istantaneo e senza perdita"), icon: "scissors", params: "trim" },
  gifcut: { title: t("GIF da un pezzo"), hint: t("Un'animazione da un tratto del video"), icon: "film", params: "trim" },
  speed: { title: t("Cambia la velocità"), hint: t("Da un quarto a quattro volte; la voce mantiene il tono"), icon: "gauge", params: "speed" },
  vmerge: { title: t("Unisci i video"), hint: t("Uno dopo l'altro, nell'ordine dell'elenco"), icon: "combine", min: 2 },
  normalize: { title: t("Volume uniforme"), hint: t("Né troppo basso né distorto"), icon: "volume-2" },
  voiceclean: { title: t("Voce più pulita"), hint: t("Meno ronzio e fruscio di fondo; il video non si ricomprime"), icon: "mic", isNew: true },
  transcribe: { title: t("Trascrivi"), hint: t("Le parole diventano testo e sottotitoli (.srt), sul computer"), icon: "file-text", isNew: true },
  subextract: { title: t("Estrai i sottotitoli"), hint: t("In un file .srt, da aprire o modificare"), icon: "file-text", isNew: true },
  subembed: { title: t("Aggiungi i sottotitoli"), hint: t("Da un file .srt con lo stesso nome, accanto al video: si accendono nel lettore"), icon: "captions", isNew: true },
  vstrip: { title: t("Rimuovi i metadati"), hint: t("Posizione, data e telefono: via, senza ricodificare"), icon: "eye-off", id: "strip", isNew: true },
  mute: { title: t("Togli l'audio"), hint: t("Istantaneo: il video non si tocca"), icon: "volume-x" },
  vrotate: { title: t("Ruota"), hint: t("Senza ricodificare: istantaneo"), icon: "rotate-cw", params: "rotate", id: "rotate" },
  // PDF
  pdfcompress: { title: t("Comprimi"), hint: t("Riduci il peso, per mandarlo via email: testo e link restano come sono"), icon: "minimize-2", params: "pdfcompress", isNew: true },
  pdfmerge: { title: t("Unisci"), hint: t("Più PDF in uno, nell'ordine dell'elenco"), icon: "combine", min: 2 },
  split: { title: t("Dividi in pagine"), hint: t("Un PDF per ogni pagina"), icon: "split" },
  extract: { title: t("Estrai alcune pagine"), hint: t("Scegli quali, per esempio 1-3, 5"), icon: "file-output", params: "pages" },
  pdfedit: { title: t("Compila, firma e oscura"), hint: t("Scrivi sul PDF, metti la firma, compila i moduli, nascondi i dati"), icon: "file-pen", params: "pdfedit", isNew: true },
  pdftext: { title: t("Estrai il testo"), hint: t("In un file di testo; dai PDF scansionati lo legge dalle pagine"), icon: "file-text", isNew: true },
  protect: { title: t("Proteggi con password"), hint: t("Serve la password per aprirlo (AES-256)"), icon: "lock", params: "password", isNew: true },
  unprotect: { title: t("Togli la password"), hint: t("Se la conosci: una copia che si apre senza"), icon: "lock-open", params: "password", isNew: true },
  prot: { title: t("Ruota le pagine"), hint: t("Tutte le pagine di 90° o capovolte"), icon: "rotate-cw", params: "rotate", id: "rotate", isNew: true },
  rename: { title: t("Rinomina tutti"), hint: t("Per esempio Vacanze 001, Vacanze 002…"), icon: "text-cursor-input", params: "rename", min: 1, isNew: true },
  reorder: { title: t("Riordina le pagine"), hint: t("Scrivi il nuovo ordine, per esempio 3, 1, 2"), icon: "list-ordered", params: "order", isNew: true },
};

export const GROUPS = {
  image: [
    [t("Modifica"), ["icompress", "resize", "removebg", "rotate", "hidemark", "strip"]],
    [t("Migliora"), ["aienhance", "upscale", "vector", "stack"]],
    [t("Documenti e più foto"), ["straighten", "ocr", "merge", "rename"]],
  ],
  video: [
    [t("Peso e grandezza"), ["vcompress", "vresize", "social"]],
    [t("Taglia e unisci"), ["cut", "gifcut", "vmerge", "speed"]],
    [t("Audio e sottotitoli"), ["transcribe", "voiceclean", "normalize", "mute", "subextract", "subembed"]],
    [t("Altro"), ["hidemark", "vrotate", "vstrip", "rename"]],
  ],
  pdf: [[t("Modifica"), ["pdfedit"]], [t("Peso"), ["pdfcompress"]], [t("Organizza"), ["pdfmerge", "split", "extract", "reorder", "prot"]], [t("Testo"), ["pdftext"]], [t("Proteggi"), ["protect", "unprotect"]], [t("Altro"), ["rename"]]],
};

/** Le scelte dei parametri, come le manopole dell'app per Mac. */
export const KNOBS = {
  vcompress: {
    hint: t("Prima si tengono qualità e misura; la risoluzione scende solo se serve."),
    options: [
      { value: "best", label: t("Stessa qualità, meno peso"), small: t("di solito la metà") },
      { value: "9", label: "Discord", small: "9 MB" },
      { value: "15", label: "WhatsApp", small: "15 MB" },
      { value: "18", label: t("Email"), small: "18 MB" },
      { value: "50", label: "50 MB" },
      { value: "100", label: "100 MB" },
    ],
    custom: { label: t("Altro peso"), unit: "MB", placeholder: t("es. 30") },
    default: "best",
  },
  icompress: {
    hint: t("Per moduli e documenti scegli il peso richiesto: OrbitLR tiene la qualità più alta possibile."),
    options: [
      { value: "best", label: t("Stessa qualità, meno peso") },
      { value: "1000", label: "1 MB" },
      { value: "500", label: "500 KB" },
      { value: "200", label: "200 KB" },
      { value: "100", label: "100 KB" },
      { value: "50", label: "50 KB" },
      { value: "20", label: "20 KB" },
    ],
    custom: { label: t("Altro peso"), unit: "KB", placeholder: t("es. 300") },
    default: "best",
  },
  vresize: {
    options: [
      { value: "1080", label: "Full HD", small: "1080p" },
      { value: "720", label: "HD", small: "720p" },
      { value: "480", label: "480p" },
      { value: "360", label: "360p" },
      { value: "hevc", label: t("Stessa misura in HEVC"), small: t("più leggero") },
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
    hint: t("Il video resta intero: i bordi si riempiono con lo stesso video sfocato."),
    flag: {
      label: t("Inquadra le persone"),
      short: t("persone"),
      hint: t("Il video riempie lo schermo e l'inquadratura segue chi c'è (i volti, con il rilevamento di Windows). Senza persone resta al centro."),
      default: true,
    },
    default: "9x16",
  },
  speed: {
    options: [
      { value: "0.5", label: t("0,5×") },
      { value: "0.75", label: t("0,75×") },
      { value: "1.25", label: t("1,25×") },
      { value: "1.5", label: t("1,5×") },
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
    custom: { label: t("Lato lungo"), unit: "px", placeholder: t("es. 1600") },
    default: "50%",
  },
  pdfcompress: {
    hint: t("Le foto dentro il PDF vengono ricompresse; testo, link e moduli restano come sono."),
    options: [
      { value: "medium", label: t("Schermo ed email"), small: t("consigliato") },
      { value: "light", label: t("Qualità di stampa") },
      { value: "strong", label: t("Il più leggero") },
    ],
    default: "medium",
  },
  straighten: {
    options: [
      { value: "jpg", label: t("Foto dritta"), small: "JPG" },
      { value: "pdf", label: t("Pagina PDF"), small: "PDF" },
    ],
    hint: t("Fotografa il foglio su un fondo scuro, con tutti e quattro gli angoli dentro la foto."),
    default: "jpg",
  },
  removebg: {
    options: [
      { value: "transparent", label: t("Trasparente"), small: "PNG" },
      { value: "white", label: t("Su bianco"), small: "JPG" },
      { value: "crop", label: t("Ritagliato"), small: t("attorno al soggetto") },
    ],
    hint: t("Tutto sul computer: la foto non va su internet."),
    default: "transparent",
  },
  aienhance: {
    options: [
      { value: "70", label: t("Naturale"), small: t("consigliato") },
      { value: "100", label: t("Più nitida") },
      { value: "anime", label: t("Disegni e anime") },
    ],
    hint: t("Usa la scheda video del PC. Stessa misura, meno rumore e più dettaglio."),
    default: "70",
  },
  vector: {
    options: [
      { value: "auto", label: t("Automatico"), small: t("consigliato") },
      { value: "logo", label: t("Logo e disegni"), small: t("colori pieni") },
      { value: "logot", label: t("Logo senza sfondo"), small: t("trasparente") },
      { value: "bw", label: t("Firme e scansioni"), small: t("un colore, trasparente") },
      { value: "photo", label: t("Foto"), small: t("effetto illustrazione") },
      { value: "photomax", label: t("Foto, più dettaglio"), small: t("file più grande") },
    ],
    hint: t("Sulle immagini piccole i bordi si ricostruiscono prima con l'IA (la prima volta scarica il motore, 45 MB). Tutto sul computer."),
    default: "auto",
  },
  upscale: {
    options: [
      { value: "2", label: "2×", small: t("il doppio") },
      { value: "4", label: "4×", small: t("quattro volte") },
    ],
    default: "2",
  },
  rotate: {
    options: [
      { value: "90", label: t("A destra"), small: "90°" },
      { value: "270", label: t("A sinistra"), small: "90°" },
      { value: "180", label: t("Capovolgi"), small: "180°" },
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
  vcompress: t("Comprimi"), icompress: t("Comprimi"), vresize: t("Cambia la grandezza"), social: t("Formato social"), cut: t("Taglia"), gifcut: t("GIF da un pezzo"),
  speed: t("Cambia la velocità"), vmerge: t("Unisci i video"), amerge: t("Unisci"), normalize: t("Volume uniforme"), voiceclean: t("Voce più pulita"), mute: t("Togli l'audio"),
  rotate: t("Ruota"), hidemark: t("Nascondi un logo"), ocr: t("Estrai il testo"), pdftext: t("Estrai il testo"), pdfedit: t("Compila, firma e oscura"), subextract: t("Estrai i sottotitoli"), subembed: t("Aggiungi i sottotitoli"), resize: t("Ridimensiona"), strip: t("Rimuovi i metadati"), merge: t("Unisci in un PDF"), pdfmerge: t("Unisci i PDF"), split: t("Dividi in pagine"),
  extract: t("Estrai pagine"), pdfcompress: t("Comprimi il PDF"), vproject: t("Esporta il montaggio"), ringtone: t("Suoneria"), silence: t("Togli i silenzi"), whatsapp: t("Vocale per WhatsApp"), tts: t("Testo in voce"), transcribe: t("Trascrivi"),
  removebg: t("Rimuovi lo sfondo"), aienhance: t("Migliora con l'IA"), upscale: t("Ingrandisci"), vector: t("Vettoriale (SVG)"), link: t("Scarica da un link"), protect: t("Proteggi con password"), unprotect: t("Togli la password"), reorder: t("Riordina le pagine"), rename: t("Rinomina tutti"), straighten: t("Raddrizza un documento"), stack: t("Unisci più scatti"),
};

export function actionName(id) {
  if (id.startsWith("to:")) return t`Converti in ${id.slice(3).toUpperCase()}`;
  return ACTION_NAMES[id] || id;
}
