//! «Estrema»: si ottimizza l'SVG intero contro l'immagine originale.
//!
//! A ogni passata OrbitLR disegna l'SVG con i bordi sfumati veri (come un browser), lo confronta pixel per
//! pixel con l'originale e calcola come spostare insieme tutti i punti di tutte le curve, e i colori, per
//! ridurre la differenza (rasterizzazione differenziabile con campionamento dei bordi, come in DiffVG):
//! spostare un bordo cambia solo i pixel lì attorno, e la differenza tra il colore da una parte e dall'altra
//! del bordo, per l'errore in quel punto, dice in che verso conviene spostarlo. Si ripete finché migliora.

use crate::fit::{Seg, Shape, P};
use std::time::{Duration, Instant};
use tiny_skia::{Color, FillRule, GradientStop, LinearGradient, Paint, PathBuilder, Pixmap, Point, Rect, SpreadMode, Transform};

#[derive(Clone, Debug)]
pub enum Fill {
    Flat([f32; 3]),
    /// Da p0 a p1 (coordinate di lavoro), dal colore c0 al colore c1
    Linear { p0: P, p1: P, c0: [f32; 3], c1: [f32; 3] },
}

#[derive(Clone, Debug)]
pub struct Layer {
    pub fill: Fill,
    pub shapes: Vec<Shape>,
    /// Lo sfondo pieno (tutta l'immagine)
    pub rect: bool,
}

/// L'immagine da raggiungere, premoltiplicata, sRGB 0…1, alle dimensioni dell'originale.
pub struct Target {
    pub w: usize,
    pub h: usize,
    pub px: Vec<[f32; 4]>,
    /// Sfondo su cui si disegna (per i bianchi e neri: la carta), o trasparente
    pub bg: Option<[f32; 3]>,
}

fn rgb8(c: [f32; 3]) -> Color {
    Color::from_rgba8((c[0].clamp(0.0, 1.0) * 255.0).round() as u8, (c[1].clamp(0.0, 1.0) * 255.0).round() as u8, (c[2].clamp(0.0, 1.0) * 255.0).round() as u8, 255)
}

pub(crate) fn path_of(shapes: &[Shape], k: f64) -> Option<tiny_skia::Path> {
    let mut pb = PathBuilder::new();
    let q = |p: P| ((p.x * k) as f32, (p.y * k) as f32);
    for s in shapes {
        match s {
            Shape::Circle { cx, cy, r } => {
                if let Some(rc) = Rect::from_xywh(((cx - r) * k) as f32, ((cy - r) * k) as f32, (2.0 * r * k) as f32, (2.0 * r * k) as f32) {
                    pb.push_oval(rc);
                }
            }
            Shape::Path { start, segs } => {
                let (x, y) = q(*start);
                pb.move_to(x, y);
                for g in segs {
                    match g {
                        Seg::Line(p) => {
                            let (x, y) = q(*p);
                            pb.line_to(x, y);
                        }
                        Seg::Cubic(a, b, p) => {
                            let ((ax, ay), (bx, by), (px, py)) = (q(*a), q(*b), q(*p));
                            pb.cubic_to(ax, ay, bx, by, px, py);
                        }
                    }
                }
                pb.close();
            }
        }
    }
    pb.finish()
}

fn paint_for(fill: &Fill, k: f64) -> Paint<'static> {
    let mut paint = Paint { anti_alias: true, ..Default::default() };
    match fill {
        Fill::Flat(c) => paint.set_color(rgb8(*c)),
        Fill::Linear { p0, p1, c0, c1 } => {
            let sh = LinearGradient::new(
                Point::from_xy((p0.x * k) as f32, (p0.y * k) as f32),
                Point::from_xy((p1.x * k) as f32, (p1.y * k) as f32),
                vec![GradientStop::new(0.0, rgb8(*c0)), GradientStop::new(1.0, rgb8(*c1))],
                SpreadMode::Pad,
                Transform::identity(),
            );
            match sh {
                Some(s) => paint.shader = s,
                None => paint.set_color(rgb8(*c0)),
            }
        }
    }
    paint
}

