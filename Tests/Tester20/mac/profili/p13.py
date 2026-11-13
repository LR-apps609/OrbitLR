#!/usr/bin/env python3
# P13 · Downloader: yt-dlp con gli argomenti esatti dell'app (M09 dl.sh) e un server locale (nessun YouTube vero).
# Messaggi all'utente: la stessa logica di MusicLink.friendly (copiata qui, non cambiata). File a metà quando il server muore.
import os, sys, time, subprocess, hashlib, shutil, urllib.request, signal
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from t20 import *

es = Esito("P13")
LIB = os.path.join(HERE, "lib")
W = os.path.join(OUT, "dl"); os.makedirs(W, exist_ok=True)
FX = os.path.join(OUT, "fx"); os.makedirs(FX, exist_ok=True)
PORT = 8765


def friendly(stderr):   # Sources/MusicLink.swift, friendly(_:) 6.0.3
    s = stderr.lower()
    if "drm" in s: return "DRM"
    if "unsupported url" in s: return "Da questo link non so prendere l'audio. Prova con il link diretto della canzone."
    if "not a bot" in s or "confirm you" in s: return "robot"
    if "private" in s or "sign in" in s or "login" in s or "members" in s: return "Il contenuto è privato o richiede l'accesso"
    if "not available" in s or "unavailable" in s or "removed" in s: return "Il contenuto non è più disponibile."
    if "403" in s or "429" in s: return "Il sito ha rifiutato la richiesta."
    if "unable to download" in s or "network" in s or "timed out" in s or "resolve" in s: return "Non riesco a collegarmi: controlla internet e riprova."
    return "Non sono riuscito a scaricare l'audio da questo link."


def prepara():
    crea_video(FX + "/video.mp4", 20, 1280, 720)
    yt = os.path.join(OUT, "yt-dlp")
    base = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
    urllib.request.urlretrieve(base + "yt-dlp_macos", yt)
    sums = urllib.request.urlopen(base + "SHA2-256SUMS").read().decode()
    want = [l.split()[0] for l in sums.splitlines() if l.endswith(" yt-dlp_macos")]
    got = hashlib.sha256(open(yt, "rb").read()).hexdigest()
    os.chmod(yt, 0o755)
    if not want or want[0] != got:
        raise RuntimeError("impronta di yt-dlp diversa")
    return yt


def dl(yt, mode, link, nome):
    w = os.path.join(W, nome)
    shutil.rmtree(w, ignore_errors=True)
    t = time.time()
    p = subprocess.Popen(["/bin/zsh", LIB + "/dl.sh", yt, MOT, mode, link, w])
    return p, w, t


def risultato(w):
    try: code = int(open(w + ".code").read().strip())
    except Exception: code = None
    err = open(w + ".err", errors="replace").read() if os.path.exists(w + ".err") else ""
    files = file_in(w)
    return code, err, files


