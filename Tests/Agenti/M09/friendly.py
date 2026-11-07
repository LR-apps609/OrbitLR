#!/usr/bin/env python3
"""M09 · Copia fedele di MusicLink.friendly / percent / link (Sources/MusicLink.swift 30-35, 100-124) per
sapere quale frase vede l'utente dato lo stderr vero di yt-dlp. Uso: friendly.py <file.err>"""
import re, sys
def friendly(stderr):
    s = stderr.lower()
    if "drm" in s: return "Questo sito protegge i suoi contenuti (DRM): non si possono scaricare."
    if "unsupported url" in s: return "Da questo link non so prendere l’audio. Prova con il link diretto della canzone."
    if "not a bot" in s or "confirm you" in s: return "YouTube chiede di confermare che non sei un robot: ..."
    if any(k in s for k in ("private", "sign in", "login", "members")): return "Il contenuto è privato o richiede l’accesso: non si può scaricare."
    if any(k in s for k in ("not available", "unavailable", "removed")): return "Il contenuto non è più disponibile."
    if "403" in s or "429" in s: return "Il sito ha rifiutato la richiesta. Riprova tra un po’: intanto aggiorno il motore."
    if any(k in s for k in ("unable to download", "network", "timed out", "resolve")): return "Non riesco a collegarmi: controlla internet e riprova."
    return "Non sono riuscito a scaricare l’audio da questo link."
def percents(text):
    out = []
    for line in re.split(r"[\r\n]", text):
        if "[download]" in line:
            m = re.search(r"(\d{1,3}(?:\.\d+)?)%", line)
            if m: out.append(min(1, float(m.group(1)) / 100))
    return out
if __name__ == "__main__":
    err = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    out = open(sys.argv[1][:-4] + ".out", encoding="utf-8", errors="replace").read()
    p = percents(out + "\n" + err)
    print("frase per l'utente:", friendly(err))
    print("valori di avanzamento letti:", len(p), "ultimo:", p[-1] if p else None)
