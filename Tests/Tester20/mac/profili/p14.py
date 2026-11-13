#!/usr/bin/env python3
# P14 · Schermo piccolo: finestra a 1280×800, 1024×700 e alta 600, foto di ogni scheda, niente di tagliato.
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from t20 import *

es = Esito("P14")
crash0 = crash_elenco()
TABS = [("1", "Converti"), ("2", "PDF e documenti"), ("3", "Immagini"), ("4", "Video"), ("5", "Audio"), ("0", "Attivita")]
rc, scr = sh([STRUM, "schermo"]); es.nota("schermo", scr.strip())
try:
    SW, SH = [int(x) for x in scr.split()[:2]]
except Exception:
    SW, SH = 1920, 1080


def misura(l, a):
    rc, o = sh(["osascript", "-e", 'tell application "System Events" to tell process "OrbitLR"',
                "-e", "set position of window 1 to {0, 30}", "-e", "set size of window 1 to {%d, %d}" % (l, a),
                "-e", "get size of window 1", "-e", "end tell"], timeout=30)
    time.sleep(2)
    w = finestra_principale()
    return rc, o.strip(), w


def giro(l, a, livello):
    nome = "%dx%d-%s" % (l, a, livello)
    if l > SW or a > SH - 30:
        es.skip("finestra %s" % nome, "lo schermo del runner è %dx%d" % (SW, SH)); return
    utente_esperto([("level.%s" % k, "-string", livello) for k in ["img", "video", "pdf", "audio", "doc"]])
    apri_app(); time.sleep(5)
    rc, o, w = misura(l, a)
    if rc != 0 or not w:
        es.skip("finestra %s" % nome, "non riesco a cambiare la misura con System Events: %s" % o[:200]); chiudi_app(); return
    es.nota("misura-" + nome, "chiesta %dx%d, avuta %dx%d" % (l, a, w["l"], w["a"]))
    if w["l"] > l + 2 or w["a"] > a + 2:
        es.confuso("finestra %s" % nome, "la finestra non scende sotto %dx%d (misura minima dell'app): su uno schermo da %dx%d non entrerebbe" % (w["l"], w["a"], l, a))
    for k, tab in TABS:
        attiva(); tasto(k); time.sleep(2.5)
        controlla_vista(es, "%s-%s" % (nome, tab.replace(" ", "_")), "%s a %s" % (tab, nome))
    chiudi_app()


for (l, a) in [(1280, 800), (1024, 700), (1024, 600)]:
    guarded(es, "%dx%d" % (l, a), giro, l, a, "simple")
guarded(es, "1024x600 Completo", giro, 1024, 600, "complete")
if es.d.get("_ax_non_autorizzato"):
    es.skip("controlli tagliati (Accessibilità)", "il processo del runner non è autorizzato per AXUIElement: solo foto")
nuovi = crash_nuovi(crash0)
es.check("nessun crash", not nuovi, "OrbitLR si chiude da sola", "bloccante", "nessun rapporto di crash", nuovi, "log/")
raccogli()
es.fine()