/// Disegna gli strati alle dimensioni dell'originale; `k` porta dalle coordinate di lavoro a quelle dell'immagine.
pub fn render(layers: &[Layer], k: f64, t: &Target) -> Vec<[f32; 4]> {
    let mut pm = Pixmap::new(t.w as u32, t.h as u32).expect("immagine");
    if let Some(bg) = t.bg {
        pm.fill(rgb8(bg));
    }
    for l in layers {
        let paint = paint_for(&l.fill, k);
        if l.rect {
            if let Some(r) = Rect::from_xywh(0.0, 0.0, t.w as f32, t.h as f32) {
                pm.fill_rect(r, &paint, Transform::identity(), None);
            }
            continue;
        }
        if let Some(path) = path_of(&l.shapes, k) {
            pm.fill_path(&path, &paint, FillRule::EvenOdd, Transform::identity(), None);
        }
    }
    pm.data().chunks_exact(4).map(|c| [c[0] as f32 / 255.0, c[1] as f32 / 255.0, c[2] as f32 / 255.0, c[3] as f32 / 255.0]).collect()
}

fn sample(img: &[[f32; 4]], w: usize, h: usize, x: f64, y: f64) -> [f32; 4] {
    let (fx, fy) = (x - 0.5, y - 0.5);
    let (x0, y0) = (fx.floor(), fy.floor());
    let (tx, ty) = ((fx - x0) as f32, (fy - y0) as f32);
    let at = |xx: f64, yy: f64| -> [f32; 4] {
        let xi = (xx as isize).clamp(0, w as isize - 1) as usize;
        let yi = (yy as isize).clamp(0, h as isize - 1) as usize;
        img[yi * w + xi]
    };
    let (a, b, c, d) = (at(x0, y0), at(x0 + 1.0, y0), at(x0, y0 + 1.0), at(x0 + 1.0, y0 + 1.0));
    let mut o = [0f32; 4];
    for i in 0..4 {
        o[i] = (a[i] * (1.0 - tx) + b[i] * tx) * (1.0 - ty) + (c[i] * (1.0 - tx) + d[i] * tx) * ty;
    }
    o
}

pub fn loss(r: &[[f32; 4]], t: &Target) -> f64 {
    r.iter().zip(&t.px).map(|(a, b)| (0..4).map(|i| ((a[i] - b[i]) as f64).powi(2)).sum::<f64>()).sum::<f64>() / r.len() as f64
}

/// I parametri da muovere: per ogni forma, i suoi punti (in ordine) o il cerchio.
#[derive(Clone)]
struct Adam {
    m: Vec<f64>,
    v: Vec<f64>,
    t: i32,
}

impl Adam {
    fn new(n: usize) -> Adam {
        Adam { m: vec![0.0; n], v: vec![0.0; n], t: 0 }
    }
    /// Passo per ogni parametro (già limitato), dato il gradiente.
    fn step(&mut self, g: &[f64], lr: f64, max: f64) -> Vec<f64> {
        self.t += 1;
        let (b1, b2) = (0.9f64, 0.999f64);
        let mut out = vec![0.0; g.len()];
        for i in 0..g.len() {
            self.m[i] = b1 * self.m[i] + (1.0 - b1) * g[i];
            self.v[i] = b2 * self.v[i] + (1.0 - b2) * g[i] * g[i];
            let mh = self.m[i] / (1.0 - b1.powi(self.t));
            let vh = self.v[i] / (1.0 - b2.powi(self.t));
            out[i] = (-lr * mh / (vh.sqrt() + 1e-12)).clamp(-max, max);
        }
        out
    }
}

