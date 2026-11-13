#!/usr/bin/env python3
# P18 · File cattivi: nomi strani, 3 GB, file rotti, disco pieno, cartella in sola lettura, disco staccato durante un lavoro.
import os, sys, time, shutil, subprocess, signal, glob
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from t20 import *

es = Esito("P18")
F = os.path.join(OUT, "fix"); os.makedirs(F, exist_ok=True)
crash0 = crash_elenco()
utente_esperto()


def nomi():
    base_j = F + "/base.jpg"; crea_foto(base_j, 1200, 900)
    base_a = F + "/base.m4a"; crea_audio(base_a, 4)
    for nome in ["Foto 🎉 festa", "Фото отпуск", "riga\nnuova", "tab\tqui", "virgolette \"doppie\" e 'singole'", "è già città – perché",
                 "-inizia-col-trattino", "punto.e.virgola;$(echo x)", "a" * 200]:
        for base, ext, act, c in [(base_j, "jpg", "to:png", ctrl_img(tipo="png")), (base_a, "m4a", "to:mp3", ctrl_media(dur=4, audio=True))]:
            src = os.path.join(F, "%s.%s" % (nome, ext))
            try:
                shutil.copy(base, src)
            except OSError as e:
                es.skip("nome «%s»" % nome[:30], "il disco non accetta il nome: %s" % e); continue
            r = motore(act, "", [src], nome="nome-" + ext)
            esito_motore(es, "nome «%s».%s → %s" % (nome.replace("\n", "⏎").replace("\t", "⇥")[:40], ext, act), r, "file creato", c,
                         titolo="Nome di file con caratteri speciali (%s): conversione non riuscita" % nome.replace("\n", "⏎").replace("\t", "⇥")[:30])
    # anche nell'app (cartella automatica), con emoji e cirillico
    cart = F + "/nomi-app"
    srcs = []
    for nome in ["Foto 🎉 app", "Фото app", "riga\napp"]:
        p = os.path.join(F, nome + ".png"); crea_foto(p, 600, 400); srcs.append(p)
    res = lavoro_app(es, "nomi app", [(regola(cart, "img", "to:jpg", ""), srcs)], attesa=90)
    n = len(res.get(cart, []))
    es.check("app: 3 nomi strani → 3 JPG", n == 3, "L'app non converte file con nomi strani (emoji, cirillico, a capo)", "medio", "3 JPG",
             "%d: %s" % (n, [os.path.basename(x) for x in res.get(cart, [])]), "log/")
    chiudi_app()


def grandi():
    g = F + "/grande.mp4"
    sh(["mkfile", "-n", "3g", g])
    r = motore("to:mov", "", [g], timeout=240, nome="3gb-sparso")
    es.check("video sparso da 3 GB (tutti zeri) → messaggio, niente blocco", not r["hang"] and r["fails"] and not [o for o in r["outs"] if os.path.exists(o)],
             "Con un file da 3 GB illeggibile il motore si blocca o crea un file", "alto", "FAIL in pochi secondi", r["lines"], prova_motore(r))
    apri_app(); time.sleep(3)
    sh(["open", "-a", APP, g], timeout=60)
    camp = []
    for i in range(5):
        q, f = campiona(1); camp.append(q); time.sleep(1)
    foto("3gb-aperto")
    es.check("app: aprire un file da 3 GB non blocca la finestra", not all(q is not None and q < 0.25 for q in camp[2:]),
             "Aprire un file da 3 GB blocca la finestra", "alto", "thread principale a riposo", camp, "sample-*.txt")
    chiudi_app(cortese=False)
    os.remove(g)
    # 3 GB veri? solo se c'è spazio
    free = shutil.disk_usage(F).free / 1e9
    if free > 12:
        big = F + "/vero-3gb.mp4"
        ok = ff(["-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=120", "-f", "lavfi", "-i", "anoisesrc=d=120",
                 "-c:v", "mpeg4", "-q:v", "1", "-c:a", "aac", "-shortest", big], timeout=900)
        sz = os.path.getsize(big) / 1e9 if os.path.exists(big) else 0
        es.nota("video_grande_GB", round(sz, 2))
        if ok:
            r = motore("cut", "10.000|20.000", [big], timeout=600, nome="grande-cut")
            esito_motore(es, "video grande (%.1f GB): taglio di 10 s" % sz, r, "10 s", ctrl_media(dur=10, video=True, audio=True))
            os.remove(big)
    else:
        es.skip("video vero da 3 GB", "solo %.0f GB liberi sul runner" % free)


