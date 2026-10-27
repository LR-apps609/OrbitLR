//! OrbitLR · «Vettoriale (SVG)»: da una foto, un logo o un disegno a un SVG vero.
//!
//! Come funziona (in ordine, ogni passo pensato per la qualità):
//! 1. l'immagine si lavora ingrandita (meglio ancora se già ingrandita con Real-ESRGAN): i bordi sfumati
//!    diventano bordi precisi a meno di un pixel, e gli artefatti JPEG si ammorbidiscono senza toccare i bordi;
//! 2. i colori veri si trovano con k-means nello spazio Lab (come li vede l'occhio), poi si uniscono quelli
//!    quasi uguali e si tolgono i colori «di passaggio» (le sfumature sottili tra due colori, che altrimenti
//!    diventano aloni e bordini);
//! 3. ogni colore diventa uno strato; ogni strato si estende un poco sotto quelli sopra, solo dove li tocca:
//!    niente fessure tra i colori e niente bordini sbagliati;
//! 4. ogni contorno diventa linee dritte, angoli netti, cerchi veri e curve morbide (vedi `fit`).
//!
//! Modi: «logo» (colori pieni), «bw» (bianco e nero: firme, scansioni, disegni a tratto, sfondo trasparente),
//! «photo» (tanti colori), «auto» (sceglie da solo).

pub mod fit;

use fit::{FitOpts, Seg, Shape, P};
use image::{DynamicImage, GenericImageView, GrayImage, Luma, RgbaImage};
use std::fmt::Write as _;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Auto,
    Logo,
    Bw,
    Photo,
}

impl Mode {
    pub fn parse(s: &str) -> Mode {
        match s {
            "logo" => Mode::Logo,
            "bw" => Mode::Bw,
            "photo" | "foto" => Mode::Photo,
            _ => Mode::Auto,
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Mode::Auto => "auto",
            Mode::Logo => "logo",
            Mode::Bw => "bw",
            Mode::Photo => "photo",
        }
    }
}

#[derive(Clone, Debug)]
pub struct Opts {
    pub mode: Mode,
    /// 1 = semplice (meno nodi), 2 = bilanciato, 3 = massimo dettaglio
    pub detail: u8,
    /// Toglie lo sfondo (il colore che tocca di più i bordi); nel bianco e nero lo sfondo è sempre trasparente
    pub transparent: bool,
    /// Sfumature vere (gradienti lineari) dove il colore cambia in modo regolare
    pub gradients: bool,
}

impl Default for Opts {
    fn default() -> Self {
        Opts { mode: Mode::Auto, detail: 2, transparent: false, gradients: true }
    }
}

#[derive(Clone, Debug)]
pub struct Output {
    pub svg: String,
    pub mode: Mode,
    pub colors: usize,
    pub shapes: usize,
}

const NONE: u8 = 255;

// ───────────────────────── colore

fn lin(c: u8) -> f32 {
    let c = c as f32 / 255.0;
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

struct LabLut([f32; 256]);
impl LabLut {
    fn new() -> LabLut {
        let mut t = [0.0; 256];
        for (i, v) in t.iter_mut().enumerate() {
            *v = lin(i as u8);
        }
        LabLut(t)
    }
    fn lab(&self, r: u8, g: u8, b: u8) -> [f32; 3] {
        let (r, g, b) = (self.0[r as usize], self.0[g as usize], self.0[b as usize]);
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
        let f = |t: f32| if t > 0.008856 { t.cbrt() } else { 7.787 * t + 16.0 / 116.0 };
        let (fx, fy, fz) = (f(x), f(y), f(z));
        [116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)]
    }
}

fn lab_to_rgb(l: [f32; 3]) -> [u8; 3] {
    let fy = (l[0] + 16.0) / 116.0;
    let fx = fy + l[1] / 500.0;
    let fz = fy - l[2] / 200.0;
    let inv = |t: f32| if t.powi(3) > 0.008856 { t.powi(3) } else { (t - 16.0 / 116.0) / 7.787 };
    let (x, y, z) = (inv(fx) * 0.95047, inv(fy), inv(fz) * 1.08883);
    let r = 3.2406 * x - 1.5372 * y - 0.4986 * z;
    let g = -0.9689 * x + 1.8758 * y + 0.0415 * z;
    let b = 0.0557 * x - 0.2040 * y + 1.0570 * z;
    let s = |c: f32| {
        let c = c.clamp(0.0, 1.0);
        let v = if c <= 0.0031308 { 12.92 * c } else { 1.055 * c.powf(1.0 / 2.4) - 0.055 };
        (v * 255.0).round().clamp(0.0, 255.0) as u8
    };
    [s(r), s(g), s(b)]
}

fn d2(a: &[f32; 3], b: &[f32; 3]) -> f32 {
    (a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)
}

// ───────────────────────── filtri

