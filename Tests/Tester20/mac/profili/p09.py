#!/usr/bin/env python3
# P09 · Video maker: formati (come M03), file pesanti e rotti, velocità 2× con l'audio, formato social.
import os, sys, time, shutil
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from t20 import *

es = Esito("P09")
F = os.path.join(OUT, "fix"); os.makedirs(F, exist_ok=True)
crash0 = crash_elenco()
utente_esperto()


def fixture():
    crea_video(F + "/clip.mp4", 6)
    crea_video(F + "/clip.mov", 6)
    crea_video(F + "/clip.mkv", 6)
    crea_video(F + "/muto.mp4", 5, audio=False)
    crea_video(F + "/verticale.mp4", 6, 720, 1280)
    crea_video(F + "/4k.mp4", 8, 3840, 2160)
    data = open(F + "/clip.mp4", "rb").read()
    open(F + "/troncato.mp4", "wb").write(data[: len(data) // 3])
    open(F + "/casuale.mkv", "wb").write(os.urandom(300000))
    open(F + "/vuoto.mp4", "wb").close()
    es.nota("fixture", {f: os.path.getsize(os.path.join(F, f)) for f in os.listdir(F)})


def formati():
    for src in ["clip.mp4", "clip.mov", "clip.mkv"]:
        p = os.path.join(F, src)
        for t in ["mp4", "mov", "webm", "gif", "mp3", "m4a"]:
            if src.endswith("." + t): continue
            r = motore("to:" + t, "", [p], timeout=300, nome="%s-%s" % (src, t))
            c = ctrl_media(dur=6, video=t not in ("mp3", "m4a"), audio=None if t == "gif" else True) if t != "gif" else ctrl_media(video=True)
            esito_motore(es, "%s → %s" % (src, t), r, "file %s valido, ~6 s" % t, c)
    p = F + "/clip.mp4"
    for act, prm, c, desc in [
        ("vcompress", "best", ctrl_media(dur=6, video=True, audio=True), "video compresso ~6 s con audio"),
        ("cut", "1.000|4.000", ctrl_media(dur=3, video=True, audio=True), "taglio di 3 s"),
        ("gifcut", "0.000|2.000", ctrl_media(video=True), "GIF di 2 s"),
        ("vresize", "720", ctrl_media(dur=6, video=True, audio=True), "video più piccolo"),
        ("strip", "", ctrl_media(dur=6, video=True, audio=True), "copia senza metadati"),
        ("normalize", "", ctrl_media(dur=6, video=True, audio=True), "audio normalizzato"),
    ]:
        r = motore(act, prm, [p], timeout=300)
        esito_motore(es, "clip.mp4 %s %s" % (act, prm), r, desc, c)


def velocita():
    p = F + "/clip.mp4"
    for prm, dur in [("2", 3.0), ("0.5", 12.0), ("1.5", 4.0)]:
        r = motore("speed", prm, [p], timeout=300, nome="speed" + prm)
        esito_motore(es, "velocità %s× con l'audio" % prm, r, "video di ~%.1f s CON audio" % dur, ctrl_media(dur=dur, video=True, audio=True),
                     titolo="«Cambia la velocità» %s× su un video con l'audio: risultato sbagliato" % prm)
    r = motore("speed", "2", [F + "/muto.mp4"], timeout=300, nome="speed-muto")
    esito_motore(es, "velocità 2× su video muto", r, "video di ~2.5 s", ctrl_media(dur=2.5, video=True))


def pesanti():
    p = F + "/4k.mp4"
    for act, prm, c in [("vresize", "1080", ctrl_media(dur=8, video=True, h=1080)), ("vcompress", "18", ctrl_media(dur=8, video=True)),
                        ("to:mov", "", ctrl_media(dur=8, video=True)), ("speed", "2", ctrl_media(dur=4, video=True, audio=True))]:
        r = motore(act, prm, [p], timeout=600, nome="4k-" + act)
        esito_motore(es, "4K 8 s: %s %s (%.0f s)" % (act, prm, r["secs"]), r, "file valido", c)


def rotti():
    for src in ["troncato.mp4", "casuale.mkv", "vuoto.mp4"]:
        for act, prm in [("to:mp4", ""), ("to:mp3", ""), ("vcompress", "best"), ("speed", "2")]:
            r = motore(act, prm, [F + "/" + src], timeout=180, nome="rotto-%s-%s" % (src, act))
            outs = [o for o in r["outs"] if os.path.exists(o)]
            cosa = "file rotto %s: %s" % (src, act)
            if r["hang"]:
                es.bug(cosa, "Su un video rotto il motore non finisce (%s)" % act, "alto", "FAIL con un messaggio entro 3 minuti", "bloccato", prova_motore(r))
            elif outs:
                ok = all(probe(o)["size"] > 1000 and (probe(o)["dur"] or 0) > 0.3 for o in outs)
                if ok or src == "troncato.mp4":
                    es.ok(cosa, "ha recuperato la parte leggibile: %s" % [os.path.basename(o) for o in outs])
                else:
                    es.bug(cosa, "Da un video rotto esce un file vuoto o illeggibile (%s %s)" % (src, act), "medio", "FAIL con un messaggio, nessun file",
                           [(os.path.basename(o), probe(o)) for o in outs], prova_motore(r))
            elif r["fails"] and any(motivo_strano(m) for _, m in r["fails"]):
                es.bug(cosa, "Il messaggio d'errore per un video rotto è solo un percorso interno", "basso", "un motivo comprensibile", r["fails"], prova_motore(r))
            elif r["fails"] and all(m.strip() for _, m in r["fails"]):
                es.ok(cosa, "FAIL: %s" % r["fails"][0][1][:120])
            else:
                es.bug(cosa, "Video rotto: nessun file e nessun messaggio (%s)" % act, "medio", "una riga FAIL con il motivo", r["lines"], prova_motore(r))


def social():
    srcs = [F + "/clip.mp4", F + "/verticale.mp4"]
    cart = os.path.join(F, "social-916")
    res = lavoro_app(es, "social", [(regola(cart, "video", "social", "9x16|0"), srcs)], attesa=240)
    out = res.get(cart, [])
    foto("social")
    if not out:
        es.bug("app: formato social 9:16", "«Formato social» 9:16 non crea il video", "alto", "2 video 9:16", "nessun file in 4 minuti", "log/, foto social.png")
    for o in out:
        i = probe(o)
        ok = i.get("w") and i.get("h") and abs(i["w"] / i["h"] - 9 / 16) < 0.02 and near(i["dur"], 6) and i["audio"]
        es.check("app: social 9:16 %s" % os.path.basename(o), ok, "«Formato social» 9:16: proporzioni, durata o audio sbagliati", "alto",
                 "9:16, ~6 s, con audio", str(i), o)
    chiudi_app()


guarded(es, "fixture", fixture)
guarded(es, "formati", formati)
guarded(es, "velocità", velocita)
guarded(es, "pesanti", pesanti)
guarded(es, "rotti", rotti)
guarded(es, "social", social)
nuovi = crash_nuovi(crash0)
es.check("nessun crash", not nuovi, "OrbitLR si chiude da sola", "bloccante", "nessun rapporto di crash", nuovi, "log/")
raccogli()
es.fine()
