#!/usr/bin/env python3
"""M03 · Controlla le uscite del motore: durata, rotazione, proporzioni, audio sì/no, peso, HDR.
Uso: controlla.py USCITA FIXTURE FFPROBE FFMPEG ETICHETTA"""
import json, os, subprocess, sys, glob
OUT, FIX, FFPROBE, FFMPEG, LABEL = sys.argv[1:6]
cache = {}
def probe(p):
    if p in cache: return cache[p]
    try:
        r = subprocess.run([FFPROBE, "-v", "error", "-show_format", "-show_streams", "-of", "json", p], capture_output=True, text=True, timeout=120)
        j = json.loads(r.stdout or "{}")
    except Exception as e:
        j = {"errore": str(e)}
    info = {"size": os.path.getsize(p) if os.path.exists(p) else 0}
    fmt = j.get("format", {})
    try: info["dur"] = float(fmt.get("duration"))
    except Exception: info["dur"] = None
    info["fmt"] = fmt.get("format_name")
    v = [s for s in j.get("streams", []) if s.get("codec_type") == "video" and not s.get("disposition", {}).get("attached_pic")]
    a = [s for s in j.get("streams", []) if s.get("codec_type") == "audio"]
    sub = [s for s in j.get("streams", []) if s.get("codec_type") == "subtitle"]
    info["audio"] = bool(a); info["acodec"] = a[0].get("codec_name") if a else None
    info["subs"] = len(sub)
    if v:
        s = v[0]; rot = 0
        for sd in s.get("side_data_list", []) or []:
            if "rotation" in sd: rot = int(round(float(sd["rotation"])))
        if not rot and s.get("tags", {}).get("rotate"): rot = int(s["tags"]["rotate"])
        w, h = s.get("width"), s.get("height")
        dw, dh = (h, w) if abs(rot) % 180 == 90 else (w, h)
        info.update(video=True, vcodec=s.get("codec_name"), w=w, h=h, rot=rot, dw=dw, dh=dh, pix=s.get("pix_fmt"),
                    trc=s.get("color_transfer"), prim=s.get("color_primaries"), fps=s.get("avg_frame_rate"))
        try:
            if s.get("duration") and (info["dur"] is None): info["dur"] = float(s["duration"])
        except Exception: pass
    else:
        info["video"] = False
    cache[p] = info
    return info

def near(a, b, tol_abs=0.35, tol_rel=0.03):
    return a is not None and b is not None and abs(a - b) <= max(tol_abs, tol_rel * b)