/// Filtro bilaterale: ammorbidisce rumore e artefatti JPEG senza ammorbidire i bordi.
fn bilateral(img: &RgbaImage, r: i32, sc: f32) -> RgbaImage {
    let (w, h) = img.dimensions();
    let ss = (r as f32 / 2.0).max(0.8);
    let mut sw = vec![0.0f32; ((2 * r + 1) * (2 * r + 1)) as usize];
    for dy in -r..=r {
        for dx in -r..=r {
            sw[((dy + r) * (2 * r + 1) + dx + r) as usize] = (-((dx * dx + dy * dy) as f32) / (2.0 * ss * ss)).exp();
        }
    }
    let ic = -1.0 / (2.0 * sc * sc);
    let mut out = img.clone();
    for y in 0..h as i32 {
        for x in 0..w as i32 {
            let c = img.get_pixel(x as u32, y as u32).0;
            if c[3] < 128 {
                continue;
            }
            let (mut a, mut ws) = ([0.0f32; 3], 0.0f32);
            for dy in -r..=r {
                let yy = y + dy;
                if yy < 0 || yy >= h as i32 {
                    continue;
                }
                for dx in -r..=r {
                    let xx = x + dx;
                    if xx < 0 || xx >= w as i32 {
                        continue;
                    }
                    let q = img.get_pixel(xx as u32, yy as u32).0;
                    if q[3] < 128 {
                        continue;
                    }
                    let dc = (c[0] as f32 - q[0] as f32).powi(2) + (c[1] as f32 - q[1] as f32).powi(2) + (c[2] as f32 - q[2] as f32).powi(2);
                    let wgt = sw[((dy + r) * (2 * r + 1) + dx + r) as usize] * (dc * ic).exp();
                    for k in 0..3 {
                        a[k] += q[k] as f32 * wgt;
                    }
                    ws += wgt;
                }
            }
            let p = out.get_pixel_mut(x as u32, y as u32);
            for k in 0..3 {
                p.0[k] = (a[k] / ws).round().clamp(0.0, 255.0) as u8;
            }
        }
    }
    out
}

/// Somme per riquadro (immagine integrale) di una maschera.
fn box_count(mask: &[bool], w: usize, h: usize, r: usize) -> Vec<u32> {
    let mut ii = vec![0u32; (w + 1) * (h + 1)];
    for y in 0..h {
        let mut row = 0u32;
        for x in 0..w {
            row += mask[y * w + x] as u32;
            ii[(y + 1) * (w + 1) + x + 1] = ii[y * (w + 1) + x + 1] + row;
        }
    }
    let mut out = vec![0u32; w * h];
    for y in 0..h {
        let (y0, y1) = (y.saturating_sub(r), (y + r + 1).min(h));
        for x in 0..w {
            let (x0, x1) = (x.saturating_sub(r), (x + r + 1).min(w));
            out[y * w + x] = ii[y1 * (w + 1) + x1] + ii[y0 * (w + 1) + x0] - ii[y0 * (w + 1) + x1] - ii[y1 * (w + 1) + x0];
        }
    }
    out
}

fn dilate(mask: &[bool], w: usize, h: usize, r: usize) -> Vec<bool> {
    box_count(mask, w, h, r).into_iter().map(|c| c > 0).collect()
}

// ───────────────────────── colori (palette)

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn f(&mut self) -> f32 {
        (self.next() >> 40) as f32 / (1u64 << 24) as f32
    }
}

fn kmeans(px: &[[f32; 3]], k: usize, iters: usize) -> (Vec<[f32; 3]>, Vec<usize>) {
    let k = k.min(px.len()).max(1);
    let mut rng = Rng(0x9E3779B97F4A7C15);
    // k-means++
    let mut c = vec![px[(rng.next() as usize) % px.len()]];
    let mut dist: Vec<f32> = px.iter().map(|p| d2(p, &c[0])).collect();
    while c.len() < k {
        let tot: f32 = dist.iter().sum();
        if tot <= 0.0 {
            break;
        }
        let mut t = rng.f() * tot;
        let mut pick = px.len() - 1;
        for (i, d) in dist.iter().enumerate() {
            t -= d;
            if t <= 0.0 {
                pick = i;
                break;
            }
        }
        c.push(px[pick]);
        let last = *c.last().unwrap();
        for (i, p) in px.iter().enumerate() {
            dist[i] = dist[i].min(d2(p, &last));
        }
    }
    let mut lbl = vec![0usize; px.len()];
    for _ in 0..iters {
        let mut sum = vec![[0.0f64; 3]; c.len()];
        let mut cnt = vec![0usize; c.len()];
        let mut moved = false;
        for (i, p) in px.iter().enumerate() {
            let mut best = (f32::MAX, 0);
            for (j, cc) in c.iter().enumerate() {
                let d = d2(p, cc);
                if d < best.0 {
                    best = (d, j);
                }
            }
            if lbl[i] != best.1 {
                moved = true;
            }
            lbl[i] = best.1;
            for q in 0..3 {
                sum[best.1][q] += p[q] as f64;
            }
            cnt[best.1] += 1;
        }
        for j in 0..c.len() {
            if cnt[j] > 0 {
                c[j] = [(sum[j][0] / cnt[j] as f64) as f32, (sum[j][1] / cnt[j] as f64) as f32, (sum[j][2] / cnt[j] as f64) as f32];
            }
        }
        if !moved {
            break;
        }
    }
    let mut cnt = vec![0usize; c.len()];
    for l in &lbl {
        cnt[*l] += 1;
    }
    (c, cnt)
}

struct PalOpts {
    k: usize,
    merge: f32,
    min_share: f64,
    fringe: bool,
}

