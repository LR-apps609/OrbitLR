# M01 · Prepara le foto di prova (nessun file grande nel repository: si creano qui).
# Uso: python genera.py CARTELLA   (servono Pillow, piexif, numpy, tifffile)
import os, sys, json
import numpy as np
from PIL import Image
import piexif, tifffile

D = sys.argv[1]
os.makedirs(D, exist_ok=True)
RED, GREEN, BLUE, YELLOW = (220, 30, 30), (30, 200, 40), (30, 50, 220), (240, 220, 20)


def quad(w, h, alpha_left=False, mode="RGB"):
    """4 quadranti: alto-sx rosso, alto-dx verde, basso-sx blu, basso-dx giallo (come è salvata)."""
    a = np.zeros((h, w, 4), dtype=np.uint8)
    a[: h // 2, : w // 2, :3] = RED
    a[: h // 2, w // 2 :, :3] = GREEN
    a[h // 2 :, : w // 2, :3] = BLUE
    a[h // 2 :, w // 2 :, :3] = YELLOW
    a[..., 3] = 255
    if alpha_left:
        a[:, : w // 2, 3] = 0
    im = Image.fromarray(a, "RGBA")
    return im if mode == "RGBA" else im.convert(mode)


def deg(v):
    d = int(v); m = int((v - d) * 60); s = round(((v - d) * 60 - m) * 60 * 100)
    return ((d, 1), (m, 1), (s, 100))


def exif_bytes(orient=1):
    z = {
        piexif.ImageIFD.Make: b"ProvaCam", piexif.ImageIFD.Model: b"M01 Test", piexif.ImageIFD.Orientation: orient,
        piexif.ImageIFD.Artist: b"Tester",
    }
    e = {piexif.ExifIFD.DateTimeOriginal: b"2025:07:14 10:20:30"}
    g = {
        piexif.GPSIFD.GPSLatitudeRef: b"N", piexif.GPSIFD.GPSLatitude: deg(40.8518),
        piexif.GPSIFD.GPSLongitudeRef: b"E", piexif.GPSIFD.GPSLongitude: deg(14.2681),
    }
    return piexif.dump({"0th": z, "Exif": e, "GPS": g, "1st": {}, "thumbnail": None})


def save(name, im, **kw):
    p = os.path.join(D, name)
    im.save(p, **kw)
    return p


save("gps.jpg", quad(1600, 1200), quality=90, exif=exif_bytes())
save("orient6.jpg", quad(600, 300), quality=90, exif=exif_bytes(6))   # si vede in verticale 300×600
save("orient8.jpg", quad(600, 300), quality=90, exif=exif_bytes(8))
save("alpha.png", quad(800, 600, alpha_left=True, mode="RGBA"))
# 16 bit per canale
a16 = np.array(quad(640, 480)).astype(np.uint16) * 257
tifffile.imwrite(os.path.join(D, "deep16.tiff"), a16, photometric="rgb")
save("cmyk.jpg", quad(800, 600).convert("CMYK"), quality=92)
save("photo.webp", quad(1000, 700), quality=85)
save("alpha.webp", quad(500, 400, alpha_left=True, mode="RGBA"), quality=85)
fr = [quad(200, 150).rotate(i * 90, expand=False) for i in range(3)]
fr[0].save(os.path.join(D, "anim.gif"), save_all=True, append_images=fr[1:], duration=200, loop=0)
save("tiny.png", Image.new("RGB", (1, 1), RED))
save("tiny.jpg", Image.new("RGB", (1, 1), BLUE), quality=90)
save("small.png", quad(100, 80))                                       # sotto i 160 px
save("huge.jpg", quad(12000, 8000), quality=80, exif=exif_bytes())
save("gray.jpg", quad(640, 480).convert("L"), quality=90)
pal = quad(300, 200, alpha_left=True, mode="RGBA").quantize(colors=8)
save("palette.png", pal)
save("photo.bmp", quad(400, 300))
# Nomi difficili
save("Città è perché.jpg", quad(400, 300), quality=90, exif=exif_bytes())
save("foto 😀 mare.png", quad(400, 300))
save("  spazi  doppi .jpg", quad(400, 300), quality=90)
save("l'estate \"2025\".jpg", quad(400, 300), quality=90)
save("scan [1].jpg", quad(400, 300), quality=90)
save("sconto 100%d.png", quad(400, 300))
save("$(touch PWNED).jpg", quad(400, 300), quality=90)
save("a;b&c|d.png", quad(400, 300))
save("a" * 240 + ".jpg", quad(400, 300), quality=90)                  # nome lungo (244 byte)
save("UPPER.JPEG", quad(400, 300), quality=90)
quad(400, 300).save(os.path.join(D, "png-dentro.jpg"), format="PNG")  # PNG con estensione .jpg
save("collide.jpg", quad(400, 300), quality=90)
save("collide.png", Image.new("RGB", (50, 50), (0, 0, 0)))             # esiste già: non va sovrascritto
save("sola-lettura.jpg", quad(400, 300), quality=90, exif=exif_bytes())
os.chmod(os.path.join(D, "sola-lettura.jpg"), 0o444)
with open(os.path.join(D, "rotta.jpg"), "wb") as f:                    # JPEG troncato
    f.write(open(os.path.join(D, "gps.jpg"), "rb").read()[:3000])
open(os.path.join(D, "vuota.png"), "wb").close()                       # 0 byte
nd = os.path.join(D, "bloccata")
os.makedirs(nd, exist_ok=True)
save("bloccata/dentro.jpg", quad(400, 300), quality=90, exif=exif_bytes())
os.chmod(nd, 0o555)
print(json.dumps(sorted(os.listdir(D)), ensure_ascii=False))
# Foto «vera» (con rumore) per la compressione, con GPS
rng = np.random.default_rng(7)
n = np.array(quad(2400, 1800)).astype(np.int16)
n[..., :3] += rng.integers(-40, 40, size=(1800, 2400, 3), dtype=np.int16)
Image.fromarray(np.clip(n, 0, 255).astype(np.uint8)[..., :3], "RGB").save(os.path.join(D, "rumore.jpg"), quality=95, exif=exif_bytes())
