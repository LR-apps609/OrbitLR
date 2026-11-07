#!/usr/bin/env python3
"""W04 · prova il motore di OrbitLR per Windows (foto e PDF) direttamente, con ~40 file di prova.

Uso: python w04_test.py --harness <exe> --work <cartella> [--group img|pdf|ai|all] [--ffmpeg <ffmpeg>]
Scrive <work>/risultati-<gruppo>.json e .md. Ogni caso: un'azione del motore su uno o più file.
Controlla: esito, tempo (blocchi), file creati (formato, misure, orientamento, pagine, metadati),
originali intatti, niente temporanei rimasti (nella cartella %TEMP% e accanto ai risultati).
"""
import argparse, hashlib, io, json, os, shutil, subprocess, sys, tempfile, time, struct, random, stat

from PIL import Image, ImageDraw, ImageFont, ImageOps, TiffImagePlugin
from PIL.ExifTags import Base as ExifBase
import pillow_heif
pillow_heif.register_heif_opener()
try:
    from PIL import features
    HAVE_AVIF = features.check("avif")
except Exception:
    HAVE_AVIF = False
import pypdf

Image.MAX_IMAGE_PIXELS = None

ap = argparse.ArgumentParser()
ap.add_argument("--harness", required=True)
ap.add_argument("--work", required=True)
ap.add_argument("--group", default="all")
ap.add_argument("--ffmpeg", default="ffmpeg")
ap.add_argument("--quick", action="store_true")
ap.add_argument("--only-fixtures", action="store_true")
args = ap.parse_args()

WORK = os.path.abspath(args.work)
IN = os.path.join(WORK, "in")
OUT = os.path.join(WORK, "out")
os.makedirs(IN, exist_ok=True)
os.makedirs(OUT, exist_ok=True)
TMP = tempfile.gettempdir()
RESULTS = []


def log(*a):
    print(*a, flush=True)


# ───────────────────────── File di prova

def exif_with(orientation=1, gps=True, date="2024:07:14 18:30:00", make="ProvaCam"):
    ex = Image.Exif()
    ex[ExifBase.Make] = make
    ex[ExifBase.Model] = "W04"
    ex[ExifBase.DateTime] = date
    ex[ExifBase.Orientation] = orientation
    if gps:
        g = ex.get_ifd(0x8825)
        g[1] = "N"
        g[2] = (TiffImagePlugin.IFDRational(40, 1), TiffImagePlugin.IFDRational(51, 1), TiffImagePlugin.IFDRational(30, 1))
        g[3] = "E"
        g[4] = (TiffImagePlugin.IFDRational(14, 1), TiffImagePlugin.IFDRational(15, 1), TiffImagePlugin.IFDRational(0, 1))
    return ex