def rotti():
    for nome, data in [("zero.jpg", b""), ("finto.jpg", b"questo non e' un jpeg" * 100), ("troncato.png", open(F + "/base.jpg", "rb").read()[:3000] if os.path.exists(F + "/base.jpg") else b"x"),
                       ("finto.pdf", b"%PDF-1.7\n" + os.urandom(2000)), ("finto.mp4", os.urandom(100000)), ("finto.docx", b"PK\x03\x04" + os.urandom(500))]:
        p = F + "/" + nome; open(p, "wb").write(data)
        act = {"jpg": "to:png", "png": "to:jpg", "pdf": "extract", "mp4": "to:mov", "docx": "to:txt"}[nome.rsplit(".", 1)[1]]
        prm = "1" if act == "extract" else ""
        r = motore(act, prm, [p], timeout=120, nome="rotto-" + nome)
        buoni = [o for o in r["outs"] if os.path.exists(o) and os.path.getsize(o) > 0]
        cosa = "file rotto %s → %s" % (nome, act)
        if r["hang"]:
            es.bug(cosa, "File rotto: il motore non finisce (%s)" % nome, "alto", "FAIL con motivo", "bloccato", prova_motore(r))
        elif r["missing"] and not buoni:
            es.skip(cosa, "MISSING %s" % r["missing"])
        elif r["fails"] and any(motivo_strano(m) for _, m in r["fails"]) and not buoni:
            es.bug(cosa, "Il messaggio d'errore per un file rotto è solo un percorso interno, non un motivo", "basso",
                   "un motivo comprensibile (es. «il file sembra danneggiato»)", r["fails"], prova_motore(r))
        elif r["fails"] and all(m.strip() for _, m in r["fails"]) and not buoni:
            es.ok(cosa, r["fails"][0][1][:120])
        elif buoni and nome == "troncato.png":
            es.confuso(cosa, "da un'immagine troncata esce un file (la parte leggibile, il resto grigio): %s" % [(os.path.basename(o), os.path.getsize(o)) for o in buoni])
        elif buoni:
            es.bug(cosa, "Da un file rotto (%s) esce un file «riuscito»" % nome, "medio", "FAIL con motivo, nessun file",
                   [(os.path.basename(o), os.path.getsize(o)) for o in buoni], prova_motore(r))
        else:
            es.bug(cosa, "File rotto (%s): nessun messaggio" % nome, "basso", "riga FAIL con motivo", r["lines"], prova_motore(r))


def disco_pieno():
    crea_video(F + "/medio.mp4", 40, 1920, 1080)
    img = os.path.join(OUT, "pieno.dmg")
    sh(["hdiutil", "create", "-size", "8m", "-fs", "HFS+", "-volname", "T20Pieno", img], timeout=60)
    rc, o = sh(["hdiutil", "attach", "-nobrowse", img], timeout=60)
    mnt = [l.split("\t")[-1].strip() for l in o.splitlines() if "/Volumes/" in l]
    if not mnt:
        es.skip("disco pieno", "immagine non montata: %s" % o[:200]); return
    m = mnt[-1]
    r = motore("to:mov", "", [F + "/medio.mp4"], dest=m, timeout=300, nome="pieno")
    resti = [x for x in os.listdir(m) if not x.startswith(".")]
    msg = " ".join(x[1] for x in r["fails"])
    es.check("disco pieno → messaggio chiaro", r["fails"] and ("spazio" in msg or "disco" in msg), "Disco pieno: il messaggio non dice che manca spazio",
             "medio", "FAIL «spazio su disco esaurito»", r["lines"], prova_motore(r))
    es.check("disco pieno: nessun pezzo di file lasciato", not resti, "Disco pieno: resta un file a metà nella destinazione", "medio",
             "destinazione vuota", resti, m)
    sh(["hdiutil", "detach", "-force", m], timeout=60)