/// I colori veri dell'immagine (piccola, già ripulita).
fn palette(small: &RgbaImage, lut: &LabLut, o: &PalOpts) -> Vec<[f32; 3]> {
    let (w, h) = small.dimensions();
    let n = (w * h) as usize;
    let step = ((n as f64 / 80_000.0).sqrt().ceil() as u32).max(1);
    let mut px = vec![];
    for y in (0..h).step_by(step as usize) {
        for x in (0..w).step_by(step as usize) {
            let p = small.get_pixel(x, y).0;
            if p[3] >= 128 {
                px.push(lut.lab(p[0], p[1], p[2]));
            }
        }
    }
    if px.is_empty() {
        return vec![[100.0, 0.0, 0.0]];
    }
    let (c, cnt) = kmeans(&px, o.k, 30);
    let tot = px.len() as f64;
    let mut order: Vec<usize> = (0..c.len()).collect();
    order.sort_by(|a, b| cnt[*b].cmp(&cnt[*a]));
    let mut keep: Vec<([f32; 3], usize)> = vec![];
    for i in order {
        if (cnt[i] as f64) < o.min_share * tot {
            continue;
        }
        if let Some(k) = keep.iter_mut().find(|k| d2(&k.0, &c[i]).sqrt() < o.merge) {
            k.1 += cnt[i];
            continue;
        }
        keep.push((c[i], cnt[i]));
    }
    if !o.fringe || keep.len() < 3 {
        return keep.into_iter().map(|k| k.0).collect();
    }
    // Colori «di passaggio»: a metà strada tra due colori più grandi E presenti solo in strisce sottili
    let pal: Vec<[f32; 3]> = keep.iter().map(|k| k.0).collect();
    let lab_small: Vec<Option<[f32; 3]>> = small.pixels().map(|p| if p.0[3] >= 128 { Some(lut.lab(p.0[0], p.0[1], p.0[2])) } else { None }).collect();
    let lbl: Vec<u8> = lab_small.iter().map(|l| l.map(|l| nearest(&pal, &l)).unwrap_or(NONE)).collect();
    let all: f64 = keep.iter().map(|k| k.1 as f64).sum();
    let mut drop = vec![false; pal.len()];
    for ci in 0..pal.len() {
        if keep[ci].1 as f64 > 0.06 * all {
            continue;
        }
        let mut between = false;
        for a in 0..pal.len() {
            for b in a + 1..pal.len() {
                if a == ci || b == ci || keep[a].1 < keep[ci].1 || keep[b].1 < keep[ci].1 {
                    continue;
                }
                let v = [pal[b][0] - pal[a][0], pal[b][1] - pal[a][1], pal[b][2] - pal[a][2]];
                let vv = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
                if vv < 1e-6 {
                    continue;
                }
                let q = [pal[ci][0] - pal[a][0], pal[ci][1] - pal[a][1], pal[ci][2] - pal[a][2]];
                let t = (q[0] * v[0] + q[1] * v[1] + q[2] * v[2]) / vv;
                let proj = [pal[a][0] + t * v[0], pal[a][1] + t * v[1], pal[a][2] + t * v[2]];
                if t > 0.08 && t < 0.92 && d2(&proj, &pal[ci]).sqrt() < 20.0 {
                    between = true;
                }
            }
        }
        if !between {
            continue;
        }
        // Sottile? Dopo un'erosione di un pixel ne resta poco
        let m: Vec<bool> = lbl.iter().map(|&l| l == ci as u8).collect();
        let total = m.iter().filter(|&&v| v).count().max(1);
        let cnt = box_count(&m, w as usize, h as usize, 1);
        let core = cnt.iter().filter(|&&c| c == 9).count();
        if (core as f64) < 0.35 * total as f64 {
            drop[ci] = true;
        }
    }
    pal.into_iter().zip(drop).filter(|(_, d)| !d).map(|(p, _)| p).collect()
}

fn nearest(pal: &[[f32; 3]], l: &[f32; 3]) -> u8 {
    let mut best = (f32::MAX, 0u8);
    for (i, p) in pal.iter().enumerate() {
        let d = d2(p, l);
        if d < best.0 {
            best = (d, i as u8);
        }
    }
    best.1
}

// ───────────────────────── contorni

fn mask_contours(mask: &[bool], w: usize, h: usize, pad: usize) -> Vec<Vec<P>> {
    // bordo ripetuto: le forme che toccano il bordo dell'immagine lo oltrepassano (niente righine sul bordo)
    // più una cornice vuota di un pixel: i contorni si trovano anche quando toccano il bordo
    let pad = pad + 1;
    let (pw, ph) = (w + 2 * pad, h + 2 * pad);
    let g = GrayImage::from_fn(pw as u32, ph as u32, |x, y| {
        if x == 0 || y == 0 || x as usize == pw - 1 || y as usize == ph - 1 {
            return Luma([0]);
        }
        let xx = (x as isize - pad as isize).clamp(0, w as isize - 1) as usize;
        let yy = (y as isize - pad as isize).clamp(0, h as isize - 1) as usize;
        Luma([if mask[yy * w + xx] { 255 } else { 0 }])
    });
    imageproc::contours::find_contours::<i32>(&g)
        .into_iter()
        .map(|c| c.points.iter().map(|p| P::new(p.x as f64 - pad as f64 + 0.5, p.y as f64 - pad as f64 + 0.5)).collect())
        .collect()
}

