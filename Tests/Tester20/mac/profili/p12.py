#!/usr/bin/env python3
# P12 · Grafico: SVG (vettoriale), pacchetto logo, rimozione dello sfondo, «Nascondi un logo», ingrandisci — con l'app vera.
import os, sys, time, zipfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from t20 import *

es = Esito("P12")
F = os.path.join(OUT, "fix"); os.makedirs(F, exist_ok=True)
crash0 = crash_elenco()
utente_esperto()


def lavori():
    logo = F + "/logo.png"; sh([STRUM, "logo", logo, "800"])
    fotoj = F + "/scatto.jpg"; crea_foto(fotoj, 1600, 1200)
    piccola = F + "/piccola.png"; crea_foto(piccola, 400, 300)
    casi = {
        "svg-auto": (regola(F + "/c-svg", "img", "vector", "auto"), [logo]),
        "svg-logo": (regola(F + "/c-svglogo", "img", "vector", "logot"), [logo]),
        "pacchetto": (regola(F + "/c-pack", "img", "vector", "pack"), [logo]),
        "sfondo": (regola(F + "/c-bg", "img", "removebg", "transparent"), [logo, fotoj]),
        "nascondi": (regola(F + "/c-hide", "img", "hidemark", "blur|0.8|0.70,0.80,0.25,0.15"), [fotoj]),
        "ingrandisci": (regola(F + "/c-up", "img", "upscale", "2"), [piccola]),
    }
    res = lavoro_app(es, "grafica", list(casi.values()), attesa=300, atteso_n=1)
    foto("grafica-fine")
    out = {k: res.get(v[0]["folder"], []) for k, v in casi.items()}
    es.nota("creati", {k: [os.path.basename(x) for x in v] for k, v in out.items()})

    def nessuno(k, cosa, atteso):
        if not out[k]:
            es.bug(cosa, "«%s» non crea niente" % cosa, "alto", atteso, "nessun file in 5 minuti", "log/LRConverter.log, foto grafica-fine.png")
            return True
        return False

    for k in ["svg-auto", "svg-logo"]:
        if not nessuno(k, "Vettoriale (SVG) %s" % k, "un .svg"):
            s = out[k][0]; t = open(s, errors="replace").read()
            es.check("SVG %s valido" % k, s.endswith(".svg") and "<svg" in t and ("<path" in t or "<polygon" in t),
                     "Il file SVG creato non contiene forme", "alto", "<svg> con <path>", t[:300], s)
    if not nessuno("pacchetto", "Pacchetto logo (ZIP)", "uno ZIP con SVG, PDF, EPS, PNG"):
        z = out["pacchetto"][0]
        try:
            nomi = zipfile.ZipFile(z).namelist() if z.endswith(".zip") else os.listdir(z)
            ext = {n.rsplit(".", 1)[-1].lower() for n in nomi if "." in n}
            mancano = [e for e in ["svg", "pdf", "eps", "png"] if e not in ext]
            es.check("pacchetto logo completo", not mancano, "Il pacchetto logo non ha tutti i formati promessi", "medio",
                     "SVG, PDF, EPS e PNG", "mancano %s; contiene %s" % (mancano, nomi[:12]), z)
        except Exception as e:
            es.bug("pacchetto logo", "Il pacchetto logo non è uno ZIP leggibile", "alto", "ZIP valido", repr(e), z)
    if not nessuno("sfondo", "Rimuovi lo sfondo", "PNG trasparenti"):
        for o in out["sfondo"]:
            m = meta(o)
            es.check("sfondo tolto: %s" % os.path.basename(o), m.get("alfa") and all(a <= 10 for a in m.get("alfa_angoli", [255])),
                     "«Rimuovi lo sfondo»: gli angoli restano pieni (%s)" % os.path.basename(o), "medio", "angoli trasparenti",
                     "alfa=%s angoli=%s centro=%s" % (m.get("alfa"), m.get("alfa_angoli"), m.get("alfa_centro")), o)
    if not nessuno("nascondi", "Nascondi un logo", "una foto con la zona sfocata"):
        o = out["nascondi"][0]; m = meta(o)
        es.check("nascondi un logo: stessa misura", m.get("larghezza") == 1600 and m.get("altezza") == 1200, "«Nascondi un logo» cambia la misura della foto",
                 "medio", "1600×1200", "%s×%s" % (m.get("larghezza"), m.get("altezza")), o)
    if not nessuno("ingrandisci", "Ingrandisci 2×", "800×600"):
        o = out["ingrandisci"][0]; m = meta(o)
        es.check("ingrandisci 2×", m.get("larghezza") == 800 and m.get("altezza") == 600, "«Ingrandisci 2×» non raddoppia", "medio", "800×600",
                 "%s×%s" % (m.get("larghezza"), m.get("altezza")), o)
    chiudi_app()


def motore_grafica():
    logo = F + "/logo.png"
    for t in ["svg", "ico", "webp", "pdf"]:
        r = motore("to:" + t, "", [logo], nome="logo-" + t)
        esito_motore(es, "motore: logo.png → %s" % t, r, "file %s" % t, lambda p: (os.path.getsize(p) > 100, "%d byte" % os.path.getsize(p)))


guarded(es, "app grafica", lavori)
guarded(es, "motore grafica", motore_grafica)
nuovi = crash_nuovi(crash0)
es.check("nessun crash", not nuovi, "OrbitLR si chiude da sola", "bloccante", "nessun rapporto di crash", nuovi, "log/")
raccogli()
es.fine()
