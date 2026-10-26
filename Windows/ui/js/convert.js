// Conversione: trascina un file, si apre la torta con i formati. Lo spicchio «Modifica» porta il file
// nella sua scheda. Con tipi diversi insieme, una torta piccola per tipo. Tasti 1–9; Invio = ultima scelta.

import { invoke, pickFiles, setDemoPick } from "./api.js";
import { CONVERT, KINDS, docTargets, fmtIcon } from "./catalog.js";
import { askOffice } from "./office.js";
import { run } from "./jobs.js";
import { resultBar } from "./resultbar.js";
import { fmtBytes, h, ico, store, toast } from "./util.js";
import { presets, runSteps } from "./presets.js";
import { subscribe } from "./jobs.js";
import { t, tr } from "./i18n.js";

export function convertPage(app) {
  let files = [];
  const bar = resultBar("convert");
  const stage = h("div.dial-wrap");
  const el = h("div.page", stage, bar.el);
  let keyMap = [];
  // «Altro»: il secondo anello con i formati che non stanno nel primo
  let moreFor = null;

  async function add(paths) {
    const probed = await invoke("probe_files", { paths });
    for (const p of probed) {
      if (!p.ok) {
        toast(tr(p.error));
        continue;
      }
      if (!files.some((f) => f.path === p.info.path)) files.push({ path: p.info.path, name: p.info.name, size: p.info.size, info: p.info, kind: p.info.kind });
    }
    render();
    const first = files[0];
    if (first && (first.kind === "image" || first.kind === "video")) {
      invoke("thumbnail", { path: first.path, side: 200 }).then((t) => {
        if (t && files[0] === first) {
          first.thumb = t;
          render();
        }
      }).catch(() => {});
    }
  }

  async function pick() {
    setDemoPick("image");
    const p = await pickFiles();
    if (p.length) add(p);
  }

  function byKind() {
    const m = new Map();
    for (const f of files) {
      const k = f.kind || "other";
      if (!m.has(k)) m.set(k, []);
      m.get(k).push(f);
    }
    return [...m.entries()];
  }

  let lastRun = { key: "", at: 0 };
  function choose(kind, list, fmt) {
    // Un doppio clic (o clic + Invio) non fa partire due volte lo stesso lavoro
    const key = fmt + "|" + list.map((f) => f.path).join("|");
    if (key === lastRun.key && Date.now() - lastRun.at < 1500) return;
    lastRun = { key, at: Date.now() };
    store.set("lastFmt." + kind, fmt);
    if (kind === "doc") {
      // Word, Excel e PowerPoint: serve LibreOffice (si installa con un clic la prima volta)
      askOffice(app).then((ok) => ok && run("to:" + fmt, list, null, "convert"));
      return;
    }
    run("to:" + fmt, list, null, "convert");
  }

  function pie(kind, list, size) {
    const R = size / 2;
    // Documenti: i formati che vanno bene per TUTTI i file scelti (un Word e un Excel insieme → solo PDF)
    const formats = kind === "doc"
      ? list.map((f) => docTargets(f.info?.ext || f.name.split(".").pop())).reduce((a, b) => a.filter((x) => b.includes(x)))
      : CONVERT[kind] || [];
    const mine = presets(kind).slice(0, 3);
    const more = moreFor === kind;
    const room = Math.max(3, 7 - mine.length);
    const shown = more ? formats.slice(room) : formats.slice(0, formats.length > room + 1 ? room : room + 1);
    const slices = shown.map((f) => ({ id: f, label: f.toUpperCase(), icon: fmtIcon(f), go: () => choose(kind, list, f) }));
    if (!more) {
      for (const p of mine) slices.push({ id: p.id, label: p.name, icon: "sparkles", mine: true, go: () => (p.steps ? runSteps(p.steps, list, "convert", run, subscribe) : run(p.action, list, p.param, "convert")) });
    }
    if (more) {
      slices.push({ id: "back", label: t("Indietro"), icon: "rotate-ccw", edit: true, go: () => { moreFor = null; render(); } });
    } else if (formats.length > shown.length) {
      slices.push({ id: "more", label: t("Altro"), icon: "ellipsis", edit: true, go: () => { moreFor = kind; render(); } });
    }
    if (!more && kind !== "other" && kind !== "doc") {
      const tab = kind === "pdf" ? "pdf" : kind;
      slices.push({ id: "edit", label: t("Modifica"), icon: "sliders-horizontal", edit: true, go: () => app.openIn(tab, list.map((f) => f.path)) });
    }
    const node = h("div.pie", { style: { width: size + "px", height: size + "px" }, role: "group", "aria-label": t`Formati per ${KINDS[kind].label}` }, h("div.pie-disc"));
    const one = list.length === 1 ? list[0] : null;
    const cs = Math.round(size * 0.4);
    node.append(h("div.pie-center", { style: { width: cs + "px", height: cs + "px" } },
      h("div",
        one?.thumb ? h("img", { src: one.thumb, alt: "" }) : h("div", { style: { color: KINDS[kind].color, display: "grid", placeItems: "center" } }, ico(KINDS[kind].icon, size > 300 ? 46 : 30)),
        h("div.nm", one ? one.name : t`${list.length} file`),
        h("div.sz", one ? fmtBytes(one.size) : `${KINDS[kind].label} · ${fmtBytes(list.reduce((a, f) => a + f.size, 0))}`))));
    if (!slices.length) {
      node.append(h("div", { style: { position: "absolute", bottom: "14%", left: "15%", right: "15%", textAlign: "center", fontSize: "12.5px", zIndex: 3 } },
        kind === "doc" ? t("Questo documento non lo so ancora convertire (Word, Excel e PowerPoint sì)") : t("Questo formato non lo so ancora lavorare")));
    }
    const ring = R * 0.72;
    slices.forEach((s, i) => {
      const a = (-90 + (i * 360) / slices.length) * (Math.PI / 180);
      const n = keyMap.length + 1;
      if (n <= 9) keyMap.push(s.go);
      const b = h("button.slice" + (s.edit ? ".edit" : "") + (s.mine ? ".mine" : ""), {
        style: { left: R + Math.cos(a) * ring + "px", top: R + Math.sin(a) * ring + "px", animationDelay: i * 30 + "ms" },
        onclick: s.go, title: s.mine ? t("Una delle mie azioni") : s.id === "more" ? t("Altri formati") : s.id === "back" ? t("Torna ai formati principali") : s.edit ? t("Apri nella sua scheda con tutti gli strumenti") : t`Converti in ${s.label}`,
      }, n <= 9 ? h("span.k", String(n)) : null, ico(s.icon, 18), s.label);
      node.append(b);
    });
    return node;
  }

  function render() {
    keyMap = [];
    if (!files.length) {
      const dz = h("div.dropzone", { role: "button", tabindex: "0", onclick: pick, onkeydown: (e) => e.key === "Enter" && pick() },
        h("div.dz-inner",
          logoRing(),
          h("h2", t("Trascina un file. Scegli cosa farne.")),
          h("p", t("oppure clicca per sceglierlo · funziona anche con più file e con le cartelle")),
          h("div.chips", ["pdf", "image", "video", "audio", "doc"].map((k) => h("span.chip-k", { style: { background: KINDS[k].color + "22", color: KINDS[k].color } }, ico(KINDS[k].icon, 13), KINDS[k].label)))));
      stage.replaceChildren(dz);
      app.dropTarget = dz;
      return;
    }
    const groups = byKind();
    const size = groups.length === 1 ? 470 : groups.length === 2 ? 330 : 260;
    const pies = h("div.pies", groups.map(([k, list]) => pie(k, list, size)));
    const close = h("button.btn", { onclick: () => { files = []; moreFor = null; bar.clear(); render(); } }, ico("x", 15), t("Togli tutto"));
    stage.replaceChildren(
      h("div.pie-stage", pies),
      h("div.pie-top", h("button.btn", { onclick: pick }, ico("plus", 15), t("Aggiungi file…")), close),
      h("div.pie-hint", h("span", ico("arrow-left-right", 14), t("Clic su un formato")), h("span", t("1–9 · Invio = ultima scelta")), h("span", t("Esc per togliere"))));
    app.dropTarget = null;
  }

  function onKey(e) {
    if (!el.isConnected || !files.length || (e.target instanceof Element && e.target.closest("input, textarea, select")) || document.querySelector(".modal-bg")) return;
    if ((e.key === "Enter" || e.key === " ") && (e.target instanceof Element && e.target.closest("button"))) return; // ci pensa il pulsante
    const n = Number(e.key);
    if (n >= 1 && n <= 9 && keyMap[n - 1]) {
      e.preventDefault();
      keyMap[n - 1]();
    } else if (e.key === "Enter") {
      const groups = byKind();
      if (groups.length === 1) {
        const [k, list] = groups[0];
        const last = store.get("lastFmt." + k, null);
        if (last && CONVERT[k]?.includes(last)) choose(k, list, last);
      }
    } else if (e.key === "Escape" && moreFor) {
      moreFor = null;
      render();
    } else if (e.key === "Escape") {
      files = [];
      render();
    }
  }
  document.addEventListener("keydown", onKey);

  render();
  return { el, add, kind: "convert", show() {} };
}

