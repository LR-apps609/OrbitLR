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
    if (m !== "editor") tools.refresh?.();
    el.replaceChildren((m === "editor" ? editor : tools).el);
    if (m === "editor" && paths?.length) editor.openWith(paths);
    // 1.1 · Tornando nel Montaggio si riapre il progetto lasciato aperto (con indicatore, zoom e strumento)
    else if (m === "editor") editor.restore(false);
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
    /** 1.1 · Dopo una chiusura improvvisa: di nuovo nel progetto aperto, con l'avviso. */
    restore(crashed) {
      if (mode !== "editor") switchTo("editor");
      editor.restore(crashed);
    },
  };
}