struct Fmt {
    k: f64,
    dec: usize,
}
impl Fmt {
    fn n(&self, v: f64) -> String {
        let s = format!("{:.*}", self.dec, v / self.k);
        let s = if s.contains('.') { s.trim_end_matches('0').trim_end_matches('.').to_string() } else { s };
        if s == "-0" {
            "0".into()
        } else {
            s
        }
    }
    fn p(&self, p: P) -> String {
        let y = self.n(p.y);
        let sep = if y.starts_with('-') { "" } else { " " };
        format!("{}{}{}", self.n(p.x), sep, y)
    }
}

fn shapes_to_d(shapes: &[Shape], f: &Fmt) -> String {
    let mut d = String::new();
    for s in shapes {
        match s {
            Shape::Circle { cx, cy, r } => {
                let (a, b) = (P::new(cx - r, *cy), P::new(cx + r, *cy));
                let rr = f.n(*r);
                let _ = write!(d, "M{}A{rr} {rr} 0 1 0 {}A{rr} {rr} 0 1 0 {}Z", f.p(a), f.p(b), f.p(a));
            }
            Shape::Path { start, segs } => {
                let _ = write!(d, "M{}", f.p(*start));
                for g in segs {
                    match g {
                        Seg::Line(p) => {
                            let _ = write!(d, "L{}", f.p(*p));
                        }
                        Seg::Cubic(a, b, p) => {
                            let _ = write!(d, "C{} {} {}", f.p(*a), f.p(*b), f.p(*p));
                        }
                    }
                }
                d.push('Z');
            }
        }
    }
    d
}

fn trace_mask(mask: &[bool], w: usize, h: usize, u: f64, fo: &FitOpts, pad: usize) -> Vec<Shape> {
    let min_area = 1.5 * u * u;
    mask_contours(mask, w, h, pad)
        .into_iter()
        .filter(|c| fit::polygon_area(c).abs() >= min_area || c.len() as f64 >= 4.0 * u)
        .filter_map(|c| {
            fit::fit_contour(&c, fo)
        })
        .collect()
}

fn hex(c: [u8; 3]) -> String {
    format!("#{:02x}{:02x}{:02x}", c[0], c[1], c[2])
}

// ───────────────────────── il lavoro