/** Il quadrante colorato con il + al centro (come sull'app per Mac). */
export function logoRing() {
  const colors = ["#8FB489", "#E3B866", "#9C95C9", "#4F9E99", "#C76B4F", "#8E6AB3", "#D9973A", "#6F8FC6"];
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "-80 -80 160 160");
  svg.setAttribute("class", "ring-logo");
  svg.setAttribute("aria-hidden", "true");
  const bg = document.createElementNS(ns, "circle");
  bg.setAttribute("r", "78");
  bg.style.fill = "color-mix(in srgb, var(--sage) 22%, transparent)";
  svg.append(bg);
  colors.forEach((c, i) => {
    const a0 = ((i * 45 - 90 + 4) * Math.PI) / 180, a1 = (((i + 1) * 45 - 90 - 4) * Math.PI) / 180;
    const r0 = 52, r1 = 70;
    const p = document.createElementNS(ns, "path");
    const pt = (r, a) => `${(Math.cos(a) * r).toFixed(2)} ${(Math.sin(a) * r).toFixed(2)}`;
    p.setAttribute("d", `M ${pt(r1, a0)} A ${r1} ${r1} 0 0 1 ${pt(r1, a1)} L ${pt(r0, a1)} A ${r0} ${r0} 0 0 0 ${pt(r0, a0)} Z`);
    p.setAttribute("fill", c);
    svg.append(p);
  });
  const mid = document.createElementNS(ns, "circle");
  mid.setAttribute("r", "36");
  mid.style.fill = "var(--card)";
  mid.style.stroke = "var(--brass)";
  mid.setAttribute("stroke-width", "2.5");
  svg.append(mid);
  const plus = document.createElementNS(ns, "path");
  plus.setAttribute("d", "M -13 0 H 13 M 0 -13 V 13");
  plus.style.stroke = "var(--sage-deep)";
  plus.setAttribute("stroke-width", "5");
  plus.setAttribute("stroke-linecap", "round");
  svg.append(plus);
  return svg;
}
