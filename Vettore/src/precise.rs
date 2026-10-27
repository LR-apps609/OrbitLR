//! «Precisione massima»: il ricalco lento, come a mano.
//!
//! Nei pixel di bordo l'immagine ha le sfumature: un pixel metà blu e metà bianco dice che il bordo passa
//! a metà del pixel. Da ogni pixel si ricava quanto «appartiene» a una forma (0…1): il bordo vero è dove
//! questa copertura vale 0,5, e si trova con una precisione molto più fine di un pixel (linee di livello).
//! Poi ogni curva viene ridisegnata e confrontata di nuovo con l'immagine, punto per punto: ogni punto della
//! curva si sposta dove la copertura vale esattamente 0,5 e la curva si ricalcola; si ripete finché non si
//! muove più (o finché c'è tempo).

use crate::fit::{self, FitOpts, Seg, Shape, P};

/// Un campo di copertura (0…1) su una griglia, con i valori al centro dei pixel.
pub struct Field<'a> {
    pub v: &'a [f32],
    pub w: usize,
    pub h: usize,
}

impl Field<'_> {
    fn at(&self, x: isize, y: isize) -> f32 {
        let x = x.clamp(0, self.w as isize - 1) as usize;
        let y = y.clamp(0, self.h as isize - 1) as usize;
        self.v[y * self.w + x]
    }

    /// Valore interpolato (bilineare) nel punto `p` (coordinate in pixel, il centro del pixel i è i + 0,5).
    pub fn sample(&self, p: P) -> f64 {
        let (fx, fy) = (p.x - 0.5, p.y - 0.5);
        let (x0, y0) = (fx.floor(), fy.floor());
        let (tx, ty) = (fx - x0, fy - y0);
        let (x0, y0) = (x0 as isize, y0 as isize);
        let a = self.at(x0, y0) as f64;
        let b = self.at(x0 + 1, y0) as f64;
        let c = self.at(x0, y0 + 1) as f64;
        let d = self.at(x0 + 1, y0 + 1) as f64;
        (a * (1.0 - tx) + b * tx) * (1.0 - ty) + (c * (1.0 - tx) + d * tx) * ty
    }

    fn grad(&self, p: P) -> P {
        let e = 0.5;
        P::new(
            (self.sample(P::new(p.x + e, p.y)) - self.sample(P::new(p.x - e, p.y))) / (2.0 * e),
            (self.sample(P::new(p.x, p.y + e)) - self.sample(P::new(p.x, p.y - e))) / (2.0 * e),
        )
    }

    /// Il punto del bordo vero (copertura 0,5) più vicino a `p`, cercato lungo la pendenza; al massimo `max` pixel.
    pub fn snap(&self, p: P, max: f64) -> Option<P> {
        let mut q = p;
        for _ in 0..6 {
            let f = self.sample(q) - 0.5;
            let g = self.grad(q);
            let gg = g.x * g.x + g.y * g.y;
            if gg < 1e-6 {
                return None;
            }
            let step = (-f / gg).clamp(-0.75, 0.75);
            q = P::new(q.x + g.x * step, q.y + g.y * step);
            if f.abs() < 0.01 {
                break;
            }
        }
        let d = ((q.x - p.x).powi(2) + (q.y - p.y).powi(2)).sqrt();
        (d <= max && (self.sample(q) - 0.5).abs() < 0.12).then_some(q)
    }
}

