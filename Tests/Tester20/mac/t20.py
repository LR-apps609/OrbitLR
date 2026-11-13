#!/usr/bin/env python3
"""Tester20 · Mac · libreria comune dei profili.
Ogni profilo importa questo modulo, usa Esito per contare passi/bug e le funzioni per motore, app, foto.
Variabili d'ambiente: T20_OUT (cartella uscita del profilo), T20_PROFILO, T20_RUNNER, T20_BUILD, T20_BIN (strumenti compilati)."""
import json, os, re, shutil, signal, subprocess, sys, time, glob, plistlib

HERE = os.path.dirname(os.path.abspath(__file__))
APP = "/Applications/OrbitLR.app"
RES = APP + "/Contents/Resources"
ENG = RES + "/LRConverter.zsh"
MOT = RES + "/Motori"
FFPROBE = MOT + "/ffprobe"
FFMPEG = MOT + "/ffmpeg"
BID = "it.ledion.OrbitLR"
HOME = os.path.expanduser("~")
SUP = HOME + "/Library/Application Support/LRConverter"
LOG = HOME + "/Library/Logs/LRConverter.log"
OUT = os.environ.get("T20_OUT", os.path.join(os.environ.get("RUNNER_TEMP", "/tmp"), "t20"))
STRUM = os.environ.get("T20_BIN", os.path.join(os.environ.get("RUNNER_TEMP", "/tmp"), "t20bin", "strumenti"))
os.makedirs(OUT, exist_ok=True)
T0 = time.time()


def say(*a):
    s = "[%5.0fs] " % (time.time() - T0) + " ".join(str(x) for x in a)
    print(s, flush=True)
    with open(os.path.join(OUT, "diario.txt"), "a") as f:
        f.write(s + "\n")


def sh(cmd, timeout=120, env=None, check=False, quiet=True):
    """Esegue un comando (lista o stringa per /bin/zsh -c). Restituisce (rc, stdout+stderr)."""
    if isinstance(cmd, str):
        cmd = ["/bin/zsh", "-c", cmd]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env, errors="replace")
        out = (r.stdout or "") + (r.stderr or "")
        rc = r.returncode
    except subprocess.TimeoutExpired as e:
        out = "TIMEOUT dopo %ds" % timeout
        rc = 124
    except OSError as e:
        out = "non eseguibile: %s" % e
        rc = 127
    if not quiet:
        say("$", " ".join(cmd)[:160], "->", rc, out[-300:])
    return rc, out


# ─────────────────────────── esito.json ───────────────────────────
class Esito:
    def __init__(self, profilo=None):
        self.path = os.path.join(OUT, "esito.json")
        self.d = {"profilo": profilo or os.environ.get("T20_PROFILO", "?"),
                  "runner": os.environ.get("T20_RUNNER", "?"),
                  "build": os.environ.get("T20_BUILD", "?"),
                  "mac": sh(["sw_vers", "-productVersion"])[1].strip() + " " + os.uname().machine,
                  "passi_fatti": 0, "passati": 0, "non_eseguiti": [], "bug": [], "confuso": [], "passi": []}
        self.save()

    def save(self):
        with open(self.path, "w") as f:
            json.dump(self.d, f, ensure_ascii=False, indent=1)

    def ok(self, cosa, dettaglio=""):
        self.d["passi_fatti"] += 1; self.d["passati"] += 1
        self.d["passi"].append({"cosa": cosa, "esito": "ok", "dettaglio": str(dettaglio)[:400]})
        say("OK  ", cosa, str(dettaglio)[:200]); self.save()

    def bug(self, cosa, titolo, gravita, atteso, visto, prova, passi=None):
        assert gravita in ("bloccante", "alto", "medio", "basso")
        self.d["passi_fatti"] += 1
        self.d["passi"].append({"cosa": cosa, "esito": "bug", "dettaglio": titolo})
        self.d["bug"].append({"titolo": titolo, "gravita": gravita, "passi": passi or [cosa], "atteso": atteso,
                              "visto": str(visto)[:1500], "prova": str(prova)[:1500]})
        say("BUG ", gravita, titolo, "|", str(visto)[:200]); self.save()

    def check(self, cosa, cond, titolo, gravita, atteso, visto, prova, passi=None, dettaglio=""):
        if cond:
            self.ok(cosa, dettaglio)
        else:
            self.bug(cosa, titolo, gravita, atteso, visto, prova, passi)
        return cond

    def skip(self, cosa, perche):
        self.d["non_eseguiti"].append({"cosa": cosa, "perche": str(perche)[:500]})
        say("SKIP", cosa, "|", perche); self.save()

    def confuso(self, cosa, perche):
        self.d["confuso"].append({"cosa": cosa, "perche": str(perche)[:800]})
        say("??  ", cosa, "|", perche); self.save()

    def nota(self, k, v):
        self.d.setdefault("note", {})[k] = v; self.save()

    def fine(self):
        self.d["secondi"] = int(time.time() - T0)
        self.save()
        say("FINE", self.d["profilo"], "passi", self.d["passi_fatti"], "passati", self.d["passati"],
            "bug", len(self.d["bug"]), "non eseguiti", len(self.d["non_eseguiti"]))