rows = []
for line in open(os.path.join(OUT, "grezzi.tsv"), encoding="utf-8"):
    n, act, param, f1, rc, secs = line.rstrip("\n").split("\t")
    J = os.path.join(OUT, "j" + n)
    std = open(os.path.join(J, "stdout.txt"), encoding="utf-8", errors="replace").read().splitlines()
    status = [l.split("\t") for l in std if l.split("\t")[0] in ("OK", "FAIL", "NOTE", "MISSING", "CANCEL", "END")]
    outs = [l.split("\t", 1)[1] for l in std if l.startswith("OUT\t")]
    src = os.path.join(FIX, f1)
    s = probe(src)
    kind = [x[0] for x in status if x[0] != "END"]
    msg = " | ".join("\t".join(x[2:]) for x in status if x[0] in ("FAIL", "NOTE", "OK") and len(x) > 2 and x[2])
    prob = []   # problemi trovati
    expect_fail = (not s.get("video") and act not in ("to:mp3", "to:m4a", "normalize", "voiceclean", "strip", "cut", "speed")) \
                  or (not s.get("audio") and act in ("to:mp3", "to:m4a", "normalize", "voiceclean")) \
                  or s.get("dur") is None
    o = probe(outs[0]) if outs else None
    if int(rc) == 142 or int(rc) >= 128: prob.append(f"interrotto/crash (rc={rc})")
    if not status: prob.append("nessuna riga di stato dal motore")
    if "FAIL" in kind and not expect_fail: prob.append("FAIL inatteso")
    if expect_fail and "OK" in kind: prob.append("OK su un file che non può riuscire")
    if "FAIL" in kind and expect_fail and any(("Invalid data" in m or "moov atom" in m or "Error" in m) for m in [msg]):
        prob.append("messaggio tecnico invece di uno comprensibile")
    if "OK" in kind and not outs: prob.append("OK senza file creato")
    for p in outs:
        if not os.path.exists(p) or os.path.getsize(p) == 0: prob.append(f"uscita vuota/mancante: {os.path.basename(p)}")
    if o and "OK" in kind:
        sd, od = s.get("dur"), o.get("dur")
        exp_d = sd
        if act == "cut":
            a_, _, b_ = param.partition("|"); a_ = float(a_)
            b_ = float(b_) if b_ else sd
            exp_d = min(b_, sd) - a_
        elif act == "gifcut":
            a_, _, b_ = param.partition("|"); exp_d = min(float(b_), sd) - float(a_)
        elif act == "speed":
            exp_d = sd / float(param)
        if act == "subembed": exp_d = sd
        if exp_d is not None and od is not None and not near(od, exp_d, tol_abs=0.4 if act != "speed" else 0.5, tol_rel=0.05 if act == "speed" else 0.03):
            prob.append(f"durata {od:.2f}s, attesa {exp_d:.2f}s")
        if od is None: prob.append("durata non leggibile nell'uscita")
        # audio sì/no
        if act in ("to:gif", "gifcut"):
            if o.get("audio"): prob.append("GIF con audio?")
            if o.get("vcodec") != "gif": prob.append(f"codec {o.get('vcodec')} invece di gif")
        elif act in ("to:mp3", "to:m4a"):
            if not o.get("audio"): prob.append("nessun audio nell'estrazione audio")
            if o.get("video"): prob.append("video rimasto nel file solo audio")
        else:
            if s.get("audio") and not o.get("audio"): prob.append("audio perso")
            if not s.get("audio") and o.get("audio"): prob.append("traccia audio aggiunta dal nulla")
            if s.get("video") and not o.get("video"): prob.append("video perso")
        # orientamento e proporzioni come si vedono
        if s.get("video") and o.get("video") and s.get("dw") and o.get("dw"):
            sa, oa = s["dw"] / s["dh"], o["dw"] / o["dh"]
            if (sa > 1) != (oa > 1) and abs(sa - 1) > 0.05: prob.append(f"orientamento cambiato: {s['dw']}x{s['dh']} → {o['dw']}x{o['dh']} (rot {o.get('rot')})")
            elif abs(sa - oa) / sa > 0.03: prob.append(f"proporzioni cambiate: {sa:.3f} → {oa:.3f}")
            if act == "vresize" and param.isdigit():
                short = min(o["dw"], o["dh"]); exp = min(int(param), min(s["dw"], s["dh"]))
                if abs(short - exp) > 2: prob.append(f"lato corto {short}, atteso {exp}")
            if act == "to:gif" and max(o["w"], o["h"]) > 720 and o["w"] > 720: prob.append(f"GIF larga {o['w']} (limite 720)")
            # HDR: se diventa 8 bit ma resta marcato HLG/PQ, i colori si vedono sbagliati
            if s.get("trc") in ("arib-std-b67", "smpte2084") and o.get("pix") in ("yuv420p", "nv12", "yuvj420p") and o.get("trc") in ("arib-std-b67", "smpte2084"):
                prob.append(f"HDR: uscita 8 bit ({o.get('vcodec')} {o.get('pix')}) ancora marcata {o.get('trc')}")
            if s.get("trc") in ("arib-std-b67", "smpte2084") and o.get("pix") in ("yuv420p", "nv12") and o.get("trc") not in ("arib-std-b67", "smpte2084"):
                prob.append(f"HDR→SDR: uscita {o.get('vcodec')} {o.get('pix')} trc={o.get('trc')} prim={o.get('prim')} (controllare i colori)")
        if act == "vcompress" and param.isdigit() and o["size"] > int(param) * 1048576:
            prob.append(f"peso {o['size']/1048576:.2f} MB oltre {param} MB")
        if act == "vresize" and param == "hevc":
            if o.get("vcodec") != "hevc": prob.append(f"codec {o.get('vcodec')} invece di hevc")
            if o["size"] >= s["size"]: prob.append("HEVC più pesante dell'originale")
        if act == "subembed" and not o.get("subs"): prob.append("nessuna traccia di sottotitoli")
        if act.startswith("to:"):
            t = act[3:]
            want = {"mp4": "mov,mp4", "mov": "mov,mp4", "mkv": "matroska", "webm": "matroska", "gif": "gif", "mp3": "mp3", "m4a": "mov,mp4"}[t]
            if o.get("fmt") and want not in o["fmt"]: prob.append(f"contenitore {o['fmt']}")
            if t == "webm" and o.get("vcodec") not in ("vp8", "vp9", "av1"): prob.append(f"WebM con video {o.get('vcodec')}")
            if t == "webm" and o.get("acodec") not in (None, "opus", "vorbis"): prob.append(f"WebM con audio {o.get('acodec')}")
    rows.append(dict(n=int(n), azione=act, param=param, file=f1, rc=int(rc), secondi=float(secs), stato=kind, messaggio=msg,
                     sorgente={k: s.get(k) for k in ("size", "dur", "w", "h", "rot", "dw", "dh", "vcodec", "acodec", "pix", "trc", "fps")},
                     uscita=None if not o else {k: o.get(k) for k in ("size", "dur", "w", "h", "rot", "dw", "dh", "vcodec", "acodec", "pix", "trc", "prim", "fps", "subs", "fmt")},
                     nome_uscita=[os.path.basename(p) for p in outs], problemi=prob))
    # fotogramma per gli HDR e i verticali (per guardarli)
    if o and o.get("video") and ("hdr" in f1 or "verticale" in f1) and outs:
        fr = os.path.join(OUT, "fotogrammi"); os.makedirs(fr, exist_ok=True)
        subprocess.run([FFMPEG, "-nostdin", "-loglevel", "error", "-y", "-ss", "0.5", "-i", outs[0], "-frames:v", "1", "-vf", "scale=360:-2",
                        os.path.join(fr, f"j{n}-{act.replace(':','_')}-{param.replace('|','_')}-{os.path.basename(f1)}.png")], timeout=120)
