#!/usr/bin/env python3
# M02 · Prove dei PDF e dei documenti sul motore LRConverter.zsh (modalità --run, come l'app).
# Uso: python3 suite.py <LRConverter.zsh> <cartella di lavoro> <pdf|doc> <etichetta build>
import os, sys, subprocess, time, json, hashlib, shutil, signal, unicodedata, zipfile, io

ENGINE, ROOT, MODE, BUILD = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
FX = os.path.join(ROOT, "fixtures")
OUT = os.path.join(ROOT, "out")
RES = os.path.join(ROOT, f"risultati-{MODE}.json")
os.makedirs(FX, exist_ok=True); os.makedirs(OUT, exist_ok=True)
RECS = []
N = [0]
T_BEGIN = time.time()
BUDGET = float(os.environ.get("M02_BUDGET", "1900"))  # secondi per tutte le prove (il lavoro ha 45 minuti)

from pypdf import PdfReader, PdfWriter
from PIL import Image, ImageDraw, ImageFont

def F(name): return os.path.join(FX, name)
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f: h.update(f.read())
    return h.hexdigest()

def save():
    with open(RES, "w") as f: json.dump({"build": BUILD, "mode": MODE, "records": RECS}, f, ensure_ascii=False, indent=1)

# ─── Fixtures ───────────────────────────────────────────────────────
def font(sz):
    for p in ["/System/Library/Fonts/Supplemental/Arial.ttf", "/System/Library/Fonts/Helvetica.ttc",
              "/Library/Fonts/Arial.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]:
        if os.path.exists(p):
            try: return ImageFont.truetype(p, sz)
            except Exception: pass
    return ImageFont.load_default()

SCAN_LINES = ["FATTURA NUMERO 12345", "CLIENTE ROSSI MARIO", "TOTALE EURO 250"]

def scan_image(path, page_no, fmt="JPEG"):
    im = Image.new("L", (1654, 2339), 255)
    d = ImageDraw.Draw(im); f = font(64)
    y = 200
    for l in SCAN_LINES + [f"PAGINA {page_no}"]:
        d.text((150, y), l, fill=0, font=f); y += 140
    im.save(path, fmt, quality=92) if fmt == "JPEG" else im.save(path, fmt)

def make_pdf_fixtures():
    from reportlab.pdfgen import canvas
    from reportlab.lib.pagesizes import A4, A3, letter, landscape
    c = canvas.Canvas(F("uno.pdf"), pagesize=A4)
    c.setFont("Helvetica", 18); c.drawString(72, 750, "Pagina uno OrbitLR prova citta perche")
    c.drawString(72, 720, "Seconda riga del documento di prova numero 4242"); c.showPage(); c.save()

    c = canvas.Canvas(F("trecento.pdf"), pagesize=A4)
    for i in range(1, 301):
        c.setFont("Helvetica", 16); c.drawString(72, 750, f"Pagina {i} di 300")
        c.setFont("Helvetica", 10)
        for k in range(30): c.drawString(72, 700 - k * 18, f"Riga {k} della pagina {i}: testo di riempimento per avere un PDF realistico.")
        c.showPage()
    c.save()

    imgs = []
    for i in range(1, 4):
        p = F(f"_scan{i}.jpg"); scan_image(p, i); imgs.append(p)
    c = canvas.Canvas(F("scansione.pdf"), pagesize=A4)
    for p in imgs: c.drawImage(p, 0, 0, width=A4[0], height=A4[1]); c.showPage()
    c.save()
    # 40 pagine scansionate, ognuna con un'immagine diversa (per i tempi dell'OCR)
    c = canvas.Canvas(F("scansione40.pdf"), pagesize=A4)
    for i in range(1, 41):
        p = F(f"_s40_{i}.jpg"); scan_image(p, i)
        c.drawImage(p, 0, 0, width=A4[0], height=A4[1]); c.showPage(); os.remove(p)
    c.save()

    c = canvas.Canvas(F("modulo.pdf"), pagesize=A4)
    c.setFont("Helvetica", 14); c.drawString(72, 760, "Modulo di prova")
    c.acroForm.textfield(name="nome", tooltip="Nome", x=72, y=700, width=300, height=24, value="Mario")
    c.acroForm.checkbox(name="accetto", x=72, y=650, size=20, checked=True)
    c.showPage()
    c.drawString(72, 760, "Seconda pagina del modulo")
    c.acroForm.textfield(name="citta", x=72, y=700, width=300, height=24, value="Napoli")
    c.showPage(); c.save()

    c = canvas.Canvas(F("misto.pdf"))
    for size, label in [(A4, "A4 verticale"), (landscape(A4), "A4 orizzontale"), (letter, "Letter ruotata"),
                        (A3, "A3"), ((252, 144), "biglietto")]:
        c.setPageSize(size); c.setFont("Helvetica", 12); c.drawString(20, size[1] - 40, label); c.showPage()
    c.save()
    r = PdfReader(F("misto.pdf")); w = PdfWriter()
    for i, pg in enumerate(r.pages):
        if i == 2: pg.rotate(90)
        w.add_page(pg)
    with open(F("misto.pdf"), "wb") as f: w.write(f)

    c = canvas.Canvas(F("grande.pdf"), pagesize=(14400, 14400))
    c.setFont("Helvetica", 400); c.drawString(500, 13000, "PAGINA ENORME 777"); c.rect(100, 100, 14200, 14200); c.showPage(); c.save()

    w = PdfWriter()
    with open(F("zero.pdf"), "wb") as f: w.write(f)

    for name, kw in [("protetto.pdf", dict(user_password="segreta", owner_password="segreta", algorithm="AES-256")),
                     ("protetto_rc4.pdf", dict(user_password="segreta", owner_password="segreta", algorithm="RC4-128")),
                     ("solo_proprietario.pdf", dict(user_password="", owner_password="capo", algorithm="AES-128",
                                                   permissions_flag=0))]:
        r = PdfReader(F("uno.pdf")); w = PdfWriter()
        for pg in r.pages: w.add_page(pg)
        w.encrypt(**kw)
        with open(F(name), "wb") as f: w.write(f)

    data = open(F("uno.pdf"), "rb").read()
    open(F("rotto.pdf"), "wb").write(data[: int(len(data) * 0.6)])
    data = open(F("trecento.pdf"), "rb").read()
    open(F("trecento_troncato.pdf"), "wb").write(data[: len(data) // 2])
    open(F("vuoto.pdf"), "wb").close()
    open(F("finto.pdf"), "w").write("questo non è un PDF, è solo testo\n" * 20)
    open(F("solo_intestazione.pdf"), "wb").write(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")

    shutil.copy(F("uno.pdf"), F("Fattura è perché – città.pdf"))
    shutil.copy(F("uno.pdf"), F(unicodedata.normalize("NFD", "Caffè NFD già.pdf")))
    shutil.copy(F("uno.pdf"), F("doppio  spazio 'apice' $HOME & (1).pdf"))
    shutil.copy(F("uno.pdf"), F("-inizia-col-trattino.pdf"))

    scan_image(F("foto.png"), 1, "PNG")
    scan_image(F("foto.jpg"), 2, "JPEG")
    if shutil.which("sips"): subprocess.run(["sips", "-s", "format", "heic", F("foto.jpg"), "--out", F("foto.heic")], capture_output=True)

def make_doc_fixtures():
    import docx, openpyxl, pptx
    d = docx.Document(); d.add_heading("Titolo di prova", 1)
    d.add_paragraph("Testo con accenti: città perché è già più € 4242")
    t = d.add_table(rows=2, cols=2); t.cell(0, 0).text = "Nome"; t.cell(0, 1).text = "Città"; t.cell(1, 0).text = "Mario"; t.cell(1, 1).text = "Napoli"
    d.save(F("documento.docx"))
    wb = openpyxl.Workbook(); ws = wb.active; ws.title = "Foglio"
    ws.append(["Prodotto", "Città", "Prezzo €"]); ws.append(["Caffè", "Napoli", 2.5]); ws.append(["Tè", "Perché", 3])
    wb.create_sheet("Secondo").append(["seconda scheda"])
    wb.save(F("foglio.xlsx"))
    pr = pptx.Presentation(); s = pr.slides.add_slide(pr.slide_layouts[1])
    s.shapes.title.text = "Diapositiva città"; s.placeholders[1].text = "perché è già più € 4242"
    pr.slides.add_slide(pr.slide_layouts[1]).shapes.title.text = "Seconda diapositiva"
    pr.save(F("presentazione.pptx"))
    open(F("testo.txt"), "w", encoding="utf-8").write("Testo con accenti: città perché è già più € 4242\nSeconda riga\n")
    open(F("testo_latin1.txt"), "wb").write("Testo latin1: città perché 4242\n".encode("latin-1"))
    open(F("nota.md"), "w", encoding="utf-8").write("# Titolo città\n\nTesto *perché* è già più € 4242\n\n- uno\n- due\n\n| a | b |\n|---|---|\n| è | à |\n")
    open(F("dati.csv"), "w", encoding="utf-8").write("Prodotto,Città,Prezzo\nCaffè,Napoli,2.5\nTè,Perché,3\n")
    open(F("dati_puntoevirgola.csv"), "w", encoding="utf-8").write("Prodotto;Città;Prezzo\nCaffè;Napoli;2,5\n")
    b = open(F("documento.docx"), "rb").read()
    open(F("rotto.docx"), "wb").write(b[: len(b) // 2])
    open(F("vuoto.docx"), "wb").close()
    open(F("vuoto.xlsx"), "wb").close()
    shutil.copy(F("documento.docx"), F("Relazione è già – città.docx"))
    from reportlab.pdfgen import canvas
    from reportlab.lib.pagesizes import A4
    c = canvas.Canvas(F("uno.pdf"), pagesize=A4); c.setFont("Helvetica", 18)
    c.drawString(72, 750, "Pagina uno OrbitLR prova citta perche"); c.drawString(72, 720, "Seconda riga 4242"); c.showPage(); c.save()
    im = F("_s.jpg"); scan_image(im, 1)
    c = canvas.Canvas(F("scansione.pdf"), pagesize=A4); c.drawImage(im, 0, 0, width=A4[0], height=A4[1]); c.showPage(); c.save()
    os.remove(im)

# ─── Esecuzione ─────────────────────────────────────────────────────
def listing(d):
    out = []
    for root, dirs, files in os.walk(d):
        for f in files: out.append(os.path.relpath(os.path.join(root, f), d))
    return sorted(out)

def run(case, act, param, files, secret=None, dest=True, timeout=600, note=""):
    N[0] += 1
    rec = {"n": N[0], "case": case, "act": act, "param": param, "files": [os.path.basename(x) for x in files],
           "note": note, "checks": []}
    if time.time() - T_BEGIN > BUDGET:
        rec["skipped"] = "tempo finito"; RECS.append(rec); save(); return rec
    d = os.path.join(OUT, f"{N[0]:03d}-{case}-{act.replace(':', '_')}")
    os.makedirs(d, exist_ok=True)
    env = dict(os.environ)
    env.pop("LR_DESTPATH", None); env.pop("LR_SECRET", None)
    if dest: env["LR_DESTPATH"] = d
    if secret is not None: env["LR_SECRET"] = secret; param = "-"
    srcdirs = sorted({os.path.dirname(x) for x in files})
    before = {x: sha(x) for x in files if os.path.isfile(x)}
    lst_before = {s: listing(s) for s in srcdirs}
    t0 = time.time()
    p = subprocess.Popen(["/bin/zsh", ENGINE, "--run", act, param] + files, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env, start_new_session=True)
    try:
        so, se = p.communicate(timeout=timeout); rec["hang"] = False
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL); so, se = p.communicate(); rec["hang"] = True
    rec["secs"] = round(time.time() - t0, 1)
    rec["rc"] = p.returncode
    so = so.decode("utf-8", "replace"); se = se.decode("utf-8", "replace")
    rec["stderr_tail"] = se[-1500:]
    lines = [l.split("\t") for l in so.splitlines() if l and not l.startswith("P\t")]
    rec["lines"] = ["\t".join(l) for l in lines]
    rec["outs"] = [l[1] for l in lines if l[0] == "OUT"]
    rec["fails"] = [l[2] if len(l) > 2 else "" for l in lines if l[0] == "FAIL"]
    rec["notes"] = [l[2] if len(l) > 2 else "" for l in lines if l[0] == "NOTE"]
    rec["oks"] = [l[2] if len(l) > 2 else "" for l in lines if l[0] == "OK"]
    rec["missing"] = [l[1] for l in lines if l[0] == "MISSING"]
    rec["end"] = [l for l in lines if l[0] == "END"]
    rec["originals_same"] = all(os.path.isfile(x) and sha(x) == h for x, h in before.items())
    if dest:
        rec["source_dir_same"] = all(listing(s) == lst_before[s] for s in srcdirs)
    rec["dest"] = d
    ck(rec, not rec["hang"], "nessun blocco (finito entro %d s)" % timeout)
    ck(rec, rec["originals_same"], "originali non modificati")
    if dest: ck(rec, rec.get("source_dir_same", True), "nessun file nuovo/tolto nella cartella degli originali")
    ck(rec, len(rec["end"]) == 1, "riga END presente", rec["end"])
    RECS.append(rec); save()
    print(f"[{rec['n']:03d}] {case:28s} {act:12s} {param!s:14s} {rec['secs']:7.1f}s rc={rec['rc']} "
          f"outs={len(rec['outs'])} fails={rec['fails']} notes={rec['notes']} miss={rec['missing']}", flush=True)
    return rec

def ck(rec, ok, desc, detail=None):
    rec["checks"].append({"ok": bool(ok), "desc": desc, "detail": None if detail is None else str(detail)[:600]})
    if not ok: print(f"      ✗ {desc} {'' if detail is None else str(detail)[:300]}", flush=True)
    save()

def npages(p):
    try:
        r = PdfReader(p)
        if r.is_encrypted: r.decrypt("")
        return len(r.pages)
    except Exception as e: return f"err:{e}"

def ptext(p, i=None, pw=None):
    try:
        r = PdfReader(p)
        if r.is_encrypted: r.decrypt(pw or "")
        pages = r.pages if i is None else [r.pages[i]]
        return "\n".join((pg.extract_text() or "") for pg in pages)
    except Exception as e: return f"err:{e}"

def fields(p):
    try:
        f = PdfReader(p).get_fields() or {}
        return sorted(f.keys())
    except Exception as e: return f"err:{e}"

def widgets(p):
    try:
        n = 0
        for pg in PdfReader(p).pages:
            for a in pg.get("/Annots") or []:
                if a.get_object().get("/Subtype") == "/Widget": n += 1
        return n
    except Exception as e: return f"err:{e}"

def one_out(rec, ext=None):
    o = [x for x in rec["outs"] if os.path.exists(x)]
    if ext: o = [x for x in o if x.lower().endswith(ext)]
    return o[0] if len(o) == 1 else None

def files_in(d, ext):
    return sorted(os.path.join(d, x) for x in os.listdir(d) if x.lower().endswith(ext)) if d and os.path.isdir(d) else []

def expect_fail(rec, words, desc):
    msg = " | ".join(rec["fails"])
    ck(rec, len(rec["outs"]) == 0, f"{desc}: nessun file creato", rec["outs"])
    ck(rec, len(rec["fails"]) >= 1, f"{desc}: segnala un errore (FAIL)", rec["lines"])
    if words:
        ck(rec, any(w.lower() in msg.lower() for w in words), f"{desc}: messaggio chiaro (atteso uno di {words})", msg)

# ─── Sequenze PDF ───────────────────────────────────────────────────
def pdf_suite():
    make_pdf_fixtures()
    for n in ["uno", "trecento", "scansione", "scansione40", "modulo", "misto", "grande", "zero"]:
        print("fixture", n, npages(F(n + ".pdf")), os.path.getsize(F(n + ".pdf")))
    gs_before = shutil.which("gs")
    print("gs presente prima dell'installazione:", gs_before)

    # Riscaldamento: la prima azione compila il programma nativo
    r = run("uno", "pdftext", "", [F("uno.pdf")], timeout=600, note="prima azione: compila lrhelper")
    o = one_out(r, ".txt")
    ck(r, o and "Pagina uno" in open(o, encoding="utf-8").read(), "testo estratto contiene «Pagina uno»", o)

    # Compressione senza Ghostscript (se non c'è)
    if not gs_before and not os.environ.get("M02_GS"):
        r = run("uno", "pdfcompress", "medium", [F("scansione.pdf")], note="senza Ghostscript")
        ck(r, r["missing"] or r["fails"], "senza Ghostscript: dice cosa manca", r["lines"])

    # ── uno.pdf, tutte le azioni
    r = run("uno", "to:png", "", [F("uno.pdf")]); o = one_out(r, ".png")
    ck(r, o is not None, "una sola immagine PNG", r["outs"])
    if o: im = Image.open(o); ck(r, abs(im.size[0] - 1654) <= 2 and abs(im.size[1] - 2339) <= 2, "PNG A4 a 200 dpi (1654×2339)", im.size)
    r = run("uno", "to:jpg", "", [F("uno.pdf")]); o = one_out(r, ".jpg")
    ck(r, o is not None and Image.open(o).format == "JPEG", "un JPG vero", r["outs"])
    r = run("uno", "split", "", [F("uno.pdf")])
    d = r["outs"][0] if r["outs"] else None
    ck(r, d and os.path.isdir(d) and len(files_in(d, ".pdf")) == 1, "split: cartella con 1 PDF", d and listing(d))
    r = run("uno", "extract", "1", [F("uno.pdf")]); o = one_out(r, ".pdf")
    ck(r, o and npages(o) == 1, "extract 1: 1 pagina", o and npages(o))
    r = run("uno", "extract", "2", [F("uno.pdf")]); expect_fail(r, ["fuori intervallo"], "extract 2 su PDF di 1 pagina")
    r = run("uno", "extract", "0", [F("uno.pdf")]); expect_fail(r, ["fuori intervallo", "non valido"], "extract 0")
    r = run("uno", "extract", "abc", [F("uno.pdf")]); expect_fail(r, ["non valido"], "extract abc")
    r = run("uno", "extract", "", [F("uno.pdf")]); expect_fail(r, ["non valido", "pagine"], "extract vuoto")
    for deg in ["90", "180", "270"]:
        r = run("uno", "rotate", deg, [F("uno.pdf")]); o = one_out(r, ".pdf")
        rot = PdfReader(o).pages[0].get("/Rotate", 0) if o else None
        ck(r, o and int(rot or 0) % 360 == int(deg), f"rotate {deg}: /Rotate={deg}", rot)
        ck(r, o and "Pagina uno" in ptext(o), "rotate: testo ancora presente")
    r = run("uno", "reorder", "reverse", [F("uno.pdf")]); o = one_out(r, ".pdf")
    ck(r, o and npages(o) == 1, "reorder reverse: 1 pagina")
    r = run("uno", "reorder", "5", [F("uno.pdf")]); expect_fail(r, ["fuori intervallo"], "reorder 5 su 1 pagina")
    r = run("uno", "protect", "", [F("uno.pdf")], secret="Pàss wörd€1"); o = one_out(r, ".pdf")
    if o:
        rr = PdfReader(o); ck(r, rr.is_encrypted, "protect: PDF cifrato")
        ck(r, rr.decrypt("sbagliata") == 0, "protect: password sbagliata non apre")
        ck(r, "Pagina uno" in ptext(o, pw="Pàss wörd€1"), "protect: la password giusta apre e il testo c'è")
    else: ck(r, False, "protect: file creato", r["lines"])
    r = run("uno", "protect", "", [F("uno.pdf")], secret=""); expect_fail(r, ["password"], "protect con password vuota")
    r = run("uno", "unprotect", "", [F("uno.pdf")], secret="x"); o = one_out(r, ".pdf")
    ck(r, (o and not PdfReader(o).is_encrypted) or r["fails"], "unprotect su PDF non protetto: copia o messaggio", r["lines"])

    # ── PDF protetti: ogni azione deve dire «protetto da password»
    for pf in ["protetto.pdf", "protetto_rc4.pdf"]:
        for act, prm in [("pdftext", ""), ("to:png", ""), ("split", ""), ("extract", "1"), ("rotate", "90"),
                         ("reorder", "reverse"), ("merge", "")]:
            r = run(pf[:-4], act, prm, [F(pf)]); expect_fail(r, ["password"], f"{act} su PDF protetto")
        r = run(pf[:-4], "protect", "", [F(pf)], secret="altra"); expect_fail(r, ["password"], "protect su PDF già protetto")
        r = run(pf[:-4], "unprotect", "", [F(pf)], secret="sbagliata"); expect_fail(r, ["non è corretta"], "unprotect password sbagliata")
        r = run(pf[:-4], "unprotect", "", [F(pf)]); expect_fail(r, ["password"], "unprotect senza password")
        r = run(pf[:-4], "unprotect", "", [F(pf)], secret="segreta"); o = one_out(r, ".pdf")
        ck(r, o and not PdfReader(o).is_encrypted and npages(o) == 1 and "Pagina uno" in ptext(o), "unprotect giusto: PDF libero con il testo", r["lines"])
    r = run("solo_proprietario", "pdftext", "", [F("solo_proprietario.pdf")])
    ck(r, len(r["outs"]) == 1 or r["fails"], "PDF con sola password del proprietario: testo o messaggio", r["lines"])
    r = run("solo_proprietario", "unprotect", "", [F("solo_proprietario.pdf")], secret="capo"); o = one_out(r, ".pdf")
    ck(r, o and not PdfReader(o).is_encrypted, "unprotect con password del proprietario: PDF libero", r["lines"])
    r = run("solo_proprietario", "rotate", "90", [F("solo_proprietario.pdf")]); o = one_out(r, ".pdf")
    ck(r, o or r["fails"], "rotate su PDF con restrizioni: file o messaggio", r["lines"])
    if o: ck(r, npages(o) == 1, "rotate su PDF con restrizioni: 1 pagina leggibile", npages(o))

    # ── PDF rotti, vuoti, finti
    for bad in ["rotto.pdf", "trecento_troncato.pdf", "vuoto.pdf", "finto.pdf", "solo_intestazione.pdf", "zero.pdf"]:
        for act, prm in [("pdftext", ""), ("to:png", ""), ("split", ""), ("extract", "1"), ("rotate", "90"),
                         ("reorder", "reverse"), ("protect", None), ("merge", "")]:
            if prm is None: r = run(bad[:-4], act, "", [F(bad)], secret="abc")
            else: r = run(bad[:-4], act, prm, [F(bad)])
            if r.get("skipped"): continue
            msg = " | ".join(r["fails"] + r["notes"])
            if r["outs"]:
                # ha creato qualcosa: deve essere un PDF/immagine sensato
                o = r["outs"][0]
                good = True
                if o.endswith(".pdf"):
                    np_ = npages(o) if act != "protect" else "cifrato"
                    good = (isinstance(np_, int) and np_ > 0) or np_ == "cifrato"
                    ck(r, good, f"{act} su {bad}: il PDF creato ha pagine", np_)
                elif os.path.isdir(o):
                    ck(r, len(listing(o)) > 0, f"{act} su {bad}: cartella creata non vuota", listing(o))
                elif o.endswith(".txt"):
                    ck(r, os.path.getsize(o) > 0, f"{act} su {bad}: testo non vuoto")
            else:
                ck(r, len(r["fails"]) >= 1, f"{act} su {bad}: segnala un errore", r["lines"])
                ck(r, len(msg) > 8 and "LRERR" not in msg and "Fatal error" not in msg and "Swift" not in msg,
                   f"{act} su {bad}: messaggio comprensibile", msg)
        if gs_ready():
            r = run(bad[:-4], "pdfcompress", "medium", [F(bad)])
            msg = " | ".join(r["fails"] + r["notes"])
            ck(r, r["outs"] == [] and (r["fails"] or r["notes"]) or (r["outs"] and isinstance(npages(r["outs"][0]), int) and npages(r["outs"][0]) > 0),
               f"compress su {bad}: errore chiaro o PDF valido", r["lines"])
            ck(r, not any(x in msg for x in ["GPL Ghostscript", "**** ", "Error:", "Unrecoverable"]) or r["outs"],
               f"compress su {bad}: messaggio non è l'output grezzo di Ghostscript", msg)

    # ── Nomi con accenti e simboli
    for nm in ["Fattura è perché – città.pdf", unicodedata.normalize("NFD", "Caffè NFD già.pdf"),
               "doppio  spazio 'apice' $HOME & (1).pdf", "-inizia-col-trattino.pdf"]:
        for act, prm in [("pdftext", ""), ("to:png", ""), ("split", ""), ("extract", "1"), ("rotate", "90")]:
            r = run("nome:" + unicodedata.normalize("NFC", nm)[:18], act, prm, [F(nm)])
            ck(r, len(r["outs"]) == 1 and os.path.exists(r["outs"][0]), f"{act} con nome «{nm}»: un risultato", r["lines"])
            if r["outs"]:
                base = os.path.basename(r["outs"][0])
                stem = unicodedata.normalize("NFC", nm[:-4])
                ck(r, stem in unicodedata.normalize("NFC", base), "il nome del risultato contiene il nome originale", base)
        if gs_ready():
            r = run("nome:" + unicodedata.normalize("NFC", nm)[:18], "pdfcompress", "strong", [F(nm)])
            ck(r, r["outs"] or r["notes"], f"compress con nome «{nm}»: risultato o nota", r["lines"])

    # ── Stessa cartella (senza LR_DESTPATH): nomi unici, originale intatto
    sd = os.path.join(ROOT, "stessa"); os.makedirs(sd, exist_ok=True); shutil.copy(F("uno.pdf"), os.path.join(sd, "uno.pdf"))
    r1 = run("stessa-cartella", "rotate", "90", [os.path.join(sd, "uno.pdf")], dest=False)
    r2 = run("stessa-cartella", "rotate", "90", [os.path.join(sd, "uno.pdf")], dest=False)
    ck(r2, r1["outs"] and r2["outs"] and r1["outs"][0] != r2["outs"][0] and os.path.exists(r1["outs"][0]),
       "seconda volta: nome nuovo, il primo risultato non viene sovrascritto", (r1["outs"], r2["outs"]))
    r3 = run("stessa-cartella", "split", "", [os.path.join(sd, "uno.pdf")], dest=False)
    r4 = run("stessa-cartella", "split", "", [os.path.join(sd, "uno.pdf")], dest=False)
    ck(r4, r3["outs"] and r4["outs"] and r3["outs"][0] != r4["outs"][0], "split due volte: cartelle diverse", (r3["outs"], r4["outs"]))

    # ── 300 pagine
    r = run("trecento", "pdftext", "", [F("trecento.pdf")]); o = one_out(r, ".txt")
    if o:
        t = open(o, encoding="utf-8").read()
        ck(r, "Pagina 300 di 300" in t and "Pagina 1 di 300" in t, "testo di tutte le 300 pagine")
        ck(r, t.count("──── Pagina ") == 300, "300 separatori di pagina", t.count("──── Pagina "))
    r = run("trecento", "split", "", [F("trecento.pdf")])
    d = r["outs"][0] if r["outs"] else None; fs = files_in(d, ".pdf")
    ck(r, len(fs) == 300, "split: 300 PDF", len(fs))
    if fs:
        ck(r, os.path.basename(fs[0]).endswith("pagina 001.pdf") and os.path.basename(fs[-1]).endswith("pagina 300.pdf"), "nomi a 3 cifre in ordine", (fs[0], fs[-1]))
        ck(r, "Pagina 300 di 300" in ptext(fs[-1]), "l'ultimo pezzo è la pagina 300")
    r = run("trecento", "extract", "1-3,5,298-", [F("trecento.pdf")]); o = one_out(r, ".pdf")
    ck(r, o and npages(o) == 7, "extract 1-3,5,298-: 7 pagine", o and npages(o))
    if o: ck(r, "Pagina 5 di 300" in ptext(o, 3) and "Pagina 300 di 300" in ptext(o, 6), "pagine giuste nell'ordine giusto")
    r = run("trecento", "extract", "1-301", [F("trecento.pdf")]); expect_fail(r, ["fuori intervallo"], "extract 1-301")
    r = run("trecento", "extract", "5-3", [F("trecento.pdf")]); expect_fail(r, ["fuori intervallo", "non valido"], "extract 5-3")
    r = run("trecento", "extract", "2,2,2", [F("trecento.pdf")]); o = one_out(r, ".pdf")
    ck(r, o and npages(o) in (1, 3), "extract 2,2,2: risultato coerente", o and npages(o))
    r = run("trecento", "reorder", "reverse", [F("trecento.pdf")]); o = one_out(r, ".pdf")
    ck(r, o and npages(o) == 300 and "Pagina 300 di 300" in ptext(o, 0) and "Pagina 1 di 300" in ptext(o, 299), "reverse: 300→1")
    r = run("trecento", "reorder", "3,1,2", [F("trecento.pdf")]); o = one_out(r, ".pdf")
    ck(r, o and npages(o) == 300 and "Pagina 3 di 300" in ptext(o, 0) and "Pagina 4 di 300" in ptext(o, 3), "3,1,2 poi il resto")
    r = run("trecento", "reorder", "10-1", [F("trecento.pdf")]); o = one_out(r, ".pdf")
    ck(r, o and npages(o) == 300 and "Pagina 10 di 300" in ptext(o, 0), "10-1 al contrario")
    r = run("trecento", "rotate", "90", [F("trecento.pdf")]); o = one_out(r, ".pdf")
    ck(r, o and npages(o) == 300 and all(int(p.get("/Rotate", 0)) == 90 for p in PdfReader(o).pages), "300 pagine ruotate")
    r = run("trecento", "to:png", "", [F("trecento.pdf")], timeout=900)
    d = r["outs"][0] if r["outs"] else None; fs = files_in(d, ".png")
    ck(r, len(fs) == 300, "300 immagini PNG", len(fs))
    r = run("trecento", "protect", "", [F("trecento.pdf")], secret="segreta"); o = one_out(r, ".pdf")
    ck(r, o and PdfReader(o).is_encrypted, "300 pagine protette")
    if o:
        r2 = run("trecento-protetto", "unprotect", "", [o], secret="segreta"); o2 = one_out(r2, ".pdf")
        ck(r2, o2 and npages(o2) == 300 and "Pagina 300 di 300" in ptext(o2, 299), "giro protect→unprotect: 300 pagine e testo")

    # ── Scansioni (solo immagini): OCR
    r = run("scansione", "pdftext", "", [F("scansione.pdf")]); o = one_out(r, ".txt")
    t = open(o, encoding="utf-8").read() if o else ""
    ck(r, "12345" in t and "FATTURA" in t.upper() and "ROSSI" in t.upper(), "OCR: trova FATTURA/12345/ROSSI", t[:300])
    ck(r, "PAGINA 3" in t.upper(), "OCR: anche la pagina 3", t[-200:])
    r = run("scansione40", "pdftext", "", [F("scansione40.pdf")], timeout=900); o = one_out(r, ".txt")
    t = open(o, encoding="utf-8").read() if o else ""
    ck(r, t.upper().count("FATTURA") >= 38, "OCR 40 pagine: testo su (quasi) tutte", t.upper().count("FATTURA"))
    r = run("foto", "ocr", "", [F("foto.png")]); o = one_out(r, ".txt")
    ck(r, o and "12345" in open(o, encoding="utf-8").read(), "OCR immagine PNG")
    r = run("foto", "ocr", "", [F("foto.heic")]); o = one_out(r, ".txt")
    ck(r, (o and "12345" in open(o, encoding="utf-8").read()) or not os.path.exists(F("foto.heic")), "OCR immagine HEIC")
    r = run("scansione", "to:png", "", [F("scansione.pdf")])
    d = r["outs"][0] if r["outs"] else None
    ck(r, len(files_in(d, ".png")) == 3, "scansione → 3 PNG")

    # ── Moduli
    nf = fields(F("modulo.pdf")); nw = widgets(F("modulo.pdf"))
    print("modulo: campi", nf, "widget", nw)
    for act, prm in [("rotate", "90"), ("extract", "1-2"), ("reorder", "reverse"), ("merge", ""), ("split", "")]:
        r = run("modulo", act, prm, [F("modulo.pdf")])
        o = r["outs"][0] if r["outs"] else None
        if o and os.path.isdir(o): o = files_in(o, ".pdf")[0] if files_in(o, ".pdf") else None
        if o:
            ff = fields(o); ww = widgets(o)
            exp = nf if act != "split" else ["accetto", "nome"]
            ck(r, isinstance(ff, list) and set(exp) <= set(ff), f"{act} modulo: campi compilabili conservati (attesi {exp})", ff)
            ck(r, isinstance(ww, int) and ww >= (nw if act != "split" else 2), f"{act} modulo: widget conservati ({nw})", ww)
        else: ck(r, False, f"{act} modulo: risultato", r["lines"])
    r = run("modulo", "pdftext", "", [F("modulo.pdf")]); o = one_out(r, ".txt")
    ck(r, o and "Modulo di prova" in open(o, encoding="utf-8").read(), "testo del modulo")
    r = run("modulo", "protect", "", [F("modulo.pdf")], secret="m"); o = one_out(r, ".pdf")
    if o:
        rr = PdfReader(o); rr.decrypt("m"); ff = sorted((rr.get_fields() or {}).keys())
        ck(r, set(nf) <= set(ff), "protect modulo: campi conservati", ff)

    # ── Formati misti e orizzontali
    rm = PdfReader(F("misto.pdf"))
    sizes = [(float(p.mediabox.width), float(p.mediabox.height), int(p.get("/Rotate", 0))) for p in rm.pages]
    print("misto:", sizes)
    r = run("misto", "to:png", "", [F("misto.pdf")])
    d = r["outs"][0] if r["outs"] else None; fs = files_in(d, ".png")
    ck(r, len(fs) == 5, "misto: 5 PNG", len(fs))
    for i, f in enumerate(fs[:5]):
        w, h, rot = sizes[i]
        if rot % 180 == 90: w, h = h, w
        im = Image.open(f)
        ck(r, abs(im.size[0] - round(w * 200 / 72)) <= 2 and abs(im.size[1] - round(h * 200 / 72)) <= 2,
           f"pagina {i+1}: misura giusta (attesa {round(w*200/72)}×{round(h*200/72)})", im.size)
    r = run("misto", "rotate", "90", [F("misto.pdf")]); o = one_out(r, ".pdf")
    if o:
        rots = [int(p.get("/Rotate", 0)) for p in PdfReader(o).pages]
        ck(r, rots == [90, 90, 180, 90, 90], "rotate su pagine già ruotate: 90,90,180,90,90", rots)
    r = run("misto", "split", "", [F("misto.pdf")])
    d = r["outs"][0] if r["outs"] else None; fs = files_in(d, ".pdf")
    if fs:
        got = [(float(PdfReader(f).pages[0].mediabox.width), float(PdfReader(f).pages[0].mediabox.height), int(PdfReader(f).pages[0].get("/Rotate", 0))) for f in fs]
        ck(r, got == sizes, "split conserva misure e rotazione", got)
    r = run("misto", "extract", "2,3", [F("misto.pdf")]); o = one_out(r, ".pdf")
    if o:
        got = [(float(p.mediabox.width), float(p.mediabox.height), int(p.get("/Rotate", 0))) for p in PdfReader(o).pages]
        ck(r, got == sizes[1:3], "extract conserva misure e rotazione", got)
    r = run("grande", "to:png", "", [F("grande.pdf")])
    ck(r, (r["outs"] and os.path.exists(r["outs"][0])) or (r["fails"] and len(r["fails"][0]) > 10), "pagina enorme 200×200 pollici: immagine o messaggio chiaro", r["lines"])
    r = run("grande", "to:jpg", "", [F("grande.pdf")])
    ck(r, (r["outs"] and os.path.exists(r["outs"][0])) or (r["fails"] and len(r["fails"][0]) > 10), "pagina enorme → JPG: immagine o messaggio chiaro", r["lines"])
    r = run("grande", "pdftext", "", [F("grande.pdf")]); o = one_out(r, ".txt")
    ck(r, o and "777" in open(o, encoding="utf-8").read(), "testo della pagina enorme")

    # ── Unire (da immagini e PDF)
    imgs = [F("foto.png"), F("foto.jpg")] + ([F("foto.heic")] if os.path.exists(F("foto.heic")) else [])
    r = run("merge", "merge", "", [F("uno.pdf"), F("misto.pdf")] + imgs); o = one_out(r, ".pdf")
    ck(r, o and npages(o) == 6 + len(imgs), f"merge: {6+len(imgs)} pagine", o and npages(o))
    r = run("merge", "merge", "", [F("trecento.pdf"), F("trecento.pdf")])
    o = one_out(r, ".pdf"); ck(r, o and npages(o) in (300, 600), "merge stesso file due volte", o and npages(o))
    r = run("merge", "merge", "", [F("uno.pdf"), F("protetto.pdf")]); expect_fail(r, ["password"], "merge con un PDF protetto")
    r = run("merge", "merge", "", [F("uno.pdf"), F("rotto.pdf")])
    ck(r, r["outs"] or r["fails"], "merge con un PDF rotto: risultato o messaggio", r["lines"])
    r = run("merge", "merge", "", [F("uno.pdf"), F("vuoto.pdf")]); expect_fail(r, ["danneggiato", "non valido"], "merge con un PDF vuoto")
    for im in imgs:
        r = run("img", "to:pdf", "", [im]); o = one_out(r, ".pdf")
        ck(r, o and npages(o) == 1, f"{os.path.basename(im)} → PDF di 1 pagina", r["lines"])
    r = run("img", "merge", "", imgs); o = one_out(r, ".pdf")
    ck(r, o and npages(o) == len(imgs), "solo immagini → un PDF", o and npages(o))

    # ── Più file insieme (uno buono e due rotti)
    r = run("lotto", "pdftext", "", [F("uno.pdf"), F("rotto.pdf"), F("vuoto.pdf")])
    ck(r, len(r["outs"]) >= 1 and len(r["fails"]) >= 1, "lotto: il buono riesce, i rotti falliscono", r["lines"])
    ck(r, r["end"] and r["end"][0][1:] == [str(len(r["oks"])), str(len(r["fails"]))], "END conta giusto", r["end"])

    # ── Compressione
    if not gs_ready():
        print("Ghostscript non disponibile: salto la compressione"); return
    for pf in ["uno.pdf", "trecento.pdf", "scansione.pdf", "scansione40.pdf", "misto.pdf", "modulo.pdf"]:
        for lvl in ["light", "medium", "strong"]:
            r = run(pf[:-4], "pdfcompress", lvl, [F(pf)], timeout=900)
            o = one_out(r, ".pdf")
            if o:
                a, b = os.path.getsize(F(pf)), os.path.getsize(o)
                ck(r, b < a, f"compress {lvl}: più piccolo ({a} → {b})", (a, b))
                ck(r, npages(o) == npages(F(pf)), "compress: stesso numero di pagine", (npages(F(pf)), npages(o)))
                if pf in ("uno.pdf", "trecento.pdf"): ck(r, "Pagina" in ptext(o, 0), "compress: testo ancora selezionabile")
                if pf == "modulo.pdf": ck(r, set(nf) <= set(fields(o) if isinstance(fields(o), list) else []), "compress modulo: campi conservati", fields(o))
                if pf == "misto.pdf":
                    got = [(round(float(p.mediabox.width)), round(float(p.mediabox.height)), int(p.get("/Rotate", 0))) for p in PdfReader(o).pages]
                    exp = [(round(w), round(h), rt) for w, h, rt in sizes]
                    ck(r, got == exp, "compress misto: misure e rotazione conservate", got)
                ck(r, len(r["oks"]) == 1 and r["oks"][0].startswith("da "), "compress: dice «da X a Y»", r["oks"])
            else:
                ck(r, len(r["notes"]) == 1, f"compress {lvl}: o più piccolo o nota «già compresso»", r["lines"])
        if pf.startswith("scansione"):
            ck(r, bool(r["outs"]), f"compress strong su scansione: deve ridurre", r["lines"])
    r = run("protetto", "pdfcompress", "medium", [F("protetto.pdf")]); expect_fail(r, ["password"], "compress su PDF protetto")
    r = run("nome", "pdfcompress", "medium", [F("Fattura è perché – città.pdf"), F("scansione.pdf")])
    ck(r, len(r["outs"]) + len(r["notes"]) == 2, "compress di 2 file insieme", r["lines"])

_GS = [None]
def gs_ready():
    if _GS[0] is None:
        _GS[0] = shutil.which("gs", path="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin") is not None
    return _GS[0]

# ─── Sequenze documenti ─────────────────────────────────────────────
ACC = ["città", "perché"]
def text_of(p):
    e = p.lower().rsplit(".", 1)[-1]
    try:
        if e == "pdf": return ptext(p)
        if e == "docx":
            import docx; d = docx.Document(p)
            return "\n".join([x.text for x in d.paragraphs] + [c.text for t in d.tables for row in t.rows for c in row.cells])
        if e == "xlsx":
            import openpyxl; wb = openpyxl.load_workbook(p)
            return "\n".join(str(c.value) for ws in wb for row in ws.iter_rows() for c in row if c.value is not None)
        if e == "pptx":
            import pptx; pr = pptx.Presentation(p)
            return "\n".join(sh.text_frame.text for s in pr.slides for sh in s.shapes if sh.has_text_frame)
        if e in ("odt", "ods", "odp", "epub"):
            z = zipfile.ZipFile(p); names = [n for n in z.namelist() if n.endswith((".xml", ".xhtml", ".html"))]
            return "\n".join(z.read(n).decode("utf-8", "replace") for n in names)
        if e in ("txt", "md", "html", "csv", "rtf"):
            b = open(p, "rb").read()
            try: return b.decode("utf-8")
            except UnicodeDecodeError: return "NON-UTF8:" + b.decode("latin-1")
    except Exception as ex: return f"err:{ex}"
    return ""

def check_conv(r, t, words):
    o = one_out(r, "." + t)
    ck(r, o is not None and os.path.getsize(o) > 0, f"→ {t}: un file non vuoto", r["lines"])
    if o:
        tx = text_of(o)
        if t == "rtf": tx = tx.replace("\\'e0", "à").replace("\\'e8", "è").replace("\\'e9", "é")
        if t == "html":
            import html as H; tx = H.unescape(tx)
        ck(r, all(w in tx for w in words), f"→ {t}: contiene {words} (accenti giusti)", tx[:400])
    return o

def doc_suite():
    make_doc_fixtures()
    for x in ["soffice", "pandoc", "textutil", "gs"]:
        print(x, shutil.which(x, path="/opt/homebrew/bin:/usr/local/bin:/Applications/LibreOffice.app/Contents/MacOS:/usr/bin:/bin"))
    W = ACC
    for t in ["pdf", "odt", "txt", "html", "md", "rtf"]:
        r = run("docx", "to:" + t, "", [F("documento.docx")], timeout=400); check_conv(r, t, W)
    for t in ["pdf", "csv", "ods", "html"]:
        r = run("xlsx", "to:" + t, "", [F("foglio.xlsx")], timeout=400); check_conv(r, t, W)
    for t in ["pdf", "odp"]:
        r = run("pptx", "to:" + t, "", [F("presentazione.pptx")], timeout=400); check_conv(r, t, W)
    for t in ["pdf", "docx", "odt", "html", "md", "rtf"]:
        r = run("txt", "to:" + t, "", [F("testo.txt")], timeout=400); check_conv(r, t, W)
    for t in ["pdf", "docx", "txt"]:
        r = run("txt-latin1", "to:" + t, "", [F("testo_latin1.txt")], timeout=400); check_conv(r, t, W)
    for t in ["pdf", "docx", "odt", "html", "epub"]:
        r = run("md", "to:" + t, "", [F("nota.md")], timeout=400); check_conv(r, t, W)
    for t in ["xlsx", "pdf", "ods", "html"]:
        r = run("csv", "to:" + t, "", [F("dati.csv")], timeout=400); check_conv(r, t, W)
    r = run("csv;", "to:xlsx", "", [F("dati_puntoevirgola.csv")], timeout=400); o = check_conv(r, "xlsx", ["Città"])
    if o:
        import openpyxl; ws = openpyxl.load_workbook(o).active
        ck(r, ws.max_column >= 3, "CSV con «;» (Excel italiano): colonne separate", [[c.value for c in row] for row in ws.iter_rows()])
    r = run("xlsx", "to:csv", "", [F("foglio.xlsx")], timeout=400)
    r = run("pdf", "to:docx", "", [F("uno.pdf")], timeout=400); check_conv(r, "docx", ["Pagina uno", "4242"])
    r = run("pdf-scansione", "to:docx", "", [F("scansione.pdf")], timeout=400)
    ck(r, r["outs"] or r["fails"], "PDF scansionato → DOCX: file o messaggio", r["lines"])
    r = run("nome", "to:pdf", "", [F("Relazione è già – città.docx")], timeout=400); check_conv(r, "pdf", W)
    r = run("nome", "to:md", "", [F("Relazione è già – città.docx")], timeout=400); check_conv(r, "md", W)
    for bad in ["rotto.docx", "vuoto.docx", "vuoto.xlsx"]:
        for t in ["pdf", "txt"] if bad.endswith("docx") else ["pdf", "csv"]:
            r = run(bad, "to:" + t, "", [F(bad)], timeout=400)
            msg = " | ".join(r["fails"])
            if r["outs"]: ck(r, os.path.getsize(r["outs"][0]) > 0, f"{bad} → {t}: file creato non vuoto", r["outs"])
            else:
                ck(r, len(r["fails"]) >= 1, f"{bad} → {t}: segnala un errore", r["lines"])
                ck(r, len(msg) > 8, f"{bad} → {t}: messaggio comprensibile", msg)
    # Più documenti insieme verso PDF (LibreOffice una volta sola)
    r = run("lotto", "to:pdf", "", [F("documento.docx"), F("foglio.xlsx"), F("presentazione.pptx"), F("Relazione è già – città.docx")], timeout=600)
    ck(r, len(r["outs"]) == 4, "4 documenti → 4 PDF", r["lines"])
    # Due file con lo stesso nome in cartelle diverse
    os.makedirs(F("a"), exist_ok=True); os.makedirs(F("b"), exist_ok=True)
    shutil.copy(F("documento.docx"), F("a/stesso.docx")); shutil.copy(F("foglio.xlsx"), F("b/stesso.xlsx"))
    shutil.copy(F("testo.txt"), F("b/stesso.txt"))
    r = run("stesso-nome", "to:pdf", "", [F("a/stesso.docx"), F("b/stesso.txt")], timeout=600)
    ck(r, len(r["outs"]) == 2, "stesso nome, tipi diversi → 2 PDF", r["lines"])
    if len(r["outs"]) == 2:
        t1, t2 = text_of(r["outs"][0]), text_of(r["outs"][1])
        ck(r, t1 != t2, "i due PDF hanno contenuti diversi", (t1[:80], t2[:80]))

if MODE == "pdf": pdf_suite()
else: doc_suite()
save()
bad = [(r["n"], r["case"], r["act"], c["desc"]) for r in RECS for c in r["checks"] if not c["ok"]]
print(f"\nPROVE: {len(RECS)}  controlli falliti: {len(bad)}")
for b in bad: print("  ✗", b)