def guarded(es, nome, fn, *a, **k):
    """Esegue un blocco di prove: un'eccezione del banco di prova non è un bug dell'app, diventa «non eseguito»."""
    try:
        return fn(*a, **k)
    except Exception as e:
        import traceback
        say("ERRORE DEL BANCO in", nome, traceback.format_exc()[-800:])
        es.skip(nome, "errore del banco di prova (non dell'app): %s" % repr(e)[:300])


# ─────────────────────────── motore (--run) ───────────────────────────
N = [0]


def motore(act, param, files, dest=None, timeout=600, env_extra=None, secret=None, nome=None):
    """Lancia il motore come fa l'app. Restituisce un dizionario con righe, OUT, FAIL, MISSING, NOTE, tempo."""
    N[0] += 1
    d = dest or os.path.join(OUT, "motore", "%03d-%s" % (N[0], re.sub(r"[^A-Za-z0-9]+", "_", nome or act)[:40]))
    os.makedirs(d, exist_ok=True)
    env = dict(os.environ)
    env.pop("LR_DESTPATH", None); env.pop("LR_SECRET", None)
    env["LR_DESTPATH"] = d
    env["LR_MOTORI"] = MOT
    if secret is not None:
        env["LR_SECRET"] = secret
    if env_extra:
        env.update(env_extra)
    t = time.time()
    p = subprocess.Popen(["/bin/zsh", ENG, "--run", act, param] + list(files), stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env, start_new_session=True, stdin=subprocess.DEVNULL)
    hang = False
    try:
        so, se = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        hang = True
        os.killpg(p.pid, signal.SIGKILL); so, se = p.communicate()
    so = so.decode("utf-8", "replace"); se = se.decode("utf-8", "replace")
    lines = [l.split("\t") for l in so.splitlines() if l and not l.startswith("P\t")]
    r = {"act": act, "param": param, "files": [os.path.basename(f) for f in files], "rc": p.returncode,
         "secs": round(time.time() - t, 1), "hang": hang, "dest": d,
         "lines": ["\t".join(l) for l in lines], "stderr": se[-1200:],
         "outs": [l[1] for l in lines if l[0] == "OUT" and len(l) > 1],
         "fails": [(l[1] if len(l) > 1 else "", l[2] if len(l) > 2 else "") for l in lines if l[0] == "FAIL"],
         "missing": [l[1] for l in lines if l[0] == "MISSING" and len(l) > 1],
         "notes": [l[2] if len(l) > 2 else "" for l in lines if l[0] == "NOTE"],
         "end": [l for l in lines if l[0] == "END"]}
    jd = os.path.join(OUT, "motore-json"); os.makedirs(jd, exist_ok=True)
    with open(os.path.join(jd, "%03d.json" % N[0]), "w") as f:
        json.dump(r, f, ensure_ascii=False, indent=1)
    say("motore", act, param, r["files"][:3], "rc=%s %.1fs outs=%d fails=%s miss=%s notes=%s" %
        (r["rc"], r["secs"], len(r["outs"]), [x[1][:80] for x in r["fails"]], r["missing"], [n[:60] for n in r["notes"]]))
    return r


def prova_motore(r):
    """Testo breve da mettere in «prova» di un bug."""
    return "motore --run %s %s %s → rc=%s, %.1fs, righe: %s ; stderr: %s ; cartella %s" % (
        r["act"], r["param"], " ".join(r["files"][:3]), r["rc"], r["secs"], " | ".join(r["lines"])[:600],
        r["stderr"][-300:].replace("\n", " "), r["dest"])