/// Punti di controllo di una forma, come lista piatta di coordinate (x, y, x, y…) o (cx, cy, r).
fn params_of(s: &Shape) -> Vec<f64> {
    match s {
        Shape::Circle { cx, cy, r } => vec![*cx, *cy, *r],
        Shape::Path { start, segs } => {
            let mut v = vec![start.x, start.y];
            for g in segs {
                match g {
                    Seg::Line(p) => v.extend([p.x, p.y]),
                    Seg::Cubic(a, b, p) => v.extend([a.x, a.y, b.x, b.y, p.x, p.y]),
                }
            }
            // l'ultimo punto coincide con l'inizio: lo si tiene uguale a «start»
            v
        }
    }
}

fn set_params(s: &mut Shape, v: &[f64]) {
    match s {
        Shape::Circle { cx, cy, r } => {
            *cx = v[0];
            *cy = v[1];
            *r = v[2].max(0.5);
        }
        Shape::Path { start, segs } => {
            *start = P::new(v[0], v[1]);
            let mut i = 2;
            for g in segs.iter_mut() {
                match g {
                    Seg::Line(p) => {
                        *p = P::new(v[i], v[i + 1]);
                        i += 2;
                    }
                    Seg::Cubic(a, b, p) => {
                        *a = P::new(v[i], v[i + 1]);
                        *b = P::new(v[i + 2], v[i + 3]);
                        *p = P::new(v[i + 4], v[i + 5]);
                        i += 6;
                    }
                }
            }
            // il tracciato si chiude: l'ultimo punto è l'inizio
            let st = *start;
            if let Some(last) = segs.last_mut() {
                match last {
                    Seg::Line(p) => *p = st,
                    Seg::Cubic(_, _, p) => *p = st,
                }
            }
        }
    }
}

