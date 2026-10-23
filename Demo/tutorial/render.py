"""Tutorial rifatti da zero: la grafica vera di OrbitLR (fotogrammi puliti della registrazione),
il movimento deciso qui (cursore lento, pause, zoom, cerchi sui clic, didascalie numerate)."""
import sys, os, subprocess, shutil, math
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ST = os.path.join(HERE, 'st')
SW, SH = 1480, 930                 # la scena: scrivania + finestra
WX, WY = 20, 30                    # dove sta la finestra (1280×870) nella scena
OW, OH = 1920, 1206                # misura del video
FPS = 30
FONT = subprocess.run(['fc-match', '-f', '%{file}', 'Inter:semibold'], capture_output=True, text=True).stdout
font = ImageFont.truetype(FONT, 30)
small = ImageFont.truetype(FONT, 13)

def ease(p): p = min(1, max(0, p)); return 4*p*p*p if p < .5 else 1 - (-2*p + 2)**3 / 2
def eout(p): p = min(1, max(0, p)); return 1 - (1 - p)**3
def seg(t, a, b): return min(1, max(0, (t - a) / (b - a)))

def load(name):
    return Image.open(os.path.join(ST, name + '.png')).convert('RGB')

def rounded(im, r=14):
    m = Image.new('L', im.size, 0); ImageDraw.Draw(m).rounded_rectangle([0, 0, im.size[0]-1, im.size[1]-1], r, fill=255)
    return m

def desktop():
    bg = Image.new('RGB', (SW, SH), (40, 46, 41))
    d = ImageDraw.Draw(bg)
    for y in range(SH):
        c = int(36 + 18 * y / SH); d.line([(0, y), (SW, y)], fill=(c, c + 8, c + 2))
    return bg

def window_shadow(scene):
    sh = Image.new('L', (SW, SH), 0)
    ImageDraw.Draw(sh).rounded_rectangle([WX + 4, WY + 18, WX + 1284, WY + 888], 18, fill=150)
    sh = sh.filter(ImageFilter.GaussianBlur(26))
    scene.paste((0, 0, 0), (0, 0), sh)

def cursor_img():
    c = Image.new('RGBA', (40, 52), (0, 0, 0, 0)); d = ImageDraw.Draw(c)
    pts = [(4, 3), (4, 38), (13, 30), (19, 44), (26, 41), (20, 27), (32, 27)]
    d.polygon(pts, fill=(255, 255, 255, 255)); d.polygon([(p[0]*0.86 + 1.6, p[1]*0.86 + 2.4) for p in pts], fill=(17, 17, 17, 255))
    return c
CURSOR = cursor_img()

