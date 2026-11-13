#!/usr/bin/env python3
# P15 · Tastiera e VoiceOver: controlli senza nome (AXUIElement), scorciatoie da tastiera, Tab tra i controlli.
import os, sys, time, json
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from t20 import *

es = Esito("P15")
crash0 = crash_elenco()
rc, fid = sh([STRUM, "fiducia"]); es.nota("processo_autorizzato_ax", fid.strip())
TABS = [("1", "Converti"), ("2", "PDF e documenti"), ("3", "Immagini"), ("4", "Video"), ("5", "Audio"), ("0", "Attivita")]


def audit(livello):
    utente_esperto([("level.%s" % k, "-string", livello) for k in ["img", "video", "pdf", "audio", "doc"]])
    apri_app(); time.sleep(6)
    tot = {}
    for k, tab in TABS:
        attiva(); tasto(k); time.sleep(3)
        nome = "%s-%s" % (livello, tab.replace(" ", "_"))
        foto(nome)
        ctr = ax_controlli(nome)
        if ctr is None:
            es.skip("controlli senza nome (VoiceOver)", "il processo del runner non è autorizzato per AXUIElement (AXIsProcessTrusted = %s): prova non eseguita" % fid.strip())
            chiudi_app(); return False
        w = finestra_principale() or {"x": 0, "y": 0, "l": 99999, "a": 99999}
        vis = [c for c in ctr if c["l"] > 1 and c["a"] > 1 and w["y"] <= c["y"] <= w["y"] + w["a"]]
        senza = [c for c in vis if c["senza_nome"] and c["ruolo"] in ("AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider")]
        tot[tab] = (len(vis), len(senza))
        if senza:
            es.bug("controlli con nome in %s (%s)" % (tab, livello), "%d controlli senza nome per VoiceOver nella scheda %s (%s)" % (len(senza), tab, livello),
                   "medio", "ogni pulsante ha un titolo o una descrizione (AXTitle/AXDescription)",
                   "%d su %d: %s" % (len(senza), len(vis), [(c["ruolo"], c["percorso"][-60:], c["x"] - w["x"], c["y"] - w["y"], c["l"], c["a"]) for c in senza[:10]]),
                   "ax-%s.json, foto/%s.png" % (nome, nome))
        else:
            es.ok("controlli con nome in %s (%s)" % (tab, livello), "%d controlli" % len(vis))
    es.nota("controlli-" + livello, tot)
    chiudi_app()
    return True


def tastiera():
    """Tab dal primo controllo: il fuoco deve muoversi (AXFocusedUIElement cambia)."""
    utente_esperto()
    sh(["defaults", "write", "-g", "AppleKeyboardUIMode", "-int", "2"])   # «Navigazione da tastiera» accesa, come chi usa la tastiera
    apri_app(); time.sleep(5); attiva()
    visti = []
    for i in range(12):
        sh(["osascript", "-e", 'tell application "System Events" to key code 48'], timeout=10); time.sleep(0.6)
        rc, o = sh(["osascript", "-e", 'tell application "System Events" to tell process "OrbitLR" to get {role, description, name} of (value of attribute "AXFocusedUIElement")'], timeout=15)
        visti.append(o.strip()[:120])
    open(os.path.join(OUT, "fuoco-tab.txt"), "w").write("\n".join(visti))
    diversi = len(set(v for v in visti if v and "error" not in v.lower()))
    if all("error" in v.lower() or not v for v in visti):
        es.skip("Tab tra i controlli", "non leggo il controllo con il fuoco: %s" % visti[:2])
    else:
        es.check("Tab sposta il fuoco tra i controlli", diversi >= 3, "Con Tab il fuoco non si sposta tra i controlli", "medio",
                 "almeno 3 controlli diversi in 12 pressioni di Tab", "%d diversi: %s" % (diversi, visti), "fuoco-tab.txt")
    chiudi_app()


if guarded(es, "audit Semplice", audit, "simple"):
    guarded(es, "audit Completo", audit, "complete")
guarded(es, "tastiera", tastiera)
nuovi = crash_nuovi(crash0)
es.check("nessun crash", not nuovi, "OrbitLR si chiude da sola", "bloccante", "nessun rapporto di crash", nuovi, "log/")
raccogli()
es.fine()
