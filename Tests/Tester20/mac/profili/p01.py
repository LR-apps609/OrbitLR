#!/usr/bin/env python3
# P01 · Prima volta, ha fretta: primo avvio pulito, benvenuto, 3 foto HEIC → JPG (motore e «Apri con»), tempo al primo risultato.
import os, sys, time, shutil
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from t20 import *

es = Esito("P01")
F = os.path.join(OUT, "fix"); os.makedirs(F, exist_ok=True)
crash0 = crash_elenco()


def primo_avvio():
    sh(["pkill", "-9", "-x", "OrbitLR"])
    defaults("delete", BID)
    shutil.rmtree(SUP, ignore_errors=True)
    t = time.time()
    sh(["open", APP], timeout=60)
    w = aspetta(lambda: [x for x in finestre(True) if x["l"] > 200 and x["a"] > 150], 45)
    dt = time.time() - t
    es.nota("secondi_alla_prima_finestra", round(dt, 1))
    if not w:
        es.bug("primo avvio", "Al primo avvio non compare nessuna finestra", "bloccante", "una finestra entro 45 s",
               "nessuna finestra di OrbitLR; processo: %s" % pid_app(), "finestre.txt, diario")
        return
    time.sleep(6)
    p = foto("01-primo-avvio-15s", finestra=False)
    testi = testi_ax()
    with open(os.path.join(OUT, "testi-primo-avvio.txt"), "w") as f:
        f.write(testi)
    benvenuto = any(k in testi for k in ["Benvenut", "Welcome", "Inizia", "Cominciamo"])
    if benvenuto:
        es.ok("benvenuto mostrato al primo avvio", testi[:300])
    elif "non è aperta" in testi or not testi.strip() or "error" in testi.lower():
        es.skip("benvenuto mostrato al primo avvio", "testi delle finestre non leggibili con Accessibilità: %s (vedi foto %s)" % (testi[:200], p))
    else:
        es.confuso("benvenuto al primo avvio", "nei testi visibili non trovo parole di benvenuto; vedi foto 01-primo-avvio-15s.png. Testi: %s" % testi[:400])
    v = sh(["defaults", "read", BID, "welcomeDone"])[1].strip()
    es.nota("welcomeDone_dopo_primo_avvio", v)
    es.check("motore copiato in Application Support al primo avvio", os.path.exists(SUP + "/LRConverter.zsh"),
             "Al primo avvio il motore non viene copiato in Application Support", "medio",
             "~/Library/Application Support/LRConverter/LRConverter.zsh presente (Paths.installScript)",
             "assente: %s" % os.listdir(SUP) if os.path.isdir(SUP) else "cartella assente", "ls Application Support")


def foto3():
    files = []
    for i, nome in enumerate(["IMG_0001.heic", "IMG_0002.heic", "Vacanze a Capri 3.heic"]):
        p = os.path.join(F, nome)
        crea_foto(p, 3024, 4032 if i != 1 else 3024, gps=True)
        files.append(p)
    ok = all(os.path.getsize(f) > 10000 for f in files)
    if not ok:
        es.skip("3 foto HEIC → JPG", "non sono riuscito a creare le HEIC di prova"); return files
    r = motore("to:jpg", "", files, timeout=300, nome="heic3-jpg")
    es.nota("secondi_heic_jpg_motore", r["secs"])
    esito_motore(es, "3 foto HEIC → JPG con il motore", r, "3 JPG validi, stessa misura", ctrl_img(tipo="jpeg", minw=3000))
    if r["outs"] and len(r["outs"]) != 3:
        es.bug("3 foto HEIC → JPG: quanti file", "Da 3 HEIC escono %d JPG" % len(r["outs"]), "alto", "3 file", r["outs"], prova_motore(r))
    return files


def apri_con(files):
    utente = SUP + "/LRConverter.zsh"
    t = time.time()
    rc, o = sh(["open", "-a", APP] + files, timeout=60)
    w = aspetta(finestra_principale, 30)
    dt = time.time() - t
    time.sleep(4)
    p = foto("02-apri-con-3-heic")
    testi = testi_ax()
    with open(os.path.join(OUT, "testi-apri-con.txt"), "w") as f:
        f.write(testi)
    if not w:
        es.bug("«Apri con» OrbitLR su 3 HEIC", "Con «Apri con» la finestra non compare", "alto", "finestra con i 3 file",
               "nessuna finestra in 30 s (open rc=%s %s)" % (rc, o[:200]), "foto 02-apri-con-3-heic.png")
        return
    es.ok("«Apri con» OrbitLR su 3 HEIC: finestra in %.1fs" % dt)
    nomi = sum(1 for n in ["IMG_0001", "IMG_0002", "Capri"] if n in testi)
    if nomi:
        es.ok("i file aperti si vedono nella finestra", "%d nomi su 3 nei testi" % nomi)
    # Prova il clic su «JPG» come farebbe chi ha fretta
    dest = os.path.join(F, "Convertiti")
    if clicca("JPG") or clicca("JPEG"):
        fatti = aspetta(lambda: file_in(F, ".jpg") + file_in(dest, ".jpg"), 90, 2)
        dt2 = time.time() - t
        es.nota("secondi_al_primo_risultato_app", round(dt2, 1))
        foto("03-dopo-clic-jpg")
        es.check("clic su JPG nell'app: 3 JPG creati", fatti and len(fatti) >= 3, "Clic su «JPG» con 3 HEIC aperti: i JPG non arrivano",
                 "alto", "3 JPG accanto agli originali o in Convertiti entro 90 s", "trovati: %s" % fatti, "foto 03-dopo-clic-jpg.png, log app")
    else:
        es.skip("clic su JPG nell'app", "non trovo un pulsante «JPG» con l'Accessibilità (vedi testi-apri-con.txt e foto 02)")


guarded(es, "primo avvio", primo_avvio)
files = guarded(es, "HEIC→JPG motore", foto3) or []
if files:
    chiudi_app(cortese=False)
    utente_esperto()
    guarded(es, "apri con", apri_con, files)
nuovi = crash_nuovi(crash0)
es.check("nessun crash", not nuovi, "OrbitLR si chiude da sola (rapporto di crash)", "bloccante", "nessun rapporto di crash", nuovi, "log/")
chiudi_app()
raccogli()
es.fine()
