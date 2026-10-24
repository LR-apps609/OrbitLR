// «Nascondi un logo»: si disegnano una o più zone sull'immagine (in proporzione, 0…1).

import { invoke } from "./api.js";
import { h, ico } from "./util.js";

export function createZones({ path, onChange }) {
  const zones = [];
  const img = h("img", { alt: "", draggable: "false" });
  const layer = h("div.zlayer");
  const box = h("div.zbox", img, layer);
  const el = h("div.zones", h("p.hint", "Trascina sopra il logo o la scritta per disegnare una zona. Puoi disegnarne più di una; × la toglie."), box);
  invoke("thumbnail", { path, side: 960 }).then((t) => { if (t) img.src = t; });

  function draw() {
    layer.replaceChildren(...zones.map((z, i) => h("div.zone", { style: { left: z.x * 100 + "%", top: z.y * 100 + "%", width: z.w * 100 + "%", height: z.h * 100 + "%" } },
      h("button.zx", { "aria-label": "Togli la zona", onpointerdown: (e) => e.stopPropagation(), onclick: () => { zones.splice(i, 1); draw(); } }, ico("x", 12)))));
    onChange?.(zones);
  }

  layer.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    const r = layer.getBoundingClientRect();
    const x0 = (e.clientX - r.left) / r.width, y0 = (e.clientY - r.top) / r.height;
    const z = { x: x0, y: y0, w: 0, h: 0 };
    zones.push(z);
    layer.setPointerCapture(e.pointerId);
    layer.onpointermove = (ev) => {
      const x1 = Math.min(1, Math.max(0, (ev.clientX - r.left) / r.width)), y1 = Math.min(1, Math.max(0, (ev.clientY - r.top) / r.height));
      z.x = Math.min(x0, x1);
      z.y = Math.min(y0, y1);
      z.w = Math.abs(x1 - x0);
      z.h = Math.abs(y1 - y0);
      draw();
    };
    layer.onpointerup = () => {
      layer.onpointermove = null;
      if (z.w < 0.01 || z.h < 0.01) zones.splice(zones.indexOf(z), 1);
      draw();
    };
  });

  return { el, get zones() { return zones.map((z) => ({ x: +z.x.toFixed(4), y: +z.y.toFixed(4), w: +z.w.toFixed(4), h: +z.h.toFixed(4) })); }, destroy() {} };
}
