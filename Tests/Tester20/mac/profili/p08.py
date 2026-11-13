#!/usr/bin/env python3
# P08 · Fotografo: 300 HEIC aperte insieme (thread principale campionato, uscita), GPS tolto, «originale nel Cestino».
import os, sys, time, shutil, glob
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from t20 import *

es = Esito("P08")
F = os.path.join(OUT, "fix"); os.makedirs(F, exist_ok=True)
crash0 = crash_elenco()
utente_esperto()


def trecento():
    base = os.path.join(F, "base.heic"); crea_foto(base, 1600, 1200, gps=True)
    d = os.path.join(F, "trecento"); os.makedirs(d, exist_ok=True)
    for i in range(300):
        shutil.copy(base, os.path.join(d, "foto%03d.heic" % i))
    apri_app(); time.sleep(5)
    t = time.time()
    sh(["open", "-a", APP] + sorted(glob.glob(d + "/*.heic")), timeout=120)
    campioni = []
    for i in range(10):
        q, f = campiona(1)
        campioni.append((round(time.time() - t, 1), q))
        time.sleep(1)
    es.nota("riposo_thread_principale_300_heic", campioni)
    foto("300-heic")
    occupati = [c for c in campioni if c[1] is not None and c[1] < 0.25]
    tard = [c for c in campioni if c[0] > 15 and c[1] is not None and c[1] < 0.25]
    if tard:
        es.bug("300 HEIC aperte insieme", "Con 300 foto aperte insieme la finestra resta bloccata", "alto",
               "thread principale di nuovo a riposo entro ~15 s", "campioni (secondi, quota a riposo): %s" % campioni,
               "sample-*.txt nella cartella del profilo, foto 300-heic.png")
    else:
        es.ok("300 HEIC aperte insieme: la finestra risponde", campioni)
    t0 = time.time()
    come = chiudi_app(cortese=True)
    es.check("uscita con ⌘Q dopo 300 foto", come == "⌘Q", "Dopo 300 foto aperte OrbitLR non si chiude con ⌘Q", "medio",
             "chiusa con ⌘Q entro 10 s", "chiusa con %s dopo %.0f s" % (come, time.time() - t0), "diario.txt")


def gps():
    src = os.path.join(F, "gps.heic"); crea_foto(src, 2000, 1500, gps=True)
    jsrc = os.path.join(F, "gps.jpg"); crea_foto(jsrc, 2000, 1500, gps=True)
    if not meta(src).get("gps"):
        es.skip("GPS tolto", "la foto di prova non ha il GPS"); return
    for f in [src, jsrc]:
        r = motore("strip", "", [f], nome="strip-" + os.path.basename(f))
        esito_motore(es, "motore: togli i metadati da %s" % os.path.basename(f), r, "copia senza GPS né modello", ctrl_img(gps=False),
                     titolo="«Rimuovi i metadati» lascia la posizione GPS (%s)" % os.path.basename(f))
    # Nell'app (motore nativo) con una cartella automatica
    cart = os.path.join(F, "strip-app")
    res = lavoro_app(es, "strip app", [(regola(cart, "img", "strip", ""), [src, jsrc])], attesa=90)
    out = res.get(cart, [])
    if not out:
        es.bug("app: togli i metadati (cartella automatica)", "«Rimuovi i metadati» nell'app non crea file", "alto", "2 copie senza GPS", "nessun file", "log/")
    for o in out:
        m = meta(o)
        es.check("app: %s senza GPS" % os.path.basename(o), not m.get("gps") and not m.get("modello"),
                 "«Rimuovi i metadati» nell'app lascia GPS o modello (%s)" % os.path.basename(o), "alto", "niente GPS, niente modello",
                 "gps=%s modello=%s" % (m.get("gps"), m.get("modello")), json.dumps(m)[:300] if False else str(m)[:300])
    chiudi_app()


def cestino():
    defaults("write", BID, "original", "-string", "trash")
    srcs = []
    for i in range(3):
        p = os.path.join(F, "cestino%d.heic" % i); crea_foto(p, 1200, 900); srcs.append(p)
    cart = os.path.join(F, "cestino-cartella")
    trash = os.path.join(HOME, ".Trash")
    prima = set(os.listdir(trash)) if os.path.isdir(trash) else set()
    res = lavoro_app(es, "cestino", [(regola(cart, "img", "to:jpg", ""), srcs)], attesa=90)
    time.sleep(5)
    out = res.get(cart, [])
    rimasti = [os.path.basename(s) for s in srcs if os.path.exists(os.path.join(cart, os.path.basename(s)))]
    nuovi = set(os.listdir(trash)) - prima if os.path.isdir(trash) else set()
    es.nota("cestino", {"creati": [os.path.basename(o) for o in out], "originali_rimasti": rimasti, "nel_cestino": sorted(nuovi)})
    if len(out) < 3:
        es.bug("«originale nel Cestino» con cartella automatica", "La conversione con «sposta l'originale nel Cestino» non crea i JPG", "alto",
               "3 JPG", [os.path.basename(o) for o in out], "log/")
    else:
        es.check("«originale nel Cestino»: originali spostati", not rimasti, "Con «sposta l'originale nel Cestino» gli originali restano",
                 "medio", "3 HEIC nel Cestino (lavoro automatico, sotto il limite di 20)", "rimasti: %s; nel Cestino: %s" % (rimasti, sorted(nuovi)), "diario")
    defaults("write", BID, "original", "-string", "keep")
    chiudi_app()


guarded(es, "300 HEIC", trecento)
guarded(es, "GPS", gps)
guarded(es, "cestino", cestino)
es.skip("RAW/DNG", "sul runner non c'è un modo di creare un vero RAW/DNG (sips/ImageIO non scrivono DNG) e non scarico foto da internet")
nuovi = crash_nuovi(crash0)
es.check("nessun crash", not nuovi, "OrbitLR si chiude da sola", "bloccante", "nessun rapporto di crash", nuovi, "log/")
raccogli()
es.fine()
