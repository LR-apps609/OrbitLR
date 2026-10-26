// «Confronta», come sul Mac: originale e risultato uno sopra l'altro, con la linea da trascinare.
// Esc o un clic fuori chiude.

import { fileUrl, invoke } from "./api.js";
import { fmtBytes, h, ico, toast } from "./util.js";

export async function openCompare(before, after) {
  const ok = await invoke("allow_made", { path: after.path }).catch(() => false);
  if (!ok) return toast("Il risultato non si può aprire qui: usa «Apri».");
  let pos = 50;
  const imgB = h("img", { src: fileUrl(before.path), alt: "Originale", draggable: "false" });
  const imgA = h("img", { src: fileUrl(after.path), alt: "Risultato", draggable: "false" });
  const top = h("div.cmp-top", imgA);
  const line = h("div.cmp-line", h("span", ico("move-horizontal", 16)));
  const stage = h("div.cmp-stage", { role: "slider", tabindex: "0", "aria-label": "Linea tra originale e risultato", "aria-valuemin": "0", "aria-valuemax": "100" }, imgB, top, line,
    h("span.cmp-tag.l", "Originale · " + fmtBytes(before.size || 0)), h("span.cmp-tag.r", "Risultato · " + fmtBytes(after.size || 0)));
  const set = (p) => {
    pos = Math.max(0, Math.min(100, p));
    top.style.clipPath = `inset(0 0 0 ${pos}%)`;
    line.style.left = pos + "%";
    stage.setAttribute("aria-valuenow", String(Math.round(pos)));
  };
  const fromEvent = (e) => {
    const r = stage.getBoundingClientRect();
    set(((e.clientX - r.left) / r.width) * 100);
  };
  let drag = false;
  stage.addEventListener("pointerdown", (e) => { drag = true; stage.setPointerCapture(e.pointerId); fromEvent(e); });
  stage.addEventListener("pointermove", (e) => drag && fromEvent(e));
  stage.addEventListener("pointerup", () => (drag = false));
  stage.addEventListener("keydown", (e) => {
    if (e.key === "ArrowLeft") set(pos - 5);
    if (e.key === "ArrowRight") set(pos + 5);
  });
  const bg = h("div.modal-bg.cmp-bg");
  const close = () => { bg.remove(); document.removeEventListener("keydown", esc); };
  const esc = (e) => e.key === "Escape" && close();
  bg.append(h("div.cmp", { role: "dialog", "aria-modal": "true", "aria-label": "Confronta" },
    h("div.cmp-head", h("b", "Confronta"), h("span", "Trascina la linea, o usa le frecce"), h("div.grow"),
      h("button.btn.icon.ghost", { "aria-label": "Chiudi", onclick: close }, ico("x", 16))), stage));
  bg.addEventListener("click", (e) => e.target === bg && close());
  document.addEventListener("keydown", esc);
  document.body.append(bg);
  set(50);
  stage.focus();
}