/// Le linee di livello 0,5 del campo (marching squares), chiuse; `v` già con il bordo esterno a 0.
pub fn iso_contours(v: &[f32], w: usize, h: usize) -> Vec<Vec<P>> {
    use std::collections::HashMap;
    // chiave di un lato: (orizzontale?, x, y) — orizzontale tra (x,y) e (x+1,y), verticale tra (x,y) e (x,y+1)
    type Key = (bool, usize, usize);
    let val = |x: usize, y: usize| v[y * w + x];
    let inside = |x: usize, y: usize| val(x, y) >= 0.5;
    let cross = |x0: usize, y0: usize, x1: usize, y1: usize| -> P {
        let (a, b) = (val(x0, y0) as f64, val(x1, y1) as f64);
        let t = if (b - a).abs() > 1e-9 { ((0.5 - a) / (b - a)).clamp(0.0, 1.0) } else { 0.5 };
        P::new(x0 as f64 + 0.5 + t * (x1 as f64 - x0 as f64), y0 as f64 + 0.5 + t * (y1 as f64 - y0 as f64))
    };
    let mut next: HashMap<Key, (Key, P)> = HashMap::new();
    for y in 0..h.saturating_sub(1) {
        for x in 0..w.saturating_sub(1) {
            let (a, b, c, d) = (inside(x, y), inside(x + 1, y), inside(x + 1, y + 1), inside(x, y + 1));
            if a == b && b == c && c == d {
                continue;
            }
            // giro in senso orario: sopra (a→b), destra (b→c), sotto (c→d), sinistra (d→a)
            let edges: [(bool, bool, Key, (usize, usize, usize, usize)); 4] = [
                (a, b, (true, x, y), (x, y, x + 1, y)),
                (b, c, (false, x + 1, y), (x + 1, y, x + 1, y + 1)),
                (c, d, (true, x, y + 1), (x, y + 1, x + 1, y + 1)),
                (d, a, (false, x, y), (x, y, x, y + 1)),
            ];
            let mut cr: Vec<(bool, Key, P)> = vec![]; // (entra?, lato, punto)
            for (s, e, k, (x0, y0, x1, y1)) in edges {
                if s != e {
                    cr.push((!s && e, k, cross(x0, y0, x1, y1)));
                }
            }
            let center = (val(x, y) + val(x + 1, y) + val(x + 1, y + 1) + val(x, y + 1)) / 4.0 >= 0.5;
            let n = cr.len();
            for i in 0..n {
                if !cr[i].0 {
                    continue;
                }
                let j = if center { (i + n - 1) % n } else { (i + 1) % n };
                next.insert(cr[i].1, (cr[j].1, cr[i].2));
            }
        }
    }
    let mut out = vec![];
    // in ordine fisso: lo stesso file dà sempre lo stesso SVG
    let mut keys: Vec<Key> = next.keys().copied().collect();
    keys.sort_by_key(|k| (k.2, k.1, k.0));
    let mut used: std::collections::HashSet<Key> = std::collections::HashSet::new();
    for k0 in keys {
        if used.contains(&k0) {
            continue;
        }
        let mut pts = vec![];
        let mut k = k0;
        loop {
            if !used.insert(k) {
                break;
            }
            let Some(&(nk, p)) = next.get(&k) else { break };
            pts.push(p);
            k = nk;
            if k == k0 {
                break;
            }
        }
        if pts.len() >= 3 {
            out.push(pts);
        }
    }
    out
}

fn sub(a: P, b: P) -> P {
    P::new(a.x - b.x, a.y - b.y)
}
fn len(a: P) -> f64 {
    a.x.hypot(a.y)
}
fn bez(c: [P; 4], t: f64) -> P {
    let mt = 1.0 - t;
    let k = [mt * mt * mt, 3.0 * mt * mt * t, 3.0 * mt * t * t, t * t * t];
    P::new(k[0] * c[0].x + k[1] * c[1].x + k[2] * c[2].x + k[3] * c[3].x, k[0] * c[0].y + k[1] * c[1].y + k[2] * c[2].y + k[3] * c[3].y)
}

/// Rifà una cubica (estremi fissi) che passa il più vicino possibile ai punti `q` ai parametri `u`.
fn refit_cubic(p0: P, p3: P, q: &[(f64, P)]) -> Option<(P, P)> {
    // minimi quadrati sui due punti di controllo interni (4 incognite, due sistemi 2×2 indipendenti per x e y)
    let (mut a11, mut a12, mut a22) = (0.0, 0.0, 0.0);
    let (mut bx1, mut bx2, mut by1, mut by2) = (0.0, 0.0, 0.0, 0.0);
    for &(t, pt) in q {
        let mt = 1.0 - t;
        let (b0, b1, b2, b3) = (mt * mt * mt, 3.0 * mt * mt * t, 3.0 * mt * t * t, t * t * t);
        a11 += b1 * b1;
        a12 += b1 * b2;
        a22 += b2 * b2;
        let rx = pt.x - b0 * p0.x - b3 * p3.x;
        let ry = pt.y - b0 * p0.y - b3 * p3.y;
        bx1 += b1 * rx;
        bx2 += b2 * rx;
        by1 += b1 * ry;
        by2 += b2 * ry;
    }
    let det = a11 * a22 - a12 * a12;
    if det.abs() < 1e-9 {
        return None;
    }
    Some((
        P::new((bx1 * a22 - bx2 * a12) / det, (by1 * a22 - by2 * a12) / det),
        P::new((a11 * bx2 - a12 * bx1) / det, (a11 * by2 - a12 * by1) / det),
    ))
}

