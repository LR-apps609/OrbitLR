import subprocess, sys, os, json
import numpy as np
from PIL import Image, ImageFilter
SRC = sys.argv[1]
os.makedirs('st', exist_ok=True)
def grab(t):
    p = f'st/f_{t:.2f}.png'
    if not os.path.exists(p):
        subprocess.run(['ffmpeg','-v','error','-y','-ss',str(t),'-i',SRC,'-frames:v','1',p],check=True)
    return np.asarray(Image.open(p).convert('RGB')).astype(np.int16)
def lum(a): return (a[...,0]*0.3 + a[...,1]*0.59 + a[...,2]*0.11)
def cursor_mask(a, h):
    m = (lum(a) < 80) & (lum(h) - lum(a) > 60)
    return m
def clean(name, t, helpers, keep=False):
    a = grab(t); info = {}
    total = np.zeros(a.shape[:2], bool)
    for ht in helpers:
        h = grab(ht)
        m = cursor_mask(a, h)
        if m.sum() < 20: continue
        ys, xs = np.nonzero(m)
        # il cursore è un blocco compatto: si tiene la zona più grande intorno alla mediana
        cy, cx = np.median(ys), np.median(xs)
        sel = (abs(ys - cy) < 40) & (abs(xs - cx) < 30)
        ys, xs = ys[sel], xs[sel]
        info = {'tip': [int(xs.min()), int(ys.min())], 'box': [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())]}
        if keep: break
        box = np.zeros(a.shape[:2], bool)
        box[max(0, ys.min()-6):ys.max()+7, max(0, xs.min()-6):xs.max()+7] = True
        a = np.where(box[..., None], h, a)
        break
    Image.fromarray(a.astype(np.uint8)).save(f'st/{name}.png')
    return info
res = {
 'empty': clean('empty', 0.2, [0.6, 1.0, 0.0]),
 'over':  clean('over', 3.7, [4.0, 3.4]),
 
 'hover': clean('hover', 14.4, [13.85], keep=True),
 'done':  clean('done', 16.4, [16.7, 16.1]),
 'sel':   clean('sel', 57.5, [57.2, 57.0]),
 'two':   clean('two', 58.6, [59.4, 59.8]),
}
json.dump(res, open('st/info.json','w'), indent=1); print(json.dumps(res))