/// Il gradiente della perdita rispetto ai parametri di una forma (coordinate di lavoro).
fn shape_grad(s: &Shape, r: &[[f32; 4]], e: &[[f32; 4]], w: usize, h: usize, k: f64) -> Vec<f64> {
    // quanto cambia la perdita spostando il bordo in `q` (coordinate dell'immagine) lungo la normale `n`
    let edge = |qx: f64, qy: f64, nx: f64, ny: f64| -> f64 {
        let hh = 0.75;
        let cm = sample(r, w, h, qx - nx * hh, qy - ny * hh);
        let cp = sample(r, w, h, qx + nx * hh, qy + ny * hh);
        let er = sample(e, w, h, qx, qy);
        // muovendo il bordo verso +n, lì il colore diventa quello del lato -n
        2.0 * (0..4).map(|i| (er[i] * (cm[i] - cp[i])) as f64).sum::<f64>()
    };
    match s {
        Shape::Circle { cx, cy, r: rad } => {
            let n = ((rad * k * std::f64::consts::TAU / 0.5) as usize).clamp(16, 4000);
            let mut g = vec![0.0; 3];
            let ds = rad * k * std::f64::consts::TAU / n as f64;
            for i in 0..n {
                let a = i as f64 / n as f64 * std::f64::consts::TAU;
                let (nx, ny) = (a.cos(), a.sin());
                let (qx, qy) = ((cx + rad * nx) * k, (cy + rad * ny) * k);
                let d = edge(qx, qy, nx, ny) * ds * k;
                g[0] += d * nx;
                g[1] += d * ny;
                g[2] += d;
            }
            g
        }
        Shape::Path { start, segs } => {
            let pv = params_of(s);
            let mut g = vec![0.0; pv.len()];
            let mut prev_idx = 0usize; // indice (in pv) del punto iniziale del tratto
            let mut prev = *start;
            let mut idx = 2usize;
            let nseg = segs.len();
            for (si, sg) in segs.iter().enumerate() {
                // l'ultimo tratto finisce su «start»: il gradiente del suo punto finale va lì
                let end_idx = |i: usize| if si == nseg - 1 { 0 } else { i };
                match sg {
                    Seg::Line(p) => {
                        let (d, len) = (P::new(p.x - prev.x, p.y - prev.y), ((p.x - prev.x).powi(2) + (p.y - prev.y).powi(2)).sqrt());
                        if len > 1e-9 {
                            let m = ((len * k / 0.5) as usize).clamp(2, 4000);
                            let (nx, ny) = (d.y / len, -d.x / len);
                            let ds = len * k / m as f64;
                            for j in 0..m {
                                let t = (j as f64 + 0.5) / m as f64;
                                let (px, py) = (prev.x + d.x * t, prev.y + d.y * t);
                                let v = edge(px * k, py * k, nx, ny) * ds * k;
                                g[prev_idx] += v * (1.0 - t) * nx;
                                g[prev_idx + 1] += v * (1.0 - t) * ny;
                                let ei = end_idx(idx);
                                g[ei] += v * t * nx;
                                g[ei + 1] += v * t * ny;
                            }
                        }
                        prev_idx = end_idx(idx);
                        prev = *p;
                        idx += 2;
                    }
                    Seg::Cubic(a, b, p) => {
                        let c = [prev, *a, *b, *p];
                        let approx = ((a.x - prev.x).hypot(a.y - prev.y) + (b.x - a.x).hypot(b.y - a.y) + (p.x - b.x).hypot(p.y - b.y)) * k;
                        let m = ((approx / 0.5) as usize).clamp(4, 4000);
                        let ids = [prev_idx, idx, idx + 2, end_idx(idx + 4)];
                        for j in 0..m {
                            let t = (j as f64 + 0.5) / m as f64;
                            let mt = 1.0 - t;
                            let bern = [mt * mt * mt, 3.0 * mt * mt * t, 3.0 * mt * t * t, t * t * t];
                            let pt = P::new((0..4).map(|q| bern[q] * c[q].x).sum(), (0..4).map(|q| bern[q] * c[q].y).sum());
                            let dx = 3.0 * mt * mt * (c[1].x - c[0].x) + 6.0 * mt * t * (c[2].x - c[1].x) + 3.0 * t * t * (c[3].x - c[2].x);
                            let dy = 3.0 * mt * mt * (c[1].y - c[0].y) + 6.0 * mt * t * (c[2].y - c[1].y) + 3.0 * t * t * (c[3].y - c[2].y);
                            let sp = dx.hypot(dy);
                            if sp < 1e-9 {
                                continue;
                            }
                            let (nx, ny) = (dy / sp, -dx / sp);
                            let ds = sp * k / m as f64;
                            let v = edge(pt.x * k, pt.y * k, nx, ny) * ds * k;
                            for q in 0..4 {
                                g[ids[q]] += v * bern[q] * nx;
                                g[ids[q] + 1] += v * bern[q] * ny;
                            }
                        }
                        prev_idx = end_idx(idx + 4);
                        prev = *p;
                        idx += 6;
                    }
                }
            }
            g
        }
    }
}

/// Dopo un passo: dove la curva era morbida (senza angolo), le maniglie tornano allineate.
fn keep_smooth(s: &mut Shape, smooth: &[bool]) {
    let Shape::Path { segs, .. } = s else { return };
    let n = segs.len();
    for i in 0..n {
        if !smooth.get(i).copied().unwrap_or(false) {
            continue;
        }
        let j = (i + 1) % n;
        let v = crate::fit::seg_end(&segs[i]);
        let (Seg::Cubic(_, a, _), Seg::Cubic(b, _, _)) = (&segs[i], &segs[j]) else { continue };
        let (a, b) = (*a, *b);
        let (dx, dy) = (b.x - a.x, b.y - a.y);
        let l = dx.hypot(dy);
        if l < 1e-9 {
            continue;
        }
        let (ux, uy) = (dx / l, dy / l);
        if let Seg::Cubic(_, bb, _) = &mut segs[i] {
            let len = (v.x - bb.x).hypot(v.y - bb.y);
            *bb = P::new(v.x - ux * len, v.y - uy * len);
        }
        if let Seg::Cubic(c1, _, _) = &mut segs[j] {
            let len = (c1.x - v.x).hypot(c1.y - v.y);
            *c1 = P::new(v.x + ux * len, v.y + uy * len);
        }
    }
}