def esito_motore(es, cosa, r, atteso_desc, controllo=None, gravita="alto", titolo=None, ammessi_missing=True):
    """Passo standard: deve finire, produrre almeno un file valido (controllo(path)->(bool, testo)), niente FAIL.
    Un MISSING (programma opzionale non installato) non è un bug: il passo diventa «non eseguito»."""
    if r["missing"] and not r["outs"] and ammessi_missing:
        es.skip(cosa, "il motore dice MISSING %s con l'indicazione per installarlo (comportamento corretto)" % r["missing"])
        return None
    if r["hang"]:
        es.bug(cosa, titolo or ("Il motore non finisce: %s %s" % (r["act"], r["param"])), "alto", atteso_desc,
               "fermato dopo il tempo massimo", prova_motore(r))
        return False
    outs = [o for o in r["outs"] if os.path.exists(o)]
    if not outs and r["outs"] and not r["fails"]:
        reali = file_in(r["dest"])
        if reali:
            es.bug(cosa, "Il motore annuncia un percorso che non esiste: il file vero ha un nome diverso (%s)" % r["act"], "basso",
                   "la riga OUT con il percorso del file creato (l'app la usa per Cassetto, cronologia, «Mostra nel Finder»)",
                   "OUT: %r ; file veri nella cartella: %r" % (r["outs"], [os.path.basename(x) for x in reali]), prova_motore(r))
            return False
    if not outs:
        es.bug(cosa, titolo or ("%s %s non crea il file" % (r["act"], r["param"])), gravita, atteso_desc,
               "nessun file creato; FAIL: %s" % r["fails"], prova_motore(r))
        return False
    if controllo:
        bad = []
        for o in outs:
            ok, txt = controllo(o)
            if not ok:
                bad.append("%s: %s" % (os.path.basename(o), txt))
        if bad:
            es.bug(cosa, titolo or ("%s %s: file creato ma sbagliato" % (r["act"], r["param"])), gravita, atteso_desc,
                   "; ".join(bad), prova_motore(r))
            return False
    es.ok(cosa, "%d file in %.1fs" % (len(outs), r["secs"]))
    return True


# ─────────────────────────── controlli sui file ───────────────────────────
def probe(p):
    rc, o = sh([FFPROBE, "-v", "error", "-show_format", "-show_streams", "-of", "json", p], timeout=120)
    try:
        j = json.loads(o[o.find("{"):]) if "{" in o else {}
    except Exception:
        j = {}
    fmt = j.get("format", {})
    info = {"size": os.path.getsize(p) if os.path.exists(p) else 0, "fmt": fmt.get("format_name"), "errore": "" if j else o[:200]}
    try:
        info["dur"] = float(fmt.get("duration"))
    except Exception:
        info["dur"] = None
    v = [s for s in j.get("streams", []) if s.get("codec_type") == "video" and not s.get("disposition", {}).get("attached_pic")]
    a = [s for s in j.get("streams", []) if s.get("codec_type") == "audio"]
    info["audio"] = bool(a); info["acodec"] = a[0].get("codec_name") if a else None
    info["video"] = bool(v)
    if v:
        info.update(w=v[0].get("width"), h=v[0].get("height"), vcodec=v[0].get("codec_name"))
    return info


def near(a, b, tol_abs=0.5, tol_rel=0.04):
    return a is not None and b is not None and abs(a - b) <= max(tol_abs, tol_rel * b)


def meta(p):
    rc, o = sh([STRUM, "meta", p], timeout=60)
    try:
        return json.loads(o.strip().splitlines()[-1])
    except Exception:
        return {"errore": o[:200]}


def ctrl_media(dur=None, video=None, audio=None, minsize=1000, w=None, h=None, fmt=None):
    def f(p):
        i = probe(p)
        prob = []
        if i["size"] < minsize: prob.append("pesa solo %d byte" % i["size"])
        if dur is not None and not near(i["dur"], dur): prob.append("durata %s invece di ~%s s" % (i["dur"], dur))
        if video is not None and i["video"] != video: prob.append("video=%s (atteso %s)" % (i["video"], video))
        if audio is not None and i["audio"] != audio: prob.append("audio=%s (atteso %s)" % (i["audio"], audio))
        if w is not None and i.get("w") != w: prob.append("larghezza %s invece di %s" % (i.get("w"), w))
        if h is not None and i.get("h") != h: prob.append("altezza %s invece di %s" % (i.get("h"), h))
        if fmt and fmt not in (i["fmt"] or ""): prob.append("formato %s invece di %s" % (i["fmt"], fmt))
        return (not prob, "; ".join(prob) or json.dumps(i))
    return f