/// `upscaled`: la stessa immagine già ingrandita (per esempio con Real-ESRGAN), se c'è.
pub fn vectorize(img: &DynamicImage, upscaled: Option<&DynamicImage>, o: &Opts, progress: &mut dyn FnMut(f64), cancelled: &dyn Fn() -> bool) -> Result<Output, String> {
    let (w, h) = img.dimensions();
    if w < 2 || h < 2 {
        return Err("l'immagine è troppo piccola".into());
    }
    let lut = LabLut::new();
    let orig = img.to_rgba8();
    if let Some(out) = pixel_art(&orig) {
        return Ok(out);
    }
    let has_alpha = orig.pixels().any(|p| p.0[3] < 250);
    let small = bilateral(&orig, 3, 25.0);
    progress(0.05);

    // Il modo
    let mut mode = o.mode;
    if mode == Mode::Auto {
        let pal = palette(&small, &lut, &PalOpts { k: 16, merge: 8.0, min_share: 0.003, fringe: true });
        // Quanto dell'immagine è a tinta unita (logo, disegno) e quanto è sfumato o con trama (foto)
        let lab: Vec<Option<[f32; 3]>> = small.pixels().map(|p| if p.0[3] >= 128 { Some(lut.lab(p.0[0], p.0[1], p.0[2])) } else { None }).collect();
        let (mut flat, mut tot) = (0usize, 0usize);
        let mut share = vec![0usize; pal.len()];
        for y in 0..h as usize - 1 {
            for x in 0..w as usize - 1 {
                let i = y * w as usize + x;
                if let (Some(a), Some(b), Some(c)) = (lab[i], lab[i + 1], lab[i + w as usize]) {
                    tot += 1;
                    if d2(&a, &b).sqrt() < 2.0 && d2(&a, &c).sqrt() < 2.0 {
                        flat += 1;
                    }
                    share[nearest(&pal, &a) as usize] += 1;
                }
            }
        }
        let flat = flat as f64 / tot.max(1) as f64;
        let mut sh: Vec<(usize, usize)> = share.iter().copied().enumerate().map(|(i, c)| (c, i)).collect();
        sh.sort_by(|a, b| b.cmp(a));
        let two = if sh.len() >= 2 { (sh[0].0 + sh[1].0) as f64 / tot.max(1) as f64 } else { 1.0 };
        let contrast = if sh.len() >= 2 { (pal[sh[0].1][0] - pal[sh[1].1][0]).abs() } else { 0.0 };
        if std::env::var("VETTORE_DEBUG").is_ok() {
            eprintln!("auto: tinta unita {flat:.2}, due colori {two:.2}, contrasto {contrast:.0}, colori {}", pal.len());
        }
        mode = if two >= 0.93 && contrast > 35.0 { Mode::Bw } else if flat < 0.75 { Mode::Photo } else { Mode::Logo };
    }
    let detail = o.detail.clamp(1, 3);
    let maxside = w.max(h) as f64;
    // Scala di lavoro: abbastanza grande per bordi precisi, non troppo per la memoria
    let s = match mode {
        Mode::Photo => (1400.0 / maxside).clamp(0.2, 2.0),
        _ => (2200.0 / maxside).clamp(0.4, 4.0),
    };
    let (ww, wh) = (((w as f64 * s).round() as u32).max(2), ((h as f64 * s).round() as u32).max(2));
    let base: RgbaImage = match upscaled {
        Some(up) => {
            let mut u = image::imageops::resize(&up.to_rgba8(), ww, wh, image::imageops::FilterType::Triangle);
            // la trasparenza viene dall'originale
            let a = image::imageops::resize(&orig, ww, wh, image::imageops::FilterType::CatmullRom);
            for (p, q) in u.pixels_mut().zip(a.pixels()) {
                p.0[3] = q.0[3];
            }
            u
        }
        None => {
            let b = image::imageops::resize(&small, ww, wh, image::imageops::FilterType::CatmullRom);
            if s >= 1.5 && (ww as u64 * wh as u64) < 9_000_000 {
                bilateral(&b, (s as i32).clamp(1, 4), 22.0)
            } else {
                b
            }
        }
    };
    if cancelled() {
        return Err("annullato".into());
    }
    progress(0.2);
    let (wu, hu) = (ww as usize, wh as usize);
    let u = s.max(1.0);
    let k_out = s; // dalle coordinate di lavoro a quelle dell'immagine
    let dec = if maxside >= 1000.0 { 1 } else { 2 };
    let f = Fmt { k: k_out, dec };
    let tolk = match detail {
        1 => 1.6,
        3 => 0.7,
        _ => 1.0,
    };

    if mode == Mode::Bw {
        // Bianco e nero: lo sfondo si «spiana» (luce non uniforme), poi la soglia a metà tra carta e inchiostro
        let g: Vec<f32> = base.pixels().map(|p| if p.0[3] < 128 { 255.0 } else { 0.299 * p.0[0] as f32 + 0.587 * p.0[1] as f32 + 0.114 * p.0[2] as f32 }).collect();
        let r = ((wu.max(hu) as f64 / 24.0) as usize).max(4);
        let bg = background(&g, wu, hu, r);
        // la carta in generale; dove il «fondo locale» è scuro si è dentro una forma piena: lì vale la carta generale
        let mut gs = g.clone();
        gs.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let paper_all = gs[(gs.len() as f64 * 0.9) as usize].max(1.0);
        let norm: Vec<f32> = g.iter().zip(&bg).map(|(v, b)| {
            let b = if *b >= 0.75 * paper_all { *b } else { paper_all };
            (v / b.max(1.0) * 255.0).min(255.0)
        }).collect();
        let mut sorted = norm.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let paper = sorted[(sorted.len() as f64 * 0.9) as usize];
        let dark: Vec<f32> = sorted.iter().copied().filter(|v| *v < paper - 40.0).collect();
        let ink = if dark.is_empty() { 0.0 } else { dark[(dark.len() as f64 * 0.1) as usize] };
        let thr = (paper + ink) / 2.0;
        let mask: Vec<bool> = norm.iter().map(|v| *v < thr).collect();
        // colore dell'inchiostro: la parte più scura dei tratti
        let mut inks: Vec<(f32, [u8; 3])> = mask.iter().enumerate().filter(|(_, m)| **m).map(|(i, _)| (norm[i], { let p = base.as_raw(); [p[i * 4], p[i * 4 + 1], p[i * 4 + 2]] })).collect();
        inks.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
        let core = &inks[..(inks.len() * 3 / 10).max(1).min(inks.len())];
        let col = if core.is_empty() { [0, 0, 0] } else { median_rgb(core.iter().map(|c| c.1)) };
        progress(0.45);
        let fo = FitOpts { sigma: 0.6 * u, tol: 0.5 * u * tolk, corner_win: (1.5 * u).round().max(3.0) as usize, corner_deg: 50.0 };
        let shapes = trace_mask(&mask, wu, hu, u, &fo, (3.0 * u) as usize);
        progress(0.95);
        let svg = format!(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{w}\" height=\"{h}\" viewBox=\"0 0 {w} {h}\"><path fill=\"{}\" fill-rule=\"evenodd\" d=\"{}\"/></svg>\n",
            hex(col),
            shapes_to_d(&shapes, &f)
        );
        return Ok(Output { svg, mode, colors: 1, shapes: shapes.len() });
    }

    // Colori
    let po = match (mode, detail) {
        (Mode::Photo, 1) => PalOpts { k: 24, merge: 6.0, min_share: 0.001, fringe: false },
        (Mode::Photo, 3) => PalOpts { k: 64, merge: 3.0, min_share: 0.0003, fringe: false },
        (Mode::Photo, _) => PalOpts { k: 40, merge: 4.0, min_share: 0.0005, fringe: false },
        (_, 1) => PalOpts { k: 10, merge: 11.0, min_share: 0.004, fringe: true },
        (_, 3) => PalOpts { k: 24, merge: 6.0, min_share: 0.0015, fringe: true },
        _ => PalOpts { k: 16, merge: 8.0, min_share: 0.003, fringe: true },
    };
    let pal = palette(&small, &lut, &po);
    if cancelled() {
        return Err("annullato".into());
    }
    progress(0.3);
    let mut lbl: Vec<u8> = base.pixels().map(|p| if p.0[3] < 128 { NONE } else { nearest(&pal, &lut.lab(p.0[0], p.0[1], p.0[2])) }).collect();
    // Moda locale: via i pixel isolati lungo i bordi (non nelle foto: lì i dettagli contano)
    if mode == Mode::Logo && s >= 1.5 {
        let r = ((s / 2.0).round() as usize).max(1);
        let mut best = vec![(0u32, NONE); wu * hu];
        for c in 0..pal.len() {
            let m: Vec<bool> = lbl.iter().map(|&l| l == c as u8).collect();
            let cnt = box_count(&m, wu, hu, r);
            for i in 0..wu * hu {
                if lbl[i] != NONE && cnt[i] > best[i].0 {
                    best[i] = (cnt[i], c as u8);
                }
            }
        }
        for i in 0..wu * hu {
            if lbl[i] != NONE {
                lbl[i] = best[i].1;
            }
        }
    }
    let mut area = vec![0usize; pal.len()];
    for &l in &lbl {
        if l != NONE {
            area[l as usize] += 1;
        }
    }
    // Sfondo trasparente: via il colore che tocca di più i bordi
    if o.transparent {
        let mut border = vec![0usize; pal.len()];
        for x in 0..wu {
            for y in [0, hu - 1] {
                let l = lbl[y * wu + x];
                if l != NONE {
                    border[l as usize] += 1;
                }
            }
        }
        for y in 0..hu {
            for x in [0, wu - 1] {
                let l = lbl[y * wu + x];
                if l != NONE {
                    border[l as usize] += 1;
                }
            }
        }
        if let Some((bgc, _)) = border.iter().enumerate().max_by_key(|(_, c)| **c) {
            for l in lbl.iter_mut() {
                if *l == bgc as u8 {
                    *l = NONE;
                }
            }
            area[bgc] = 0;
        }
    }
    let any_none = lbl.iter().any(|&l| l == NONE);
    let mut order: Vec<usize> = (0..pal.len()).filter(|&i| area[i] > 0).collect();
    order.sort_by(|a, b| area[*b].cmp(&area[*a]));
    let mut rank = vec![usize::MAX; pal.len()];
    for (n, &i) in order.iter().enumerate() {
        rank[i] = n;
    }
    let fo = match mode {
        Mode::Photo => FitOpts { sigma: 0.7 * u, tol: 0.8 * u * tolk, corner_win: (1.5 * u).round().max(3.0) as usize, corner_deg: 55.0 },
        _ => FitOpts { sigma: 0.6 * u, tol: 0.6 * u * tolk, corner_win: (1.5 * u).round().max(3.0) as usize, corner_deg: 50.0 },
    };
    let rgb: Vec<[u8; 3]> = pal.iter().map(|c| lab_to_rgb(*c)).collect();
    let base_lab: Vec<[f32; 3]> = if o.gradients { base.pixels().map(|p| lut.lab(p.0[0], p.0[1], p.0[2])).collect() } else { vec![] };
    let dil = (2.0 * s).round().max(1.0) as usize;
    let mut body = String::new();
    let mut nshapes = 0;
    for (n, &c) in order.iter().enumerate() {
        if cancelled() {
            return Err("annullato".into());
        }
        progress(0.35 + 0.6 * n as f64 / order.len() as f64);
        let mut col = hex(rgb[c]);
        if let Some(g) = gradient_for(&lbl, &base_lab, wu, c as u8, s) {
            let id = format!("g{n}");
            let _ = write!(body, "<linearGradient id=\"{id}\" gradientUnits=\"userSpaceOnUse\" x1=\"{}\" y1=\"{}\" x2=\"{}\" y2=\"{}\"><stop offset=\"0\" stop-color=\"{}\"/><stop offset=\"1\" stop-color=\"{}\"/></linearGradient>",
                f.n(g.0 + 0.5), f.n(g.1 + 0.5), f.n(g.2 + 0.5), f.n(g.3 + 0.5), hex(g.4), hex(g.5));
            col = format!("url(#{id})");
        }
        if n == 0 && !any_none && !has_alpha {
            let _ = write!(body, "<rect width=\"{w}\" height=\"{h}\" fill=\"{col}\"/>");
            nshapes += 1;
            continue;
        }
        let own: Vec<bool> = lbl.iter().map(|&l| l == c as u8).collect();
        let near = dilate(&own, wu, hu, dil);
        let mask: Vec<bool> = (0..wu * hu).map(|i| own[i] || (near[i] && lbl[i] != NONE && rank[lbl[i] as usize] > n)).collect();
        let shapes = trace_mask(&mask, wu, hu, u, &fo, if any_none || has_alpha { 0 } else { (3.0 * u) as usize });
        if shapes.is_empty() {
            continue;
        }
        nshapes += shapes.len();
        let _ = write!(body, "<path fill=\"{col}\" fill-rule=\"evenodd\" d=\"{}\"/>", shapes_to_d(&shapes, &f));
    }
    progress(1.0);
    let svg = format!("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{w}\" height=\"{h}\" viewBox=\"0 0 {w} {h}\">{body}</svg>\n");
    Ok(Output { svg, mode, colors: order.len(), shapes: nshapes })
}