fn smooth_joins(s: &Shape) -> Vec<bool> {
    let Shape::Path { start, segs } = s else { return vec![] };
    let n = segs.len();
    (0..n)
        .map(|i| {
            let j = (i + 1) % n;
            let v = crate::fit::seg_end(&segs[i]);
            let pin = match &segs[i] {
                Seg::Cubic(_, b, _) => *b,
                Seg::Line(_) => if i == 0 { *start } else { crate::fit::seg_end(&segs[i - 1]) },
            };
            let pout = match &segs[j] {
                Seg::Cubic(c1, _, _) => *c1,
                Seg::Line(p) => *p,
            };
            let (ax, ay) = (v.x - pin.x, v.y - pin.y);
            let (bx, by) = (pout.x - v.x, pout.y - v.y);
            let (la, lb) = (ax.hypot(ay), bx.hypot(by));
            // solo tra due curve (le linee restano linee e gli angoli restano angoli)
            let both_cubic = matches!(segs[i], Seg::Cubic(..)) && matches!(segs[j], Seg::Cubic(..));
            both_cubic && la > 1e-9 && lb > 1e-9 && (ax * bx + ay * by) / (la * lb) > 0.985
        })
        .collect()
}

/// Colori: il passo migliore per ogni strato a tinta unita, dato quanto ogni strato si vede in ogni pixel.
fn refit_colors(layers: &mut [Layer], k: f64, t: &Target, r: &[[f32; 4]]) {
    let n = t.w * t.h;
    // copertura di ogni strato (da solo), dall'alto verso il basso: quanto si vede = copertura × ciò che resta scoperto sopra
    let mut uncovered = vec![1.0f32; n];
    for li in (0..layers.len()).rev() {
        let mut pm = Pixmap::new(t.w as u32, t.h as u32).expect("immagine");
        let mut paint = Paint { anti_alias: true, ..Default::default() };
        paint.set_color(Color::WHITE);
        if layers[li].rect {
            if let Some(rc) = Rect::from_xywh(0.0, 0.0, t.w as f32, t.h as f32) {
                pm.fill_rect(rc, &paint, Transform::identity(), None);
            }
        } else if let Some(path) = path_of(&layers[li].shapes, k) {
            pm.fill_path(&path, &paint, FillRule::EvenOdd, Transform::identity(), None);
        }
        let cov: Vec<f32> = pm.data().chunks_exact(4).map(|c| c[3] as f32 / 255.0).collect();
        if let Fill::Flat(c) = &mut layers[li].fill {
            let (mut num, mut den) = ([0f64; 3], 0f64);
            for i in 0..n {
                let vis = (cov[i] * uncovered[i]) as f64;
                if vis < 1e-3 {
                    continue;
                }
                for ch in 0..3 {
                    num[ch] += vis * (r[i][ch] - t.px[i][ch]) as f64;
                }
                den += vis * vis;
            }
            if den > 4.0 {
                for ch in 0..3 {
                    c[ch] = (c[ch] as f64 - num[ch] / den).clamp(0.0, 1.0) as f32;
                }
            }
        }
        for i in 0..n {
            uncovered[i] *= 1.0 - cov[i];
        }
    }
}

