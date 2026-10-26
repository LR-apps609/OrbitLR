// Il riquadro delle scelte sotto uno strumento: pastiglie con i valori pronti, un campo per il valore libero,
// e il pulsante che fa partire il lavoro. Si ricorda l'ultima scelta.

import { KNOBS } from "./catalog.js";
import { fmtBytes, h, store } from "./util.js";

/**
 * kind: chiave di KNOBS. onGo(value). extra: { estimate(value) → testo, goLabel }
 */
export function knobPanel(kind, onGo, extra = {}) {
  const k = KNOBS[kind];
  let value = store.get("knob." + kind, k.default);
  if (!k.options.some((o) => o.value === value) && !k.custom) value = k.default;
  const est = h("div.est");
  const input = k.custom ? h("input", { type: "text", inputmode: "decimal", placeholder: k.custom.placeholder, "aria-label": k.custom.label }) : null;
  if (input && !k.options.some((o) => o.value === value)) input.value = String(value).replace(".", ",");

  const opts = h("div.opts", { role: "radiogroup" });
  function draw() {
    opts.replaceChildren(...k.options.map((o) =>
      h("button.opt" + (o.value === value ? ".on" : ""), { role: "radio", "aria-checked": o.value === value ? "true" : "false", onclick: () => { value = o.value; if (input) input.value = ""; draw(); } },
        o.label, o.small ? h("small", " · " + o.small) : null)));
    const e = extra.estimate?.(value);
    est.textContent = e || "";
  }
  input?.addEventListener("input", () => {
    const v = input.value.trim().replace(",", ".");
    if (v && !isNaN(Number(v)) && Number(v) > 0) {
      value = v;
      draw();
    }
  });
  draw();
  const go = h("button.btn.primary.big", {
    onclick: () => {
      store.set("knob." + kind, value);
      onGo(value);
    },
  }, extra.goLabel || "Avvia");
  // «Salva come mia azione»: la scelta di adesso, con un nome, in cima agli strumenti e nella torta
  const star = extra.onSave ? h("button.btn.ghost.save-preset", { type: "button", title: "La ritrovi in cima agli strumenti e nella torta", onclick: () => extra.onSave(value) }, "★ Salva come mia azione") : null;
  return h("div.params",
    k.hint ? h("p.hint", k.hint) : null,
    opts,
    input ? h("div.field", input, h("span", { style: { color: "var(--quiet)", fontSize: "12.5px" } }, k.custom.unit)) : null,
    est,
    go,
    star);
}

/** Peso stimato di «Comprimi» per i video. */
export function videoEstimate(files) {
  return (v) => {
    const total = files.reduce((a, f) => a + (f.size || 0), 0);
    if (!total) return "";
    if (v === "best") return `≈ ${fmtBytes(total * 0.5)} (dipende dal video)`;
    const mb = Number(String(v).replace(",", "."));
    if (!mb) return "";
    const each = mb * 1e6;
    const fits = files.filter((f) => f.size > each).length;
    if (!fits) return "Pesa già meno: non serve comprimere.";
    return files.length > 1 ? `Ogni video sotto ${fmtBytes(each)}` : `Da ${fmtBytes(total)} a meno di ${fmtBytes(each)}`;
  };
}

export function imageEstimate(files) {
  return (v) => {
    const total = files.reduce((a, f) => a + (f.size || 0), 0);
    if (!total) return "";
    if (v === "best") return `≈ ${fmtBytes(total * 0.45)} (dipende dalla foto)`;
    const kb = Number(String(v).replace(",", "."));
    return kb ? `Ogni foto sotto ${fmtBytes(kb * 1000)}` : "";
  };
}