def file_icon():
    c = Image.new('RGBA', (120, 120), (0, 0, 0, 0)); d = ImageDraw.Draw(c)
    d.rounded_rectangle([18, 8, 102, 72], 6, fill=(255, 255, 255, 255))
    ph = Image.new('RGB', (76, 56)); pd = ImageDraw.Draw(ph)
    for y in range(56):
        if y < 30: col = (142 - y, 197 - y // 2, 232)
        elif y < 38: col = (233, 215, 168)
        else: col = (78, 154, 146)
        pd.line([(0, y), (76, y)], fill=col)
    pd.ellipse([52, 6, 64, 18], fill=(255, 214, 140))
    c.paste(ph, (22, 12))
    tw = d.textlength('foto-mare.heic', font=small)
    d.rounded_rectangle([60 - tw/2 - 5, 80, 60 + tw/2 + 5, 100], 5, fill=(48, 98, 196, 235))
    d.text((60 - tw/2, 82), 'foto-mare.heic', font=small, fill=(255, 255, 255, 255))
    return c
FILE = file_icon()

def build(spec, out):
    work = os.path.join(HERE, 'frames'); shutil.rmtree(work, ignore_errors=True); os.makedirs(work)
    base = desktop(); window_shadow(base)
    states = {k: load(v) for k, v in spec['states'].items()}
    n = int(spec['duration'] * FPS)
    for i in range(n):
        t = i / FPS
        scene = base.copy()
        win = spec['window'](t, states)            # la finestra in quel momento (1280×870)
        scene.paste(win, (WX, WY), rounded(win))
        extra = ImageDraw.Draw(scene, 'RGBA')
        # file trascinato
        if 'file' in spec:
            pos = spec['file'](t)
            if pos:
                x, y, s, a = pos
                f = FILE.resize((int(120*s), int(120*s)), Image.LANCZOS)
                if a < 1: f.putalpha(f.getchannel('A').point(lambda v: int(v * a)))
                scene.paste(f, (int(x - f.size[0]/2), int(y - f.size[1]/2)), f)
        # cerchi sui clic
        for (tc, cx, cy) in spec['clicks']:
            p = seg(t, tc, tc + 0.55)
            if 0 < p < 1:
                r = 10 + 34 * eout(p); X, Y = cx + WX, cy + WY
                extra.ellipse([X - r, Y - r, X + r, Y + r], outline=(184, 146, 90, int(255 * (1 - p))), width=4)
        # cursore
        cur = spec['cursor'](t)
        if cur:
            cx, cy, pressed = cur
            c = CURSOR if not pressed else CURSOR.resize((34, 44))
            scene.paste(c, (int(cx + WX - 4), int(cy + WY - 3)), c)
        # telecamera
        s, fx, fy = spec['camera'](t)
        cw, ch = SW / s, SH / s
        x0 = min(max(fx + WX - cw/2, 0), SW - cw); y0 = min(max(fy + WY - ch/2, 0), SH - ch)
        frame = scene.crop((int(x0), int(y0), int(x0 + cw), int(y0 + ch))).resize((OW, OH), Image.LANCZOS)
        # didascalia
        d = ImageDraw.Draw(frame, 'RGBA')
        for (a, b, num, text) in spec['captions']:
            if a <= t < b:
                o = min(1, (t - a) / .3, (b - t) / .3)
                tw = d.textlength(text, font=font); nw = d.textlength(num, font=font)
                pw, ph = tw + nw + 64, 64
                X, Y = (OW - pw) / 2, OH - ph - 40
                d.rounded_rectangle([X, Y, X + pw, Y + ph], 32, fill=(36, 44, 38, int(240 * o)))
                d.text((X + 28, Y + 14), num, font=font, fill=(230, 194, 138, int(255 * o)))
                d.text((X + 28 + nw + 14, Y + 14), text, font=font, fill=(255, 255, 255, int(255 * o)))
        frame.save(os.path.join(work, f'{i:05d}.png'))
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-framerate', str(FPS), '-i', os.path.join(work, '%05d.png'),
                    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '18', '-preset', 'medium', '-movflags', '+faststart', out], check=True)
    shutil.rmtree(work)

# ── utilità per le scene ─────────────────────────────────────────────
def path(t, keys):
    """Cursore a tappe: [(t, x, y), …] con movimento morbido."""
    if t <= keys[0][0]: return keys[0][1], keys[0][2]
    for (t0, x0, y0), (t1, x1, y1) in zip(keys, keys[1:]):
        if t <= t1:
            p = ease(seg(t, t0, t1)); return x0 + (x1 - x0)*p, y0 + (y1 - y0)*p
    return keys[-1][1], keys[-1][2]

def camera(keys):
    def f(t):
        s, x, y = keys[0][1:]
        for (t0, s0, x0, y0), (t1, s1, x1, y1) in zip(keys, keys[1:]):
            if t >= t0:
                p = ease(seg(t, t0, t1)); s, x, y = s0 + (s1-s0)*p, x0 + (x1-x0)*p, y0 + (y1-y0)*p
        return s, x, y
    return f

def blend(a, b, p): return a if p <= 0 else (b if p >= 1 else Image.blend(a, b, p))
def reveal(a, b, p, cx, cy, rmax=900):
    """b compare dentro un cerchio che cresce da (cx, cy): la torta che nasce dal file."""
    if p <= 0: return a
    if p >= 1: return b
    m = Image.new('L', a.size, 0); r = rmax * eout(p)
    ImageDraw.Draw(m).ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    m = m.filter(ImageFilter.GaussianBlur(18))
    out = a.copy(); out.paste(b, (0, 0), m); return out