/// Il ricalco: `iters` passate in cui ogni curva si avvicina al bordo vero.
pub fn refine(shape: &mut Shape, f: &Field, iters: usize, max_move: f64) {
    match shape {
        Shape::Circle { cx, cy, r } => {
            for _ in 0..iters {
                let n = ((*r * std::f64::consts::TAU) as usize).clamp(24, 2000);
                let pts: Vec<P> = (0..n)
                    .filter_map(|i| {
                        let a = i as f64 / n as f64 * std::f64::consts::TAU;
                        f.snap(P::new(*cx + *r * a.cos(), *cy + *r * a.sin()), max_move)
                    })
                    .collect();
                if pts.len() < n / 2 {
                    return;
                }
                let (x, y, rr, _) = fit::circle_of(&pts);
                *cx = x;
                *cy = y;
                *r = rr;
            }
        }
        Shape::Path { start, segs } => {
            let n = segs.len();
            if n == 0 {
                return;
            }
            for _ in 0..iters {
                let mut v: Vec<P> = segs.iter().map(fit::seg_end).collect();
                let prev_of = |v: &Vec<P>, i: usize| if i == 0 { v[n - 1] } else { v[i - 1] };
                // direzioni in uscita e in entrata di ogni tratto (per sapere quali vertici sono angoli)
                let dir_out = |s: &Seg, a: P| -> P { match s { Seg::Line(p) => unit(sub(*p, a)), Seg::Cubic(c1, _, p) => unit(if len(sub(*c1, a)) > 1e-6 { sub(*c1, a) } else { sub(*p, a) }) } };
                let dir_in = |s: &Seg, a: P| -> P { match s { Seg::Line(p) => unit(sub(*p, a)), Seg::Cubic(_, c2, p) => unit(if len(sub(*p, *c2)) > 1e-6 { sub(*p, *c2) } else { sub(*p, a) }) } };
                // 1) le linee: la retta migliore sui punti del bordo vero
                let mut lines: Vec<Option<(P, P)>> = vec![None; n];
                for i in 0..n {
                    if let Seg::Line(p) = segs[i] {
                        let a = prev_of(&v, i);
                        let l = len(sub(p, a));
                        let m = (l as usize).clamp(6, 600);
                        let q: Vec<P> = (1..m).filter_map(|k| {
                            let t = 0.08 + 0.84 * k as f64 / m as f64;
                            f.snap(P::new(a.x + (p.x - a.x) * t, a.y + (p.y - a.y) * t), max_move)
                        }).collect();
                        if q.len() >= 4 {
                            lines[i] = Some(fit::line_of(&q));
                        }
                    }
                }
                // 2) i vertici: tra due linee → il loro incrocio (angolo netto); dove la curva prosegue morbida → sul bordo vero
                let mut nv = v.clone();
                for i in 0..n {
                    let j = (i + 1) % n;
                    let din = dir_in(&segs[i], prev_of(&v, i));
                    let dout = dir_out(&segs[j], v[i]);
                    let smooth = din.x * dout.x + din.y * dout.y > 0.94;
                    if let (Some(l1), Some(l2)) = (lines[i], lines[j]) {
                        if !smooth {
                            if let Some(x) = intersect(l1, l2) {
                                if len(sub(x, v[i])) <= 2.0 * max_move {
                                    nv[i] = x;
                                }
                            }
                            continue;
                        }
                    }
                    if smooth {
                        if let Some(q) = f.snap(v[i], max_move) {
                            nv[i] = q;
                        }
                    } else if let Some(l) = lines[i].or(lines[j]) {
                        nv[i] = project(l, v[i]);
                    }
                }
                v = nv;
                // 3) le curve: ridisegnate sui punti del bordo vero, con gli estremi nuovi
                let mut prev = v[n - 1];
                for (i, s) in segs.iter_mut().enumerate() {
                    let end = v[i];
                    match s {
                        Seg::Cubic(c1, c2, p) => {
                            let o4 = [prev, *c1, *c2, end];
                            let l = len(sub(o4[3], o4[0])) + len(sub(o4[1], o4[0])) + len(sub(o4[2], o4[3]));
                            let m = (l as usize).clamp(8, 600);
                            let q: Vec<(f64, P)> = (1..m).filter_map(|k| {
                                let t = k as f64 / m as f64;
                                f.snap(bez(o4, t), max_move).map(|pt| (t, pt))
                            }).collect();
                            if q.len() >= 4 {
                                if let Some((n1, n2)) = refit_cubic(prev, end, &q) {
                                    *c1 = n1;
                                    *c2 = n2;
                                }
                            }
                            *p = end;
                        }
                        Seg::Line(p) => *p = end,
                    }
                    prev = end;
                }
                *start = v[n - 1];
            }
        }
    }
}

fn unit(a: P) -> P {
    let l = len(a);
    if l > 1e-12 { P::new(a.x / l, a.y / l) } else { a }
}

/// Incrocio di due rette (punto, direzione).
fn intersect(a: (P, P), b: (P, P)) -> Option<P> {
    let (p, r) = a;
    let (q, s) = b;
    let den = r.x * s.y - r.y * s.x;
    if den.abs() < 1e-6 {
        return None;
    }
    let t = ((q.x - p.x) * s.y - (q.y - p.y) * s.x) / den;
    Some(P::new(p.x + r.x * t, p.y + r.y * t))
}

fn project(l: (P, P), x: P) -> P {
    let (p, d) = l;
    let t = (x.x - p.x) * d.x + (x.y - p.y) * d.y;
    P::new(p.x + d.x * t, p.y + d.y * t)
}

/// Imposta il ricalco preciso per un contorno già sub-pixel (linea di livello).
pub fn fit_opts(u: f64, tolk: f64) -> FitOpts {
    FitOpts { sigma: 0.35 * u, tol: 0.22 * u * tolk, corner_win: (1.5 * u).round().max(3.0) as usize, corner_deg: 45.0 }
}
