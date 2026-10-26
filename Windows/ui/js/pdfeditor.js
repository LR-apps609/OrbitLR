// Editor PDF, come sul Mac: compila i campi, scrivi, firma e oscura. Si apre a tutta finestra sopra la scheda File.
// Le modifiche restano qui finché non premi «Salva»: allora esce un PDF nuovo e l'originale non si tocca.

import { fileUrl, invoke } from "./api.js";
import { t } from "./i18n.js";
import { run } from "./jobs.js";
import { h, ico, modal, toast } from "./util.js";

export async function openPdfEditor(file) {
  let info;
  try {
    info = await invoke("pdf_info", { path: file.path });
  } catch (e) {
    return toast(String(e));
  }
  if (!info || !info.pages?.length) return toast(t("Questo PDF non si apre nell'editor."));

  const marks = { texts: [], images: [], redactions: [] }; // coordinate in punti, dall'alto a sinistra
  const fields = Object.fromEntries((info.fields || []).map((f) => [f.name, f.value]));
  const changedFields = new Set();
  let page = 1;
  let mode = "text"; // text | sign | redact
  let signature = null; // { png, ratio }
  let selected = null;
  let freshBox = null;

  const img = h("img.pe-img", { alt: "", draggable: "false" });
  img.addEventListener("error", () => (img.style.visibility = "hidden"));
  img.addEventListener("load", () => (img.style.visibility = ""));
  const layer = h("div.pe-layer");
  const sheet = h("div.pe-sheet", img, layer);
  const stage = h("div.pe-stage", sheet);
  const pageLabel = h("span.pe-pn");
  const side = h("aside.pe-side");
  const countEl = h("p.hint");
  const bg = h("div.pe-bg", { role: "dialog", "aria-modal": "true", "aria-label": t("Editor PDF") });

  const count = () => marks.texts.length + marks.images.length + marks.redactions.length + changedFields.size;
  const scale = () => sheet.clientWidth / info.pages[page - 1].width;

  async function loadPage() {
    pageLabel.textContent = t`Pagina ${page} di ${info.pages.length}`;
    const p = info.pages[page - 1];
    sheet.style.aspectRatio = `${p.width} / ${p.height}`;
    img.removeAttribute("src");
    try {
      const png = await invoke("pdf_page", { path: file.path, page });
      img.src = fileUrl(png) + "?v=" + page;
    } catch (e) {
      toast(String(e));
    }
    draw();
  }

  function draw() {
    const s = scale() || 1;
    const px = (v) => v * s + "px";
    const kids = [];
    marks.redactions.forEach((r, i) => {
      if (r.page !== page) return;
      kids.push(h("div.pe-red", { style: { left: px(r.x), top: px(r.y), width: px(r.w), height: px(r.h) } },
        h("button.pe-x", { "aria-label": t("Togli"), onpointerdown: (e) => e.stopPropagation(), onclick: () => { marks.redactions.splice(i, 1); draw(); } }, ico("x", 11))));
    });
    marks.images.forEach((m, i) => {
      if (m.page !== page) return;
      const el = h("div.pe-img-mark" + (selected === m ? ".on" : ""), { style: { left: px(m.x), top: px(m.y), width: px(m.w), height: px(m.h) } },
        h("img", { src: "data:image/png;base64," + m.png, alt: t("Firma"), draggable: "false" }),
        h("button.pe-x", { "aria-label": t("Togli"), onpointerdown: (e) => e.stopPropagation(), onclick: () => { marks.images.splice(i, 1); draw(); } }, ico("x", 11)),
        h("span.pe-grip", { title: t("Trascina per cambiare misura"), onpointerdown: (e) => resizeImage(e, m) }));
      el.addEventListener("pointerdown", (e) => moveMark(e, m));
      kids.push(el);
    });
    marks.texts.forEach((m, i) => {
      if (m.page !== page) return;
      const ta = h("textarea.pe-text", { rows: 1, spellcheck: "false", style: { fontSize: px(m.size), lineHeight: "1.15" } });
      ta.value = m.text;
      const fit = () => { ta.style.height = "auto"; ta.style.height = ta.scrollHeight + "px"; ta.style.width = Math.max(40, ...ta.value.split("\n").map((l) => l.length * m.size * s * 0.56)) + 8 + "px"; };
      ta.addEventListener("input", () => { m.text = ta.value; fit(); });
      ta.addEventListener("blur", () => { if (!m.text.trim()) { marks.texts.splice(marks.texts.indexOf(m), 1); draw(); } });
      const box = h("div.pe-text-mark", { style: { left: px(m.x), top: px(m.y) } }, ta,
        h("button.pe-x", { "aria-label": t("Togli"), onpointerdown: (e) => e.stopPropagation(), onclick: () => { marks.texts.splice(i, 1); draw(); } }, ico("x", 11)),
        h("span.pe-move", { title: t("Trascina per spostare"), onpointerdown: (e) => moveMark(e, m) }, ico("move", 11)));
      kids.push(box);
      if (m.fresh) { m.fresh = false; freshBox = ta; }
      setTimeout(fit, 0);
    });
    layer.replaceChildren(...kids);
    if (freshBox) { freshBox.focus(); freshBox = null; }
    renderSide();
  }

  function pointAt(e) {
    const r = layer.getBoundingClientRect();
    const s = scale() || 1;
    return { x: (e.clientX - r.left) / s, y: (e.clientY - r.top) / s };
  }

  function moveMark(e, m) {
    if (e.button !== 0) return;
    e.stopPropagation();
    selected = m;
    const start = pointAt(e), x0 = m.x, y0 = m.y;
    const p = info.pages[page - 1];
    const onMove = (ev) => {
      const q = pointAt(ev);
      m.x = Math.max(0, Math.min(p.width - 10, x0 + q.x - start.x));
      m.y = Math.max(0, Math.min(p.height - 10, y0 + q.y - start.y));
      const s = scale();
      const node = e.target.closest(".pe-img-mark, .pe-text-mark");
      if (node) { node.style.left = m.x * s + "px"; node.style.top = m.y * s + "px"; }
    };
    const onUp = () => { window.removeEventListener("pointermove", onMove); window.removeEventListener("pointerup", onUp); };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  }

  function resizeImage(e, m) {
    e.stopPropagation();
    e.preventDefault();
    const start = pointAt(e), w0 = m.w, ratio = m.h / m.w;
    const onMove = (ev) => {
      const q = pointAt(ev);
      m.w = Math.max(20, w0 + q.x - start.x);
      m.h = m.w * ratio;
      draw();
    };
    const onUp = () => { window.removeEventListener("pointermove", onMove); window.removeEventListener("pointerup", onUp); };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  }

  layer.addEventListener("pointerdown", (e) => {
    if (e.button !== 0 || e.target !== layer) return;
    const p0 = pointAt(e);
    if (mode === "text") {
      e.preventDefault();
      marks.texts.push({ page, x: p0.x, y: p0.y - 6, size: 12, text: "", fresh: true });
      draw();
    } else if (mode === "sign") {
      if (!signature) return drawSignature();
      const w = 150, hgt = w * signature.ratio;
      marks.images.push({ page, x: p0.x - w / 2, y: p0.y - hgt / 2, w, h: hgt, png: signature.png });
      draw();
    } else if (mode === "redact") {
      const r = { page, x: p0.x, y: p0.y, w: 0, h: 0 };
      marks.redactions.push(r);
      layer.setPointerCapture(e.pointerId);
      layer.onpointermove = (ev) => {
        const q = pointAt(ev);
        r.x = Math.min(p0.x, q.x); r.y = Math.min(p0.y, q.y);
        r.w = Math.abs(q.x - p0.x); r.h = Math.abs(q.y - p0.y);
        draw();
      };
      layer.onpointerup = () => {
        layer.onpointermove = null;
        if (r.w < 3 || r.h < 3) marks.redactions.splice(marks.redactions.indexOf(r), 1);
        draw();
      };
    }
  });

  async function drawSignature() {
    const cv = h("canvas.pe-pad", { width: 600, height: 220 });
    const ctx = cv.getContext("2d");
    ctx.lineWidth = 3.2; ctx.lineCap = "round"; ctx.lineJoin = "round"; ctx.strokeStyle = "#13233f";
    let drawing = false, any = false, last = null;
    const pos = (e) => { const r = cv.getBoundingClientRect(); return [(e.clientX - r.left) * cv.width / r.width, (e.clientY - r.top) * cv.height / r.height]; };
    cv.addEventListener("pointerdown", (e) => { drawing = true; last = pos(e); cv.setPointerCapture(e.pointerId); });
    cv.addEventListener("pointermove", (e) => { if (!drawing) return; const p = pos(e); ctx.beginPath(); ctx.moveTo(...last); ctx.lineTo(...p); ctx.stroke(); last = p; any = true; });
    cv.addEventListener("pointerup", () => (drawing = false));
    const wrap = h("div.modal-bg");
    const done = (ok) => {
      wrap.remove();
      if (!ok || !any) return;
      // Solo la parte disegnata, con lo sfondo trasparente
      const d = ctx.getImageData(0, 0, cv.width, cv.height).data;
      let x0 = cv.width, y0 = cv.height, x1 = 0, y1 = 0;
      for (let y = 0; y < cv.height; y++) for (let x = 0; x < cv.width; x++) if (d[(y * cv.width + x) * 4 + 3] > 10) { x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y); }
      if (x1 <= x0 || y1 <= y0) return;
      const pad = 6, cw = x1 - x0 + pad * 2, ch = y1 - y0 + pad * 2;
      const out = document.createElement("canvas");
      out.width = cw; out.height = ch;
      out.getContext("2d").drawImage(cv, x0 - pad, y0 - pad, cw, ch, 0, 0, cw, ch);
      signature = { png: out.toDataURL("image/png").split(",")[1], ratio: ch / cw };
      toast(t("Firma pronta: clicca sulla pagina dove metterla."));
      renderSide();
    };
    wrap.append(h("div.modal", { role: "dialog", "aria-modal": "true" }, h("h3", t("Disegna la tua firma")), h("p", t("Con il mouse, il touchpad o la penna.")), cv,
      h("div.row", h("button.btn", { onclick: () => { ctx.clearRect(0, 0, cv.width, cv.height); any = false; } }, t("Cancella")), h("div", { style: { flex: 1 } }),
        h("button.btn", { onclick: () => done(false) }, t("Annulla")), h("button.btn.primary", { onclick: () => done(true) }, t("Usa questa firma")))));
    document.body.append(wrap);
  }

  function setMode(m) {
    mode = m;
    if (m === "sign" && !signature) drawSignature();
    render();
  }

  function renderSide() {
    const tip = mode === "text" ? t("Clicca sulla pagina dove scrivere. La maniglia sposta il testo.")
      : mode === "sign" ? (signature ? t("Clicca sulla pagina dove mettere la firma; trascinala per spostarla, l'angolo per ingrandirla.") : t("Prima disegna la firma."))
        : t("Trascina sopra quello che vuoi nascondere. Le pagine oscurate diventano un'immagine: il testo sotto sparisce davvero.");
    const flist = (info.fields || []).map((f) => {
      const input = f.kind === "check"
        ? h("input", { type: "checkbox", checked: fields[f.name] && fields[f.name] !== "Off" ? true : null, onchange: (e) => { fields[f.name] = e.target.checked ? "Yes" : "Off"; changedFields.add(f.name); updateCount(); } })
        : h("input.pe-field", { type: "text", value: fields[f.name] || "", oninput: (e) => { fields[f.name] = e.target.value; changedFields.add(f.name); updateCount(); } });
      return h("label.pe-frow", h("span", f.name.split(".").pop()), input);
    });
    side.replaceChildren(
      h("div.group", t("Cosa vuoi fare")),
      h("div.pe-modes",
        ...[["text", "type", t("Scrivi")], ["sign", "pen-line", t("Firma")], ["redact", "square", t("Oscura")]].map(([id, icon, label]) =>
          h("button.pe-mode" + (mode === id ? ".on" : ""), { onclick: () => setMode(id) }, ico(icon, 16), label))),
      h("p.hint", tip),
      mode === "sign" && signature ? h("button.btn", { onclick: drawSignature }, t("Rifai la firma")) : null,
      flist.length ? h("div.group", t`Campi del modulo (${flist.length})`) : null,
      flist.length ? h("div.pe-fields", ...flist) : null,
      h("div.grow"),
      countEl);
    updateCount();
  }

  function updateCount() {
    countEl.textContent = count() ? t`${count()} modifiche` : t("Nessuna modifica ancora");
  }

  async function save() {
    if (!count()) return toast(t("Non hai fatto modifiche."));
    const edits = {
      texts: marks.texts.filter((m) => m.text.trim()).map(({ page, x, y, size, text }) => ({ page, x, y, size, text })),
      images: marks.images.map(({ page, x, y, w, h: hh, png }) => ({ page, x, y, w, h: hh, png })),
      redactions: marks.redactions.map(({ page, x, y, w, h: hh }) => ({ page, x, y, w, h: hh })),
      fields: Object.fromEntries([...changedFields].map((k) => [k, fields[k] ?? ""])),
    };
    close(true);
    run("pdfedit", [file], edits, "pdf");
  }

  async function close(force = false) {
    if (!force && count()) {
      const ok = await modal(t("Chiudere senza salvare?"), t("Le modifiche fatte qui andranno perse."), [{ label: t("Resta"), value: false }, { label: t("Chiudi"), value: true, primary: true }]);
      if (!ok) return;
    }
    document.removeEventListener("keydown", onKey);
    window.removeEventListener("resize", draw);
    bg.remove();
  }

  function onKey(e) {
    if (e.target instanceof Element && e.target.closest("textarea, input")) return;
    if (e.key === "Escape") close();
    if (e.key === "ArrowRight" && page < info.pages.length) { page++; loadPage(); }
    if (e.key === "ArrowLeft" && page > 1) { page--; loadPage(); }
  }

  function render() {
    bg.replaceChildren(h("div.pe",
      h("div.pe-head",
        h("div", h("b", file.name), h("div.sub", t("Editor PDF · l'originale non si tocca"))),
        h("div.grow"),
        h("button.btn.icon", { "aria-label": t("Pagina precedente"), disabled: page <= 1 || null, onclick: () => { page--; render(); loadPage(); } }, ico("chevron-left", 16)),
        pageLabel,
        h("button.btn.icon", { "aria-label": t("Pagina successiva"), disabled: page >= info.pages.length || null, onclick: () => { page++; render(); loadPage(); } }, ico("chevron-right", 16)),
        h("button.btn", { onclick: () => close() }, t("Chiudi")),
        h("button.btn.primary", { onclick: save }, ico("check", 15), t("Salva un PDF nuovo"))),
      h("div.pe-body", stage, side)));
    renderSide();
  }

  document.addEventListener("keydown", onKey);
  window.addEventListener("resize", draw);
  render();
  document.body.append(bg);
  loadPage();
}