fn median_rgb(it: impl Iterator<Item = [u8; 3]>) -> [u8; 3] {
    let v: Vec<[u8; 3]> = it.collect();
    let mut out = [0u8; 3];
    for k in 0..3 {
        let mut c: Vec<u8> = v.iter().map(|p| p[k]).collect();
        c.sort();
        out[k] = c[c.len() / 2];
    }
    out
}

/// Il colore della carta punto per punto: massimo locale, poi media (toglie le ombre e la luce non uniforme).
fn background(g: &[f32], w: usize, h: usize, r: usize) -> Vec<f32> {
    let mx = |src: &[f32], horiz: bool| -> Vec<f32> {
        let mut out = vec![0.0; w * h];
        for y in 0..h {
            for x in 0..w {
                let mut m = 0.0f32;
                if horiz {
                    for xx in x.saturating_sub(r)..(x + r + 1).min(w) {
                        m = m.max(src[y * w + xx]);
                    }
                } else {
                    for yy in y.saturating_sub(r)..(y + r + 1).min(h) {
                        m = m.max(src[yy * w + x]);
                    }
                }
                out[y * w + x] = m;
            }
        }
        out
    };
    let m = mx(&mx(g, true), false);
    // media su riquadro (immagine integrale)
    let mut ii = vec![0f64; (w + 1) * (h + 1)];
    for y in 0..h {
        let mut row = 0f64;
        for x in 0..w {
            row += m[y * w + x] as f64;
            ii[(y + 1) * (w + 1) + x + 1] = ii[y * (w + 1) + x + 1] + row;
        }
    }
    let mut out = vec![0f32; w * h];
    for y in 0..h {
        let (y0, y1) = (y.saturating_sub(r), (y + r + 1).min(h));
        for x in 0..w {
            let (x0, x1) = (x.saturating_sub(r), (x + r + 1).min(w));
            let s = ii[y1 * (w + 1) + x1] + ii[y0 * (w + 1) + x0] - ii[y0 * (w + 1) + x1] - ii[y1 * (w + 1) + x0];
            out[y * w + x] = (s / ((y1 - y0) * (x1 - x0)) as f64) as f32;
        }
    }
    out
}

