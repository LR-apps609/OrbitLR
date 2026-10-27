// Benvenuto al primo avvio (tre schermate) e «Lo sapevi?» agli avvii successivi, come sul Mac.
// I consigli si spengono con «Non mostrare più» o dalle Opzioni.

import { env, h, ico, store } from "./util.js";
import { t } from "./i18n.js";
import { play } from "./sounds.js";

const STEPS = () => [
  { icon: "circle-arrow-down", title: t("Trascina un file, scegli uno spicchio"), text: t("Lascia cadere foto, video, audio o PDF nella scheda Conversione: intorno al file si apre la torta con quello che puoi farne. Il file nuovo finisce accanto all'originale.") },
  { icon: "layers", title: t("Una scheda per ogni tipo di file"), text: t("Immagini, Video, Audio e File hanno tutti gli strumenti: comprimi, taglia, togli lo sfondo, firma un PDF, crea una suoneria. Tutto sul computer, niente viene caricato.") },
  { icon: "external-link", title: t("OrbitLR è sempre a portata di mano"), text: env.store ? t("In Esplora file: tasto destro → «Apri con» → OrbitLR, oppure seleziona i file e premi Ctrl+Alt+C. Chiudendo la finestra resta l'icona vicino all'orologio.") : t("In Esplora file: tasto destro → «Apri con OrbitLR», oppure seleziona i file e premi Ctrl+Alt+C. Chiudendo la finestra resta l'icona vicino all'orologio.") },
];

const TIPS = () => [
  [t("Tasti 1–9"), t("Nella torta ogni spicchio ha il suo numero: premilo e parte subito.")],
  [t("Le mie azioni"), t("Quando scegli le opzioni premi «★ Salva come mia azione»: la ritrovi in cima agli strumenti e nella torta.")],
  [t("Ricette"), t("Dopo due passi di fila (per esempio comprimi e poi converti), salvali dalla barra del risultato: la prossima volta basta un clic.")],
  [t("Confronta prima e dopo"), t("Dopo una compressione premi «Confronta» e trascina la linea per vedere la differenza.")],
  [t("Annulla"), t("Il file creato non ti piace? «Annulla» lo manda nel Cestino; l'originale resta com'era.")],
  [t("Al telefono"), t("Dalla barra del risultato, «Al telefono» mostra un codice QR: inquadralo e il file arriva sul telefono, sulla stessa Wi-Fi.")],
  [t("Cartelle automatiche"), t("Scegli una cartella e cosa fare: ogni file che ci arriva viene sistemato da solo.")],
  [t("Video Downloader"), t("Nelle schede Video e Audio incolla un link: OrbitLR scarica il video o solo l'audio.")],
  [t("Togli un logo"), t("In Immagini, «Nascondi un logo» → «Togli con l'IA»: lo sfondo dietro viene ricostruito, sul computer.")],
  [t("Radio di notte"), t("In Opzioni → Aspetto scegli la modalità scura; lì spegni anche i suoni.")],
];

export const tipsOn = () => store.get("tips", true) !== false;
export const setTips = (on) => store.set("tips", !!on);

function welcome(done) {
  const steps = STEPS();
  let i = 0;
  const bg = h("div.modal-bg.welcome-bg");
  const card = h("div.modal.welcome", { role: "dialog", "aria-modal": "true", "aria-label": t("Benvenuto in OrbitLR") });
  const draw = () => {
    const s = steps[i];
    card.replaceChildren(
      h("div.w-mark", h("img", { src: "img/icona.png", alt: "", width: 56, height: 56, onerror: (e) => e.target.remove() })),
      h("span.w-step", `${i + 1} / ${steps.length}`),
      h("div.w-ico", ico(s.icon, 30)),
      h("h2", i === 0 ? t("Benvenuto in OrbitLR") : s.title),
      i === 0 ? h("h3", s.title) : null,
      h("p", s.text),
      h("div.w-dots", steps.map((_, k) => h("i" + (k === i ? ".on" : "")))),
      h("div.w-btns",
        i > 0 ? h("button.btn.ghost", { onclick: () => { i--; draw(); } }, t("Indietro")) : h("button.btn.ghost", { onclick: close }, t("Salta")),
        h("button.btn.primary", { onclick: () => { play("select"); if (i < steps.length - 1) { i++; draw(); } else close(); } }, i < steps.length - 1 ? t("Avanti") : t("Cominciamo"))));
    card.querySelector(".btn.primary")?.focus();
  };
  function close() {
    store.set("welcomed", true);
    bg.remove();
    document.removeEventListener("keydown", key);
    done?.();
  }
  const key = (e) => {
    if (e.key === "Escape") close();
    if (e.key === "ArrowRight" && i < steps.length - 1) { i++; draw(); }
    if (e.key === "ArrowLeft" && i > 0) { i--; draw(); }
  };
  document.addEventListener("keydown", key);
  bg.append(card);
  document.body.append(bg);
  draw();
}

function tip() {
  const list = TIPS();
  let i = (store.get("tipIndex", -1) + 1) % list.length;
  store.set("tipIndex", i);
  const box = h("div.tip-card", { role: "status" });
  const draw = () => {
    const [title, text] = list[i];
    box.replaceChildren(
      h("div.tip-head", ico("lightbulb", 16), h("b", t("Lo sapevi?")), h("button.btn.icon.ghost", { "aria-label": t("Chiudi"), title: t("Chiudi"), onclick: () => box.remove() }, ico("x", 14))),
      h("h4", title), h("p", text),
      h("div.tip-btns",
        h("button.btn.ghost", { onclick: () => { setTips(false); box.remove(); } }, t("Non mostrare più")),
        h("button.btn", { onclick: () => { i = (i + 1) % list.length; store.set("tipIndex", i); draw(); } }, t("Un altro"))));
  };
  draw();
  document.body.append(box);
  setTimeout(() => box.classList.add("in"), 30);
  // Sparisce da solo dopo un po', se non lo tocchi
  let timer = setTimeout(() => box.remove(), 20000);
  box.addEventListener("pointerenter", () => clearTimeout(timer));
}

/** All'avvio: il benvenuto la prima volta, poi (se acceso) un consiglio. */
export function startWelcome(skipTip = false) {
  if (!store.get("welcomed", false)) {
    setTimeout(() => welcome(), 700);
    return;
  }
  if (!skipTip && tipsOn()) setTimeout(tip, 2500);
}
