#!/usr/bin/env python3
# P03 · Torna e aggiorna: 6.0.2 con dati dell'utente → aggiornamento a 6.0.3 con il percorso dell'app (doppio clic sul .orbitlr).
import os, sys, time, shutil, json, uuid, filecmp, glob
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from t20 import *

es = Esito("P03")
REL = os.environ.get("T20_REL", os.path.join(os.environ.get("RUNNER_TEMP", "/tmp"), "rel"))
DOC = os.path.join(HOME, "Documents", "T20")
os.makedirs(DOC, exist_ok=True)
crash0 = crash_elenco()


def installa(v):
    chiudi_app(cortese=False)
    x = os.path.join(OUT, "..", "x-" + v)
    shutil.rmtree(x, ignore_errors=True); os.makedirs(x)
    sh(["ditto", "-x", "-k", os.path.join(REL, "OrbitLR.%s.orbitlr" % v), x], timeout=300)
    a = [p for p in glob.glob(x + "/**/OrbitLR.app", recursive=True) if "Prebuilt" in p]
    if not a:
        return None
    shutil.rmtree(APP, ignore_errors=True)
    sh(["ditto", a[0], APP], timeout=300)
    sh(["xattr", "-dr", "com.apple.quarantine", APP])
    sh(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", APP])
    return versione()


def dati_utente():
    # file «creati» prima, che il Cassetto deve ritrovare
    outs = []
    for i in range(3):
        p = os.path.join(DOC, "risultato %d.jpg" % (i + 1))
        crea_foto(p, 800, 600); outs.append(p)
    hist = [{"id": str(uuid.uuid4()).upper(), "date": "2026-11-0%dT10:00:00Z" % (i + 1), "title": "Converti in JPG",
             "action": "In JPG", "outputs": [o], "undone": False, "kind": "img", "before": 2000000, "after": 900000,
             "actionId": "to:jpg", "param": "", "inputs": [o.replace(".jpg", ".heic")]} for i, o in enumerate(outs)]
    presets = [{"id": str(uuid.uuid4()).upper(), "name": "Instagram 1080", "kind": "img", "actionId": "resize", "param": "1920"},
               {"id": str(uuid.uuid4()).upper(), "name": "Email video", "kind": "video", "actionId": "vcompress", "param": "18", "hotkey": 2}]
    rules = [regola(os.path.join(DOC, "Sorvegliata"), "img", "to:jpg", "", exts=["heic"])]
    os.makedirs(rules[0]["folder"], exist_ok=True)
    os.makedirs(SUP, exist_ok=True)
    json.dump(hist, open(SUP + "/history.json", "w"))
    json.dump(presets, open(SUP + "/presets.json", "w"))
    json.dump(rules, open(SUP + "/watch.json", "w"))
    for k, t, v in [("lastTab", "-string", "Video"), ("level.img", "-string", "complete"), ("original", "-string", "keep"),
                    ("keepDates", "-bool", "true"), ("appearance", "-string", "dark")]:
        defaults("write", BID, k, t, v)
    return hist, presets, rules


def stato():
    d = {}
    for n in ["history.json", "presets.json", "watch.json"]:
        try:
            d[n] = json.load(open(SUP + "/" + n))
        except Exception as e:
            d[n] = "ERRORE: %s" % e
    for k in ["lastTab", "level.img", "original", "keepDates", "appearance", "welcomeDone"]:
        d[k] = sh(["defaults", "read", BID, k])[1].strip()
    return d


def aggiorna():
    v = installa("6.0.2")
    if v != "6.0.2":
        es.skip("aggiornamento 6.0.2 → 6.0.3", "6.0.2 non installata (%s)" % v); return
    es.ok("6.0.2 installata dal pacchetto pubblicato")
    utente_esperto([("lastLaunchVersion", "-string", "6.0.2")])
    apri_app(); time.sleep(5); chiudi_app(cortese=False)
    hist, presets, rules = dati_utente()
    # 6.0.2 legge i dati (e li riscrive come li tiene lei)
    t = apri_app(); time.sleep(8)
    foto("01-602-con-dati")
    chiudi_app()
    prima = stato()
    json.dump(prima, open(os.path.join(OUT, "stato-prima.json"), "w"), ensure_ascii=False, indent=1)
    hid = {h["id"] for h in hist}
    if isinstance(prima["history.json"], list) and not hid <= {h.get("id") for h in prima["history.json"]}:
        es.confuso("dati creati per la prova", "6.0.2 non ha tenuto le voci di cronologia scritte dal banco: la prova dei dati dopo l'aggiornamento è meno forte")
    # aggiornamento come un utente: 6.0.2 aperta, doppio clic sul file scaricato (quarantena del browser)
    apri_app(); time.sleep(6)
    dl = os.path.join(HOME, "Downloads"); os.makedirs(dl, exist_ok=True)
    f = os.path.join(dl, "OrbitLR.6.0.3.orbitlr")
    shutil.copy(os.path.join(REL, "OrbitLR.6.0.3.orbitlr"), f)
    sh(["xattr", "-w", "com.apple.quarantine", "0083;%x;Safari;%s" % (int(time.time()), str(uuid.uuid4()).upper()), f])
    t0 = time.time()
    sh(["open", f], timeout=60)
    domanda = aspetta(lambda: ("Installa" in (x := testi_ax())) and x, 90, 3)
    foto("02-domanda-aggiornamento", finestra=False)
    if not domanda:
        tx = testi_ax()
        es.bug("doppio clic sul .orbitlr 6.0.3 con 6.0.2 aperta", "Doppio clic sull'aggiornamento: la domanda «Installare…» non compare",
               "alto", "la domanda con «Installa» entro 90 s", "testi visibili: %s" % tx[:600], "foto 02-domanda-aggiornamento.png, testi")
        return
    es.ok("domanda di installazione mostrata", domanda[:200])
    clicca("Installa")
    ok = aspetta(lambda: versione() == "6.0.3" and pid_app(), 240, 3)
    dt = time.time() - t0
    time.sleep(10)
    foto("03-dopo-aggiornamento", finestra=False)
    tx = testi_ax()
    open(os.path.join(OUT, "testi-dopo.txt"), "w").write(tx)
    if not ok:
        es.bug("aggiornamento 6.0.2 → 6.0.3", "L'aggiornamento a 6.0.3 non si completa", "bloccante",
               "app 6.0.3 installata e riaperta entro 4 minuti", "versione ora: %s, aperta: %s, testi: %s" % (versione(), pid_app(), tx[:500]),
               "foto 03-dopo-aggiornamento.png, log/OrbitLR-aggiornamento.log")
        return
    es.ok("aggiornata a 6.0.3 e riaperta in %.0fs" % dt)
    chiudi_app()
    dopo = stato()
    json.dump(dopo, open(os.path.join(OUT, "stato-dopo.json"), "w"), ensure_ascii=False, indent=1)
    for n in ["history.json", "presets.json", "watch.json"]:
        a, b = prima[n], dopo[n]
        ids_a = {x.get("id") for x in a} if isinstance(a, list) else set()
        ids_b = {x.get("id") for x in b} if isinstance(b, list) else set()
        es.check("dopo l'aggiornamento: %s conservato" % n, ids_a <= ids_b and isinstance(b, list),
                 "Dopo l'aggiornamento si perdono dati (%s)" % n, "alto", "tutte le voci di prima ci sono ancora",
                 "prima %d voci, dopo %s; mancano %s" % (len(ids_a), len(ids_b) if isinstance(b, list) else b, list(ids_a - ids_b)[:5]),
                 "stato-prima.json / stato-dopo.json")
    for k in ["lastTab", "level.img", "original", "keepDates", "appearance"]:
        es.check("preferenza %s conservata" % k, prima[k] == dopo[k], "Dopo l'aggiornamento la preferenza «%s» cambia" % k, "medio",
                 "uguale a prima (%s)" % prima[k], dopo[k], "stato-*.json")
    bun = RES + "/LRConverter.zsh"
    apri_app(); time.sleep(6)
    es.check("motore in Application Support aggiornato", os.path.exists(SUP + "/LRConverter.zsh") and filecmp.cmp(bun, SUP + "/LRConverter.zsh", shallow=False),
             "Dopo l'aggiornamento resta il motore vecchio in Application Support", "alto", "LRConverter.zsh uguale a quello di 6.0.3",
             "diverso o assente", "confronto file")
    foto("04-603-riaperta")
    rapporti = [p for p in glob.glob(SUP + "/*problema*") + glob.glob(HOME + "/Desktop/*") if os.path.isfile(p)]
    if rapporti:
        es.confuso("rapporti dopo l'aggiornamento", "trovati %s (copiati in log/)" % rapporti)


guarded(es, "aggiornamento", aggiorna)
nuovi = crash_nuovi(crash0)
es.check("nessun crash", not nuovi, "OrbitLR si chiude da sola durante l'aggiornamento", "bloccante", "nessun rapporto di crash", nuovi, "log/")
chiudi_app()
raccogli()
es.fine()