# ═══ 1 · Converti un file ═════════════════════════════════════════════
def convert_spec():
    drop = (640, 390)                       # dove si lascia il file (coordinate della finestra)
    jpg = (781, 282)                        # cursore sullo spicchio JPG (lo stesso del fotogramma vero)
    mostra = (1028, 802)
    T = dict(grab=1.6, drop=3.4, bloom=3.95, toJpg=5.3, atJpg=6.4, click=8.6, done=8.9, mostra=11.2, end=12.6)
    def window(t, S):
        if t < T['drop']:
            w = blend(S['empty'], S['over'], seg(t, 2.3, 2.55))
        else:
            w = reveal(S['over'], S['pie'], seg(t, T['drop'], T['bloom']), *drop)
        if t >= T['atJpg']: w = blend(w, S['hover'], seg(t, T['atJpg'], T['atJpg'] + .15))
        if t >= T['click'] + .15:
            # dopo il clic: la torta torta normale e dal basso sale la barra del risultato
            w = blend(S['hover'], S['pie'], seg(t, T['click'] + .15, T['click'] + .35))
            p = eout(seg(t, T['done'], T['done'] + .45))
            if p > 0:
                strip = S['done'].crop((0, 735, 1280, 870))
                w = w.copy(); y = int(735 + (1 - p) * 140)
                w.paste(blend(S['pie'].crop((0, y, 1280, 870)), strip.crop((0, 0, 1280, 870 - y)), p), (0, y))
        return w
    def file(t):
        if t < T['grab']: return (1395 - WX, 780 - WY + 0, 1, 1) if False else (1395, 760, 1, 1)
        if t < T['drop']:
            x, y = path(t, [(T['grab'], 1395, 760), (T['drop'] - .25, drop[0] + WX + 8, drop[1] + WY + 14)])
            return (x, y, 1.05, .92)
        p = seg(t, T['drop'], T['drop'] + .35)
        if p >= 1: return None
        return (drop[0] + WX, drop[1] + WY, 1.05 * (1 - .7 * p), .9 * (1 - p))
    def cursor(t):
        if T['atJpg'] <= t < T['click'] + .15: return None      # il cursore vero è già nel fotogramma
        keys = [(0, 960, 560), (.5, 960, 560), (T['grab'] - .1, 1395 - WX - 8, 760 - WY - 10), (T['grab'], 1395 - WX - 8, 760 - WY - 10),
                (T['drop'] - .25, drop[0], drop[1]), (T['bloom'] + .3, drop[0] + 40, drop[1] + 140),
                (T['toJpg'], drop[0] + 40, drop[1] + 140), (T['atJpg'], *jpg), (T['click'] + .15, *jpg),
                (T['done'] + .9, *jpg), (T['mostra'], *mostra), (T['end'], *mostra)]
        x, y = path(t, keys)
        pressed = T['grab'] <= t < T['drop'] or abs(t - T['mostra'] - .1) < .1
        return x, y, pressed
    return dict(
        duration=T['end'], states=dict(empty='empty', over='over', pie='pie', hover='hover_s', done='done'),
        window=window, file=file, cursor=cursor,
        clicks=[(T['grab'], 1395 - WX - 8, 760 - WY - 10), (T['click'], *jpg), (T['mostra'] + .1, *mostra)],
        camera=camera([(0, 1, 740, 465), (T['atJpg'] + .1, 1, 740, 465), (T['atJpg'] + .7, 1.9, 771, 330),
                       (T['click'] - .2, 1.9, 771, 330), (T['click'] + .5, 1, 740, 465), (T['done'] + .7, 1, 740, 465),
                       (T['done'] + 1.4, 1.55, 760, 760), (T['end'], 1.55, 760, 760)]),
        captions=[(0.2, T['drop'] + .2, '1', 'Trascina il file nella finestra'),
                  (T['drop'] + .3, T['atJpg'] - .05, '2', 'Si apre la torta: ogni spicchio è un’azione'),
                  (T['atJpg'], T['click'] + .1, '3', 'Sotto lo spicchio c’è il peso previsto: clicca'),
                  (T['click'] + .3, T['end'], '4', 'Fatto: il file nuovo, l’originale resta com’è')],
    )

