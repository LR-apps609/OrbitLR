#!/usr/bin/env python3
# P11 · Ufficio: PDF (unisci, dividi, estrai, ruota, riordina, proteggi, comprimi senza Ghostscript), documenti senza LibreOffice.
import os, sys, time, shutil
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from t20 import *

es = Esito("P11")
F = os.path.join(OUT, "fix"); os.makedirs(F, exist_ok=True)
crash0 = crash_elenco()
rc, w = sh("command -v gs soffice pandoc magick"); es.nota("programmi_presenti", w.strip())


def ctrl_pdf(pagine=None):
    def f(p):
        n = pdf_pagine(p)
        if not open(p, "rb").read(5).startswith(b"%PDF"):
            return False, "non è un PDF"
        if pagine is not None and n != pagine:
            return False, "%s pagine invece di %s" % (n, pagine)
        return True, "%s pagine" % n
    return f


def fixture():
    crea_pdf(F + "/tre.pdf", 3, "Tre")
    crea_pdf(F + "/cinque.pdf", 5, "Cinque")
    crea_pdf(F + "/trecento.pdf", 300, "Lungo")
    open(F + "/rotto.pdf", "wb").write(b"%PDF-1.4\n" + os.urandom(4000))
    open(F + "/lettera.txt", "w").write("Gentile cliente,\nla fattura numero 4242 è pronta.\nCittà: Napoli\n")
    sh(["textutil", "-convert", "docx", F + "/lettera.txt", "-output", F + "/lettera.docx"])
    sh(["textutil", "-convert", "rtf", F + "/lettera.txt", "-output", F + "/lettera.rtf"])


