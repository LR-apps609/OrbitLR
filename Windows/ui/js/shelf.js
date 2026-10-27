// La linguetta sul bordo dello schermo (vedi shelf.html).
  // Stessa origine della finestra principale: legge le stesse impostazioni (lingua, linguetta accesa)
  const T = window.__TAURI__;
  const get = (k, d) => { try { const v = localStorage.getItem("orbitlr." + k); return v == null ? d : JSON.parse(v); } catch { return d; } };
  const lang = get("appLang", "auto");
  const en = lang === "en" || (lang === "auto" && !/^it/i.test(navigator.language || ""));
  if (en) {
    document.getElementById("t1").textContent = "Drop files here";
    document.getElementById("t2").textContent = "they open in OrbitLR";
    document.getElementById("tab").title = "OrbitLR · drop files here";
  }
  if (T) {
    if (get("shelf", true) !== false) T.core.invoke("shelf_show", { on: true });
    let open = false;
    const setOpen = (v) => { if (v === open) return; open = v; document.body.classList.toggle("open", v); T.core.invoke("shelf_expand", { open: v }); };
    T.webview.getCurrentWebview().onDragDropEvent((ev) => {
      const p = ev.payload;
      if (p.type === "enter" || p.type === "over") { setOpen(true); document.body.classList.add("over"); }
      else if (p.type === "leave") { document.body.classList.remove("over"); setTimeout(() => setOpen(false), 250); }
      else if (p.type === "drop") { document.body.classList.remove("over"); open = false; document.body.classList.remove("open"); T.core.invoke("shelf_drop", { paths: p.paths || [] }); }
    });
    document.getElementById("tab").addEventListener("click", () => T.core.invoke("shelf_drop", { paths: [] }));
    // Spenta o riaccesa dalle Opzioni della finestra principale
    window.addEventListener("storage", (e) => { if (e.key === "orbitlr.shelf") T.core.invoke("shelf_show", { on: get("shelf", true) !== false }); });
  }
