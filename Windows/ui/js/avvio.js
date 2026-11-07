// 2.0.1 · La pagina d'avvio si vede subito, prima che parta l'app (la prima apertura può durare qualche secondo).
// Script normale e piccolo, senza moduli: gira appena arriva. Lo stesso testo in italiano e in inglese.
(function () {
  var el = document.getElementById("avvio-testo");
  if (!el) return;
  var lang = "auto", first = true;
  try {
    lang = JSON.parse(localStorage.getItem("orbitlr.appLang") || '"auto"');
    first = localStorage.getItem("orbitlr.installedAt") == null && localStorage.getItem("orbitlr.welcomed") == null;
  } catch (e) {}
  var en = lang === "en" || (lang !== "it" && !/^it/i.test(navigator.language || ""));
  el.textContent = first
    ? (en ? "Opening OrbitLR for the first time: Windows is getting it ready, it can take a few seconds…" : "Prima apertura di OrbitLR: Windows la sta preparando, può volerci qualche secondo…")
    : (en ? "Opening OrbitLR…" : "Apro OrbitLR…");
})();