def pdf():
    r = motore("merge", "", [F + "/tre.pdf", F + "/cinque.pdf"], nome="merge")
    esito_motore(es, "unisci 3+5 pagine", r, "un PDF di 8 pagine", ctrl_pdf(8))
    r = motore("split", "", [F + "/cinque.pdf"], nome="split")
    outs = [o for o in r["outs"] if os.path.exists(o)]
    pdfs = [x for o in outs for x in ([o] if o.endswith(".pdf") else file_in(o, ".pdf"))]
    es.check("dividi 5 pagine", len(pdfs) == 5, "«Dividi» non dà un PDF per pagina", "alto", "5 PDF", "%d file: %s" % (len(pdfs), outs[:3]), prova_motore(r))
    for prm, n in [("2-4", 3), ("1,3,5", 3), ("5", 1)]:
        r = motore("extract", prm, [F + "/cinque.pdf"], nome="extract" + prm)
        esito_motore(es, "estrai pagine %s" % prm, r, "%d pagine" % n, ctrl_pdf(n))
    for prm in ["9", "0", "abc", "4-2"]:
        r = motore("extract", prm, [F + "/cinque.pdf"], nome="extract-sbagliato" + prm)
        es.check("estrai «%s» (sbagliato) → messaggio" % prm, not r["outs"] and r["fails"] and r["fails"][0][1].strip(),
                 "Estrai pagine con un intervallo sbagliato (%s): nessun messaggio o file creato" % prm, "basso", "FAIL con motivo, nessun file",
                 r["lines"], prova_motore(r))
    r = motore("rotate", "90", [F + "/tre.pdf"], nome="rotate")
    esito_motore(es, "ruota 90°", r, "3 pagine ruotate", ctrl_pdf(3))
    r = motore("reorder", "reverse", [F + "/tre.pdf"], nome="reorder")
    esito_motore(es, "riordina al contrario", r, "3 pagine", ctrl_pdf(3))
    r = motore("protect", "-", [F + "/tre.pdf"], secret="Segreta1", nome="protect")
    if esito_motore(es, "proteggi con password", r, "PDF cifrato", ctrl_pdf()):
        prot = r["outs"][0]
        enc = b"/Encrypt" in open(prot, "rb").read()
        es.check("il PDF protetto è cifrato", enc, "«Proteggi» non cifra il PDF", "alto", "/Encrypt nel file", "nessun /Encrypt", prot)
        r2 = motore("unprotect", "-", [prot], secret="Sbagliata", nome="unprotect-sbagliata")
        es.check("sblocca con password sbagliata → messaggio", not r2["outs"] and r2["fails"], "Sblocca con password sbagliata non avvisa",
                 "medio", "FAIL «password non corretta»", r2["lines"], prova_motore(r2))
        r3 = motore("unprotect", "-", [prot], secret="Segreta1", nome="unprotect")
        esito_motore(es, "sblocca con la password giusta", r3, "PDF senza /Encrypt", lambda p: (b"/Encrypt" not in open(p, "rb").read(), "ancora cifrato"))
    r = motore("pdfcompress", "medium", [F + "/trecento.pdf"], timeout=600, nome="compress")
    if r["missing"]:
        es.ok("comprimi senza Ghostscript → MISSING con indicazione", r["missing"])
    else:
        esito_motore(es, "comprimi PDF di 300 pagine", r, "300 pagine", ctrl_pdf(300))
    # testo corto (meno di 15 caratteri per pagina) e testo lungo: il motore usa l'OCR sotto i 15 caratteri
    crea_pdf(F + "/lungo-testo.pdf", 2, "Fattura numero 4242 per il cliente Mario Rossi, pagina")
    for nome, atteso in [("lungo-testo.pdf", "4242"), ("tre.pdf", "Tre")]:
        r = motore("pdftext", "", [F + "/" + nome], nome="pdftext-" + nome)
        outs = [o for o in r["outs"] if os.path.exists(o)]
        txt = open(outs[0], errors="replace").read() if outs else ""
        es.nota("pdftext-" + nome, {"fails": r["fails"], "testo": txt[:200]})
        if nome == "tre.pdf" and not outs and r["fails"] and "4242" in es.d["note"].get("pdftext-lungo-testo.pdf", {}).get("testo", ""):
            es.bug("estrai il testo da un PDF con poco testo per pagina", "«Estrai il testo»: le pagine con meno di 15 caratteri perdono il loro testo (rimpiazzato dall'OCR)",
                   "basso", "il testo vero «Tre 1 di 3» di ogni pagina (PDFPage.string lo ha)",
                   "FAIL «%s»; con testo lungo invece funziona (%s)" % (r["fails"][0][1] if r["fails"] else "", es.d["note"]["pdftext-lungo-testo.pdf"]["testo"][:80]),
                   prova_motore(r) + " · LRConverter.zsh lrhelper «text»: if s.count < 15 { s = recognize(img) } — il testo vero si butta anche se l'OCR non trova niente",
                   passi=["PDF di 3 pagine con «Tre 1 di 3» su ogni pagina (testo vero, non scansione)", "Estrai il testo", "messaggio «nel PDF non ho trovato testo leggibile»"])
        elif atteso in txt:
            es.ok("estrai il testo da %s" % nome, txt[:60])
        else:
            es.bug("estrai il testo da %s" % nome, "«Estrai il testo» non trova il testo di un PDF", "medio", "il testo «%s»" % atteso, "fails %s, testo %r" % (r["fails"], txt[:100]), prova_motore(r))
    r = motore("merge", "", [F + "/tre.pdf", F + "/rotto.pdf"], nome="merge-rotto")
    es.check("unisci con un PDF rotto → messaggio", not r["hang"] and r["fails"], "Unire un PDF rotto non dà un messaggio", "medio",
             "FAIL con il motivo", r["lines"], prova_motore(r))


def documenti():
    for src, t in [("lettera.docx", "pdf"), ("lettera.docx", "txt"), ("lettera.rtf", "docx"), ("lettera.txt", "pdf"), ("lettera.txt", "docx"),
                   ("tre.pdf", "docx"), ("lettera.docx", "odt")]:
        r = motore("to:" + t, "", [F + "/" + src], timeout=300, nome="%s-%s" % (src, t))
        if r["missing"]:
            es.ok("%s → %s senza LibreOffice/pandoc: MISSING con indicazione" % (src, t), r["missing"]); continue
        esito_motore(es, "%s → %s" % (src, t), r, "file %s valido" % t, lambda p: (os.path.getsize(p) > 20, "%d byte" % os.path.getsize(p)))


guarded(es, "fixture", fixture)
guarded(es, "pdf", pdf)
guarded(es, "documenti", documenti)
nuovi = crash_nuovi(crash0)
es.check("nessun crash", not nuovi, "OrbitLR si chiude da sola", "bloccante", "nessun rapporto di crash", nuovi, "log/")
raccogli()
es.fine()
