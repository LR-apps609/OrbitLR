#!/usr/bin/env python3
# P10 · Podcaster: azioni audio del motore (come M04), suoneria iPhone e vocale WhatsApp nell'app, trascrizione.
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from t20 import *

es = Esito("P10")
F = os.path.join(OUT, "fix"); os.makedirs(F, exist_ok=True)
crash0 = crash_elenco()
utente_esperto()


def fixture():
    crea_audio(F + "/voce.m4a", voce=True)
    crea_audio(F + "/tono.wav", 40)
    ff(["-f", "lavfi", "-i", "sine=f=300:d=3", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-f", "lavfi", "-i", "sine=f=500:d=3",
        "-filter_complex", "[1]atrim=0:4[s];[0][s][2]concat=n=3:v=0:a=1", F + "/silenzi.wav"])
    crea_audio(F + "/episodio.mp3", 65)
    open(F + "/rotto.mp3", "wb").write(os.urandom(50000))
    es.nota("fixture", {f: os.path.getsize(os.path.join(F, f)) for f in os.listdir(F)})


def motore_audio():
    dv = probe(F + "/voce.m4a")["dur"] or 5
    for t in ["mp3", "wav", "flac", "ogg"]:   # formati che il motore offre per l'audio (OPTS[audio]), non lo stesso del file
        r = motore("to:" + t, "", [F + "/voce.m4a"], nome="voce-" + t)
        esito_motore(es, "voce.m4a → %s" % t, r, "audio %s di ~%.1f s" % (t, dv), ctrl_media(dur=dv, audio=True, video=False))
    for act, prm, src, c, d in [
        ("normalize", "", "voce.m4a", ctrl_media(dur=dv, audio=True), "volume uniforme"),
        ("voiceclean", "", "voce.m4a", ctrl_media(dur=dv, audio=True), "voce pulita"),
        ("cut", "1.000|3.000", "tono.wav", ctrl_media(dur=2, audio=True), "2 s"),
        ("silence", "", "silenzi.wav", ctrl_media(audio=True), "senza la pausa di 4 s"),
        ("to:wav", "", "episodio.mp3", ctrl_media(dur=65, audio=True), "mp3 → wav"),
    ]:
        r = motore(act, prm, [F + "/" + src], nome="%s-%s" % (act, src))
        ok = esito_motore(es, "%s %s su %s" % (act, prm, src), r, d, c)
        if ok and act == "silence":
            dd = probe(r["outs"][0])["dur"]
            es.check("silenzi tolti davvero", dd is not None and dd < 8.5, "«Togli i silenzi» non accorcia l'audio", "medio",
                     "meno di 8.5 s (era 10 s con 4 s di silenzio)", "durata %s" % dd, prova_motore(r))
    r = motore("to:wav", "", [F + "/rotto.mp3"], nome="rotto")
    if r["hang"]:
        es.bug("mp3 rotto", "Su un mp3 rotto il motore non finisce", "alto", "FAIL con un messaggio", "bloccato", prova_motore(r))
    elif r["fails"] and r["fails"][0][1].strip():
        es.ok("mp3 rotto → FAIL con messaggio", r["fails"][0][1][:120])
    elif not [o for o in r["outs"] if os.path.exists(o) and (probe(o)["dur"] or 0) > 0.5]:
        es.bug("mp3 rotto", "File audio rotto: nessun messaggio chiaro", "basso", "riga FAIL con un motivo", r["lines"], prova_motore(r))
    else:
        es.ok("mp3 rotto: recuperato qualcosa", r["outs"])


def trascrizione():
    r = motore("transcribe", "", [F + "/voce.m4a"], timeout=600, nome="trascrivi")
    if r["missing"]:
        es.skip("trascrizione", "il motore dice MISSING %s (whisper non installato: l'indicazione per installarlo è il comportamento corretto)" % r["missing"]); return
    ok = esito_motore(es, "trascrizione voce.m4a", r, "un file di testo/sottotitoli", None)
    if ok:
        txt = " ".join(open(o, errors="replace").read() for o in r["outs"] if os.path.exists(o)).lower()
        es.check("trascrizione contiene le parole dette", any(w in txt for w in ["prova", "podcast", "caffè", "musica"]),
                 "La trascrizione non contiene le parole dette", "medio", "parole come «prova», «podcast»", txt[:300], prova_motore(r))


def app_audio():
    c1, c2 = os.path.join(F, "suoneria"), os.path.join(F, "whatsapp")
    res = lavoro_app(es, "suoneria e whatsapp", [(regola(c1, "audio", "ringtone", "5.000|60.000"), [F + "/episodio.mp3"]),
                                                  (regola(c2, "audio", "whatsapp", ""), [F + "/voce.m4a"])], attesa=180)
    foto("audio-app")
    s = res.get(c1, [])
    if not s:
        es.bug("app: suoneria iPhone", "«Suoneria iPhone» non crea il file", "alto", "un .m4r", "nessun file in 3 minuti", "log/, foto audio-app.png")
    else:
        i = probe(s[0])
        es.check("app: suoneria al massimo 30 s (chiesti 55 s)", s[0].endswith(".m4r") and i["dur"] and i["dur"] <= 30.5 and i["audio"],
                 "La suoneria supera i 30 s o non è un .m4r", "medio", ".m4r di al massimo 30 s", "%s %s" % (os.path.basename(s[0]), i), s[0])
    w = res.get(c2, [])
    if not w:
        es.bug("app: vocale WhatsApp", "«Vocale leggero» non crea il file", "alto", "un .m4a mono", "nessun file in 3 minuti", "log/")
    else:
        i = probe(w[0])
        es.check("app: vocale WhatsApp leggero", i["audio"] and near(i["dur"], probe(F + "/voce.m4a")["dur"]), "Il vocale WhatsApp ha la durata sbagliata",
                 "medio", "stessa durata dell'originale", str(i), w[0])
    chiudi_app()


guarded(es, "fixture", fixture)
guarded(es, "motore audio", motore_audio)
guarded(es, "trascrizione", trascrizione)
guarded(es, "app audio", app_audio)
nuovi = crash_nuovi(crash0)
es.check("nessun crash", not nuovi, "OrbitLR si chiude da sola", "bloccante", "nessun rapporto di crash", nuovi, "log/")
raccogli()
es.fine()
