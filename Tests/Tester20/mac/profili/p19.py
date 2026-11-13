#!/usr/bin/env python3
# P19 · Rete assente per l'app: i siti dell'app (GitHub, modelli) bloccati con /etc/hosts. Avvio, controllo aggiornamenti,
# modello di IA scaricato la prima volta («Nascondi un logo» con l'IA), yt-dlp. Il runner continua a parlare con GitHub Actions.
import os, sys, time, shutil, subprocess
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from t20 import *

es = Esito("P19")
F = os.path.join(OUT, "fix"); os.makedirs(F, exist_ok=True)
crash0 = crash_elenco()
HOSTS = ["github.com", "api.github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
         "raw.githubusercontent.com", "lr-apps609.github.io"]
BAK = os.path.join(OUT, "hosts.bak")


def blocca():
    shutil.copy("/etc/hosts", BAK)
    righe = "".join("0.0.0.0 %s\n::0 %s\n" % (h, h) for h in HOSTS)
    sh("sudo sh -c 'cat >> /etc/hosts' <<'EOF'\n# t20-P19\n%sEOF" % righe)
    sh("sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder")
    time.sleep(2)
    rc, o = sh(["curl", "-sS", "-m", "10", "-o", "/dev/null", "-w", "%{http_code}", "https://api.github.com/"], timeout=20)
    return rc != 0, o


def sblocca():
    if os.path.exists(BAK):
        sh("sudo cp '%s' /etc/hosts; sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder" % BAK)


def prove():
    ok, o = blocca()
    es.nota("blocco", {"curl_api_github": o.strip()[-200:], "bloccato": ok})
    if not ok:
        es.skip("rete bloccata", "il blocco con /etc/hosts non funziona: %s" % o[-200:]); return
    es.ok("siti dell'app bloccati (curl a api.github.com non riesce)")
    # 1. avvio con il controllo automatico degli aggiornamenti acceso
    utente_esperto([("updateAutoCheck", "-bool", "true")])
    defaults("delete", BID, "updateTimes")
    t = apri_app(attesa=60)
    es.check("avvio senza rete", t is not None, "Senza rete l'app non apre la finestra", "bloccante", "finestra entro 60 s", "nessuna finestra", "foto")
    time.sleep(12)
    q = [campiona(1)[0] for _ in range(3)]
    foto("senza-rete-avvio")
    es.check("avvio senza rete: finestra reattiva", not all(x is not None and x < 0.25 for x in q), "Senza rete la finestra resta bloccata all'avvio",
             "alto", "thread principale a riposo", q, "sample-*.txt")
    # 2. «Controlla aggiornamenti…» dal menu
    ok, o = menu("Controlla aggiornamenti…", "OrbitLR")
    if not ok:
        es.skip("Controlla aggiornamenti senza rete", "menu non cliccabile: %s" % o[:200])
    else:
        time.sleep(15)
        foto("senza-rete-aggiornamenti", finestra=False)
        tx = testi_ax()
        open(os.path.join(OUT, "testi-aggiornamenti.txt"), "w").write(tx)
        q = [campiona(1)[0] for _ in range(2)]
        if any(k in tx.lower() for k in ["internet", "connessione", "collegar", "rete", "raggiung", "non ha risposto", "riprova"]):
            es.ok("Controlla aggiornamenti senza rete: messaggio chiaro", tx[:300])
        elif not tx.strip() or "error" in tx.lower()[:40]:
            es.skip("messaggio di Controlla aggiornamenti", "testi non leggibili; vedi foto senza-rete-aggiornamenti.png")
        else:
            es.confuso("Controlla aggiornamenti senza rete", "nei testi visibili non trovo un messaggio sulla rete: %s (vedi foto)" % tx[:300])
        es.check("Controlla aggiornamenti senza rete: niente blocco", not all(x is not None and x < 0.25 for x in q),
                 "Controlla aggiornamenti senza rete blocca la finestra", "alto", "a riposo", q, "sample")
        clicca("OK"); clicca("Va bene"); clicca("Chiudi")
    chiudi_app()
    # 3. prima volta con l'IA: il modello non si può scaricare
    src = F + "/logo.jpg"; crea_foto(src, 1200, 900)
    modelli = os.path.join(SUP, "Models")
    cart = F + "/ia"
    shutil.rmtree(modelli, ignore_errors=True)
    t0 = time.time()
    res = lavoro_app(es, "ia senza rete", [(regola(cart, "img", "hidemark", "ai|0.8|0.70,0.80,0.25,0.15"), [src])], attesa=120)
    time.sleep(5)
    foto("senza-rete-ia")
    st = [h for h in cronologia() if "hidemark" in str(h.get("actionId"))]
    log = open(LOG, errors="replace").read()[-4000:] if os.path.exists(LOG) else ""
    es.nota("ia_senza_rete", {"creati": res.get(cart), "cronologia": st[:2], "log": log[-800:]})
    q = [campiona(1)[0] for _ in range(2)]
    es.check("modello di IA senza rete: finestra reattiva", pid_app() and not all(x is not None and x < 0.25 for x in q),
             "Senza rete il download del modello di IA blocca o chiude l'app", "alto", "app aperta e a riposo", "pid=%s campioni=%s" % (pid_app(), q), "foto senza-rete-ia.png")
    tx = testi_ax()
    open(os.path.join(OUT, "testi-ia.txt"), "w").write(tx)
    if res.get(cart):
        es.confuso("IA senza rete", "un file è stato creato senza rete: %s (modello già incluso?)" % res.get(cart))
    else:
        es.ok("IA senza rete: nessun file finto creato")
    chiudi_app()
    # 4. il motore del Downloader (yt-dlp) non si può scaricare: l'app chiede a GitHub, come curl
    rc, o = sh(["curl", "-sS", "-m", "15", "-L", "-o", os.path.join(OUT, "yt"), "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"], timeout=30)
    es.nota("yt-dlp_senza_rete", o[-200:])
    es.skip("Downloader senza rete dentro l'app", "il Downloader va guidato dalla finestra (incolla il link): senza Automazione non lo provo; il download di yt-dlp fallisce come atteso (%s)" % o.strip()[-100:])


try:
    guarded(es, "senza rete", prove)
finally:
    sblocca()
nuovi = crash_nuovi(crash0)
es.check("nessun crash", not nuovi, "OrbitLR si chiude da sola senza rete", "bloccante", "nessun rapporto di crash", nuovi, "log/")
raccogli()
es.fine()
