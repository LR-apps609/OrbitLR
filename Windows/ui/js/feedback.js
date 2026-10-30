// «Suggerisci un'idea», come sul Mac: tre faccine e una riga di testo, mandate per email (solo quello che
// scrivi e la versione di OrbitLR, niente nomi di file). Dopo 10 lavori riusciti OrbitLR lo chiede una volta sola.

import { openUrl } from "./api.js";
import { askDiscard, guardClose, h, store, toast } from "./util.js";
import { t } from "./i18n.js";

const RECIPIENT = "ledion.proaccs@gmail.com";
export const FACES = [["meh", "😕", "Così così"], ["ok", "🙂", "Bene"], ["love", "😍", "Benissimo"]];
const THRESHOLD = 10;

export function mailFor(face, text, version) {
  const f = FACES.find((x) => x[0] === face);
  const subject = `[OrbitLR per Windows ${version}] Idea` + (f ? ` · ${f[2]}` : "");
  const body = (f ? `Come mi trovo: ${f[1]} ${f[2]}\n\n` : "") + (text.trim() || "(scrivi qui la tua idea)") +
    `\n\n---\nOrbitLR per Windows ${version} · ${navigator.userAgent.match(/Windows NT [\d.]+/)?.[0] || navigator.platform}`;
  return `mailto:${RECIPIENT}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
}

export function showFeedback(version, face = null) {
  store.set("feedbackAsked", true);
  let chosen = face;
  const faces = h("div.fb-faces");
  const draw = () => faces.replaceChildren(...FACES.map(([id, emoji, name]) =>
    h("button.fb-face" + (chosen === id ? ".on" : ""), { type: "button", "aria-pressed": chosen === id ? "true" : "false", onclick: () => { chosen = id; draw(); check(); } }, h("span.e", emoji), h("span", t(name)))));
  const ta = h("textarea.fb-text", { rows: 5, placeholder: t("Un’idea, una cosa che manca, una che non ti piace…"), "aria-label": t("La tua idea") });
  const send = h("button.btn.primary", { type: "button" }, t("Scrivi l’email"));
  const check = () => (send.disabled = !chosen && !ta.value.trim());
  ta.addEventListener("input", check);
  const bg = h("div.modal-bg");
  // 1.1 · Esc, Annulla o un clic fuori: se hai scritto o scelto qualcosa, prima si chiede
  let unguard = () => {};
  const close = () => { bg.remove(); unguard(); document.removeEventListener("keydown", esc, true); };
  const hasWork = () => !!(chosen || ta.value.trim());
  const ask = async () => { if (!hasWork() || (await askDiscard(t("Buttare l’idea?"), t("Quello che hai scritto non si ritrova.")))) close(); };
  const esc = (e) => { if (e.key === "Escape" && bg.isConnected && [...document.querySelectorAll(".modal-bg")].pop() === bg) { e.preventDefault(); e.stopImmediatePropagation(); ask(); } };
  document.addEventListener("keydown", esc, true);
  unguard = guardClose(() => (hasWork() ? t("«Suggerisci un’idea» ha un testo non ancora mandato.") : null));
  send.addEventListener("click", () => {
    // L'email non si apre (nessun programma di posta)? Lo si dice, e il testo resta qui
    openUrl(mailFor(chosen, ta.value, version)).then(close, () => toast(t`Non riesco ad aprire il programma di posta: copia il testo e mandalo a ${RECIPIENT}.`, 8000));
  });
  draw();
  check();
  bg.append(h("div.modal.fb", { role: "dialog", "aria-modal": "true", "aria-label": t("Suggerisci un’idea") },
    h("h3", t("Come ti trovi con OrbitLR?")), faces, ta,
    h("p.fb-note", t("Si apre un’email già pronta: contiene solo quello che scrivi e la versione di OrbitLR, niente nomi di file.")),
    h("div.row", h("button.btn", { type: "button", onclick: ask }, t("Annulla")), send)));
  bg.addEventListener("click", (e) => e.target === bg && ask());
  document.body.append(bg);
  ta.focus();
}

/** Dopo un lavoro riuscito: conta, e alla decima volta (una sola) aggiunge la domanda alla barra. */
export function askFeedbackOnce(bar) {
  if (!bar || store.get("feedbackAsked", false)) return;
  const n = store.get("feedbackOk", 0) + 1;
  store.set("feedbackOk", n);
  if (n < THRESHOLD) return;
  store.set("feedbackAsked", true);
  const version = window.__orbitVersion || "";
  bar.append(h("div.fb-ask", h("span", t("Ti piace OrbitLR?")),
    ...FACES.map(([id, emoji, name]) => h("button.fb-mini", { type: "button", title: t(name), "aria-label": t(name), onclick: () => showFeedback(version, id) }, emoji)),
    h("button.linkish", { type: "button", onclick: (e) => e.target.closest(".fb-ask")?.remove() }, t("No grazie"))));
}