def asym(w, h):
    """Un'immagine non simmetrica: si vede subito se è girata o specchiata."""
    im = Image.new("RGB", (w, h), (240, 240, 240))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, w // 2, h // 4], fill=(220, 20, 20))       # rosso in alto a sinistra
    d.rectangle([w * 3 // 4, h // 2, w - 1, h - 1], fill=(20, 40, 220))  # blu in basso a destra
    d.ellipse([w // 3, h // 3, w // 2, h // 2], fill=(20, 180, 40))
    return im


def photo_like(w, h, seed=1):
    random.seed(seed)
    base = Image.linear_gradient("L").resize((w, h))
    noise = Image.effect_noise((w, h), 40)
    r = Image.blend(base, noise, 0.35)
    g = Image.blend(base.rotate(90).resize((w, h)), noise, 0.3)
    b = Image.blend(base.transpose(Image.FLIP_LEFT_RIGHT), noise, 0.3)
    im = Image.merge("RGB", (r, g, b))
    d = ImageDraw.Draw(im)
    for i in range(30):
        x, y = random.randrange(w), random.randrange(h)
        s = max(4, min(w, h) // 10)
        d.ellipse([x, y, x + s, y + s], fill=(random.randrange(255), random.randrange(255), random.randrange(255)))
    return im


def font(size):
    for f in ["C:/Windows/Fonts/arial.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default(size=size)


def text_image(w, h, lines, size=48):
    im = Image.new("RGB", (w, h), "white")
    d = ImageDraw.Draw(im)
    f = font(size)
    y = 40
    for l in lines:
        d.text((40, y), l, fill="black", font=f)
        y += int(size * 1.5)
    return im


def ff(*a):
    subprocess.run([args.ffmpeg, "-hide_banner", "-loglevel", "error", "-y", *a], check=True)


FIX = {}  # nome -> {path, kind, w, h (come si vede), notes}


def add(name, kind, **kw):
    p = os.path.join(IN, name)
    FIX[name] = dict(path=p, kind=kind, **kw)
    return p


def make_images():
    # 1 foto normale con EXIF e GPS
    im = photo_like(4000, 3000)
    im.save(add("foto.jpg", "img", w=4000, h=3000, gps=True), quality=92, exif=exif_with(1))
    # 2-4 orientamento EXIF
    for o in (3, 6, 8):
        a = asym(400, 300)
        disp = (300, 400) if o in (6, 8) else (400, 300)
        a.save(add(f"orient{o}.jpg", "img", w=disp[0], h=disp[1], gps=True, orient=o), quality=95, exif=exif_with(o))
    # 5 CMYK
    c = asym(600, 400).convert("CMYK")
    c.save(add("cmyk.jpg", "img", w=600, h=400, cmyk=True), quality=95)
    # 6 grigio
    photo_like(800, 600).convert("L").save(add("grigio.jpg", "img", w=800, h=600), quality=90)
    # 7 PNG 16 bit RGB (ffmpeg)
    p = add("16bit.png", "img", w=640, h=480, deep=True)
    ff("-f", "lavfi", "-i", "testsrc2=s=640x480", "-frames:v", "1", "-pix_fmt", "rgb48be", p)
    # 8 PNG 16 bit grigio
    Image.linear_gradient("L").resize((512, 512)).convert("I").point(lambda v: v * 256).convert("I;16").save(add("grigio16.png", "img", w=512, h=512, deep=True))
    # 9 PNG trasparente
    t = Image.new("RGBA", (800, 600), (0, 0, 0, 0))
    ImageDraw.Draw(t).ellipse([100, 100, 700, 500], fill=(250, 120, 0, 255))
    t.save(add("alpha.png", "img", w=800, h=600, alpha=True))
    # 10 PNG RGBA ma tutto opaco
    Image.new("RGBA", (300, 200), (10, 200, 30, 255)).save(add("rgba-opaco.png", "img", w=300, h=200))
    # 11 PNG a tavolozza con trasparenza
    pal = asym(320, 240).convert("P", palette=Image.ADAPTIVE, colors=16)
    pal.info["transparency"] = 0
    pal.save(add("tavolozza.png", "img", w=320, h=240, alpha=True), transparency=0)
    # 12 enorme (96 MP)
    photo_like(12000, 8000, seed=7).save(add("enorme.jpg", "img", w=12000, h=8000, huge=True), quality=85)
    # 13 «bomba»: 16000×16000 a tinta unita (file piccolo, 256 MP)
    Image.new("RGB", (16000, 16000), (30, 60, 90)).save(add("bomba.png", "img", w=16000, h=16000, huge=True, bomb=True))
    # 14 minuscole
    Image.new("RGB", (1, 1), (255, 0, 0)).save(add("1x1.png", "img", w=1, h=1, tiny=True))
    Image.new("RGB", (2, 3), (0, 255, 0)).save(add("2x3.jpg", "img", w=2, h=3, tiny=True), quality=95)
    # 15 panorama
    photo_like(9000, 300, seed=3).save(add("panorama.jpg", "img", w=9000, h=300), quality=88, exif=exif_with(1))
    # 16 HEIC con EXIF e GPS
    photo_like(1600, 1200, seed=4).save(add("iphone.heic", "img", w=1600, h=1200, gps=True), quality=80, exif=exif_with(1).tobytes())
    # 17 HEIC con trasparenza
    t.save(add("alpha.heic", "img", w=800, h=600, alpha=True), quality=80)
    # 18 WebP
    photo_like(1200, 800, seed=5).save(add("foto.webp", "img", w=1200, h=800, gps=True), quality=80, exif=exif_with(1).tobytes())
    t.save(add("alpha.webp", "img", w=800, h=600, alpha=True), lossless=True)
    # 19 AVIF
    if HAVE_AVIF:
        photo_like(1000, 700, seed=6).save(add("foto.avif", "img", w=1000, h=700), quality=60)
    else:
        p = add("foto.avif", "img", w=1000, h=700)
        ff("-f", "lavfi", "-i", "testsrc2=s=1000x700", "-frames:v", "1", "-c:v", "libaom-av1", "-still-picture", "1", p)
    # 20 GIF animata
    frames = [asym(200, 150).rotate(i * 30) for i in range(6)]
    frames[0].save(add("animata.gif", "img", w=200, h=150), save_all=True, append_images=frames[1:], duration=100, loop=0)
    # 21 BMP, TIFF (più pagine), TIFF CMYK, TIFF 16 bit, ICO
    asym(500, 300).save(add("foto.bmp", "img", w=500, h=300))
    asym(640, 480).save(add("pagine.tiff", "img", w=640, h=480), save_all=True, append_images=[photo_like(640, 480)], compression="tiff_lzw")
    asym(400, 300).convert("CMYK").save(add("cmyk.tif", "img", w=400, h=300, cmyk=True))
    Image.linear_gradient("L").resize((300, 300)).convert("I;16").save(add("16bit.tif", "img", w=300, h=300, deep=True))
    asym(256, 256).save(add("icona.ico", "img", w=256, h=256), sizes=[(256, 256), (32, 32)])
    # 22 rotti
    data = open(FIX["foto.jpg"]["path"], "rb").read()
    open(add("troncata.jpg", "img", broken=True), "wb").write(data[: len(data) * 2 // 5])
    open(add("vuota.png", "img", broken=True, empty=True), "wb").write(b"")
    open(add("finta.jpg", "img", broken=True), "wb").write(b"questo non e' una foto\n" * 20)
    hd = open(FIX["iphone.heic"]["path"], "rb").read()
    open(add("troncata.heic", "img", broken=True), "wb").write(hd[: len(hd) // 2])
    # 23 PNG con estensione sbagliata
    asym(300, 200).save(add("png-travestito.jpg", "img", w=300, h=200), format="PNG")
    # 24 nomi strani
    asym(640, 480).save(add("Città già è perché ñ 日本 😀.jpg", "img", w=640, h=480, gps=True), quality=90, exif=exif_with(1))
    asym(640, 480).save(add("foto (compresso).jpg", "img", w=640, h=480), quality=90)
    asym(640, 480).save(add("a&b #1 100% ;'x'.png", "img", w=640, h=480))
    photo_like(800, 600).save(add("-strano.heic", "img", w=800, h=600), quality=80)
    long = "n" * 170 + ".jpg"
    asym(320, 240).save(add(long, "img", w=320, h=240, longname=True), quality=90)
    # 25 sola lettura
    p = add("sola-lettura.jpg", "img", w=1200, h=900, gps=True)
    photo_like(1200, 900).save(p, quality=95, exif=exif_with(1))
    os.chmod(p, stat.S_IREAD)
    # 26 documento fotografato (per «Raddrizza»), testo (per OCR)
    doc = Image.new("RGB", (1600, 1200), (35, 35, 40))
    page = text_image(800, 1000, ["FATTURA 2026", "Totale 1234 euro", "Grazie mille"], 60)
    page = page.transform((1600, 1200), Image.QUAD, (0, 0, 0, 1000, 800, 1000, 800, 0), fill=0)
    mask = Image.new("L", (800, 1000), 255).transform((1600, 1200), Image.QUAD, (0, 0, 0, 1000, 800, 1000, 800, 0))
    # posizione con prospettiva: quadrilatero nella foto
    quad_img = text_image(800, 1000, ["FATTURA 2026", "Totale 1234 euro", "Grazie mille"], 60)
    coeffs = Image.new("RGB", (1, 1))
    doc.paste(quad_img.resize((700, 900)).rotate(8, expand=True, fillcolor=(35, 35, 40)), (420, 120))
    doc.save(add("documento.jpg", "img", w=1600, h=1200), quality=92)
    text_image(1400, 500, ["Hello OrbitLR test", "Second line 2026"], 64).save(add("testo.png", "img", w=1400, h=500))
    # 27 logo (vettoriale) e soggetto (sfondo)
    lg = Image.new("RGB", (600, 600), "white")
    d = ImageDraw.Draw(lg)
    d.ellipse([60, 60, 540, 540], fill=(200, 30, 60))
    d.rectangle([220, 180, 380, 420], fill="white")
    lg.save(add("logo.png", "img", w=600, h=600))
    sub = photo_like(900, 700, seed=9).filter(__import__("PIL.ImageFilter", fromlist=["x"]).GaussianBlur(12))
    d = ImageDraw.Draw(sub)
    d.ellipse([330, 120, 570, 360], fill=(230, 190, 160))
    d.rectangle([300, 340, 600, 700], fill=(40, 70, 160))
    sub.save(add("soggetto.jpg", "img", w=900, h=700), quality=92)
    # 28 sRGB con profilo ICC
    from PIL import ImageCms
    srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    asym(500, 400).save(add("icc.jpg", "img", w=500, h=400, icc=True), quality=92, icc_profile=srgb)
    def patched(space):
        b = bytearray(srgb)
        b[16:20] = space
        return bytes(b)
    # 28b CMYK con profilo CMYK, grigio con profilo grigio (il profilo deve seguire i pixel)
    asym(500, 400).convert("CMYK").save(add("cmyk-icc.jpg", "img", w=500, h=400, cmyk=True, icc_space="CMYK"), quality=92, icc_profile=patched(b"CMYK"))
    asym(500, 400).convert("L").save(add("grigio-icc.jpg", "img", w=500, h=400, icc_space="GRAY"), quality=92, icc_profile=patched(b"GRAY"))
    # 29 tre scatti uguali (per «stack»)
    for i in range(3):
        b = photo_like(800, 600, seed=11)
        b = Image.blend(b, Image.effect_noise((800, 600), 60).convert("RGB"), 0.08)
        b.save(add(f"scatto{i+1}.jpg", "img", w=800, h=600), quality=90)


def make_pdfs():
    from reportlab.pdfgen import canvas
    from reportlab.lib.pagesizes import A4, letter, landscape
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont
    fn = "Helvetica"
    for f in ["C:/Windows/Fonts/arial.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]:
        if os.path.exists(f):
            pdfmetrics.registerFont(TTFont("F", f))
            fn = "F"
            break

    def txt(path, sizes, label):
        c = canvas.Canvas(path)
        for i, s in enumerate(sizes):
            c.setPageSize(s)
            c.setFont(fn, 18)
            c.drawString(50, s[1] - 80, f"{label} pagina {i+1} città perché")
            c.drawString(50, s[1] - 120, "Lorem ipsum dolor sit amet consectetur")
            c.showPage()
        c.save()

    txt(add("testo3.pdf", "pdf", pages=3, text="pagina"), [A4, landscape(A4), letter], "Documento")
    # 300 pagine
    c = canvas.Canvas(add("300pagine.pdf", "pdf", pages=300, text="Pagina"))
    for i in range(300):
        c.setFont("Helvetica", 30)
        c.drawString(80, 700, f"Pagina {i+1} di 300")
        c.showPage()
    c.save()
    # scansione (solo immagine)
    pg = text_image(1240, 1754, ["INVOICE NUMBER 4821", "Total amount 990 EUR", "Thank you"], 70)
    pg.save(add("scansione.pdf", "pdf", pages=1, scan=True), "PDF", resolution=150)
    pg2 = text_image(1240, 1754, ["SECOND PAGE SCAN", "Another line here"], 70)
    pg.save(add("scansione2.pdf", "pdf", pages=2, scan=True), "PDF", resolution=150, save_all=True, append_images=[pg2])
    # PDF con foto grandi (per comprimere): JPEG e PNG (Flate)
    c = canvas.Canvas(add("foto-grandi.pdf", "pdf", pages=2))
    c.drawImage(FIX["foto.jpg"]["path"], 0, 0, width=595, height=446)
    c.showPage()
    big_png = os.path.join(WORK, "flate.png")
    photo_like(2400, 1800, seed=2).save(big_png)
    c.drawImage(big_png, 0, 0, width=595, height=446)
    c.showPage()
    c.save()
    # come sopra ma senza ASCII85 (filtri semplici), e foto messe da Pillow (DCT diretto)
    from reportlab import rl_config
    rl_config.useA85 = 0
    c = canvas.Canvas(add("foto-grandi-noa85.pdf", "pdf", pages=2))
    c.drawImage(FIX["foto.jpg"]["path"], 0, 0, width=595, height=446)
    c.showPage()
    c.drawImage(big_png, 0, 0, width=595, height=446)
    c.showPage()
    c.save()
    rl_config.useA85 = 1
    Image.open(FIX["foto.jpg"]["path"]).save(add("foto-pillow.pdf", "pdf", pages=2), "PDF", resolution=300, quality=95, save_all=True, append_images=[photo_like(3000, 2000, seed=8)])
    # PDF con immagine CMYK
    c = canvas.Canvas(add("cmyk.pdf", "pdf", pages=1))
    c.drawImage(FIX["cmyk.jpg"]["path"], 50, 300, width=400, height=266)
    c.showPage()
    c.save()
    # Password: utente (AES-256), solo proprietario (permessi), RC4
    base = FIX["testo3.pdf"]["path"]
    for name, user, owner, alg in [("password.pdf", "segreta1", "segreta1", "AES-256"), ("solo-permessi.pdf", "", "padrone1", "AES-256"), ("rc4.pdf", "vecchia1", "vecchia1", "RC4-128")]:
        w = pypdf.PdfWriter(clone_from=base)
        w.encrypt(user_password=user, owner_password=owner, algorithm=alg)
        w.write(add(name, "pdf", pages=3, password=user, owner=owner))
    # pagina 2 già ruotata
    w = pypdf.PdfWriter(clone_from=base)
    w.pages[1].rotate(90)
    w.write(add("ruotato.pdf", "pdf", pages=3))
    # modulo
    c = canvas.Canvas(add("modulo.pdf", "pdf", pages=1, form=True))
    c.drawString(50, 750, "Nome:")
    c.acroForm.textfield(name="nome", x=100, y=735, width=200, height=20)
    c.acroForm.checkbox(name="accetto", x=100, y=700, size=15)
    c.showPage()
    c.save()
    # rotti
    d = open(base, "rb").read()
    open(add("troncato.pdf", "pdf", broken=True), "wb").write(d[: len(d) // 2])
    open(add("vuoto.pdf", "pdf", broken=True), "wb").write(b"")
    shutil.copy(FIX["foto.jpg"]["path"], add("finto.pdf", "pdf", broken=True))
    # xref rovinato (si può riparare)
    bad = d.replace(b"startxref", b"startxref\n999999999\n%")
    open(add("xref-rotto.pdf", "pdf", pages=3, xref=True), "wb").write(bad)
    # nome con accenti
    shutil.copy(base, add("Relazione è già (finale) 日本.pdf", "pdf", pages=3, text="pagina"))


# ───────────────────────── Esecuzione e controlli

def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def temp_snapshot():
    out = set()
    try:
        for n in os.listdir(TMP):
            if "orbit" in n.lower():
                out.add(n)
    except Exception:
        pass
    return out


CASE_N = [0]
CUR = [""]


def run(action, param, files, timeout=420, env=None, out_dir=None, tag=""):
    CASE_N[0] += 1
    cid = f"{CASE_N[0]:03d}"
    od = out_dir or os.path.join(OUT, cid)
    if out_dir is None:
        os.makedirs(od, exist_ok=True)
    pj = param if isinstance(param, str) and not param.startswith("{") and not param.startswith("\"") else param
    if not isinstance(pj, str):
        pj = json.dumps(pj, ensure_ascii=False)
    before_tmp = temp_snapshot()
    in_dirs = {os.path.dirname(f) for f in files}
    before_in = {d: set(os.listdir(d)) for d in in_dirs}
    e = dict(os.environ)
    if env:
        e.update(env)
    t0 = time.time()
    hung = False
    try:
        cp = subprocess.run([args.harness, action, pj, od if out_dir != "-" else "-", *files], capture_output=True, timeout=timeout, env=e)
        stdout, stderr, code = cp.stdout.decode("utf-8", "replace"), cp.stderr.decode("utf-8", "replace"), cp.returncode
    except subprocess.TimeoutExpired as ex:
        hung = True
        stdout, stderr, code = (ex.stdout or b"").decode("utf-8", "replace"), (ex.stderr or b"").decode("utf-8", "replace"), None
    wall = time.time() - t0
    res = None
    for line in stdout.splitlines()[::-1]:
        if line.startswith("{"):
            try:
                res = json.loads(line)
                break
            except Exception:
                pass
    time.sleep(0.2)
    after_tmp = temp_snapshot()
    left_tmp = sorted(after_tmp - before_tmp)
    left_in = []
    if out_dir != "-":
        for d in in_dirs:
            left_in += sorted(set(os.listdir(d)) - before_in[d])
    leftovers_out = []
    if out_dir != "-" and os.path.isdir(od):
        for n in os.listdir(od):
            p = os.path.join(od, n)
            if n.startswith(".orbitlr-") or (os.path.isfile(p) and os.path.getsize(p) == 0):
                leftovers_out.append(n)
    r = dict(id=cid, action=action, param=pj, files=[os.path.basename(f) for f in files], code=code, wall=round(wall, 2), hung=hung,
             res=res, stderr=stderr[-1500:], left_tmp=left_tmp, left_in=left_in, left_out=leftovers_out, problems=[], notes=[], tag=tag)
    if code not in (0, None) and res is None:
        r["problems"].append(f"il motore è uscito con codice {code} senza risposta (crash?): {stderr[-400:]}")
    if hung:
        r["problems"].append(f"BLOCCO: nessuna risposta dopo {timeout} s")
    if left_tmp:
        r["problems"].append(f"temporanei rimasti in %TEMP%: {left_tmp}")
    if left_in:
        r["problems"].append(f"file nuovi accanto all'originale (doveva scrivere nella cartella scelta): {left_in}")
    if leftovers_out:
        r["problems"].append(f"file vuoti o temporanei rimasti tra i risultati: {leftovers_out}")
    for f in left_tmp:
        p = os.path.join(TMP, f)
        try:
            shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
        except Exception:
            pass
    RESULTS.append(r)
    if len(RESULTS) % 10 == 0:
        try:
            json.dump(dict(partial=True, results=RESULTS), open(os.path.join(WORK, f"risultati-{args.group}.json"), "w", encoding="utf-8"), ensure_ascii=False)
        except Exception:
            pass
    st = "OK " if res and res.get("ok") else ("ERR" if res else "???")
    msg = (res or {}).get("error", "")
    log(f"[{cid}] {st} {wall:6.1f}s {action} {pj[:40]} {r['files']} {msg[:140]} {'; '.join(r['problems'])[:300]}")
    return r


def outs(r):
    return [o["path"] for o in ((r.get("res") or {}).get("outputs") or [])]


def ok(r):
    return bool(r.get("res") and r["res"].get("ok"))


def prob(r, s):
    r["problems"].append(s)


def note(r, s):
    r["notes"].append(s)


def get_exif(path):
    try:
        im = Image.open(path)
        ex = im.getexif()
        gps = ex.get_ifd(0x8825)
        return dict(orient=ex.get(ExifBase.Orientation), date=ex.get(ExifBase.DateTime), make=ex.get(ExifBase.Make), gps=bool(gps))
    except Exception as e:
        return dict(err=str(e))


EXPECT_FMT = {"jpg": "JPEG", "png": "PNG", "webp": "WEBP", "avif": "AVIF", "bmp": "BMP", "tiff": "TIFF", "gif": "GIF", "ico": "ICO", "heic": "HEIF"}


def displayed(fx):
    return fx.get("w"), fx.get("h")


def check_image(r, path, ext, w=None, h=None, ref=None):
    try:
        im = Image.open(path)
        im.load()
    except Exception as e:
        prob(r, f"il risultato «{os.path.basename(path)}» non si apre: {e}")
        return None
    want = EXPECT_FMT.get(ext)
    if want and im.format != want and not (want == "AVIF" and im.format in ("AVIF", "HEIF")):
        prob(r, f"«{os.path.basename(path)}» dice {ext} ma è {im.format}")
    if w and h and im.size != (w, h):
        prob(r, f"misure sbagliate: {im.size}, attese {(w, h)}")
    if ref is not None:
        try:
            a = ref.convert("RGB").resize((64, 64))
            b = im.convert("RGB").resize((64, 64))
            diff = sum(abs(x - y) for pa, pb in zip(a.getdata(), b.getdata()) for x, y in zip(pa, pb)) / (64 * 64 * 3)
            if diff > 40:
                prob(r, f"contenuto diverso dall'originale (differenza media {diff:.0f}/255: girata, specchiata o colori sbagliati?)")
            elif diff > 18:
                note(r, f"differenza media dall'originale {diff:.0f}/255")
        except Exception as e:
            note(r, f"confronto non riuscito: {e}")
    return im


def ref_of(fx):
    """L'immagine come dovrebbe vedersi (orientamento applicato), letta con Pillow."""
    try:
        im = Image.open(fx["path"])
        im = ImageOps.exif_transpose(im)
        if im.mode in ("RGBA", "LA", "P"):
            bg = Image.new("RGB", im.size, "white")
            im = im.convert("RGBA")
            bg.paste(im, mask=im.split()[3])
            return bg
        if im.mode.startswith("I"):
            return im.point(lambda v: v / 256).convert("L")
        return im.convert("RGB")
    except Exception:
        return None


def pdf_pages(path, password=None):
    rd = pypdf.PdfReader(path)
    if rd.is_encrypted:
        if password is None:
            return None
        rd.decrypt(password)
    return len(rd.pages)


def pdf_text(path):
    rd = pypdf.PdfReader(path)
    return "\n".join((p.extract_text() or "") for p in rd.pages)


# ───────────────────────── Gruppo «img»

CONV = ["jpg", "png", "webp", "avif", "bmp", "tiff", "gif", "ico", "pdf"]


def group_img():
    names = [n for n, f in FIX.items() if f["kind"] == "img" and bool(f.get("huge") or n == "panorama.jpg") == (CUR[0] == "huge")]
    if args.quick:
        names = names[:6]
    for n in names:
        fx = FIX[n]
        p = fx["path"]
        broken = fx.get("broken")
        bomb = fx.get("bomb")
        ref = None if broken or bomb or fx.get("huge") else ref_of(fx)
        W, H = displayed(fx)
        ops = list(CONV)
        if fx.get("huge"):
            ops = ["jpg", "png", "webp", "avif", "pdf"]
        for to in ops:
            r = run(f"to:{to}", "", [p], timeout=600)
            if broken:
                if ok(r):
                    prob(r, "un file rotto è stato «convertito» senza errore")
                elif r["res"] and not r["res"].get("error"):
                    prob(r, "errore senza messaggio")
                continue
            if not ok(r):
                if not r["hung"]:
                    note(r, "non riuscito: " + (r["res"] or {}).get("error", "?"))
                    if not bomb:
                        prob(r, "conversione non riuscita: " + (r["res"] or {}).get("error", "?"))
                continue
            o = outs(r)
            if len(o) != 1:
                prob(r, f"attesi 1 file, creati {len(o)}")
                continue
            if to == "pdf":
                try:
                    if pdf_pages(o[0]) != 1:
                        prob(r, "il PDF non ha 1 pagina")
                except Exception as e:
                    prob(r, f"PDF illeggibile: {e}")
                continue
            ew, eh = (W, H)
            if to == "ico" and W and H and max(W, H) > 256:
                k = 256 / max(W, H)
                ew, eh = None, None  # misura: lato lungo 256
            im = check_image(r, o[0], to, ew, eh, ref if to not in ("gif",) else None)
            if im is not None:
                if to == "ico" and max(im.size) > 256:
                    prob(r, f"icona più grande di 256: {im.size}")
                ex = get_exif(o[0])
                if ex.get("orient") not in (None, 1):
                    prob(r, f"orientamento EXIF rimasto {ex.get('orient')} su pixel già raddrizzati (si vedrà girata due volte)")
                if fx.get("gps"):
                    if to == "jpg" and not ex.get("gps"):
                        prob(r, "GPS perso convertendo in JPG (la promessa: posizione e data restano)")
                    elif to in ("png", "webp", "avif", "tiff") and not ex.get("gps"):
                        note(r, f"GPS/data persi convertendo in {to.upper()}")
                if fx.get("deep") and to in ("png", "tiff") and im.mode not in ("I;16", "I;16B", "I", "RGB;16", "I;16L") and "16" not in im.mode:
                    note(r, f"16 bit diventati 8 bit ({im.mode})")
                if fx.get("alpha") and to in ("png", "webp", "tiff", "avif"):
                    if "A" not in im.mode and "transparency" not in im.info:
                        prob(r, f"trasparenza persa in {to.upper()} (modo {im.mode})")
                if fx.get("cmyk") and to == "jpg":
                    if im.mode != "RGB":
                        note(r, f"JPG in modo {im.mode}")
                    if im.info.get("icc_profile"):
                        note(r, "profilo ICC copiato")
                if fx.get("icc") and to in ("jpg", "png") and not im.info.get("icc_profile"):
                    note(r, f"profilo ICC perso in {to}")
                icc = im.info.get("icc_profile")
                if icc and len(icc) > 20:
                    space = bytes(icc[16:20])
                    pix = {"RGB": b"RGB ", "RGBA": b"RGB ", "L": b"GRAY", "LA": b"GRAY", "CMYK": b"CMYK", "P": b"RGB "}.get(im.mode)
                    if pix and space != pix:
                        prob(r, f"profilo colore {space.decode(errors='replace').strip()} dentro un'immagine {im.mode}: i programmi mostrano colori sbagliati o la rifiutano")
        if broken:
            for act, par in [("icompress", "best"), ("resize", "50%"), ("rotate", 90), ("strip", ""), ("vector", "auto")]:
                r = run(act, par, [p])
                if ok(r):
                    prob(r, "un file rotto ha dato un risultato")
            continue
        # comprimi
        r = run("icompress", "best", [p], timeout=600)
        if ok(r):
            o = outs(r)[0]
            check_image(r, o, "jpg", W, H, ref)
            if os.path.getsize(o) >= os.path.getsize(p):
                prob(r, f"«compresso» non pesa meno: {os.path.getsize(o)} ≥ {os.path.getsize(p)}")
            ex = get_exif(o)
            if fx.get("gps") and not ex.get("gps"):
                prob(r, "GPS perso comprimendo")
            if ex.get("orient") not in (None, 1):
                prob(r, f"orientamento EXIF {ex.get('orient')} rimasto")
        else:
            note(r, "comprimi: " + (r["res"] or {}).get("error", "?"))
        if not bomb:
            r = run("icompress", 50, [p], timeout=600)  # sotto 50 KB
            if ok(r):
                o = outs(r)[0]
                if os.path.getsize(o) > 50_000:
                    prob(r, f"doveva stare sotto 50 KB, pesa {os.path.getsize(o)}")
                im = check_image(r, o, "jpg")
            else:
                note(r, "sotto 50 KB: " + (r["res"] or {}).get("error", "?"))
        # ridimensiona
        for par in ["50%", "800"]:
            r = run("resize", par, [p], timeout=600)
            if W and H:
                if par == "50%":
                    ew, eh = max(1, round(W * 0.5)), max(1, round(H * 0.5))
                else:
                    k = 800 / max(W, H)
                    ew, eh = (max(1, round(W * k)), max(1, round(H * k))) if k < 1 else (None, None)
                if ok(r):
                    ext = os.path.splitext(outs(r)[0])[1][1:].lower()
                    im = check_image(r, outs(r)[0], ext, ew, eh, ref)
                    if im is not None and fx.get("gps") and ext == "jpg" and not get_exif(outs(r)[0]).get("gps"):
                        prob(r, "GPS perso ridimensionando")
                elif ew is not None and not bomb and not fx.get("tiny"):
                    prob(r, "ridimensiona non riuscito: " + (r["res"] or {}).get("error", "?"))
        # ruota
        for deg in [90, 180, 270]:
            if fx.get("huge") and deg != 90:
                continue
            r = run("rotate", deg, [p], timeout=600)
            if ok(r):
                ext = os.path.splitext(outs(r)[0])[1][1:].lower()
                ew, eh = (H, W) if deg in (90, 270) else (W, H)
                rref = None
                if ref is not None:
                    rref = ref.rotate(-deg, expand=True)
                im = check_image(r, outs(r)[0], ext, ew, eh, rref)
                ex = get_exif(outs(r)[0])
                if ex.get("orient") not in (None, 1):
                    prob(r, f"orientamento EXIF {ex.get('orient')} rimasto dopo la rotazione")
            elif not bomb:
                prob(r, "ruota non riuscito: " + (r["res"] or {}).get("error", "?"))
        # togli i metadati
        r = run("strip", "", [p])
        if ok(r):
            o = outs(r)[0]
            ex = get_exif(o)
            if ex.get("gps") or ex.get("make") or ex.get("date"):
                prob(r, f"metadati ancora presenti: {ex}")
            ext = os.path.splitext(o)[1][1:].lower()
            # senza metadati l'orientamento EXIF sparisce: i pixel devono essere quelli giusti
            im = check_image(r, o, ext, None, None)
            if im is not None and fx.get("orient") in (6, 8) and im.size != (W, H):
                prob(r, f"«Rimuovi i metadati» su una foto con orientamento {fx['orient']}: ora si vede {im.size[0]}×{im.size[1]} invece di {W}×{H} (girata)")
            if im is not None and fx.get("orient") == 3 and ref is not None:
                check_image(r, o, ext, None, None, ref)
        else:
            note(r, "strip: " + (r["res"] or {}).get("error", "?"))
    if CUR[0] == "huge":
      for act in ["to:avif", "to:webp", "to:png", "icompress"]:
        r = run(act, 50 if act == "icompress" else "", [FIX["enorme.jpg"]["path"]], env={"W04_CANCEL_AFTER_MS": "1500"}, tag="interrompi")
        if ok(r):
            note(r, "finito prima dell'interruzione")
        elif r["res"] and not r["res"].get("cancelled"):
            prob(r, f"interrotto ma l'errore non dice «interrotto»: {r['res'].get('error')}")
        if r["wall"] > 20:
            prob(r, f"«Interrompi» dopo 1,5 s non ferma: finito dopo {r['wall']} s")
        if ok(r):
            prob(r, f"«Interrompi» dopo 1,5 s ma il file è stato creato lo stesso: {outs(r)}")
      return
    # più foto in un PDF, con ordine
    imgs = [FIX[n]["path"] for n in ["orient6.jpg", "alpha.png", "iphone.heic", "Città già è perché ñ 日本 😀.jpg"]]
    r = run("merge", "", imgs, timeout=600)
    if ok(r):
        n = pdf_pages(outs(r)[0])
        if n != 4:
            prob(r, f"PDF con {n} pagine invece di 4")
        rd = pypdf.PdfReader(outs(r)[0])
        mb = rd.pages[0].mediabox
        if float(mb.width) > float(mb.height):
            prob(r, "la prima foto (verticale per l'EXIF) è in una pagina orizzontale")
    else:
        prob(r, "unisci foto in PDF non riuscito")
    r = run("merge", "", [FIX["foto.jpg"]["path"], FIX["troncata.jpg"]["path"]])
    if ok(r):
        prob(r, "con una foto rotta il PDF è stato creato lo stesso")
    for act, fs in [("merge", ["orient6.jpg", "alpha.png"]), ("stack", ["scatto1.jpg", "scatto2.jpg"]), ("straighten", ["documento.jpg"]), ("to:pdf", ["foto.bmp", "alpha.png"])]:
        r = run(act, "", [FIX[x]["path"] for x in fs], env={"W04_LANG": "en"}, tag="en")
        if ok(r):
            nm = [os.path.basename(x) for x in outs(r)]
            note(r, f"nomi in inglese: {nm}")
            ita = [w for w in [" e altre ", "scatti", "raddrizzato"] if any(w in x for x in nm)]
            if ita:
                prob(r, f"app in inglese, ma il file creato si chiama {nm[0]!r} (parole italiane «{ita[0].strip()}»)")
            if act == "to:pdf":
                k = pdf_pages(outs(r)[0])
                note(r, f"«Converti in PDF» con 2 foto: {len(outs(r))} file, {k} pagine")
    # stack
    r = run("stack", "", [FIX[f"scatto{i}.jpg"]["path"] for i in (1, 2, 3)])
    if ok(r):
        check_image(r, outs(r)[0], "jpg", 800, 600)
    else:
        note(r, "stack: " + (r["res"] or {}).get("error", "?"))
    r = run("stack", "", [FIX["scatto1.jpg"]["path"], FIX["foto.jpg"]["path"]])
    if ok(r):
        prob(r, "stack di foto di misure diverse non ha dato errore")
    # stesso lavoro due volte nella stessa cartella: mai sovrascrivere
    od = os.path.join(OUT, "doppio")
    os.makedirs(od, exist_ok=True)
    r1 = run("to:png", "", [FIX["foto (compresso).jpg"]["path"]], out_dir=od)
    r2 = run("to:png", "", [FIX["foto (compresso).jpg"]["path"]], out_dir=od)
    if ok(r1) and ok(r2):
        if outs(r1)[0] == outs(r2)[0]:
            prob(r2, "il secondo risultato ha sovrascritto il primo")
        note(r2, f"nomi: {os.path.basename(outs(r1)[0])} / {os.path.basename(outs(r2)[0])}")
    # risultato accanto all'originale (out_dir None)
    beside = os.path.join(WORK, "accanto")
    os.makedirs(beside, exist_ok=True)
    cp = os.path.join(beside, "Perché è così.heic")
    shutil.copy(FIX["iphone.heic"]["path"], cp)
    r = run("to:jpg", "", [cp], out_dir="-")
    if ok(r):
        if os.path.dirname(outs(r)[0]) != beside:
            prob(r, f"il risultato non è accanto all'originale: {outs(r)[0]}")
        if not get_exif(outs(r)[0]).get("gps"):
            prob(r, "HEIC → JPG: GPS perso")
        left = [n for n in os.listdir(beside) if n.startswith(".orbitlr-")]
        if left:
            prob(r, f"temporanei accanto all'originale: {left}")
    else:
        prob(r, "HEIC → JPG accanto all'originale non riuscito")
    # OCR
    for n in ["testo.png", "documento.jpg", "foto.jpg"]:
        r = run("ocr", "", [FIX[n]["path"]])
        if ok(r):
            t = open(outs(r)[0], encoding="utf-8", errors="replace").read()
            note(r, "testo: " + t[:120].replace("\n", " | "))
            if n == "testo.png" and "orbit" not in t.lower():
                prob(r, f"OCR non ha letto «OrbitLR»: {t[:100]!r}")
        else:
            note(r, "ocr: " + (r["res"] or {}).get("error", "?"))
    # Raddrizza
    for par in ["", "pdf"]:
        r = run("straighten", par, [FIX["documento.jpg"]["path"]])
        if ok(r):
            o = outs(r)[0]
            if par == "pdf":
                if pdf_pages(o) != 1:
                    prob(r, "PDF raddrizzato senza 1 pagina")
            else:
                im = check_image(r, o, "jpg")
                if im is not None:
                    note(r, f"raddrizzata {im.size}")
        else:
            note(r, "raddrizza: " + (r["res"] or {}).get("error", "?"))
    r = run("straighten", "", [FIX["1x1.png"]["path"]])
    r = run("straighten", "", [FIX["foto.jpg"]["path"]])


# ───────────────────────── Gruppo «pdf»

def group_pdf():
    pdfs = [n for n, f in FIX.items() if f["kind"] == "pdf"]
    for n in pdfs:
        fx = FIX[n]
        p = fx["path"]
        broken = fx.get("broken")
        pw = fx.get("password")
        locked = pw is not None and pw != ""
        np_ = fx.get("pages")
        big = np_ and np_ >= 300
        # in immagini
        for to in ["png", "jpg"]:
            if big and to == "jpg":
                continue
            r = run(f"to:{to}", "", [p], timeout=900)
            if broken or locked:
                if ok(r):
                    prob(r, "un PDF rotto/protetto ha dato immagini")
                elif locked and "password" not in ((r["res"] or {}).get("error", "")).lower():
                    prob(r, f"PDF con password: il messaggio non lo dice: {(r['res'] or {}).get('error')!r}")
                elif broken and (r["res"] or {}).get("error", "").rstrip().endswith(":"):
                    prob(r, f"messaggio vuoto per un PDF rotto: {(r['res'] or {}).get('error')!r}")
                continue
            if not ok(r):
                prob(r, "PDF in immagini non riuscito: " + (r["res"] or {}).get("error", "?"))
                continue
            o = outs(r)
            if np_ and len(o) != np_:
                prob(r, f"{len(o)} immagini per {np_} pagine")
            for q in o[:3]:
                im = check_image(r, q, to)
                if im is not None and n == "testo3.pdf":
                    note(r, f"{os.path.basename(q)} {im.size}")
            if n == "ruotato.pdf" and len(o) >= 2:
                a, b = Image.open(o[0]).size, Image.open(o[1]).size
                if (a[0] > a[1]) == (b[0] > b[1]):
                    prob(r, f"la pagina 2 ruotata di 90° non risulta ruotata: {a} e {b}")
            if n == "testo3.pdf" and len(o) == 3:
                s = [Image.open(q).size for q in o]
                if not (s[1][0] > s[1][1] and s[0][1] > s[0][0]):
                    prob(r, f"orientamento pagine sbagliato: {s}")
        # testo
        r = run("pdftext", "", [p], timeout=900)
        if broken or locked:
            if ok(r):
                prob(r, "testo da un PDF rotto/protetto")
            elif locked and "password" not in ((r["res"] or {}).get("error", "")).lower():
                prob(r, f"PDF con password, «Estrai il testo»: il messaggio non lo dice: {(r['res'] or {}).get('error')!r}")
        elif ok(r):
            t = open(outs(r)[0], encoding="utf-8", errors="replace").read()
            note(r, "testo: " + t[:100].replace("\n", " | "))
            if fx.get("text") and fx["text"].lower() not in t.lower():
                prob(r, f"nel testo manca «{fx['text']}»")
            if fx.get("text") and "città" not in t.lower() and n != "300pagine.pdf":
                note(r, "le lettere accentate non sono uscite giuste")
            if fx.get("scan") and "invoice" not in t.lower():
                prob(r, f"OCR della scansione non ha letto «INVOICE»: {t[:80]!r}")
            if big and "Pagina 300" not in t:
                prob(r, "manca il testo dell'ultima pagina")
        else:
            if fx.get("form") or n == "cmyk.pdf" or n == "foto-grandi.pdf":
                note(r, "pdftext: " + (r["res"] or {}).get("error", "?"))
            else:
                prob(r, "estrai testo non riuscito: " + (r["res"] or {}).get("error", "?"))
        if broken:
            for act, par in [("split", ""), ("extract", "1"), ("pdfcompress", "medium"), ("protect", {"password": "abcd1234"}), ("rotate", {"angle": 90}), ("reorder", "2,1")]:
                r = run(act, par, [p])
                if ok(r):
                    prob(r, "un PDF rotto ha dato un risultato")
                elif r["res"] and "valido" not in r["res"].get("error", "") and "password" not in r["res"].get("error", ""):
                    note(r, "messaggio: " + r["res"].get("error", ""))
            continue
        if locked:
            r = run("unprotect", {"password": "sbagliata"}, [p])
            if ok(r):
                prob(r, "sbloccato con la password sbagliata")
            r = run("unprotect", {"password": pw}, [p])
            if ok(r):
                o = outs(r)[0]
                rd = pypdf.PdfReader(o)
                if rd.is_encrypted:
                    prob(r, "il PDF «sbloccato» ha ancora la password")
                elif len(rd.pages) != np_:
                    prob(r, f"pagine {len(rd.pages)} invece di {np_}")
                elif "pagina" not in pdf_text(o).lower():
                    prob(r, "il testo del PDF sbloccato non si legge (decifratura sbagliata?)")
            else:
                prob(r, "sblocca con la password giusta non riuscito: " + (r["res"] or {}).get("error", "?"))
            for act, par in [("split", ""), ("extract", "1"), ("pdfcompress", "medium"), ("rotate", {"angle": 90})]:
                r = run(act, par, [p])
                if ok(r):
                    prob(r, "lavoro su un PDF protetto senza password")
            continue
        if pw == "":
            # solo permessi: si apre senza password
            r = run("unprotect", {"password": fx["owner"]}, [p])
            note(r, "sblocca (password del proprietario): " + ("ok" if ok(r) else (r["res"] or {}).get("error", "?")))
            r = run("unprotect", {"password": ""}, [p])
            note(r, "sblocca (password vuota): " + ("ok" if ok(r) else (r["res"] or {}).get("error", "?")))
            r = run("extract", "1", [p])
            note(r, "estrai da PDF con soli permessi: " + ("ok" if ok(r) else (r["res"] or {}).get("error", "?")))
            r = run("to:png", "", [p])
            continue
        # proteggi
        r = run("protect", {"password": "Città-è1"}, [p], timeout=600)
        if ok(r):
            o = outs(r)[0]
            rd = pypdf.PdfReader(o)
            if not rd.is_encrypted:
                prob(r, "il PDF protetto non ha la password")
            else:
                if rd.decrypt("Città-è1") == 0:
                    prob(r, "la password con lettere accentate non apre il PDF (con pypdf)")
                elif np_ and len(rd.pages) != np_:
                    prob(r, "pagine diverse dopo la protezione")
            r2 = run("unprotect", {"password": "Città-è1"}, [o])
            if not ok(r2):
                prob(r2, "il PDF appena protetto non si sblocca con la sua password")
            r3 = run("to:png", "", [o])
            if ok(r3):
                prob(r3, "PDF protetto trasformato in immagini senza password")
            elif "password" not in ((r3["res"] or {}).get("error", "")).lower():
                prob(r3, f"il PDF appena protetto dall'app, trasformato in immagini, non dice «password»: {(r3['res'] or {}).get('error')!r}")
        else:
            prob(r, "proteggi non riuscito: " + (r["res"] or {}).get("error", "?"))
        r = run("protect", {"password": "ab"}, [p])
        if ok(r):
            prob(r, "password di 2 caratteri accettata")
        r = run("unprotect", {"password": "x"}, [p])
        if ok(r):
            prob(r, "sbloccato un PDF senza password")
        # dividi, estrai, riordina, ruota
        if np_ and np_ >= 2:
            r = run("split", "", [p], timeout=900)
            if ok(r):
                o = outs(r)
                if len(o) != np_:
                    prob(r, f"{len(o)} file per {np_} pagine")
                bad = [q for q in o[:5] + o[-3:] if pdf_pages(q) != 1]
                if bad:
                    prob(r, f"file con più di una pagina: {bad[:2]}")
                if big:
                    t = pdf_text(o[-1])
                    if "Pagina 300" not in t:
                        prob(r, f"l'ultimo file non è la pagina 300: {t[:40]!r}")
                note(r, f"{len(o)} file in {r['wall']} s")
            else:
                prob(r, "dividi non riuscito: " + (r["res"] or {}).get("error", "?"))
            for par, want in [("1-2", 2), ("2-", np_ - 1), ("1, 1, 2", 2), ("0", None), (f"{np_+1}", None), ("abc", None), ("3-1", None)]:
                r = run("extract", par, [p])
                if want is None:
                    if ok(r):
                        prob(r, f"«{par}» accettato")
                elif ok(r):
                    k = pdf_pages(outs(r)[0])
                    if k != want:
                        prob(r, f"estrai «{par}»: {k} pagine invece di {want}")
                else:
                    prob(r, f"estrai «{par}» non riuscito: " + (r["res"] or {}).get("error", "?"))
            r = run("reorder", f"{np_},1", [p], timeout=600)
            if ok(r):
                o = outs(r)[0]
                rd = pypdf.PdfReader(o)
                if len(rd.pages) != np_:
                    prob(r, f"riordina: {len(rd.pages)} pagine invece di {np_}")
                t0 = rd.pages[0].extract_text() or ""
                if fx.get("text") and str(np_) not in t0:
                    prob(r, f"riordina: la prima pagina non è la {np_}: {t0[:40]!r}")
            else:
                prob(r, "riordina non riuscito: " + (r["res"] or {}).get("error", "?"))
            r = run("rotate", {"angle": 90, "pages": "2"}, [p], timeout=600)
            if ok(r):
                rd = pypdf.PdfReader(outs(r)[0])
                rots = [pg.rotation % 360 for pg in rd.pages[:3]]
                exp1 = (0 + 0) % 360
                orig = [pg.rotation % 360 for pg in pypdf.PdfReader(p).pages[:3]]
                want = [orig[0], (orig[1] + 90) % 360] + orig[2:3]
                if rots != want:
                    prob(r, f"rotazioni {rots}, attese {want}")
            else:
                prob(r, "ruota pagine non riuscito: " + (r["res"] or {}).get("error", "?"))
        r = run("rotate", {"angle": 270}, [p], timeout=600)
        if ok(r):
            rd = pypdf.PdfReader(outs(r)[0])
            orig = [pg.rotation % 360 for pg in pypdf.PdfReader(p).pages]
            rots = [pg.rotation % 360 for pg in rd.pages]
            if rots != [(o + 270) % 360 for o in orig]:
                prob(r, f"ruota tutte 270: {rots[:5]}… attese {[(o + 270) % 360 for o in orig][:5]}")
        else:
            prob(r, "ruota tutte non riuscito: " + (r["res"] or {}).get("error", "?"))
        # comprimi
        for lev in ["light", "medium", "strong"]:
            r = run("pdfcompress", lev, [p], timeout=900)
            if ok(r):
                o = outs(r)[0]
                if pdf_pages(o) != np_:
                    prob(r, "pagine diverse dopo la compressione")
                if os.path.getsize(o) >= os.path.getsize(p):
                    prob(r, "compresso ma non più leggero")
                note(r, f"{os.path.getsize(p)} → {os.path.getsize(o)}")
                if fx.get("form"):
                    if not pypdf.PdfReader(o).get_fields():
                        prob(r, "i campi del modulo sono spariti")
            else:
                note(r, f"comprimi {lev}: " + (r["res"] or {}).get("error", "?"))
                if n.startswith("foto-") and os.path.getsize(p) > 3_000_000:
                    prob(r, f"PDF di {os.path.getsize(p)//1_000_000} MB con foto grandi: «{lev}» non comprime: {(r['res'] or {}).get('error')!r}")
        # editor
        if np_:
            ed = {"texts": [{"page": 1, "x": 60, "y": 60, "size": 14, "text": "Città è già € — ok"}]}
            if np_ >= 2:
                ed["redactions"] = [{"page": 2, "x": 0, "y": 0, "w": 600, "h": 300}]
            if fx.get("form"):
                ed["fields"] = {"nome": "Ledà Prova", "accetto": "true"}
            r = run("pdfedit", ed, [p], timeout=900)
            if ok(r):
                o = outs(r)[0]
                rd = pypdf.PdfReader(o)
                if len(rd.pages) != np_:
                    prob(r, "pagine diverse dopo le modifiche")
                t1 = rd.pages[0].extract_text() or ""
                if "Citt" not in t1:
                    prob(r, f"il testo aggiunto non c'è sulla pagina 1: {t1[:80]!r}")
                elif "Città è già" not in t1:
                    note(r, f"testo aggiunto letto come {t1[:80]!r}")
                if np_ >= 2:
                    t2 = rd.pages[1].extract_text() or ""
                    if fx.get("text") and "pagina 2" in t2.lower():
                        prob(r, f"la pagina 2 oscurata ha ancora il testo copiabile: {t2[:60]!r}")
                if fx.get("form"):
                    fl = rd.get_fields() or {}
                    v = (fl.get("nome") or {}).get("/V")
                    note(r, f"campo nome = {v!r}")
                    if v != "Ledà Prova":
                        prob(r, f"campo «nome» = {v!r} invece di «Ledà Prova»")
            else:
                prob(r, "editor PDF non riuscito: " + (r["res"] or {}).get("error", "?"))
        # editor con pagina che non c'è
        r = run("pdfedit", {"texts": [{"page": 99, "x": 1, "y": 1, "text": "x"}]}, [p])
        if ok(r):
            note(r, "testo su pagina 99: nessun errore, creato comunque un PDF")
    # App in inglese: i nomi dei file creati non devono avere parole italiane
    en = {"W04_LANG": "en"}
    for act, par, fs in [("pdfedit", {"texts": [{"page": 1, "x": 50, "y": 50, "text": "hello"}]}, ["testo3.pdf"]),
                         ("pdfedit", {"redactions": [{"page": 1, "x": 0, "y": 0, "w": 100, "h": 100}]}, ["testo3.pdf"]),
                         ("pdfedit", {"fields": {"nome": "Bob"}}, ["modulo.pdf"]),
                         ("split", "", ["testo3.pdf"]), ("extract", "1", ["testo3.pdf"]), ("pdfmerge", "", ["testo3.pdf", "ruotato.pdf"]),
                         ("protect", {"password": "abcd1234"}, ["testo3.pdf"]), ("pdftext", "", ["testo3.pdf"]), ("to:png", "", ["testo3.pdf"])]:
        r = run(act, par, [FIX[x]["path"] for x in fs], env=en, tag="en")
        if ok(r):
            nm = [os.path.basename(x) for x in outs(r)]
            note(r, f"nomi in inglese: {nm[:3]}")
            ita = [w for w in ["compilato", "oscurato", "firmato", "pagina", "pagine", "uniti", "protetto", "testo", " e altre "] if any(w in x for x in nm)]
            if ita:
                prob(r, f"app in inglese, ma il file creato si chiama {nm[0]!r} (parola italiana «{ita[0]}»)")
    # unisci
    groups = [
        ["testo3.pdf", "Relazione è già (finale) 日本.pdf", "ruotato.pdf"],
        ["300pagine.pdf", "testo3.pdf"],
        ["scansione.pdf", "foto-grandi.pdf", "modulo.pdf"],
        ["testo3.pdf", "password.pdf"],
        ["testo3.pdf", "troncato.pdf"],
        ["testo3.pdf", "xref-rotto.pdf"],
        ["testo3.pdf", "testo3.pdf"],
    ]
    for g in groups:
        fs = [FIX[x]["path"] for x in g]
        r = run("pdfmerge", "", fs, timeout=900)
        want = sum((FIX[x].get("pages") or 0) for x in g)
        bad = any(FIX[x].get("broken") or (FIX[x].get("password") or "") for x in g)
        if bad:
            if ok(r):
                prob(r, "unito con un PDF rotto o protetto")
            continue
        if ok(r):
            o = outs(r)[0]
            k = pdf_pages(o)
            if k != want:
                prob(r, f"{k} pagine invece di {want}")
            t = pdf_text(o)
            if "ruotato.pdf" in g:
                rd = pypdf.PdfReader(o)
                if rd.pages[7].rotation % 360 != 90:
                    prob(r, f"la rotazione della pagina 2 di «ruotato.pdf» si è persa ({rd.pages[7].rotation})")
            if "300pagine.pdf" in g and "Pagina 300" not in t:
                prob(r, "manca la pagina 300 nel PDF unito")
            if "modulo.pdf" in g:
                note(r, f"campi del modulo dopo l'unione: {list((pypdf.PdfReader(o).get_fields() or {}).keys())}")
        else:
            prob(r, "unisci non riuscito: " + (r["res"] or {}).get("error", "?"))
    r = run("pdfmerge", "", [FIX["testo3.pdf"]["path"]])
    if ok(r):
        prob(r, "unito un PDF solo")
    # Interrompi lo split di 300 pagine
    r = run("to:png", "", [FIX["300pagine.pdf"]["path"]], env={"W04_CANCEL_AFTER_MS": "3000"})
    if ok(r):
        note(r, "finito prima dell'interruzione")
    else:
        note(r, f"interrotto: {(r['res'] or {}).get('error')} · file rimasti nella cartella: {len(os.listdir(os.path.join(OUT, r['id'])))}")
        if r["wall"] > 30:
            prob(r, f"«Interrompi» non ferma: {r['wall']} s")


# ───────────────────────── Gruppo «ai»

def group_ai():
    data_off = os.path.join(WORK, "dati-vuoti")
    os.makedirs(data_off, exist_ok=True)
    off = {"W04_DATA": data_off, "HTTPS_PROXY": "http://127.0.0.1:9", "HTTP_PROXY": "http://127.0.0.1:9", "ALL_PROXY": "http://127.0.0.1:9", "https_proxy": "http://127.0.0.1:9"}
    subj = FIX["soggetto.jpg"]["path"]
    logo = FIX["logo.png"]["path"]
    # 1 senza modelli e senza internet: messaggio chiaro, niente blocco
    for act, par, f in [("removebg", "transparent", subj), ("upscale", 2, subj), ("aienhance", 70, subj), ("vector", "logo", logo), ("hidemark", {"zones": [{"x": 0.1, "y": 0.1, "w": 0.2, "h": 0.1}]}, subj)]:
        r = run(act, par, [f], timeout=180, env=off, tag="offline")
        if r["hung"]:
            continue
        if act == "vector":
            if not ok(r):
                prob(r, "vettoriale senza il motore dell'IA non va avanti da solo: " + (r["res"] or {}).get("error", "?"))
            else:
                note(r, f"vettoriale senza IA in {r['wall']} s")
            continue
        if ok(r):
            note(r, "riuscito senza internet")
            continue
        msg = (r["res"] or {}).get("error", "")
        note(r, "messaggio: " + msg)
        if "internet" not in msg.lower() and "scaric" not in msg.lower():
            prob(r, f"senza internet il messaggio non dice di internet/scaricare: {msg!r}")
        if r["wall"] > 70:
            prob(r, f"senza internet ci mette {r['wall']} s per dirlo")
        left = []
        for root, _, fs in os.walk(data_off):
            left += fs
        if left:
            note(r, f"file rimasti nella cartella dei modelli: {left}")
    # 2 modello finto (misura giusta? no: misura sbagliata → si riscarica; contenuto rovinato della misura giusta)
    fake = os.path.join(WORK, "dati-finti")
    os.makedirs(os.path.join(fake, "modelli", "realesrgan", "models"), exist_ok=True)
    with open(os.path.join(fake, "modelli", "isnet-general-use.onnx"), "wb") as f:
        f.truncate(178_648_008)
    for fn in ["realesrgan-ncnn-vulkan.exe", "vcomp140.dll", "models/realesrgan-x4plus.bin", "models/realesrgan-x4plus.param", "models/realesrgan-x4plus-anime.bin", "models/realesrgan-x4plus-anime.param", "pronto.txt",
               "realesrgan-ncnn-vulkan"]:
        open(os.path.join(fake, "modelli", "realesrgan", fn), "wb").write(b"rotto")
    for act, par in [("removebg", "transparent"), ("upscale", 2)]:
        r = run(act, par, [subj], timeout=240, env={"W04_DATA": fake}, tag="finto")
        if ok(r):
            prob(r, "con un modello rovinato ha dato un risultato")
        else:
            note(r, "messaggio: " + (r["res"] or {}).get("error", "?"))
    r = run("vector", "logo", [logo], timeout=240, env={"W04_DATA": fake}, tag="finto")
    if not ok(r):
        prob(r, "vettoriale con motore IA rovinato non va avanti senza: " + (r["res"] or {}).get("error", "?"))
    # 3 per davvero (scarica i modelli)
    real = os.path.join(WORK, "dati")
    os.makedirs(real, exist_ok=True)
    env = {"W04_DATA": real}
    for mode in ["transparent", "white", "crop"]:
        r = run("removebg", mode, [subj], timeout=1500, env=env, tag="vero")
        if ok(r):
            o = outs(r)[0]
            im = Image.open(o)
            note(r, f"{os.path.basename(o)} {im.size} {im.mode} in {r['wall']} s")
            if mode == "transparent":
                if im.size != (900, 700) or im.mode != "RGBA":
                    prob(r, f"atteso PNG 900×700 trasparente, è {im.size} {im.mode}")
                else:
                    a = im.split()[3]
                    if a.getpixel((10, 10)) > 128 or a.getpixel((450, 500)) < 128:
                        note(r, f"maschera: angolo {a.getpixel((10, 10))}, soggetto {a.getpixel((450, 500))}")
            if mode == "crop" and im.size[0] >= 900 and im.size[1] >= 700:
                note(r, "ritaglio grande come la foto")
        else:
            note(r, "removebg: " + (r["res"] or {}).get("error", "?"))
    for f in [FIX["alpha.png"]["path"], FIX["orient6.jpg"]["path"], FIX["iphone.heic"]["path"], FIX["1x1.png"]["path"], FIX["enorme.jpg"]["path"]]:
        r = run("removebg", "transparent", [f], timeout=1500, env=env, tag="vero")
        if ok(r):
            im = Image.open(outs(r)[0])
            fx = FIX[os.path.basename(f)]
            if im.size != (fx["w"], fx["h"]):
                prob(r, f"senza sfondo: misure {im.size} invece di {(fx['w'], fx['h'])}")
        else:
            note(r, "removebg: " + (r["res"] or {}).get("error", "?"))
    for act, par, f in [("upscale", 2, subj), ("upscale", 4, FIX["orient6.jpg"]["path"]), ("aienhance", 70, subj), ("aienhance", "anime", logo), ("upscale", 2, FIX["enorme.jpg"]["path"]), ("upscale", 2, FIX["2x3.jpg"]["path"])]:
        r = run(act, par, [f], timeout=1500, env=env, tag="vero")
        if ok(r):
            im = Image.open(outs(r)[0])
            fx = FIX[os.path.basename(f)]
            k = par if isinstance(par, int) and act == "upscale" else 1
            if im.size != (fx["w"] * k, fx["h"] * k):
                prob(r, f"misure {im.size} invece di {(fx['w'] * k, fx['h'] * k)}")
        else:
            msg = (r["res"] or {}).get("error", "?")
            note(r, f"{act}: {msg}")
            if r["wall"] > 600:
                prob(r, f"{act}: ci mette {r['wall']} s per fallire")
    for par in ["auto", "logo", "logot", "bw", "photo", "logo+", "pack"]:
        f = logo if par != "photo" else subj
        r = run("vector", par, [f], timeout=1500, env=env, tag="vero")
        if ok(r):
            o = outs(r)[0]
            head = open(o, "rb").read(400)
            if par == "pack":
                import zipfile
                try:
                    note(r, "zip: " + ", ".join(zipfile.ZipFile(o).namelist()[:12]))
                except Exception as e:
                    prob(r, f"pacchetto non è uno zip: {e}")
            elif b"<svg" not in head and b"<?xml" not in head:
                prob(r, f"non sembra un SVG: {head[:80]!r}")
            note(r, f"{os.path.basename(o)} {os.path.getsize(o)} B in {r['wall']} s")
        else:
            prob(r, f"vettoriale «{par}» non riuscito: " + (r["res"] or {}).get("error", "?"))
    for f in [FIX["1x1.png"]["path"], FIX["alpha.png"]["path"], FIX["iphone.heic"]["path"], FIX["enorme.jpg"]["path"]]:
        r = run("vector", "auto", [f], timeout=1500, env=env, tag="vero")
        if not ok(r):
            note(r, "vettoriale: " + (r["res"] or {}).get("error", "?"))
    r = run("hidemark", {"zones": [{"x": 0.1, "y": 0.1, "w": 0.2, "h": 0.1}]}, [subj], timeout=1500, env=env, tag="vero")
    note(r, "hidemark: " + ("ok" if ok(r) else (r["res"] or {}).get("error", "?")))


# ───────────────────────── Via

t0 = time.time()
make_images()
make_pdfs()
log(f"{len(FIX)} file di prova pronti in {time.time() - t0:.0f} s")
if args.only_fixtures:
    for n, f in FIX.items():
        log(n, os.path.getsize(f["path"]))
    sys.exit(0)
hashes = {n: sha(f["path"]) for n, f in FIX.items()}
groups = args.group.split(",") if args.group != "all" else ["img", "huge", "pdf", "ai"]
for g in groups:
    CUR[0] = g
    try:
        {"img": group_img, "huge": group_img, "pdf": group_pdf, "ai": group_ai}[g]()
    except Exception as e:
        import traceback
        log("ERRORE DELLO SCRIPT DI PROVA:", traceback.format_exc())
        RESULTS.append(dict(id="script", action=g, param="", files=[], problems=[], notes=[f"errore dello script di prova: {e!r}"], res=None, wall=0))
# originali intatti
changed = [n for n, f in FIX.items() if not os.path.exists(f["path"]) or sha(f["path"]) != hashes[n]]
summary = dict(group=args.group, fixtures=len(FIX), cases=len(RESULTS), with_problems=sum(1 for r in RESULTS if r["problems"]),
               originals_changed=changed, minutes=round((time.time() - t0) / 60, 1), platform=sys.platform)
if changed:
    log("ORIGINALI CAMBIATI: " + ", ".join(changed))
json.dump(dict(summary=summary, fixtures={n: {k: v for k, v in f.items() if k != "path"} | {"size": os.path.getsize(f["path"]) if os.path.exists(f["path"]) else None} for n, f in FIX.items()}, results=RESULTS),
          open(os.path.join(WORK, f"risultati-{args.group}.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
with open(os.path.join(WORK, f"risultati-{args.group}.md"), "w", encoding="utf-8") as f:
    f.write(f"# W04 · {args.group}\n\n{json.dumps(summary, ensure_ascii=False)}\n\n")
    for r in RESULTS:
        if r["problems"]:
            f.write(f"- **[{r['id']}] {r['action']} {r['param'][:60]} {r['files']}** ({r['wall']} s): {' · '.join(r['problems'])}\n  - risposta: {json.dumps(r['res'], ensure_ascii=False)[:400]}\n")
    f.write("\n## Note\n\n")
    for r in RESULTS:
        if r["notes"]:
            f.write(f"- [{r['id']}] {r['action']} {r['param'][:40]} {r['files']}: {' · '.join(r['notes'])[:500]}\n")
log("\n===== PROBLEMI =====")
for r in RESULTS:
    if r.get("problems"):
        log(f"P [{r['id']}] {r['action']} {r['param'][:70]} {r['files']} ({r['wall']} s): {' · '.join(r['problems'])} || risposta: {json.dumps(r['res'], ensure_ascii=False)[:300]}")
log("\n===== NOTE =====")
for r in RESULTS:
    if r.get("notes"):
        log(f"N [{r['id']}] {r['action']} {r['param'][:50]} {r['files']}: {' · '.join(r['notes'])[:600]}")
log(json.dumps(summary, ensure_ascii=False))