/// Pixel art (immagini minuscole con pochi colori esatti): quadratini netti, uniti riga per riga.
fn pixel_art(img: &RgbaImage) -> Option<Output> {
    let (w, h) = img.dimensions();
    if w.max(h) > 96 {
        return None;
    }
    let mut cols: Vec<[u8; 3]> = vec![];
    for p in img.pixels() {
        if p.0[3] < 128 {
            continue;
        }
        let c = [p.0[0], p.0[1], p.0[2]];
        if !cols.contains(&c) {
            cols.push(c);
            if cols.len() > 64 {
                return None;
            }
        }
    }
    let mut body = String::new();
    let mut shapes = 0;
    for c in &cols {
        let mut d = String::new();
        for y in 0..h {
            let mut x = 0;
            while x < w {
                let p = img.get_pixel(x, y).0;
                if p[3] >= 128 && [p[0], p[1], p[2]] == *c {
                    let x0 = x;
                    while x < w && { let q = img.get_pixel(x, y).0; q[3] >= 128 && [q[0], q[1], q[2]] == *c } {
                        x += 1;
                    }
                    let _ = write!(d, "M{x0} {y}h{}v1h-{}z", x - x0, x - x0);
                    shapes += 1;
                } else {
                    x += 1;
                }
            }
        }
        let _ = write!(body, "<path fill=\"{}\" d=\"{d}\"/>", hex(*c));
    }
    let svg = format!("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{w}\" height=\"{h}\" viewBox=\"0 0 {w} {h}\" shape-rendering=\"crispEdges\">{body}</svg>\n");
    Some(Output { svg, mode: Mode::Logo, colors: cols.len(), shapes })
}

