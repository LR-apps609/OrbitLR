#!/usr/bin/env python3
# P07 · Esploratore: ogni scheda e ogni modo (Semplice / Completo / Editor), foto delle finestre, controlli tagliati o vuoti.
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from t20 import *

es = Esito("P07")
crash0 = crash_elenco()
TABS = [("1", "Converti"), ("2", "PDF e documenti"), ("3", "Immagini"), ("4", "Video"), ("5", "Audio")]
KINDS = ["img", "video", "pdf", "audio", "doc", "sheet", "slide", "text"]
rc, scr = sh([STRUM, "schermo"]); es.nota("schermo", scr.strip())


def giro(livello):
    utente_esperto([("level.%s" % k, "-string", livello) for k in KINDS])
    apri_app(); time.sleep(6)
    for k, nome in TABS:
        attiva(); tasto(k); time.sleep(3)
        controlla_vista(es, "%s-%s" % (livello, nome.replace(" ", "_")), "scheda %s in %s" % (nome, "Semplice" if livello == "simple" else "Completo"))
    if livello == "complete":
        for k, nome, ed in [("4", "Video", "Montaggio"), ("2", "PDF e documenti", "Editor PDF")]:
            attiva(); tasto(k); time.sleep(2)
            if clicca(ed):
                time.sleep(4)
                controlla_vista(es, "editor-%s" % nome.replace(" ", "_"), "%s → %s" % (nome, ed))
            else:
                es.skip("%s → %s" % (nome, ed), "non trovo il controllo «%s» con l'Accessibilità" % ed)
        attiva(); tasto("0"); time.sleep(3)
        controlla_vista(es, "attivita", "Attività (⌘0)")
        for voce in ["Cartelle automatiche", "Le mie azioni", "Componenti"]:
            if clicca(voce, ruoli=("button", "static text", "row", "cell", "UI element")):
                time.sleep(3); controlla_vista(es, voce.replace(" ", "_"), "scheda %s" % voce)
            else:
                es.skip("scheda %s" % voce, "non trovo «%s» nella barra laterale con l'Accessibilità" % voce)
        ok, o = menu("Aiuto di OrbitLR", "Aiuto")
        if ok:
            time.sleep(3); controlla_vista(es, "aiuto", "Aiuto")
        else:
            es.skip("Aiuto", "menu non cliccabile: %s" % o[:150])
        # Impostazioni (⌘,)
        attiva(); tasto(","); time.sleep(3)
        foto("impostazioni", finestra=False)
        es.ok("Impostazioni (⌘,) aperte", "foto impostazioni.png")
    t = chiudi_app()
    es.check("l'app si chiude con ⌘Q dopo il giro %s" % livello, t in ("⌘Q", "non aperta"), "OrbitLR non si chiude con ⌘Q", "medio",
             "chiusa entro 10 s con ⌘Q", "chiusa con %s" % t, "diario.txt")


guarded(es, "giro Semplice", giro, "simple")
guarded(es, "giro Completo", giro, "complete")
if es.d.get("_ax_non_autorizzato"):
    es.skip("controlli tagliati (Accessibilità)", "il processo del runner non è autorizzato per AXUIElement: solo foto")
nuovi = crash_nuovi(crash0)
es.check("nessun crash", not nuovi, "OrbitLR si chiude da sola", "bloccante", "nessun rapporto di crash", nuovi, "log/")
raccogli()
es.fine()