def prove(yt):
    srv = subprocess.Popen([sys.executable, "-I", LIB + "/server.py", FX, str(PORT)], stderr=open(OUT + "/server.log", "w"))
    time.sleep(1.5)
    try:
        for mode in ["video", "audio", "videoBest"]:
            p, w, t = dl(yt, mode, "http://127.0.0.1:%d/video.mp4" % PORT, "valido-" + mode); p.wait(300)
            code, err, files = risultato(w)
            ok = code == 0 and files and probe(files[0])["dur"] and near(probe(files[0])["dur"], 20)
            es.check("download %s da link valido" % mode, ok, "Il Downloader non scarica un video da un link valido (%s)" % mode, "alto",
                     "un file di ~20 s", "uscita %s, file %s, stderr %s" % (code, files, err[-300:]), w + ".err")
        p, w, t = dl(yt, "video", "http://127.0.0.1:%d/lungo.html" % PORT, "titolo-lungo"); p.wait(300)
        code, err, files = risultato(w)
        es.check("titolo lunghissimo con emoji", code == 0 and files and len(os.path.basename(files[0]).encode()) <= 255,
                 "Con un titolo lunghissimo il download fallisce", "medio", "file salvato con nome accorciato", "uscita %s, %s, %s" % (code, files, err[-200:]), w + ".err")
        casi = [("pagina senza video", "http://127.0.0.1:%d/muto.html" % PORT, ["link", "scaricare"]),
                ("file che non esiste (404)", "http://127.0.0.1:%d/mancante.mp4" % PORT, ["disponibile", "link", "scaricare"]),
                ("porta chiusa", "http://127.0.0.1:9/video.mp4", ["collegarmi"])]
        for nome, link, parole in casi:
            p, w, t = dl(yt, "video", link, nome.replace(" ", "-")); p.wait(300)
            code, err, files = risultato(w)
            msg = friendly(err)
            es.nota("messaggio-" + nome, {"uscita": code, "messaggio_app": msg, "stderr": err[-300:]})
            if code == 0:
                es.bug(nome, "Il Downloader dice riuscito su «%s»" % nome, "medio", "errore", files, w + ".err"); continue
            if not any(x in msg for x in parole):
                es.bug("messaggio per %s" % nome, "Link a un file che non esiste (404): l'app dice di controllare internet" if "404" in nome
                       else "Messaggio fuorviante per «%s»" % nome, "basso",
                       "un messaggio che parli del link (es. «Il contenuto non è più disponibile»)", "messaggio: «%s»" % msg,
                       "stderr di yt-dlp: %s · regole di MusicLink.friendly (Sources/MusicLink.swift ~106-125): «unable to download» viene prima del 404" % err[-250:].replace("\n", " "))
            else:
                es.ok("messaggio per %s" % nome, msg)
        # rete che si stacca a metà
        p, w, t = dl(yt, "video", "http://127.0.0.1:%d/lento/video.mp4" % PORT, "taglio")
        time.sleep(6)
        srv.kill(); srv.wait()
        t1 = time.time()
        try:
            p.wait(240)
        except subprocess.TimeoutExpired:
            p.kill()
        dt = time.time() - t1
        code, err, files = risultato(w)
        es.nota("taglio", {"uscita": code, "secondi_dopo_lo_stacco": round(dt, 1), "file_rimasti": [(os.path.basename(f), os.path.getsize(f)) for f in files],
                           "messaggio_app": friendly(err)})
        es.check("server che muore a metà: yt-dlp si ferma", dt < 200, "Il Downloader resta appeso se la rete cade a metà", "alto",
                 "si ferma entro qualche minuto", "%.0f s" % dt, w + ".err")
        if code == 0:
            es.bug("server che muore a metà", "Download interrotto a metà ma risultato «riuscito»", "alto", "errore", files, w + ".err")
        else:
            es.ok("server che muore a metà: errore", friendly(err))
        if files:
            # MusicLink.download lavora in una cartella temporanea propria e la cancella sempre (defer, MusicLink.swift:146),
            # anche quando yt-dlp esce con errore: il pezzo a metà lasciato da --no-part non arriva mai all'utente.
            es.ok("pezzo a metà (%s, %d byte) resta solo nella cartella di lavoro: l'app la cancella (defer in MusicLink.swift:146)" %
                  (os.path.basename(files[0]), os.path.getsize(files[0])))
    finally:
        try: srv.kill()
        except Exception: pass


try:
    yt = prepara()
    es.ok("yt-dlp scaricato come fa l'app, impronta controllata")
    guarded(es, "download", prove, yt)
except Exception as e:
    es.skip("Downloader", "non riesco a preparare yt-dlp: %r" % e)
es.skip("Downloader dentro l'app (incolla il link)", "va guidato con clic e testo nella finestra: senza Automazione provo il motore con gli stessi argomenti dell'app")
raccogli()
es.fine()
