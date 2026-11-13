#!/usr/bin/env python3
# P16 · Mac Intel senza Homebrew: conversioni video, audio, immagini con il motore, memoria e tempo; avvio dell'app.
import os, sys, time, re, subprocess
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from t20 import *

es = Esito("P16")
F = os.path.join(OUT, "fix"); os.makedirs(F, exist_ok=True)
crash0 = crash_elenco()
utente_esperto()
es.nota("homebrew_visibile", sh("ls -d /usr/local/opt /usr/local/Cellar /usr/local/lib /opt/homebrew 2>&1; command -v ffmpeg brew")[1].strip())


def librerie():
    for b in ["ffmpeg", "ffprobe"]:
        rc, o = sh(["otool", "-L", MOT + "/" + b])
        fuori = [l.split()[0] for l in o.splitlines()[1:] if l.strip() and not l.strip().startswith(("/usr/lib/", "/System/Library/", "@"))]
        es.check("%s dell'app senza librerie esterne" % b, not fuori, "%s dell'app chiede librerie che un Mac normale non ha" % b, "bloccante",
                 "solo /usr/lib e /System", fuori, "otool -L")
        rc, o = sh([MOT + "/" + b, "-hide_banner", "-version"])
        es.check("%s parte su Intel senza Homebrew" % b, rc == 0, "%s dell'app non parte su Mac Intel" % b, "bloccante", "versione stampata", o[-300:], "uscita %s" % rc)


def misura(act, prm, files, cosa, c, timeout=900):
    """Come motore(), ma con /usr/bin/time -l per la memoria massima."""
    d = os.path.join(OUT, "motore", re.sub(r"\W+", "_", cosa)[:40]); os.makedirs(d, exist_ok=True)
    env = dict(os.environ, LR_DESTPATH=d, LR_MOTORI=MOT)
    t = time.time()
    p = subprocess.run(["/usr/bin/time", "-l", "/bin/zsh", ENG, "--run", act, prm] + files, capture_output=True, text=True, env=env, timeout=timeout, errors="replace")
    secs = time.time() - t
    m = re.search(r"(\d+)\s+maximum resident set size", p.stderr)
    mb = int(m.group(1)) / 1e6 if m else None
    lines = [l.split("\t") for l in p.stdout.splitlines() if l and not l.startswith("P\t")]
    r = {"act": act, "param": prm, "files": [os.path.basename(f) for f in files], "rc": p.returncode, "secs": round(secs, 1), "hang": False,
         "dest": d, "lines": ["\t".join(l) for l in lines], "stderr": p.stderr[-600:],
         "outs": [l[1] for l in lines if l[0] == "OUT"], "fails": [(l[1], l[2] if len(l) > 2 else "") for l in lines if l[0] == "FAIL"],
         "missing": [l[1] for l in lines if l[0] == "MISSING"], "notes": [], "end": []}
    es.nota("risorse-" + cosa, {"secondi": round(secs, 1), "memoria_max_MB_zsh": mb})
    esito_motore(es, cosa + " (%.0f s)" % secs, r, "file valido", c)


def conversioni():
    crea_video(F + "/clip.mp4", 10, 1280, 720)
    crea_audio(F + "/voce.m4a", voce=True)
    crea_foto(F + "/foto.heic", 3000, 2000, gps=True)
    crea_foto(F + "/foto.png", 2000, 1500)
    dv = probe(F + "/voce.m4a")["dur"] or 5
    for act, prm, src, c in [("to:mov", "", "clip.mp4", ctrl_media(dur=10, video=True, audio=True)),
                             ("vcompress", "best", "clip.mp4", ctrl_media(dur=10, video=True, audio=True)),
                             ("speed", "2", "clip.mp4", ctrl_media(dur=5, video=True, audio=True)),
                             ("to:gif", "", "clip.mp4", ctrl_media(video=True)),
                             ("to:mp3", "", "clip.mp4", ctrl_media(dur=10, audio=True, video=False)),
                             ("to:mp3", "", "voce.m4a", ctrl_media(dur=dv, audio=True)),
                             ("normalize", "", "voce.m4a", ctrl_media(dur=dv, audio=True)),
                             ("to:jpg", "", "foto.heic", ctrl_img(tipo="jpeg")),
                             ("to:webp", "", "foto.png", lambda p: (os.path.getsize(p) > 100, "")),
                             ("resize", "1280", "foto.heic", ctrl_img(maxlato=1280)),
                             ("strip", "", "foto.heic", ctrl_img(gps=False))]:
        misura(act, prm, [F + "/" + src], "%s %s %s" % (src, act, prm), c)


def avvio():
    t = apri_app(attesa=60)
    if t is None:
        es.confuso("avvio dell'app su Intel", "nessuna finestra in 60 s (i Mac Intel di GitHub non hanno Metal: M06 lo aveva già visto)")
    else:
        es.ok("avvio dell'app su Intel: finestra in %.1f s" % t)
    foto("intel-avvio", finestra=False)
    vivi = []
    for i in range(10):
        vivi.append(pid_app()); time.sleep(1)
    say("pid ogni secondo dopo la finestra:", vivi)
    rc, lg = sh("log show --last 3m --style compact --predicate 'process == \"OrbitLR\"' 2>/dev/null | grep -iE 'exit|terminat|metal|crash|abort|fault|quit|error' | tail -n 40", timeout=120)
    say("registro di sistema (uscita):", lg[-3000:].replace("\n", " ¶ "))
    try:
        say("registro app:", open(LOG, errors="replace").read()[-1500:].replace("\n", " ¶ "))
    except Exception:
        pass
    rc, o = sh(["ps", "-o", "rss=", "-p", str(pid_app() or 0)])
    es.nota("memoria_app_MB_dopo_avvio", round(int(o.strip()) / 1024, 1) if o.strip().isdigit() else None)
    if pid_app() is None:
        es.confuso("l'app resta aperta su Intel", "la finestra compare in %s s ma il processo sparisce entro 10 s, senza rapporto di crash (pid ogni secondo: %s). I Mac Intel di GitHub non hanno Metal: da confermare su un Mac Intel vero (registro di sistema nel log del lavoro)" % (t, vivi))
    else:
        es.ok("l'app resta aperta su Intel")
    chiudi_app()


guarded(es, "librerie", librerie)
guarded(es, "conversioni", conversioni)
guarded(es, "avvio", avvio)
nuovi = crash_nuovi(crash0)
es.check("nessun crash", not nuovi, "OrbitLR si chiude da sola", "bloccante", "nessun rapporto di crash", nuovi, "log/")
raccogli()
es.fine()