/// L'ottimizzazione: al massimo `budget` di tempo o `max_iters` passate; ritorna la perdita prima e dopo.
/// `threads`: quanti core usare per i gradienti delle forme (ogni forma si calcola da sola).
pub fn optimize(layers: &mut [Layer], k: f64, t: &Target, max_iters: usize, budget: Duration, threads: usize, progress: &mut dyn FnMut(f64), cancelled: &dyn Fn() -> bool) -> (f64, f64) {
    let started = Instant::now();
    let w = t.w;
    let h = t.h;
    let smooth: Vec<Vec<Vec<bool>>> = layers.iter().map(|l| l.shapes.iter().map(smooth_joins).collect()).collect();
    let mut adam: Vec<Vec<Adam>> = layers.iter().map(|l| l.shapes.iter().map(|s| Adam::new(params_of(s).len())).collect()).collect();
    let mut r = render(layers, k, t);
    let first = loss(&r, t);
    let mut best = first;
    let mut best_layers: Vec<Layer> = layers.to_vec();
    let mut since_best = 0;
    // passo massimo per iterazione: mezzo pixel dell'immagine (in coordinate di lavoro)
    // (passi più fini alla fine abbassano ancora l'errore, ma piegano le curve sui pixel: provato, peggio)
    let max_step = 0.5 / k;
    let lr = 0.15 / k;
    for it in 0..max_iters {
        if cancelled() || started.elapsed() > budget {
            if std::env::var("VETTORE_DEBUG").is_ok() {
                eprintln!("  fermata a {it}: tempo {} annullato {}", started.elapsed() > budget, cancelled());
            }
            break;
        }
        let e: Vec<[f32; 4]> = r.iter().zip(&t.px).map(|(a, b)| [a[0] - b[0], a[1] - b[1], a[2] - b[2], a[3] - b[3]]).collect();
        {
            let mut jobs: Vec<(&mut Shape, &mut Adam, Option<&Vec<bool>>)> = vec![];
            for ((l, ad), sm) in layers.iter_mut().zip(adam.iter_mut()).zip(smooth.iter()) {
                if l.rect {
                    continue;
                }
                for (si, (s, a)) in l.shapes.iter_mut().zip(ad.iter_mut()).enumerate() {
                    jobs.push((s, a, sm.get(si)));
                }
            }
            let (r, e) = (&r, &e);
            let one = move |(s, a, sm): &mut (&mut Shape, &mut Adam, Option<&Vec<bool>>)| {
                let g = shape_grad(s, r, e, w, h, k);
                let step = a.step(&g, lr, max_step);
                let mut pv = params_of(s);
                for (p, d) in pv.iter_mut().zip(&step) {
                    *p += d;
                }
                set_params(s, &pv);
                if let Some(sm) = sm {
                    keep_smooth(s, sm);
                }
            };
            if threads <= 1 || jobs.len() < 2 * threads {
                jobs.iter_mut().for_each(one);
            } else {
                // a pezzi per peso (i nodi), così i core finiscono insieme
                let one = &one;
                let chunk = jobs.len().div_ceil(threads * 4);
                let mut parts: Vec<&mut [(&mut Shape, &mut Adam, Option<&Vec<bool>>)]> = jobs.chunks_mut(chunk).collect();
                let next = std::sync::atomic::AtomicUsize::new(0);
                let parts_ref: Vec<std::sync::Mutex<&mut [(&mut Shape, &mut Adam, Option<&Vec<bool>>)]>> = parts.drain(..).map(std::sync::Mutex::new).collect();
                std::thread::scope(|sc| {
                    for _ in 0..threads {
                        sc.spawn(|| {
                            crate::lower_priority();
                            loop {
                                let i = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                                let Some(p) = parts_ref.get(i) else { break };
                                p.lock().unwrap().iter_mut().for_each(one);
                            }
                        });
                    }
                });
            }
        }
        if it % 20 == 19 {
            refit_colors(layers, k, t, &r);
        }
        r = render(layers, k, t);
        let lnow = loss(&r, t);
        if lnow < best * 0.9995 {
            best = lnow;
            best_layers = layers.to_vec();
            since_best = 0;
        } else {
            since_best += 1;
            if since_best > 60 {
                break;
            }
        }
        // avanzamento: di solito si ferma entro qualche centinaio di passate
        progress((it as f64 / 400.0).max(started.elapsed().as_secs_f64() / budget.as_secs_f64()).min(0.98));
    }
    if std::env::var("VETTORE_DEBUG").is_ok() {
        eprintln!("  ottimizzazione: {first:.6} → {best:.6}, {:.1} s", started.elapsed().as_secs_f64());
    }
    layers.clone_from_slice(&best_layers);
    (first, best)
}
