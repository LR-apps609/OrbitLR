#!/usr/bin/env python3
# P05 · Esperto: servizio del Finder, azioni salvate, orbitlr://, scorciatoie dei menu (senza permesso di Automazione).
import os, sys, time, shutil, json, uuid, urllib.parse
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from t20 import *

es = Esito("P05")
F = os.path.join(OUT, "fix"); os.makedirs(F, exist_ok=True)
crash0 = crash_elenco()
utente_esperto()


def scorciatoie():
    apri_app(); time.sleep(5)
    attese = {"1": "Conversione", "2": "File", "3": "Immagini", "4": "Video", "5": "Audio"}
    for k, tab in attese.items():
        attiva(); tasto(k); time.sleep(2.5)
        v = sh(["defaults", "read", BID, "lastTab"])[1].strip()
        foto("scorciatoia-cmd-%s" % k)
        es.check("⌘%s apre la scheda %s" % (k, tab), v == tab, "⌘%s non apre la scheda «%s»" % (k, tab), "medio",
                 "lastTab = %s" % tab, "lastTab = %s" % v, "foto scorciatoia-cmd-%s.png" % k)
    attiva(); tasto("0"); time.sleep(2); foto("scorciatoia-cmd-0-attivita")
    ok, o = menu("Aiuto di OrbitLR", "Aiuto")
    time.sleep(2); foto("menu-aiuto")
    if not ok:
        es.skip("menu Aiuto → Aiuto di OrbitLR", "System Events non clicca il menu: %s" % o[:200])
    else:
        es.ok("menu Aiuto → Aiuto di OrbitLR")
    chiudi_app()


def azione_salvata():
    pid = str(uuid.uuid4()).upper()
    json.dump([{"id": pid, "name": "Web 1280", "kind": "img", "actionId": "resize", "param": "1280"}], open(SUP + "/presets.json", "w"))
    src = os.path.join(F, "grande.jpg"); crea_foto(src, 4000, 3000)
    cart = os.path.join(F, "azione-salvata")
    res = lavoro_app(es, "azione salvata", [(regola(cart, "img", "preset:" + pid, ""), [src])], attesa=90)
    out = res.get(cart, [])
    foto("azione-salvata")
    if not out:
        es.bug("azione salvata «Web 1280» usata da una cartella automatica", "Un'azione salvata usata in una regola non produce niente",
               "alto", "una foto con lato lungo 1280 in Convertiti", "nessun file in 90 s", "log/LRConverter.log, foto azione-salvata.png")
        return
    m = meta(out[0])
    lato = max(m.get("larghezza") or 0, m.get("altezza") or 0)
    es.check("azione salvata: lato lungo 1280", lato == 1280, "L'azione salvata «Web 1280» non dà 1280 px", "medio", "lato lungo 1280",
             "lato lungo %s (%s)" % (lato, os.path.basename(out[0])), json.dumps(m)[:300])
    chiudi_app()


def servizio():
    src = os.path.join(F, "servizio.png"); crea_foto(src, 640, 480)
    apri_app(); time.sleep(4)
    rc, o = sh([STRUM, "servizio", "OrbitLR", src], timeout=60)
    time.sleep(4)
    foto("servizio-finder")
    tx = testi_ax()
    if rc != 0:
        es.skip("servizio del Finder «OrbitLR» (⌥⌘C / menu Servizi)", "NSPerformService non lo trova sul runner: %s (i servizi di un'app appena copiata possono non essere registrati)" % o[:200])
    else:
        es.check("servizio del Finder «OrbitLR» porta il file nella finestra", "servizio" in tx, "Il servizio «OrbitLR» non mostra il file",
                 "medio", "il file «servizio.png» nella finestra", tx[:400], "foto servizio-finder.png")
    chiudi_app()


def link():
    src = os.path.join(F, "dal link.jpg"); crea_foto(src, 640, 480)
    url = "orbitlr://open?f=" + urllib.parse.quote(src)
    apri_app(); time.sleep(3)
    sh(["open", url], timeout=30); time.sleep(4)
    foto("link-orbitlr")
    tx = testi_ax()
    open(os.path.join(OUT, "testi-link.txt"), "w").write(tx)
    if "dal link" in tx:
        es.ok("orbitlr://open?f=… apre il file nella finestra")
    else:
        es.confuso("orbitlr://open?f=…", "non vedo il nome del file nei testi della finestra (Accessibilità); vedi foto link-orbitlr.png")
    # sicurezza: un link non deve spostare file dai dati di altre app
    altra = os.path.join(HOME, "Library/Containers/com.esempio.altra/Data/segreto.jpg")
    os.makedirs(os.path.dirname(altra), exist_ok=True); crea_foto(altra, 100, 100)
    sh(["open", "orbitlr://open?f=" + urllib.parse.quote(altra)], timeout=30); time.sleep(4)
    es.check("orbitlr:// non tocca i file di altre app", os.path.exists(altra), "Un link orbitlr:// sposta file dai dati di un'altra app",
             "alto", "il file resta dov'è", "il file è sparito", altra)
    # link strani: nessun crash
    for u in ["orbitlr://", "orbitlr://open", "orbitlr://open?f=", "orbitlr://open?f=%2Fnon%2Fesiste.jpg", "orbitlr://altro?x=1",
              "orbitlr://open?f=" + urllib.parse.quote("/etc/passwd")]:
        sh(["open", u], timeout=20); time.sleep(1.5)
    time.sleep(2)
    es.check("link orbitlr:// strani: l'app resta aperta", pid_app() is not None, "Un link orbitlr:// strano fa chiudere l'app", "alto",
             "app ancora aperta", "processo assente", "log/, DiagnosticReports")
    foto("link-strani")
    chiudi_app()


guarded(es, "scorciatoie", scorciatoie)
guarded(es, "azione salvata", azione_salvata)
guarded(es, "servizio", servizio)
guarded(es, "link", link)
es.skip("ricette (recipe:)", "una ricetta si crea solo dall'interfaccia (Attività → «Rifai questi passi»): senza Automazione non la guido")
es.skip("⌥⌘C globale e ⌃⌥1…9", "le scorciatoie globali leggono la selezione del Finder con Apple Events: sul runner manca il permesso di Automazione (-1712)")
nuovi = crash_nuovi(crash0)
es.check("nessun crash", not nuovi, "OrbitLR si chiude da sola", "bloccante", "nessun rapporto di crash", nuovi, "log/")
chiudi_app()
raccogli()
es.fine()