def ctrl_img(tipo=None, gps=None, minw=None, maxlato=None, alfa_angoli=None):
    def f(p):
        m = meta(p)
        prob = []
        if m.get("errore"): return False, "non leggibile come immagine: %s" % m["errore"]
        if tipo and tipo not in m.get("tipo", ""): prob.append("tipo %s invece di %s" % (m.get("tipo"), tipo))
        if gps is not None and bool(m.get("gps")) != gps: prob.append("GPS presente=%s (atteso %s)" % (m.get("gps"), gps))
        if minw and (m.get("larghezza") or 0) < minw: prob.append("larghezza %s" % m.get("larghezza"))
        if maxlato and max(m.get("larghezza") or 0, m.get("altezza") or 0) > maxlato:
            prob.append("lato lungo %s > %s" % (max(m.get("larghezza") or 0, m.get("altezza") or 0), maxlato))
        if alfa_angoli == 0 and any(a > 10 for a in m.get("alfa_angoli", [255])): prob.append("angoli non trasparenti %s" % m.get("alfa_angoli"))
        return (not prob, "; ".join(prob) or json.dumps(m))
    return f


# ─────────────────────────── file di prova ───────────────────────────
def ff(args, timeout=300):
    """ffmpeg dell'app per creare i file di prova (encoder interni: mpeg4/aac/pcm)."""
    rc, o = sh([FFMPEG, "-hide_banner", "-loglevel", "error", "-y"] + args, timeout=timeout)
    if rc != 0:
        say("ffmpeg fixture rc", rc, o[-300:])
    return rc == 0


def crea_video(path, secs=6, w=640, h=360, audio=True, extra=None):
    a = ["-f", "lavfi", "-i", "testsrc2=size=%dx%d:rate=30:duration=%s" % (w, h, secs)]
    if audio:
        a += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=%s" % secs]
    enc = ["-c:v", "mpeg4", "-q:v", "5", "-pix_fmt", "yuv420p"]
    if path.endswith(".webm"):
        enc = ["-c:v", "libvpx", "-b:v", "1M"] if "libvpx" in encoders() else enc
    if audio:
        enc += ["-c:a", "aac", "-b:a", "128k"] if not path.endswith((".webm", ".mkv")) else ["-c:a", "aac"]
    return ff(a + enc + (extra or []) + ["-shortest", path] if audio else a + enc + (extra or []) + [path])


_ENC = []


def encoders():
    if not _ENC:
        _ENC.append(sh([FFMPEG, "-hide_banner", "-encoders"])[1])
    return _ENC[0]


def crea_audio(path, secs=8, voce=False):
    if voce:
        aiff = path + ".aiff"
        sh(["say", "-v", "Alice", "-o", aiff, "Buongiorno a tutti, questa è una prova di trascrizione del podcast di OrbitLR. Oggi parliamo di caffè e di musica."], timeout=60)
        if os.path.exists(aiff):
            ok = ff(["-i", aiff, path]); os.remove(aiff); return ok
    return ff(["-f", "lavfi", "-i", "sine=frequency=330:sample_rate=44100:duration=%s" % secs, path])


def crea_foto(path, w=1600, h=1200, gps=False):
    rc, o = sh([STRUM, "foto", path, str(w), str(h)] + (["gps"] if gps else []), timeout=60)
    if rc != 0: say("foto non creata", path, o[-200:])
    return rc == 0