fr = os.path.join(OUT, "fotogrammi"); os.makedirs(fr, exist_ok=True)
for f in ("hdr10bit.mov", "verticale.mov"):
    if os.path.exists(os.path.join(FIX, f)):
        subprocess.run([FFMPEG, "-nostdin", "-loglevel", "error", "-y", "-ss", "0.5", "-i", os.path.join(FIX, f), "-frames:v", "1", "-vf", "scale=360:-2",
                        os.path.join(fr, f"sorgente-{f}.png")], timeout=120)
json.dump(dict(etichetta=LABEL, lavori=rows), open(os.path.join(OUT, "verdetti.json"), "w"), ensure_ascii=False, indent=1)
bad = [r for r in rows if r["problemi"]]
with open(os.path.join(OUT, "riepilogo.txt"), "w") as fh:
    fh.write(f"{LABEL}: {len(rows)} lavori, {len(rows)-len(bad)} senza problemi, {len(bad)} con problemi\n\n")
    for r in rows:
        u = r["uscita"] or {}
        fh.write(f"{r['n']:3d} {r['azione']:<10} {r['param']:<14} {r['file'][:34]:<34} rc={r['rc']} {r['secondi']:7.2f}s {','.join(r['stato']):<6} "
                 f"{(u.get('dur') or 0):7.2f}s {u.get('dw')}x{u.get('dh')} rot={u.get('rot')} a={u.get('acodec')} v={u.get('vcodec')} {(u.get('size') or 0)/1048576:.2f}MB"
                 f" {'!! ' + '; '.join(r['problemi']) if r['problemi'] else ''} {('« ' + r['messaggio'][:150] + ' »') if r['messaggio'] else ''}\n")
print(open(os.path.join(OUT, "riepilogo.txt")).read())
