// Scheda Video: in partenza le cose di base («Strumenti veloci»); il pulsante «Editor» apre il montaggio
// completo e porta con sé i video già scelti (come su Mac).

import { editorPage } from "./editor.js";
import { mediaPage } from "./media.js";
import { h, store } from "./util.js";

export function videoTab(app) {
  const el = h("div.page");
  let mode = store.get("videoMode", "tools");
  const tools = mediaPage("video", app, { onEditor: (paths) => switchTo("editor", paths) });
  const editor = editorPage(app, () => switchTo("tools"));

  function switchTo(m, paths) {
    mode = m;
    store.set("videoMode", m);
    if (m !== "editor") editor.leave();
    el.replaceChildren((m === "editor" ? editor : tools).el);
    if (m === "editor" && paths?.length) editor.openWith(paths);
  }
  document.addEventListener("keydown", (e) => {
    if (!el.isConnected || !(e.ctrlKey && e.shiftKey) || (e.key !== "E" && e.key !== "e")) return;
    e.preventDefault();
    switchTo(mode === "editor" ? "tools" : "editor");
  });
  switchTo(mode);
  return {
    el,
    kind: "video",
    add(paths) {
      return mode === "editor" ? editor.add(paths) : tools.add(paths);
    },
    show() {},
  };
}