def crea_pdf(path, pagine=3, testo="Pagina"):
    """PDF semplice scritto a mano (nessuna libreria)."""
    objs = []
    kids = []
    n = pagine
    # 1 catalog, 2 pages, 3 font, poi per pagina: page, content
    for i in range(n):
        kids.append(4 + 2 * i)
    objs.append("<< /Type /Catalog /Pages 2 0 R >>")
    objs.append("<< /Type /Pages /Kids [%s] /Count %d >>" % (" ".join("%d 0 R" % k for k in kids), n))
    objs.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    for i in range(n):
        stream = "BT /F1 24 Tf 72 720 Td (%s %d di %d) Tj ET" % (testo, i + 1, n)
        objs.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> /Contents %d 0 R >>" % (5 + 2 * i))
        objs.append("<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream))
    out = "%PDF-1.4\n"
    offs = []
    for i, o in enumerate(objs):
        offs.append(len(out.encode("latin-1")))
        out += "%d 0 obj\n%s\nendobj\n" % (i + 1, o)
    x = len(out.encode("latin-1"))
    out += "xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for o in offs:
        out += "%010d 00000 n \n" % o
    out += "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
    with open(path, "wb") as f:
        f.write(out.encode("latin-1"))
    return True


def pdf_pagine(p):
    rc, o = sh([STRUM, "pagine", p])
    try:
        return int(o.strip().splitlines()[-1])
    except Exception:
        pass
    # conto «/Type /Page» (non «/Pages») come ripiego
    try:
        data = open(p, "rb").read()
        return len(re.findall(rb"/Type\s*/Page[^s]", data))
    except Exception:
        return None


# ─────────────────────────── app ───────────────────────────
def defaults(*a):
    return sh(["defaults"] + list(a))


def utente_esperto(extra=None):
    """Preferenze come un utente che ha già usato l'app (niente benvenuto, niente controllo aggiornamenti)."""
    defaults("delete", BID)
    for k, t, v in [("welcomeDone", "-bool", "true"), ("launchScreen", "-bool", "false"), ("tips", "-bool", "false"),
                    ("updateAutoCheck", "-bool", "false"), ("closeNoticeShown", "-bool", "true"),
                    ("lastLaunchVersion", "-string", versione()), ("sidebarAdvanced", "-bool", "true")]:
        defaults("write", BID, k, t, v)
    defaults("write", BID, "AppleLanguages", "-array", "it-IT", "it")
    defaults("write", BID, "appLanguage", "-string", "it")
    for k, t, v in (extra or []):
        defaults("write", BID, k, t, v)


def versione(app=APP):
    try:
        return plistlib.load(open(app + "/Contents/Info.plist", "rb")).get("CFBundleShortVersionString", "?")
    except Exception:
        return "nessuna"


def pid_app():
    rc, o = sh(["pgrep", "-x", "OrbitLR"])
    p = [x for x in o.split() if x.isdigit()]
    return int(p[0]) if p else None


def finestre(tutte=False):
    rc, o = sh([STRUM, "finestre"] + (["tutte"] if tutte else []), timeout=30)
    res = []
    for l in o.splitlines():
        parts = l.split(" ", 6)
        if len(parts) == 7 and parts[0].isdigit():
            res.append({"id": int(parts[0]), "livello": int(parts[1]), "x": int(parts[2]), "y": int(parts[3]),
                        "l": int(parts[4]), "a": int(parts[5]), "nome": parts[6]})
    return res


def finestra_principale():
    w = [x for x in finestre() if x["livello"] == 0 and x["l"] > 300 and x["a"] > 200]
    w.sort(key=lambda x: -x["l"] * x["a"])
    return w[0] if w else None


def aspetta(cond, secs, passo=1.0):
    t = time.time()
    while time.time() - t < secs:
        v = cond()
        if v:
            return v
        time.sleep(passo)
    return None


def apri_app(*files, attesa=40):
    t = time.time()
    if files:
        sh(["open", "-a", APP] + list(files), timeout=60)
    else:
        sh(["open", APP], timeout=60)
    w = aspetta(finestra_principale, attesa)
    return (time.time() - t) if w else None


def chiudi_app(cortese=True):
    """Chiude l'app. Con cortese: ⌘Q via System Events, poi SIGTERM, poi kill. Restituisce come si è chiusa."""
    if not pid_app():
        return "non aperta"
    if cortese:
        attiva()
        sh(["osascript", "-e", 'tell application "System Events" to keystroke "q" using command down'], timeout=15)
        if aspetta(lambda: not pid_app(), 10):
            return "⌘Q"
    sh(["pkill", "-TERM", "-x", "OrbitLR"])
    if aspetta(lambda: not pid_app(), 8):
        return "TERM"
    sh(["pkill", "-9", "-x", "OrbitLR"]); time.sleep(2)
    return "kill"


def attiva():
    sh(["osascript", "-e", 'tell application "System Events" to set frontmost of (first process whose name is "OrbitLR") to true'], timeout=15)


def foto(nome, finestra=True):
    """Foto della finestra principale (o dello schermo). Restituisce il percorso."""
    d = os.path.join(OUT, "foto"); os.makedirs(d, exist_ok=True)
    p = os.path.join(d, nome + ".png")
    w = finestra_principale() if finestra else None
    if w:
        sh(["screencapture", "-x", "-o", "-l%d" % w["id"], p], timeout=30)
    if not os.path.exists(p) or os.path.getsize(p) < 1000:
        sh(["screencapture", "-x", p], timeout=30)
    with open(os.path.join(OUT, "finestre.txt"), "a") as f:
        f.write("== %s\n%s\n" % (nome, "\n".join(json.dumps(x, ensure_ascii=False) for x in finestre(True) if "OrbitLR" in x["nome"] or x["livello"] in (0, 3, 8, 20, 101))))
    return p if os.path.exists(p) else None


def foto_png_vuota(p):
    """Una foto quasi tutta di un colore (finestra vuota?): restituisce la quota di pixel uguali al colore più frequente."""
    tmp = p + ".bmp"
    sh(["sips", "-s", "format", "bmp", "-Z", "200", p, "--out", tmp], timeout=30)
    try:
        data = open(tmp, "rb").read()
        off = int.from_bytes(data[10:14], "little")
        px = data[off:]
        from collections import Counter
        c = Counter(px[i:i + 3] for i in range(0, len(px) - 3, 3))
        top = c.most_common(1)[0][1] / max(1, sum(c.values()))
        os.remove(tmp)
        return round(top, 3)
    except Exception:
        return None


def testi_ax():
    """I testi visibili nelle finestre di OrbitLR via System Events (Accessibilità del runner)."""
    rc, o = sh(["osascript", "-e", '''tell application "System Events"
    if not (exists process "OrbitLR") then return "(OrbitLR non è aperta)"
    set r to ""
    tell process "OrbitLR"
      repeat with w in windows
        set r to r & "[finestra " & (name of w as text) & "] "
        try
          repeat with s in (static texts of entire contents of w)
            try
              set r to r & (value of s as text) & " | "
            end try
          end repeat
        end try
        try
          repeat with b in (buttons of w)
            set r to r & "<" & (name of b as text) & "> "
          end repeat
        end try
        set r to r & linefeed
      end repeat
    end tell
    return r
  end tell'''], timeout=60)
    return o


def menu(voce, menu_nome):
    rc, o = sh(["osascript", "-e", 'tell application "System Events" to tell process "OrbitLR"',
                "-e", "set frontmost to true",
                "-e", 'click menu item "%s" of menu "%s" of menu bar 1' % (voce, menu_nome), "-e", "end tell"], timeout=20)
    return rc == 0, o


def tasto(car, mod="command down"):
    return sh(["osascript", "-e", 'tell application "System Events" to keystroke "%s" using {%s}' % (car, mod)], timeout=15)


def campiona(secs=1):
    """`sample` del processo: quota del thread principale a riposo (mach_msg). None se non c'è il processo."""
    pid = pid_app()
    if not pid:
        return None, ""
    f = os.path.join(OUT, "sample-%d.txt" % int(time.time() * 10))
    rc, o = sh(["sample", str(pid), str(secs), "-file", f], timeout=secs + 40)
    try:
        text = open(f, errors="replace").read()
    except Exception:
        return None, o
    lines = text.split("\n")
    total, sec = 0, []
    for i, l in enumerate(lines):
        if "Thread_" in l and ("com.apple.main-thread" in l or "DispatchQueue_1" in l):
            m = re.match(r"^\s*(\d+)\s+Thread_", l)
            total = int(m.group(1)) if m else 0
            for l2 in lines[i + 1:]:
                if not l2.strip() or re.match(r"^\s*\d+\s+Thread_", l2):
                    break
                sec.append(l2)
            break
    if not total:
        return None, f
    idle = 0
    for l in sec:
        m = re.match(r"^[\s+!:|]*?(\d+)\s+(\S.*)$", l)
        if m and (m.group(2).startswith("mach_msg2_trap") or m.group(2).startswith("mach_msg_trap")):
            idle = max(idle, int(m.group(1)))
    return round(idle / total, 2), f


def raccogli():
    """Log dell'app, rapporti di crash e blocchi, rapporto del guardiano."""
    d = os.path.join(OUT, "log"); os.makedirs(d, exist_ok=True)
    for src in [LOG, HOME + "/Library/Logs/OrbitLR-aggiornamento.log"]:
        if os.path.exists(src):
            shutil.copy(src, d)
    for pat in [HOME + "/Library/Logs/DiagnosticReports/*OrbitLR*", "/Library/Logs/DiagnosticReports/*OrbitLR*",
                SUP + "/*.txt", SUP + "/*.json", HOME + "/Desktop/*OrbitLR*", HOME + "/Desktop/*rapporto*"]:
        for f in glob.glob(pat):
            try:
                if os.path.isfile(f) and os.path.getsize(f) < 5_000_000:
                    shutil.copy(f, d)
            except Exception:
                pass
    sh("defaults read %s > '%s/defaults.txt' 2>&1" % (BID, d))


def crash_nuovi(prima):
    now = set(glob.glob(HOME + "/Library/Logs/DiagnosticReports/*OrbitLR*") + glob.glob("/Library/Logs/DiagnosticReports/*OrbitLR*"))
    return sorted(now - set(prima))


def crash_elenco():
    return glob.glob(HOME + "/Library/Logs/DiagnosticReports/*OrbitLR*") + glob.glob("/Library/Logs/DiagnosticReports/*OrbitLR*")


def regola(folder, kind, action, param, exts=None, output="sub", rid=None):
    import uuid
    r = {"id": rid or str(uuid.uuid4()).upper(), "folder": folder, "kind": kind, "actionId": action, "param": param,
         "output": output, "outputPath": "", "enabled": True, "processed": 0}
    if exts:
        r["exts"] = exts
    return r


def scrivi_regole(regole):
    os.makedirs(SUP, exist_ok=True)
    with open(SUP + "/watch.json", "w") as f:
        json.dump(regole, f)
    try:
        os.remove(SUP + "/watch-seen.json")
    except FileNotFoundError:
        pass


def cronologia():
    try:
        return json.load(open(SUP + "/history.json"))
    except Exception:
        return []


def file_in(d, ext=None):
    if not os.path.isdir(d):
        return []
    return sorted(os.path.join(d, x) for x in os.listdir(d) if not x.startswith(".") and (ext is None or x.lower().endswith(ext)))


def clicca(nome, ruoli=("button", "radio button", "checkbox")):
    """Clic su un controllo di OrbitLR per nome o descrizione: prima AXPress diretto, poi System Events."""
    pid = pid_app()
    if pid:
        rc, o = sh([STRUM, "premi", str(pid), nome], timeout=60)
        if rc == 0:
            return True
    for ruolo in ruoli:
        rc, o = sh(["osascript", "-e", '''tell application "System Events" to tell process "OrbitLR"
  set frontmost to true
  repeat with w in windows
    try
      set cs to (every %s of entire contents of w)
      repeat with c in cs
        set n to ""
        try
          set n to name of c as text
        end try
        set d to ""
        try
          set d to description of c as text
        end try
        set v to ""
        try
          set v to value of c as text
        end try
        if n is "%s" or d is "%s" or v is "%s" then
          click c
          return "cliccato"
        end if
      end repeat
    end try
  end repeat
  return "non trovato"
end tell''' % (ruolo, nome, nome, nome)], timeout=90)
        if "cliccato" in o:
            return True
    return False


def lavoro_app(es, cosa, regole_file, attesa=120, atteso_n=None, uscita_ext=None, pulisci=True):
    """Fa lavorare l'app vera con le «Cartelle automatiche»: regole = [(regola, [file da copiare dentro])].
    L'app deve essere chiusa; la apre, copia i file, aspetta i risultati nella sottocartella «Convertiti».
    Restituisce {cartella: [file creati]}."""
    if pid_app():
        chiudi_app(cortese=False)
    scrivi_regole([r for r, _ in regole_file])
    apri_app(attesa=40)
    time.sleep(4)
    for r, files in regole_file:
        os.makedirs(r["folder"], exist_ok=True)
        for f in files:
            shutil.copy(f, r["folder"])
    res = {}

    def pronto():
        tutto = True
        for r, files in regole_file:
            fatti = [x for sub in ("Convertiti", "Converted") for x in file_in(os.path.join(r["folder"], sub))
                     if not x.endswith((".tmp", ".part", ".download"))]
            res[r["folder"]] = fatti
            n = atteso_n if atteso_n is not None else len(files)
            if len(fatti) < n:
                tutto = False
        return tutto
    aspetta(pronto, attesa, 2)
    time.sleep(3)
    if not pronto():
        diagnosi_regole(regole_file)
    return res


def diagnosi_regole(regole_file):
    """Nel registro: cosa c'è nelle cartelle, regole, cronologia, registro dell'app (per capire un «non crea niente»)."""
    say("DIAGNOSI cartelle automatiche: app aperta=%s" % pid_app())
    for r, files in regole_file:
        say("  cartella", r["folder"], "->", sh(["ls", "-laR", r["folder"]])[1][-600:].replace("\n", " ¶ "))
    for n in ["watch.json", "watch-seen.json"]:
        try:
            say("  " + n, open(SUP + "/" + n).read()[:600])
        except Exception as e:
            say("  " + n, e)
    say("  cronologia", json.dumps(cronologia()[:3], ensure_ascii=False)[:800])
    try:
        say("  log app", open(LOG, errors="replace").read()[-1500:].replace("\n", " ¶ "))
    except Exception as e:
        say("  log app", e)
    say("  testi", testi_ax()[:800].replace("\n", " ¶ "))
    say("  defaults", sh("defaults read %s | head -c 1200" % BID)[1].replace("\n", " "))


def ax_controlli(nome):
    """Elenco dei controlli della finestra (AXUIElement). None se il processo non è autorizzato."""
    pid = pid_app()
    if not pid:
        return None
    p = os.path.join(OUT, "ax-%s.json" % nome)
    rc, o = sh([STRUM, "ax", str(pid), p], timeout=180)
    if rc == 3:
        return None
    try:
        return json.load(open(p))["controlli"]
    except Exception:
        return []


def controlla_vista(es, nome, livello_cosa):
    """Foto + controlli: finestra vuota, controlli tagliati ai lati, controlli sovrapposti."""
    w = finestra_principale()
    p = foto(nome)
    if not w:
        es.bug(livello_cosa, "Finestra principale assente: %s" % nome, "alto", "finestra visibile", "nessuna finestra", "foto %s.png" % nome)
        return
    q = foto_png_vuota(p) if p else None
    ctr = ax_controlli(nome)
    risultato = {"finestra": w, "uniforme": q, "controlli": None if ctr is None else len(ctr)}
    if q is not None and q > 0.97:
        es.confuso(livello_cosa, "la foto %s.png è quasi tutta di un colore (%.0f%%): vista vuota?" % (nome, q * 100))
    if ctr is None:
        es.d.setdefault("_ax_non_autorizzato", True)
        es.ok(livello_cosa, "foto %s.png (controlli non leggibili: processo non autorizzato)" % nome)
        return risultato
    x0, x1, y0, y1 = w["x"], w["x"] + w["l"], w["y"], w["y"] + w["a"]
    vis = [c for c in ctr if c["l"] > 2 and c["a"] > 2 and y0 <= c["y"] <= y1 - 4]
    tagli = [c for c in vis if (c["x"] < x0 - 1 or c["x"] + c["l"] > x1 + 1) and c["x"] < x1 and c["x"] + c["l"] > x0]
    sovr = []
    bott = [c for c in vis if c["ruolo"] in ("AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton") and x0 <= c["x"] < x1]
    for i in range(len(bott)):
        for j in range(i + 1, len(bott)):
            a, b = bott[i], bott[j]
            ix = max(0, min(a["x"] + a["l"], b["x"] + b["l"]) - max(a["x"], b["x"]))
            iy = max(0, min(a["y"] + a["a"], b["y"] + b["a"]) - max(a["y"], b["y"]))
            small = min(a["l"] * a["a"], b["l"] * b["a"])
            contiene = (a["x"] <= b["x"] and a["y"] <= b["y"] and a["x"] + a["l"] >= b["x"] + b["l"] and a["y"] + a["a"] >= b["y"] + b["a"]) or \
                       (b["x"] <= a["x"] and b["y"] <= a["y"] and b["x"] + b["l"] >= a["x"] + a["l"] and b["y"] + b["a"] >= a["y"] + a["a"])
            if small > 0 and ix * iy > 0.5 * small and not contiene and a["percorso"] not in b["percorso"] and b["percorso"] not in a["percorso"]:
                sovr.append((a.get("titolo") or a.get("descrizione"), b.get("titolo") or b.get("descrizione"), a["x"], a["y"]))
    risultato.update(tagliati=len(tagli), sovrapposti=len(sovr))
    if tagli:
        es.bug(livello_cosa, "Controlli tagliati dal bordo della finestra (%s)" % nome, "basso",
               "tutti i controlli dentro la finestra larga %d" % w["l"],
               "%d controlli escono dai lati: %s" % (len(tagli), [(c["ruolo"], c["titolo"] or c["descrizione"], c["x"] - x0, c["l"]) for c in tagli[:8]]),
               "foto/%s.png, ax-%s.json" % (nome, nome))
    elif sovr:
        es.confuso(livello_cosa, "%d coppie di pulsanti sovrapposti in %s: %s (vedi foto/%s.png)" % (len(sovr), nome, sovr[:5], nome))
        es.ok(livello_cosa, "nessun controllo tagliato")
    else:
        es.ok(livello_cosa, "%d controlli, nessuno tagliato o sovrapposto" % len(vis))
    return risultato