def sola_lettura():
    d = F + "/sola-lettura"; os.makedirs(d, exist_ok=True)
    src = F + "/ro.jpg"; crea_foto(src, 800, 600)
    os.chmod(d, 0o555)
    r = motore("to:png", "", [src], dest=d, timeout=120, nome="sola-lettura")
    msg = " ".join(x[1] for x in r["fails"])
    es.check("cartella in sola lettura → messaggio", r["fails"] and not r["hang"], "Destinazione in sola lettura: nessun messaggio", "medio",
             "FAIL con il motivo (permesso)", r["lines"], prova_motore(r))
    if r["fails"] and motivo_strano(msg):
        es.bug("messaggio sola lettura", "Destinazione in sola lettura: il messaggio è solo un percorso interno", "basso",
               "«macOS non ha dato il permesso di scrivere in quella cartella»", msg, prova_motore(r))
    elif r["fails"] and "permess" not in msg:
        es.confuso("messaggio sola lettura", "il motivo non parla di permessi: «%s»" % msg)
    os.chmod(d, 0o755)
    # originale in una cartella senza permesso di scrittura, destinazione «accanto all'originale» (come l'app di base)
    d2 = F + "/originali-ro"; os.makedirs(d2, exist_ok=True); s2 = d2 + "/foto.jpg"; crea_foto(s2, 800, 600); os.chmod(d2, 0o555)
    env = dict(os.environ); env.pop("LR_DESTPATH", None)
    p = subprocess.run(["/bin/zsh", ENG, "--run", "to:png", "", s2], capture_output=True, text=True, env=env, timeout=120)
    es.nota("originale-in-cartella-ro", p.stdout[-400:])
    ok = "FAIL" in p.stdout or "OUT" in p.stdout
    es.check("originale in cartella non scrivibile: messaggio o file altrove", ok, "Originale in una cartella non scrivibile: nessun risultato né messaggio",
             "medio", "FAIL con motivo o file creato altrove", p.stdout[-300:], "stdout motore")
    os.chmod(d2, 0o755)


def staccato():
    crea_video(F + "/lungo.mp4", 120, 1920, 1080) if not os.path.exists(F + "/lungo.mp4") else None
    img = os.path.join(OUT, "staccabile.dmg")
    sh(["hdiutil", "create", "-size", "600m", "-fs", "HFS+", "-volname", "T20Chiavetta", img], timeout=120)
    rc, o = sh(["hdiutil", "attach", "-nobrowse", img], timeout=60)
    mnt = [l.split("\t")[-1].strip() for l in o.splitlines() if "/Volumes/" in l]
    if not mnt:
        es.skip("disco staccato durante un lavoro", "immagine non montata"); return
    m = mnt[-1]
    shutil.copy(F + "/lungo.mp4", m + "/lungo.mp4")
    env = dict(os.environ, LR_DESTPATH=m + "/out", LR_MOTORI=MOT); os.makedirs(m + "/out", exist_ok=True)
    t = time.time()
    p = subprocess.Popen(["/bin/zsh", ENG, "--run", "vcompress", "best", m + "/lungo.mp4"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, start_new_session=True)
    time.sleep(6)
    rc2, o2 = sh(["hdiutil", "detach", "-force", m], timeout=60)
    t1 = time.time()
    try:
        so, se = p.communicate(timeout=180); hang = False
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL); so, se = p.communicate(); hang = True
    so = so.decode(errors="replace")
    es.nota("staccato", {"staccato_dopo_s": round(t1 - t, 1), "fine_dopo_s": round(time.time() - t1, 1), "stdout": so[-500:], "detach": o2[-200:]})
    es.check("disco staccato durante il lavoro: il motore si ferma", not hang, "Disco staccato durante un lavoro: il motore resta appeso", "alto",
             "finisce entro 3 minuti", "bloccato", "nota «staccato»")
    if not hang:
        es.check("disco staccato: messaggio", "FAIL" in so, "Disco staccato durante un lavoro: nessun messaggio di errore", "medio", "riga FAIL", so[-400:], "stdout")


for n, f in [("nomi", nomi), ("grandi", grandi), ("rotti", rotti), ("disco pieno", disco_pieno), ("sola lettura", sola_lettura), ("staccato", staccato)]:
    guarded(es, n, f)
nuovi = crash_nuovi(crash0)
es.check("nessun crash", not nuovi, "OrbitLR si chiude da sola", "bloccante", "nessun rapporto di crash", nuovi, "log/")
raccogli()
es.fine()