# ═══ 2 · Togli un pezzo di video ══════════════════════════════════════
def clip_spec():
    dividi = (701, 797); x_btn = (737, 576)
    T = dict(toDiv=1.6, clickDiv=2.6, toX=4.6, clickX=6.2, undo=8.4, end=11.0)
    def window(t, S):
        if t < T['clickDiv'] + .1: return S['split']
        w = blend(S['split'], S['sel'], seg(t, T['clickDiv'] + .1, T['clickDiv'] + .3))
        if t >= T['clickX'] + .1: w = blend(S['sel'], S['two'], seg(t, T['clickX'] + .1, T['clickX'] + .4))
        if t >= T['undo'] + .2: w = blend(S['two'], S['sel'], seg(t, T['undo'] + .2, T['undo'] + .5))
        return w
    def cursor(t):
        keys = [(0, 980, 420), (.6, 980, 420), (T['toDiv'] + .9, *dividi), (T['toX'], *dividi), (T['clickX'] - .4, *x_btn),
                (T['clickX'] + .5, *x_btn), (T['clickX'] + 1.3, x_btn[0] + 60, x_btn[1] + 90), (T['end'], x_btn[0] + 60, x_btn[1] + 90)]
        x, y = path(t, keys)
        return x, y, abs(t - T['clickDiv']) < .1 or abs(t - T['clickX']) < .1
    def keycap(frame_t): return None
    spec = dict(
        duration=T['end'], states=dict(split='split', sel='sel', two='two'), window=window, cursor=cursor,
        clicks=[(T['clickDiv'], *dividi), (T['clickX'], *x_btn)],
        camera=camera([(0, 1, 740, 465), (.8, 1, 740, 465), (1.6, 1.55, 760, 690), (T['toX'] + .2, 1.55, 760, 690),
                       (T['toX'] + .9, 2.1, 760, 600), (T['clickX'] + 1.2, 2.1, 760, 600), (T['undo'] - .4, 1.4, 740, 560),
                       (T['end'], 1.4, 740, 560)]),
        captions=[(0.2, T['clickDiv'] + .3, '1', 'Porta la linea dove tagliare e premi «Dividi» (o S)'),
                  (T['clickDiv'] + .4, T['clickX'] + .1, '2', 'Il pezzo è scelto: premi la × (o il tasto ⌫)'),
                  (T['clickX'] + .3, T['undo'] - .1, '3', 'Tolto. Il resto del video si avvicina da solo'),
                  (T['undo'], T['end'], '4', 'Ti sei sbagliato? ⌘Z lo rimette')],
        undo=T['undo'],
    )
    return spec

if __name__ == '__main__':
    which = sys.argv[1]
    if which == 'convert': build(convert_spec(), os.path.join(HERE, 'OrbitLR - Converti un file.mp4'))
    else:
        sp = clip_spec()
        # tasto ⌘Z disegnato sopra la finestra
        orig = sp['window']
        def win(t, S, orig=orig, u=sp['undo']):
            w = orig(t, S)
            p = min(seg(t, u - .3, u), 1 - seg(t, u + .9, u + 1.2))
            if p > 0:
                w = w.copy(); d = ImageDraw.Draw(w, 'RGBA'); f = ImageFont.truetype(FONT, 46)
                txt = '⌘ Z'; tw = d.textlength(txt, font=f)
                d.rounded_rectangle([640 - tw/2 - 34, 300, 640 + tw/2 + 34, 384], 18, fill=(36, 44, 38, int(235 * p)))
                d.text((640 - tw/2, 312), txt, font=f, fill=(255, 255, 255, int(255 * p)))
            return w
        sp['window'] = win
        build(sp, os.path.join(HERE, 'OrbitLR - Togli un pezzo di video.mp4'))