/// Una sfumatura lineare per lo strato `c`, se il colore dentro cambia davvero in modo regolare.
/// Ritorna (x1, y1, x2, y2) in coordinate di lavoro e i due colori agli estremi.
fn gradient_for(lbl: &[u8], lab: &[[f32; 3]], w: usize, c: u8, _s: f64) -> Option<(f64, f64, f64, f64, [u8; 3], [u8; 3])> {
    if lab.is_empty() {
        return None;
    }
    let idx: Vec<usize> = (0..lbl.len()).filter(|&i| lbl[i] == c).collect();
    if idx.len() < 400 {
        return None;
    }
    let step = (idx.len() / 30_000).max(1);
    let pts: Vec<(f64, f64, [f64; 3])> = idx.iter().step_by(step).map(|&i| ((i % w) as f64, (i / w) as f64, [lab[i][0] as f64, lab[i][1] as f64, lab[i][2] as f64])).collect();
    let n = pts.len() as f64;
    let (mx, my) = (pts.iter().map(|p| p.0).sum::<f64>() / n, pts.iter().map(|p| p.1).sum::<f64>() / n);
    let mut mean = [0.0; 3];
    for p in &pts {
        for k in 0..3 {
            mean[k] += p.2[k] / n;
        }
    }
    // minimi quadrati: colore = media + G · (x - mx, y - my)
    let (mut sxx, mut sxy, mut syy) = (0.0, 0.0, 0.0);
    let mut sxc = [0.0; 3];
    let mut syc = [0.0; 3];
    for p in &pts {
        let (dx, dy) = (p.0 - mx, p.1 - my);
        sxx += dx * dx;
        sxy += dx * dy;
        syy += dy * dy;
        for k in 0..3 {
            sxc[k] += dx * (p.2[k] - mean[k]);
            syc[k] += dy * (p.2[k] - mean[k]);
        }
    }
    let det = sxx * syy - sxy * sxy;
    if det.abs() < 1e-9 {
        return None;
    }
    let mut g = [[0.0f64; 2]; 3];
    for k in 0..3 {
        g[k][0] = (sxc[k] * syy - syc[k] * sxy) / det;
        g[k][1] = (syc[k] * sxx - sxc[k] * sxy) / det;
    }
    // direzione in cui il colore cambia di più
    let (a, b, d) = (
        (0..3).map(|k| g[k][0] * g[k][0]).sum::<f64>(),
        (0..3).map(|k| g[k][0] * g[k][1]).sum::<f64>(),
        (0..3).map(|k| g[k][1] * g[k][1]).sum::<f64>(),
    );
    let th = 0.5 * (2.0 * b).atan2(a - d);
    let (ux, uy) = (th.cos(), th.sin());
    // errore senza e con la sfumatura
    let (mut e0, mut e1) = (0.0, 0.0);
    let mut ts: Vec<f64> = Vec::with_capacity(pts.len());
    for p in &pts {
        let (dx, dy) = (p.0 - mx, p.1 - my);
        let t = dx * ux + dy * uy;
        ts.push(t);
        let mut s0 = 0.0;
        let mut s1 = 0.0;
        for k in 0..3 {
            let pred = mean[k] + (g[k][0] * ux + g[k][1] * uy) * t;
            s0 += (p.2[k] - mean[k]).powi(2);
            s1 += (p.2[k] - pred).powi(2);
        }
        e0 += s0;
        e1 += s1;
    }
    ts.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let (t0, t1) = (ts[(ts.len() as f64 * 0.02) as usize], ts[((ts.len() as f64 * 0.98) as usize).min(ts.len() - 1)]);
    let at = |t: f64| -> [f32; 3] { let mut c = [0f32; 3]; for k in 0..3 { c[k] = (mean[k] + (g[k][0] * ux + g[k][1] * uy) * t) as f32; } c };
    let (c0, c1) = (at(t0), at(t1));
    let range = d2(&c0, &c1).sqrt();
    if range < 7.0 || e1 > 0.6 * e0 {
        return None;
    }
    Some((mx + ux * t0, my + uy * t0, mx + ux * t1, my + uy * t1, lab_to_rgb(c0), lab_to_rgb(c1)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(img: RgbaImage, mode: Mode) -> Output {
        let o = Opts { mode, ..Default::default() };
        vectorize(&DynamicImage::ImageRgba8(img), None, &o, &mut |_| {}, &|| false).unwrap()
    }

    #[test]
    fn forma_piena_resta_piena() {
        // Un rettangolo pieno su bianco: un solo tracciato, senza buco dentro
        let img = RgbaImage::from_fn(120, 80, |x, y| if (20..100).contains(&x) && (15..65).contains(&y) { image::Rgba([30, 80, 120, 255]) } else { image::Rgba([255, 255, 255, 255]) });
        let out = run(img, Mode::Auto);
        assert_eq!(out.svg.matches('M').count(), 1, "{}", out.svg);
    }

    #[test]
    fn logo_a_colori_con_cerchio() {
        let img = RgbaImage::from_fn(300, 200, |x, y| {
            let (dx, dy) = (x as f64 - 150.0, y as f64 - 100.0);
            if dx * dx + dy * dy < 3600.0 { image::Rgba([240, 180, 50, 255]) } else if (40..260).contains(&x) && (20..180).contains(&y) { image::Rgba([30, 80, 120, 255]) } else { image::Rgba([255, 255, 255, 255]) }
        });
        let out = run(img, Mode::Logo);
        assert_eq!(out.colors, 3);
        assert!(out.svg.contains("<rect"), "lo sfondo è un rettangolo");
        assert!(out.svg.contains('A'), "il cerchio è un cerchio vero: {}", out.svg);
    }

    #[test]
    fn trasparenza_rispettata() {
        let img = RgbaImage::from_fn(100, 100, |x, y| if (30..70).contains(&x) && (30..70).contains(&y) { image::Rgba([200, 30, 30, 255]) } else { image::Rgba([0, 0, 0, 0]) });
        let out = run(img, Mode::Logo);
        assert!(!out.svg.contains("<rect"), "niente sfondo dove era trasparente: {}", out.svg);
        assert_eq!(out.colors, 1);
    }

    #[test]
    fn pixel_art_a_quadratini() {
        let img = RgbaImage::from_fn(8, 8, |x, y| if (x + y) % 2 == 0 { image::Rgba([0, 0, 0, 255]) } else { image::Rgba([255, 255, 255, 255]) });
        let out = run(img, Mode::Auto);
        assert!(out.svg.contains("crispEdges"));
        assert_eq!(out.colors, 2);
    }
}
